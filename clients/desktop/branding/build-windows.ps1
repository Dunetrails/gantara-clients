# Build an unsigned Gantara-branded Windows installer of nextcloud/desktop via
# KDE Craft — the same toolchain upstream's windows-build-and-test.yml uses.
#
# Prerequisites (workflow installs these):
#   - Python 3.12
#   - Inkscape (choco) for icon rasterisation
#   - apply-branding.sh already run against $DesktopSrc
#
# Signing is OFF (craftmaster.ini has SIGN_PACKAGE=False; we never set a cert).
# Output: NSIS installer under <craft-target>/tmp/ (NullsoftInstallerPackager).
#
# Usage:
#   build-windows.ps1 -DesktopSrc <path-to-branded-desktop> [-Workspace <root>]
#
# The blueprint repositories and branches come from the tag's craftmaster.ini,
# as in upstream CI. -BlueprintBranch overrides both branches.
#
param(
    [Parameter(Mandatory = $true)][string]$DesktopSrc,
    [string]$Workspace = $(if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path "$DesktopSrc\..").Path }),
    [string]$CraftTarget = "windows-msvc2022_64-cl",
    [string]$BlueprintBranch = "",
    [string]$DesktopRef = ""
)

$ErrorActionPreference = "Stop"
if (-not $DesktopRef) { $DesktopRef = [string]$env:DESKTOP_REF }
$Version = if ($DesktopRef) { $DesktopRef -replace '^v', '' } else { "" }

$DesktopSrc = (Resolve-Path $DesktopSrc).Path
$CraftMaster = Join-Path $Workspace "CraftMaster"
$CraftConfig = Join-Path $DesktopSrc "craftmaster.ini"
$NsisTemplateStaged = Join-Path $Workspace "$CraftTarget\tmp\dunetrails-brand\NullsoftInstaller.nsi"
$BrandingDir = $PSScriptRoot
# Brand identity comes from branding.env, the same file apply-branding.sh reads.
# Hardcoding it here let the two drift: the installer kept advertising a domain
# we no longer use long after the Linux build had moved on.
$BrandEnvFile = Join-Path $BrandingDir "branding.env"
if (-not (Test-Path $BrandEnvFile)) { throw "branding.env missing: $BrandEnvFile" }
$BrandEnv = @{}
foreach ($line in (Get-Content $BrandEnvFile)) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?([^"]*)"?\s*$') {
        $BrandEnv[$Matches[1]] = $Matches[2].Trim()
    }
}
function Get-BrandValue([string]$Key) {
    if (-not $BrandEnv.ContainsKey($Key) -or -not $BrandEnv[$Key]) {
        throw "branding.env does not define $Key"
    }
    return $BrandEnv[$Key]
}
$AppName = Get-BrandValue "APPLICATION_NAME"
# The name the client first shipped under; only used to move an old Start-menu folder.
$InstallId = Get-BrandValue "APPLICATION_SHORTNAME"
$AppExe = Get-BrandValue "APPLICATION_EXECUTABLE"
$Company = Get-BrandValue "APPLICATION_VENDOR"
$AppWebsite = Get-BrandValue "BRAND_SITE_URL"
$AppRevDomain = Get-BrandValue "APPLICATION_REV_DOMAIN"
$AppDescription = "$AppName Desktop Client"
$IconIco = (Resolve-Path (Join-Path $BrandingDir "assets\logo.ico")).Path
$IconPng = (Resolve-Path (Join-Path $BrandingDir "assets\logo.png")).Path

if (-not (Test-Path $CraftConfig)) {
    throw "craftmaster.ini missing in desktop src: $CraftConfig (wrong desktop_ref?)"
}
if (-not (Test-Path $IconIco)) {
    throw "branding icon missing: $IconIco (expected the same Gantara star as Linux)"
}

function Get-CraftIniValue([string]$Key) {
    $m = [regex]::Matches((Get-Content -Raw $CraftConfig), "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(\S+)\s*$")
    if ($m.Count -ne 1) { throw "expected exactly one '$Key' in $CraftConfig" }
    return $m[0].Groups[1].Value
}
$KdeBlueprintRef = if ($BlueprintBranch) { $BlueprintBranch } else { Get-CraftIniValue "craft/craft-blueprints-kde.revision" }
$NextcloudBlueprintRef = if ($BlueprintBranch) { $BlueprintBranch } else { Get-CraftIniValue "craft/craft-blueprints-nextcloud.revision" }

