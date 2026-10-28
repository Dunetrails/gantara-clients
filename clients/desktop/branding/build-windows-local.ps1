#Requires -Version 5.1
<#
.SYNOPSIS
  Build the Gantara Windows sync-client installer locally (no GitHub Actions).

.DESCRIPTION
  Start WITHOUT git installed. This script:
    1. Installs prereqs including Git for Windows (plus Python 3.12, Inkscape,
       VS 2022 C++ Build Tools, GitHub CLI, 7-Zip)
    2. Prompts for GitHub login / PAT when needed (private Dunetrails repos)
    3. Clones this platform repo (branding) + nextcloud/desktop @ pinned tag
    4. Applies Gantara branding and runs Craft/NSIS (build-windows.ps1)

  Output: <Workspace>\desktop-windows-out\*.exe

.EXAMPLE
  # Elevated PowerShell — no git required first:
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Dunetrails/k8s-platform-ovh/main/clients/desktop/branding/build-windows-local.ps1" -OutFile $env:TEMP\dt-win-build.ps1
  Set-ExecutionPolicy -Scope Process Bypass -Force
  & $env:TEMP\dt-win-build.ps1

.EXAMPLE
  & $env:TEMP\dt-win-build.ps1 -Workspace D:\dt-build -PlatformRepo https://github.com/Dunetrails/k8s-platform-ovh.git
#>
[CmdletBinding()]
param(
    [string]$Workspace = $(Join-Path $env:USERPROFILE "dunetrails-desktop-build"),
    [string]$DesktopRef = "v35.0.0",
    # Empty: use the blueprint branches pinned in the tag's craftmaster.ini.
    [string]$CraftBlueprintBranch = "",
    [string]$PlatformRepo = "https://github.com/Dunetrails/k8s-platform-ovh.git",
    [string]$PlatformBranch = "main",
    # If this script already lives inside a checkout, reuse it instead of cloning.
    [string]$PlatformSrc = "",
    [switch]$SkipPrereqs,
    [switch]$SkipClone
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WithWinget {
    param([Parameter(Mandatory = $true)][string]$Id)
    if (-not (Ensure-Command winget)) {
        throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
    }
    Write-Host "    winget install $Id"
    & winget install -e --id $Id --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        # -1978335189 = already installed
        throw "winget install failed for $Id (exit $LASTEXITCODE)"
    }
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Get-GitBash {
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "C:\Program Files\Git\bin\bash.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Convert-ToGitBashPath([string]$WinPath) {
    # Avoid nested PowerShell quoting; map C:\foo -> /c/foo for Git Bash.
    $full = [System.IO.Path]::GetFullPath($WinPath)
    if ($full -match '^[A-Za-z]:\\') {
        $drive = $full.Substring(0, 1).ToLowerInvariant()
        $rest = $full.Substring(2) -replace '\\', '/'
        return "/$drive$rest"
    }
    return ($full -replace '\\', '/')
}

# git writes progress to stderr; with $ErrorActionPreference=Stop that becomes a
# terminating NativeCommandError even on success. Always use this helper.
function Invoke-Git {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$GitArgs
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git @GitArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Host $_.Exception.Message
            } else {
                Write-Host $_
            }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Ensure-GitHubAuth {
    param([string]$RepoUrl)

    Write-Step "GitHub authentication (needed for private Dunetrails repos)"
    if (-not (Ensure-Command gh)) {
        Write-Host "    GitHub CLI (gh) missing - installing..."
        Install-WithWinget -Id "GitHub.cli"
        Refresh-Path
    }
    if (-not (Ensure-Command git)) {
        throw "git missing after prereq install - open a new elevated PowerShell and re-run"
    }

    $status = & gh auth status 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Browser device login often times out on VMs. Use a classic PAT (repo scope)." -ForegroundColor Yellow
        Write-Host "Create one at: https://github.com/settings/tokens" -ForegroundColor Yellow
        Write-Host ""
        # GH_TOKEN in the environment blocks `gh auth login --with-token` from storing creds.
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        $plain = Read-Host "Paste GitHub PAT (blank = try browser anyway)"
        if ([string]::IsNullOrWhiteSpace($plain)) {
            & gh auth login -h github.com -p https -w
            if ($LASTEXITCODE -ne 0) { throw "gh auth login failed (timeout?) - re-run and paste a PAT" }
        } else {
            $plain | & gh auth login --with-token
            if ($LASTEXITCODE -ne 0) {
                throw "PAT login failed - create a classic PAT with 'repo' at https://github.com/settings/tokens"
            }
        }
    } else {
        Write-Host "    gh already authenticated"
        ($status.Trim() -split "`n" | Select-Object -First 6) | ForEach-Object { Write-Host "    $_" }
    }

    # Makes `git pull` / `git ls-remote` work without /dev/tty prompts.
    & gh auth setup-git
    $env:GIT_TERMINAL_PROMPT = "0"

    Write-Host "    probing $RepoUrl ..."
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $probe = & git ls-remote $RepoUrl HEAD 2>&1 | Out-String
        $probeCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($probeCode -ne 0) {
        Write-Host "Cannot read $RepoUrl yet - paste a PAT to re-authenticate." -ForegroundColor Yellow
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        $plain = Read-Host "Paste GitHub PAT"
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw "Still cannot access $RepoUrl (no PAT). Output: $probe"
        }
        $plain | & gh auth login --with-token
        & gh auth setup-git
        $ErrorActionPreference = "Continue"
        try {
            $probe = & git ls-remote $RepoUrl HEAD 2>&1 | Out-String
            $probeCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldEap
        }
        if ($probeCode -ne 0) { throw "Still cannot access $RepoUrl : $probe" }
    }
    Write-Host "    repo reachable"
}

