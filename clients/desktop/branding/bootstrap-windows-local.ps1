#Requires -Version 5.1
<#
.SYNOPSIS
  Paste-safe entrypoint: install git+gh, clone platform, run local Windows build.

.DESCRIPTION
  Avoids Invoke-WebRequest of a raw *.ps1 URL (clipboard often turns the closing
  quote after .ps1 into %27/%22 and breaks PowerShell parsing).
#>
[CmdletBinding()]
param(
    [string]$Repo = "Dunetrails/k8s-platform-ovh",
    [string]$CloneDir = $(Join-Path $env:USERPROFILE "dunetrails-platform")
)

$ErrorActionPreference = "Stop"

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Ensure-WingetId([string]$Id) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install App Installer from the Microsoft Store."
    }
    Write-Host "winget install $Id"
    & winget install -e --id $Id --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget install failed for $Id (exit $LASTEXITCODE)"
    }
    Refresh-Path
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Ensure-WingetId "Git.Git"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Ensure-WingetId "GitHub.cli"
}
Refresh-Path

& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Browser device login often times out on VMs. Prefer a classic PAT (repo scope)." -ForegroundColor Yellow
    Write-Host "Create one at: https://github.com/settings/tokens" -ForegroundColor Yellow
    $pat = Read-Host "Paste GitHub PAT"
    if ([string]::IsNullOrWhiteSpace($pat)) {
        Write-Host "No PAT - trying browser login (complete within ~1 minute)..." -ForegroundColor Yellow
        & gh auth login -h github.com -p https -w
    } else {
        $pat | & gh auth login --with-token
    }
    if ($LASTEXITCODE -ne 0) { throw "gh auth login failed" }
}
& gh auth setup-git

if (Test-Path -LiteralPath $CloneDir) {
    Remove-Item -Recurse -Force -LiteralPath $CloneDir
}
Write-Host "Cloning $Repo -> $CloneDir"
& gh repo clone $Repo $CloneDir
if ($LASTEXITCODE -ne 0) { throw "gh repo clone failed" }

$build = Join-Path $CloneDir "clients\desktop\branding\build-windows-local.ps1"
if (-not (Test-Path -LiteralPath $build)) {
    throw "Missing $build after clone"
}

Set-ExecutionPolicy -Scope Process Bypass -Force
& $build -PlatformSrc $CloneDir
exit $LASTEXITCODE