# Pin unsigned. Upstream's craftmaster.ini already has SIGN_PACKAGE=False for CI;
# force it so a tag bump cannot start requiring a cert we do not have.
$ini = Get-Content -Raw $CraftConfig
$ini = [regex]::Replace($ini, '(?m)^SIGN_PACKAGE\s*=.*$', 'SIGN_PACKAGE = False')
if ($ini -notmatch '(?m)^SIGN_PACKAGE\s*=') {
    $ini = $ini.TrimEnd() + "`r`n`r`n[Env]`r`nSIGN_PACKAGE = False`r`n"
}
[System.IO.File]::WriteAllText($CraftConfig, $ini)
Write-Host "==> SIGN_PACKAGE=False (no Authenticode cert)"

function Invoke-Craft {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CraftArgs)
    # Craft/python write status to stderr; with $ErrorActionPreference=Stop that
    # becomes a terminating NativeCommandError even when Craft succeeds.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & python (Join-Path $CraftMaster "CraftMaster.py") --config $CraftConfig --target $CraftTarget -c @CraftArgs 2>&1
        $code = $LASTEXITCODE
        foreach ($line in @($output)) {
            if ($null -eq $line) { continue }
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                Write-Host $line.ToString()
            } else {
                Write-Host $line
            }
        }
        if ($code -ne 0) {
            throw "craft failed: craft $($CraftArgs -join ' ') (exit $code)"
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

# v35 moved the nextcloud-client blueprint from desktop-client-blueprints to
# craft-blueprints-nextcloud; accept either so an older tag still builds.
$BlueprintDirPattern = "(desktop-client-blueprints|craft-blueprints-nextcloud)[/\\]nextcloud-client[/\\]"

function Get-NextcloudClientBlueprintFiles {
    Get-ChildItem -Path $Workspace -Recurse -Filter "nextcloud-client.py" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match $BlueprintDirPattern }
}

function Get-NextcloudClientBlacklistFiles {
    Get-ChildItem -Path $Workspace -Recurse -Filter "blacklist.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match $BlueprintDirPattern }
}