function Ensure-Prereqs {
    Write-Step "Installing prerequisites (includes Git for Windows)"

    if (-not (Test-IsAdmin)) {
        Write-Host "This script installs Git, VS Build Tools, Inkscape, etc." -ForegroundColor Yellow
        Write-Host "Re-run from an elevated PowerShell (right-click -> Run as administrator)," -ForegroundColor Yellow
        Write-Host "or pass -SkipPrereqs if everything is already installed." -ForegroundColor Yellow
        $cont = Read-Host "Continue without elevation? [y/N]"
        if ($cont -notmatch '^[Yy]') { throw "Aborted - elevate or use -SkipPrereqs" }
    }

    if (-not (Ensure-Command winget)) {
        throw "winget is required. Install/update 'App Installer' from the Microsoft Store."
    }

    if (-not (Ensure-Command git) -or -not (Get-GitBash)) {
        Install-WithWinget -Id "Git.Git"
        Refresh-Path
        if (-not (Ensure-Command git)) {
            throw "git still not on PATH - open a new elevated PowerShell window and re-run this script"
        }
        if (-not (Get-GitBash)) {
            throw "Git Bash (bash.exe) missing after Git install - reinstall Git for Windows with defaults"
        }
    } else {
        Write-Host "    git OK"
        Write-Host "    Git Bash OK"
    }

    if (-not (Ensure-Command gh)) {
        Install-WithWinget -Id "GitHub.cli"
        Refresh-Path
    } else { Write-Host "    gh OK" }

    $pyOk = $false
    # Windows Store "python" stub exists on PATH, writes to stderr, and with
    # $ErrorActionPreference=Stop that aborts the script. Probe carefully.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            $ver = & py -3.12 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
            if ("$ver" -eq "3.12") { $pyOk = $true }
        }
        if (-not $pyOk) {
            $pyCmd = Get-Command python -ErrorAction SilentlyContinue
            if ($pyCmd -and $pyCmd.Source -and ($pyCmd.Source -notlike "*\WindowsApps\*")) {
                $ver = & $pyCmd.Source -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
                if ("$ver" -eq "3.12") { $pyOk = $true }
            }
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if (-not $pyOk) {
        Write-Host "    Installing Python 3.12 (ignore Microsoft Store python alias if present)..."
        Install-WithWinget -Id "Python.Python.3.12"
        Refresh-Path
        $ErrorActionPreference = "Continue"
        try {
            if (Get-Command py -ErrorAction SilentlyContinue) {
                $prefix = & py -3.12 -c 'import sys; print(sys.base_prefix)' 2>$null
                if ($prefix) { $env:Path = "$prefix;$prefix\Scripts;$env:Path" }
            }
        } finally {
            $ErrorActionPreference = $oldEap
        }
    } else { Write-Host "    python 3.12 OK" }

    $inkscapeCandidates = @(
        (Join-Path $env:ProgramFiles "Inkscape\bin\inkscape.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inkscape\bin\inkscape.exe")
    )
    $inkscape = $inkscapeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $inkscape) {
        Install-WithWinget -Id "Inkscape.Inkscape"
        Refresh-Path
    } else { Write-Host "    Inkscape OK ($inkscape)" }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $hasMsvc = $false
    $inst = $null
    if (Test-Path -LiteralPath $vswhere) {
        $inst = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($inst) { $hasMsvc = $true }
    }
    if (-not $hasMsvc) {
        Write-Host "    Installing Visual Studio 2022 Build Tools (C++). This is large (~6-10 GB)..." -ForegroundColor Yellow
        & winget install -e --id Microsoft.VisualStudio.2022.BuildTools --accept-package-agreements --accept-source-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            Write-Host "    winget VS install returned $LASTEXITCODE - if Build Tools are present, continue; else install from https://aka.ms/vs/17/release/vs_BuildTools.exe" -ForegroundColor Yellow
        }
        Refresh-Path
    } else {
        Write-Host "    VS C++ tools OK ($inst)"
    }

    $sevenZip = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
    if (-not (Ensure-Command 7z) -and -not (Test-Path -LiteralPath $sevenZip)) {
        Install-WithWinget -Id "7zip.7zip"
        Refresh-Path
    }

    Write-Host "    prereqs look good"
}

function Test-PlatformTree([string]$Root) {
    return (Test-Path (Join-Path $Root "clients\desktop\branding\build-windows.ps1")) -and
           (Test-Path (Join-Path $Root "clients\desktop\branding\apply-branding.sh")) -and
           (Test-Path (Join-Path $Root "clients\desktop\branding\assets\logo.ico"))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  Gantara Windows sync-client local build" -ForegroundColor Green
Write-Host "  Workspace : $Workspace" -ForegroundColor Green
Write-Host "  Desktop   : nextcloud/desktop @$DesktopRef" -ForegroundColor Green
Write-Host "  Blueprints: $(if ($CraftBlueprintBranch) { $CraftBlueprintBranch } else { 'from craftmaster.ini' })" -ForegroundColor Green
Write-Host "  No prior git install required - this script installs Git and the rest." -ForegroundColor Green
Write-Host "  Disk: plan for 50+ GB free. First Craft run can take 1-2 hours." -ForegroundColor Green
Write-Host ""

if (-not $SkipPrereqs) {
    Ensure-Prereqs
} else {
    Write-Step "Skipping prereq installs (-SkipPrereqs)"
    if (-not (Ensure-Command git)) { throw "git not found (required even with -SkipPrereqs)" }
}

Refresh-Path
Ensure-GitHubAuth -RepoUrl $PlatformRepo

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
$Workspace = (Resolve-Path $Workspace).Path

# Resolve platform source (branding overlay). Prefer an existing checkout;
# otherwise clone. Running from a lone downloaded .ps1 is fine — we clone.
if (-not $PlatformSrc) {
    $here = $PSScriptRoot
    if ($here -and (Test-PlatformTree (Join-Path $here "..\..\.."))) {
        $PlatformSrc = (Resolve-Path (Join-Path $here "..\..\..")).Path
        Write-Step "Using existing platform checkout: $PlatformSrc"
    }
}

if (-not $PlatformSrc -or -not (Test-PlatformTree $PlatformSrc)) {
    $PlatformSrc = Join-Path $Workspace "platform"
    if (-not $SkipClone) {
        Write-Step "Clone platform branding repo (script installs/uses git for this)"
        if (Test-Path (Join-Path $PlatformSrc ".git")) {
            Push-Location $PlatformSrc
            if ((Invoke-Git fetch origin $PlatformBranch) -ne 0) { Pop-Location; throw "git fetch platform failed" }
            if ((Invoke-Git checkout $PlatformBranch) -ne 0) { Pop-Location; throw "git checkout platform failed" }
            if ((Invoke-Git pull --ff-only origin $PlatformBranch) -ne 0) { Pop-Location; throw "git pull platform failed" }
            Pop-Location
        } else {
            if (Test-Path $PlatformSrc) { Remove-Item -Recurse -Force $PlatformSrc }
            if ((Invoke-Git clone --branch $PlatformBranch --single-branch $PlatformRepo $PlatformSrc) -ne 0) {
                throw "git clone platform failed"
            }
        }
    }
}
$PlatformSrc = (Resolve-Path $PlatformSrc).Path
if (-not (Test-PlatformTree $PlatformSrc)) {
    throw "platform tree incomplete at $PlatformSrc (missing branding files)"
}

# If we started from a downloaded copy, re-launch the version from the clone so
# paths/$PSScriptRoot match the repo (logo.ico next to build-windows.ps1).
$canonical = Join-Path $PlatformSrc "clients\desktop\branding\build-windows-local.ps1"
$running = $null
if ($PSCommandPath) { $running = $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $running = $MyInvocation.MyCommand.Path }

if ($canonical -and (Test-Path -LiteralPath $canonical) -and $running) {
    $runFull = (Resolve-Path -LiteralPath $running).Path
    $canFull = (Resolve-Path -LiteralPath $canonical).Path
    if ($runFull -ne $canFull) {
        Write-Step "Re-launching from cloned repo: $canonical"
        $relaunchArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $canonical,
            "-Workspace", $Workspace,
            "-DesktopRef", $DesktopRef,
            "-PlatformRepo", $PlatformRepo,
            "-PlatformBranch", $PlatformBranch,
            "-PlatformSrc", $PlatformSrc,
            "-SkipPrereqs",
            "-SkipClone"
        )
        if ($CraftBlueprintBranch) { $relaunchArgs += @("-CraftBlueprintBranch", $CraftBlueprintBranch) }
        & powershell.exe @relaunchArgs
        exit $LASTEXITCODE
    }
}