# Craft's NSIS template names the install folder, the registry key and the
# uninstall key after productname (Gantara); every installer has shipped that
# way, so they stay as they are and a new installer upgrades in place.
function Patch-NsisTemplate {
    Write-Host "==> Patch Craft NSIS template: publisher, finish page, desktop shortcut"
    # <target>\craft is a junction to the craft-core clone; -Recurse does not follow junctions.
    $known = Join-Path $Workspace "$CraftTarget\craft\bin\Packager\Nsis\NullsoftInstaller.nsi"
    if (Test-Path $known) {
        $templates = @(Get-Item $known)
    } else {
        $search = @{ Path = (Join-Path $Workspace $CraftTarget); Recurse = $true; Depth = 6; Filter = "NullsoftInstaller.nsi"; ErrorAction = "SilentlyContinue" }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $search.FollowSymlink = $true }
        $templates = @(Get-ChildItem @search |
            Where-Object { $_.FullName -match "Packager[/\\]Nsis[/\\]" })
    }
    if ($templates.Count -eq 0) { throw "could not locate Craft's Packager/Nsis/NullsoftInstaller.nsi" }
    $edits = [ordered]@{
        '"Publisher" "@{company}"' = '"Publisher" "@{publisher}"'
        # Craft's finish page neither starts the client nor offers a desktop shortcut, and the
        # client only registers its autostart entry once an account is set up, so after a plain
        # install nothing runs. The installer is elevated; Explorer starts the client as the user.
        '!insertmacro MUI_PAGE_FINISH' = @(
            '!define MUI_FINISHPAGE_RUN'
            '!define MUI_FINISHPAGE_RUN_TEXT "Start @{productname}"'
            '!define MUI_FINISHPAGE_RUN_FUNCTION LaunchAsUser'
            '!define MUI_FINISHPAGE_SHOWREADME'
            '!define MUI_FINISHPAGE_SHOWREADME_TEXT "Create a desktop shortcut"'
            '!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcut'
            '!insertmacro MUI_PAGE_FINISH'
        ) -join "`n"
        'Function .onInit' = @(
            'Function LaunchAsUser'
            ('Exec ''"$WINDIR\explorer.exe" "$INSTDIR\bin\' + $AppExe + '.exe"''')
            'FunctionEnd'
            ''
            'Function CreateDesktopShortcut'
            ('CreateShortCut "$DESKTOP\@{productname}.lnk" "$INSTDIR\bin\' + $AppExe + '.exe"')
            'FunctionEnd'
            ''
            'Function .onInit'
        ) -join "`n"
        'RMDir /r "$SMPROGRAMS\$StartMenuFolder"' = @(
            'RMDir /r "$SMPROGRAMS\$StartMenuFolder"'
            'Delete "$DESKTOP\@{productname}.lnk"'
        ) -join "`n"
    }
    # CraftMaster runs `git checkout -f` on the craft clone at the start of every call, which
    # would undo an in-place edit before --package runs. Write the patched copy outside the
    # clone; the blueprint points the packager's scriptname at it.
    $tpl = $templates[0]
    $nsi = Get-Content -Raw $tpl.FullName
    foreach ($from in $edits.Keys) {
        $to = $edits[$from]
        if ($nsi.IndexOf($to) -ge 0) { continue }
        if ($nsi.IndexOf($from) -lt 0) { throw "NSIS template anchor not found in $($tpl.FullName): $from" }
        $nsi = $nsi.Replace($from, $to)
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $NsisTemplateStaged) | Out-Null
    [System.IO.File]::WriteAllText($NsisTemplateStaged, $nsi)
    Write-Host "    patched $($tpl.FullName) -> $NsisTemplateStaged"
}

# Rewrite the Craft blueprint so NSIS ships our identity.
#
# Root cause of the broken Windows installer:
#   - cmake (via apply-branding) installs bin\dunetrails.exe
#   - craft --package without --offline git-fetches desktop-client-blueprints and
#     restores upstream createPackage(), which sets appname=nextcloud and never
#     sets defines["executable"] for Dunetrails
#   - NullsoftInstallerPackager uses defines["executable"] for the Start Menu
#     shortcut; upstream's applicationExecutable attribute is ignored by this
#     Craft revision. Result: Nextcloud website link + missing/wrong exe.
#   - blacklist.txt also strips every bin\*.exe except nextcloud|nextcloudcmd|
#     QtWebEngineProcess — so dunetrails.exe was packaged out of the NSIS payload.
function Patch-NextcloudClientBlueprint {
    Write-Host "==> Patch craft blueprint for $AppName packaging identity"
    $blueprints = @(Get-NextcloudClientBlueprintFiles)
    if ($blueprints.Count -eq 0) {
        throw "could not locate desktop-client-blueprints/nextcloud-client/nextcloud-client.py"
    }

    foreach ($blueprint in $blueprints) {
        # Normalize to LF so Python + our regexes behave consistently on the runner.
        $py = (Get-Content -Raw $blueprint.FullName) -replace "`r`n", "`n" -replace "`r", "`n"

        $py = $py.Replace('self.displayName = "Nextcloud"', "self.displayName = `"$AppName`"")
        $py = $py.Replace('self.description = "Nextcloud Desktop Client"', "self.description = `"$AppDescription`"")
        $py = $py.Replace('self.webpage = "https://nextcloud.com"', "self.webpage = `"$AppWebsite`"")
        $py = $py.Replace('self.defines["appname"] = "nextcloud"', "self.defines[`"appname`"] = `"$AppExe`"")
        $py = $py.Replace('self.defines["company"] = "Nextcloud GmbH"', "self.defines[`"company`"] = `"$Company`"")
        # Craft ignores applicationExecutable; NSIS needs defines["executable"]
        # for the Start Menu shortcut, and defines["icon"] / icon_png or the
        # installer keeps Craft's default craft.ico instead of the Gantara
        # star used on Linux.
        #
        # makensis: MUI_ICON is resolved relative to the .nsi (under C:\_\...),
        # while File may use cwd=blueprintDir. Relative "logo.ico" therefore
        # fails MUI. Absolute C:/... fails File. Use absolute Windows paths
        # with backslashes (same as Craft's own craft.ico default).
        $brandStage = Join-Path $Workspace "$CraftTarget\tmp\dunetrails-brand"
        New-Item -ItemType Directory -Force -Path $brandStage | Out-Null
        Copy-Item -Force $IconIco (Join-Path $brandStage "logo.ico")
        Copy-Item -Force $IconPng (Join-Path $brandStage "logo.png")
        # Also beside blueprint (harmless; some Craft versions look there).
        Copy-Item -Force $IconIco (Join-Path $blueprint.Directory.FullName "logo.ico")
        Copy-Item -Force $IconPng (Join-Path $blueprint.Directory.FullName "logo.png")
        $stagedIco = (Resolve-Path -LiteralPath (Join-Path $brandStage "logo.ico")).Path
        $stagedPng = (Resolve-Path -LiteralPath (Join-Path $brandStage "logo.png")).Path

        # appId makes Craft emit SnoreShortcut to $SMPROGRAMS\<name>.lnk (a
        # top-level All-apps entry on Windows 11). Without it, the only
        # shortcut is $SMPROGRAMS\$StartMenuFolder\<name>.lnk, which Win11
        # hides as a nested folder. un_sections deletes that top-level .lnk
        # on uninstall (RMDir of StartMenuFolder does not cover it).
        $shortcutAssign = "self.defines[`"shortcuts`"] = [{`"name`": `"$AppName`", `"target`": r`"bin\$AppExe.exe`", `"icon`": r`"$stagedIco`", `"description`": `"$AppDescription`", `"appId`": `"$AppRevDomain`"}]"
        $unAssign = 'self.defines["un_sections"] = ''Section "Un.Shortcuts"\nDelete "$SMPROGRAMS\\' + $AppName + '.lnk"\nSectionEnd'''
        # publisher feeds Patch-NsisTemplate. The Start-menu page
        # preselects the folder an earlier install recorded; move one still
        # carrying the install id over to the display name.
        $identityAssign = "self.defines[`"install_id`"] = `"$InstallId`"`n        self.defines[`"publisher`"] = `"$AppName`"`n        self.defines[`"preInstallHook`"] = 'StrCmp `$StartMenuFolder `"$InstallId`" 0 +2\nStrCpy `$StartMenuFolder `"$AppName`"'"

        $py = $py.Replace(
            'self.applicationExecutable = "nextcloud"',
            "self.defines[`"executable`"] = r`"bin\$AppExe.exe`"`n        self.defines[`"icon`"] = r`"$stagedIco`"`n        self.defines[`"icon_png`"] = r`"$stagedPng`"`n        $identityAssign`n        $shortcutAssign`n        $unAssign"
        )
        # The packager reads its template from scriptname; see Patch-NsisTemplate.
        $scriptAssign = "self.scriptname = r`"$NsisTemplateStaged`""
        if ($py -match 'self\.scriptname\s*=') {
            $py = [regex]::Replace($py, 'self\.scriptname\s*=\s*r?"[^"]*"', $scriptAssign.Replace('$', '$$'))
        } else {
            $py = ([regex]'(?m)^([ \t]*)(self\.defines\["executable"\]\s*=.*)$').Replace($py, "`$1`$2`n`$1$($scriptAssign.Replace('$', '$$'))", 1)
        }
        # Re-runs: force-refresh icon paths and shortcuts (applicationExecutable already gone).
        $py = [regex]::Replace($py, 'self\.defines\["icon"\]\s*=\s*r?"[^"]*"', "self.defines[`"icon`"] = r`"$stagedIco`"")
        $py = [regex]::Replace($py, 'self\.defines\["icon_png"\]\s*=\s*r?"[^"]*"', "self.defines[`"icon_png`"] = r`"$stagedPng`"")
        if ($py -match 'self\.defines\["shortcuts"\]') {
            $py = [regex]::Replace($py, 'self\.defines\["shortcuts"\]\s*=\s*\[[^\]]*\]', $shortcutAssign)
        } elseif ($py.IndexOf("self.defines[`"executable`"] = r`"bin\$AppExe.exe`"") -ge 0) {
            $py = $py.Replace(
                "self.defines[`"executable`"] = r`"bin\$AppExe.exe`"",
                "self.defines[`"executable`"] = r`"bin\$AppExe.exe`"`n        $shortcutAssign`n        $unAssign"
            )
        }
        if ($py.IndexOf('defines["install_id"]') -lt 0 -and $py.IndexOf("self.defines[`"executable`"] = r`"bin\$AppExe.exe`"") -ge 0) {
            $py = $py.Replace(
                "self.defines[`"executable`"] = r`"bin\$AppExe.exe`"",
                "self.defines[`"executable`"] = r`"bin\$AppExe.exe`"`n        $identityAssign"
            )
        }
        if ($py -match 'self\.defines\["un_sections"\]') {
            $py = [regex]::Replace($py, 'self\.defines\["un_sections"\]\s*=\s*''[^'']*''', $unAssign)
        }
        if ($py.IndexOf('defines["executable"]') -lt 0) {
            throw "blueprint missing defines[executable] after patch: $($blueprint.FullName)"
        }
        if ($py.IndexOf('defines["shortcuts"]') -lt 0) {
            throw "blueprint missing defines[shortcuts] after patch: $($blueprint.FullName)"
        }

        if ($py -notmatch '(?m)^import os\s*$') {
            $py = $py.Replace(
                'from Package.CMakePackageBase import *',
                "from Package.CMakePackageBase import *`nimport os"
            )
        }

        [System.IO.File]::WriteAllText($blueprint.FullName, $py)

        $verify = Get-Content -Raw $blueprint.FullName
        # Use IndexOf — PowerShell -like treats [ ] as character-class wildcards,
        # so checks like defines["appname"] would false-fail even when patched.
        $checks = [ordered]@{
            displayName = "displayName = `"$AppName`""
            webpage     = "webpage = `"$AppWebsite`""
            appname     = "defines[`"appname`"] = `"$AppExe`""
            executable  = "defines[`"executable`"] = r`"bin\$AppExe.exe`""
            shortcuts   = "defines[`"shortcuts`"] = ["
            installId   = "defines[`"install_id`"] = `"$InstallId`""
            appId       = "`"appId`": `"$AppRevDomain`""
            icon        = 'defines["icon"] = r"'
            nsisScript  = "self.scriptname = r`"$NsisTemplateStaged`""
            importOs    = 'import os'
        }
        foreach ($name in $checks.Keys) {
            if ($verify.IndexOf($checks[$name]) -lt 0) {
                $snippet = ($verify -split "`n" | Select-String -Pattern 'displayName|webpage|appname|executable|applicationExecutable|icon|import os' | ForEach-Object { $_.Line.Trim() }) -join ' | '
                throw "blueprint patch incomplete in $($blueprint.FullName); missing $($name): $($checks[$name]). saw: $snippet"
            }
        }
        if ($verify.IndexOf($stagedIco) -lt 0) {
            throw "blueprint icon path not updated to $stagedIco"
        }
        Write-Host "    patched $($blueprint.FullName)"
        Write-Host "    icon -> $stagedIco"
    }

    $blacklists = @(Get-NextcloudClientBlacklistFiles)
    if ($blacklists.Count -eq 0) {
        throw "could not locate desktop-client-blueprints/nextcloud-client/blacklist.txt"
    }
    foreach ($bl in $blacklists) {
        $txt = (Get-Content -Raw $bl.FullName) -replace "`r`n", "`n" -replace "`r", "`n"
        $old = 'bin/(?!(nextcloud|nextcloudcmd|QtWebEngineProcess)).*\.exe'
        $new = "bin/(?!($AppExe|${AppExe}cmd|QtWebEngineProcess)).*\.exe"
        if ($txt.IndexOf($old) -lt 0 -and $txt.IndexOf($new) -lt 0) {
            throw "blacklist.exe allowlist line not found in $($bl.FullName)"
        }
        $txt = $txt.Replace($old, $new)
        [System.IO.File]::WriteAllText($bl.FullName, $txt)
        $verifyBl = Get-Content -Raw $bl.FullName
        if ($verifyBl.IndexOf($new) -lt 0) {
            throw "blacklist patch incomplete in $($bl.FullName); expected: $new"
        }
        Write-Host "    patched $($bl.FullName) (allow $AppExe.exe / ${AppExe}cmd.exe)"
    }
}