$BrandScript = Join-Path $PlatformSrc "clients\desktop\branding\apply-branding.sh"
$BuildScript = Join-Path $PlatformSrc "clients\desktop\branding\build-windows.ps1"

$DesktopSrc = Join-Path $Workspace "desktop"
if (-not $SkipClone) {
    Write-Step "Clone nextcloud/desktop @$DesktopRef"
    if (Test-Path (Join-Path $DesktopSrc ".git")) {
        Push-Location $DesktopSrc
        if ((Invoke-Git fetch --tags origin) -ne 0) { Pop-Location; throw "git fetch desktop failed" }
        if ((Invoke-Git checkout $DesktopRef) -ne 0) { Pop-Location; throw "git checkout desktop failed" }
        if ((Invoke-Git submodule update --init --recursive) -ne 0) { Pop-Location; throw "git submodule update failed" }
        Pop-Location
    } else {
        if (Test-Path $DesktopSrc) { Remove-Item -Recurse -Force $DesktopSrc }
        $cloneCode = Invoke-Git clone --branch $DesktopRef --depth 1 --recurse-submodules https://github.com/nextcloud/desktop.git $DesktopSrc
        if ($cloneCode -ne 0) { throw "git clone nextcloud/desktop failed (exit $cloneCode)" }
    }
}
$DesktopSrc = (Resolve-Path $DesktopSrc).Path

Write-Step "Apply Gantara branding"
$bash = Get-GitBash
if (-not $bash) { throw "Git Bash not found" }
$desktopUnix = Convert-ToGitBashPath $DesktopSrc
$brandUnix = Convert-ToGitBashPath $BrandScript
& $bash -lc "bash '$brandUnix' '$desktopUnix'"
if ($LASTEXITCODE -ne 0) { throw "apply-branding.sh failed" }

Write-Step "Craft compile + NSIS package (long)"
if (Ensure-Command py) {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $py312 = & py -3.12 -c 'import sys; print(sys.executable)' 2>$null
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($py312 -and (Test-Path $py312)) {
        $env:Path = "$(Split-Path $py312);$(Split-Path $py312)\Scripts;$env:Path"
        Write-Host "    using $py312"
    }
}

& $BuildScript -DesktopSrc $DesktopSrc -Workspace $Workspace -BlueprintBranch $CraftBlueprintBranch
if ($LASTEXITCODE -ne 0) { throw "build-windows.ps1 failed" }

$outDir = Join-Path $Workspace "desktop-windows-out"
Write-Host ""
Write-Host "Build finished." -ForegroundColor Green
Write-Host "Installer(s): $outDir"
Get-ChildItem $outDir -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime
Write-Host ""
Write-Host "Install the .exe on this VM (SmartScreen -> More info -> Run anyway if unsigned)."
try { explorer.exe $outDir } catch {}