Write-Host "==> Clone CraftMaster"
if (-not (Test-Path $CraftMaster)) {
    & cmd /C "git clone -q --depth=1 https://invent.kde.org/packaging/craftmaster.git `"$CraftMaster`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "git clone craftmaster failed" }
}

Write-Host "==> Install Craft + nextcloud-client deps (uses upstream binary cache)"
Write-Host "    blueprints: craft-blueprints-kde@$KdeBlueprintRef, craft-blueprints-nextcloud@$NextcloudBlueprintRef"
Invoke-Craft --add-blueprint-repository "https://github.com/nextcloud/craft-blueprints-kde.git|$KdeBlueprintRef|"
Invoke-Craft --add-blueprint-repository "https://github.com/nextcloud/craft-blueprints-nextcloud.git|$NextcloudBlueprintRef|"
Invoke-Craft craft
Invoke-Craft --install-deps nextcloud-client

# Put craft's bin on PATH (deployqt etc.)
$craftBin = Join-Path $Workspace "$CraftTarget\bin"
if (Test-Path $craftBin) {
    if ($env:GITHUB_PATH) {
        echo $craftBin | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
    }
    $env:PATH = "$craftBin;$env:PATH"
}

Write-Host "==> Compile branded desktop from $DesktopSrc"
# --src-dir already forces craft WorkOffline for this invocation.
Patch-NextcloudClientBlueprint
Invoke-Craft --options "nextcloud-client.versionSuffix=$($AppName.ToLower())"
Invoke-Craft --src-dir $DesktopSrc nextcloud-client

Write-Host "==> Install NSIS (required by Craft NullsoftInstallerPackager)"
Invoke-Craft nsis

Write-Host "==> Package NSIS installer (unsigned)"
# Must re-patch then package with --offline so craft does not git-fetch the
# blueprint repo and restore upstream Nextcloud createPackage().
Patch-NextcloudClientBlueprint
Patch-NsisTemplate
Invoke-Craft --offline --package nextcloud-client

# Collect installer artifacts for upload.
$outDir = Join-Path $Workspace "desktop-windows-out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$patterns = @(
    (Join-Path $Workspace "$CraftTarget\tmp\*.exe"),
    (Join-Path $Workspace "$CraftTarget\packages\**\*.exe"),
    (Join-Path $Workspace "$CraftTarget\tmp\*.msi"),
    (Join-Path $Workspace "$CraftTarget\packages\**\*.msi")
)
$found = @()
foreach ($p in $patterns) {
    $found += @(Get-Item $p -ErrorAction SilentlyContinue)
}
$found = $found | Where-Object { $_ -and $_.Name -match "(?i)$AppExe|$($AppName.ToLower())|nextcloud|setup" } | Select-Object -Unique
if (-not $found -or $found.Count -eq 0) {
    Write-Host "No filtered installer match; copying every .exe/.msi under craft tmp/packages:"
    $found = @(Get-ChildItem (Join-Path $Workspace $CraftTarget) -Recurse -Include *.exe,*.msi -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\tmp\\|\\packages\\' })
}
if (-not $found -or $found.Count -eq 0) {
    throw "craft --package produced no .exe/.msi under $CraftTarget\tmp or packages"
}
$renamedExe = $false
foreach ($f in $found) {
    $destName = $f.Name -replace '(?i)nextcloud-client', "$($AppName.ToLower())-desktop" -replace '(?i)nextcloud', $AppName.ToLower()
    if ($Version -and $f.Extension -eq '.exe' -and -not $renamedExe) {
        $destName = "${AppName}_Desktop-$Version-x64-setup.exe"
        $renamedExe = $true
    }
    $dest = Join-Path $outDir $destName
    Copy-Item -Force $f.FullName $dest
    Write-Host "    artifact: $($f.FullName) -> $dest"
}

# Fail the job if the NSIS payload still lacks the main GUI binary (blacklist regression).
$verifyExe = Get-ChildItem $outDir -Filter '*.exe' | Select-Object -First 1
if (-not $verifyExe) { throw "no installer exe in $outDir to verify" }
$sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
$sevenZipPath = $null
if ($sevenZip) {
    $sevenZipPath = $sevenZip.Source
} else {
    $candidate = Join-Path $Workspace "$CraftTarget\dev-utils\bin\7za.exe"
    if (Test-Path $candidate) { $sevenZipPath = $candidate }
}
if ($sevenZipPath) {
    Write-Host "==> Verifying installer payload contains bin\$AppExe.exe"
    $tmpList = Join-Path $env:TEMP "craft-nsis-list-$PID"
    New-Item -ItemType Directory -Force -Path $tmpList | Out-Null
    try {
        & $sevenZipPath x "-o$tmpList" $verifyExe.FullName "*.7z" -y | Out-Null
        $inner = Get-ChildItem $tmpList -Filter '*.7z' | Select-Object -First 1
        $listing = if ($inner) {
            & $sevenZipPath l $inner.FullName 2>&1 | Out-String
        } else {
            & $sevenZipPath l $verifyExe.FullName 2>&1 | Out-String
        }
    } finally {
        Remove-Item -Recurse -Force $tmpList -ErrorAction SilentlyContinue
    }
    if ($listing -notmatch [regex]::Escape("bin\$AppExe.exe") -and $listing -notmatch [regex]::Escape("bin/$AppExe.exe")) {
        throw "installer payload missing bin\$AppExe.exe (blacklist likely still stripping it)"
    }
    Write-Host "    ok: bin\$AppExe.exe present in payload"
} else {
    Write-Host "==> Skipping payload exe verification (7z/7za not found)"
}

Write-Host "==> Windows build complete. Artifacts in $outDir"
