# Authenticode signing of the Windows clients with Azure Artifact Signing. See SIGNING.md in
# public/gantara-clients for the Azure side and how users verify.
#
#   windows-signing.ps1 install
#       Fetches signtool and the Artifact Signing dlib (the same NuGet packages, at the same
#       versions, that azure/artifact-signing-action v2.0.0 uses), writes the dlib metadata from
#       ARTIFACT_SIGNING_ENDPOINT / _ACCOUNT / _PROFILE, and exports SIGNTOOL_EXE,
#       ARTIFACT_SIGNING_DLIB, ARTIFACT_SIGNING_METADATA and ARTIFACT_SIGNING_PARAMS to later steps.
#   windows-signing.ps1 sign <file>... | sign -List <file-with-one-path-per-line>
#       Signs and timestamps (RFC 3161, SHA-256), then verifies what it signed.
#   windows-signing.ps1 verify <file-or-dir>...
#       signtool verify /pa /tw on each file, and on every .exe/.dll/.node below each directory.
#       Fails on any unsigned or untimestamped file.
#
# Credentials come from DefaultAzureCredential inside the dlib, i.e. the az CLI session that
# azure/login (OIDC, no client secret) leaves behind. Nothing secret passes through here.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet("install", "sign", "verify")][string]$Action,
    [string]$List = "",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths = @()
)

$ErrorActionPreference = "Stop"
$TimestampUrl = "http://timestamp.acs.microsoft.com"
$Packages = @(
    @{ Id = "Microsoft.Windows.SDK.BuildTools"; Version = "10.0.26100.4188"; Sha256 = "180DEB372659029864C10A0C04787833234D64AACD1D2C0661D2C00295D8E022" },
    @{ Id = "Microsoft.ArtifactSigning.Client"; Version = "1.0.128"; Sha256 = "74BD7D27E6CE1051409C38D9B46BC8DF0400ECD643D51FFBF2AC00869061E40B" }
)

function Get-Required([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) { throw "$Name is not set" }
    return $value
}

function Export-Env([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value)
    if ($env:GITHUB_ENV) { "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append }
}

function Install-Tools {
    $root = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }) "artifact-signing"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($p in $Packages) {
        $id = $p.Id.ToLowerInvariant()
        $nupkg = Join-Path $root "$id.$($p.Version).nupkg"
        $dir = Join-Path $root "$id.$($p.Version)"
        if (-not (Test-Path $dir)) {
            Invoke-WebRequest -UseBasicParsing -Uri "https://api.nuget.org/v3-flatcontainer/$id/$($p.Version)/$id.$($p.Version).nupkg" -OutFile $nupkg
            $hash = (Get-FileHash -Algorithm SHA256 $nupkg).Hash
            if ($hash -ne $p.Sha256) { throw "$($p.Id) $($p.Version): SHA-256 $hash, expected $($p.Sha256)" }
            [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $dir)
        }
    }
    $signtool = Join-Path $root "microsoft.windows.sdk.buildtools.10.0.26100.4188\bin\10.0.26100.0\x64\signtool.exe"
    $dlib = Join-Path $root "microsoft.artifactsigning.client.1.0.128\bin\x64\Azure.CodeSigning.Dlib.dll"
    foreach ($f in @($signtool, $dlib)) { if (-not (Test-Path $f)) { throw "missing after install: $f" } }

    $metadata = Join-Path $root "metadata.json"
    [ordered]@{
        Endpoint               = Get-Required "ARTIFACT_SIGNING_ENDPOINT"
        CodeSigningAccountName = Get-Required "ARTIFACT_SIGNING_ACCOUNT"
        CertificateProfileName = Get-Required "ARTIFACT_SIGNING_PROFILE"
        ExcludeCredentials     = @(
            "ManagedIdentityCredential", "EnvironmentCredential", "WorkloadIdentityCredential",
            "SharedTokenCacheCredential", "VisualStudioCredential", "VisualStudioCodeCredential",
            "AzurePowerShellCredential", "AzureDeveloperCliCredential", "InteractiveBrowserCredential"
        )
    } | ConvertTo-Json | Out-File -FilePath $metadata -Encoding utf8

    foreach ($f in @($signtool, $dlib, $metadata)) {
        if ($f -match '\s') { throw "path contains whitespace, which the Electron and Squirrel signers cannot quote: $f" }
    }
    Export-Env "SIGNTOOL_EXE" $signtool
    Export-Env "ARTIFACT_SIGNING_DLIB" $dlib
    Export-Env "ARTIFACT_SIGNING_METADATA" $metadata
    Export-Env "ARTIFACT_SIGNING_PARAMS" "/v /fd SHA256 /tr $TimestampUrl /td SHA256 /dlib $dlib /dmdf $metadata"
    Write-Host "signtool: $signtool"
    Write-Host "dlib:     $dlib"
}

function Invoke-SignTool([string[]]$Arguments) {
    & (Get-Required "SIGNTOOL_EXE") @Arguments | Out-Host
    return $LASTEXITCODE
}

function Get-Targets {
    $files = @()
    if ($List) { $files += @(Get-Content -LiteralPath $List | Where-Object { $_.Trim() }) }
    $files += $Paths
    if ($files.Count -eq 0) { throw "no files given" }
    return $files
}

function Sign-Files {
    $files = @(Get-Targets)
    $dlib = Get-Required "ARTIFACT_SIGNING_DLIB"
    $metadata = Get-Required "ARTIFACT_SIGNING_METADATA"
    for ($i = 0; $i -lt $files.Count; $i += 50) {
        $batch = $files[$i..([Math]::Min($i + 49, $files.Count - 1))]
        $code = Invoke-SignTool (@("sign", "/v", "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256", "/dlib", $dlib, "/dmdf", $metadata) + $batch)
        if ($code -ne 0) { throw "signtool sign failed (exit $code)" }
    }
    Verify-Files $files
}

function Verify-Files([string[]]$Targets) {
    $files = @()
    foreach ($t in $Targets) {
        if (Test-Path -LiteralPath $t -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $t -Recurse -File -Include *.exe, *.dll, *.node | ForEach-Object FullName)
        } elseif (Test-Path -LiteralPath $t) {
            $files += (Resolve-Path -LiteralPath $t).Path
        } else {
            throw "not found: $t"
        }
    }
    if ($files.Count -eq 0) { throw "nothing to verify in: $($Targets -join ', ')" }
    $failed = @()
    foreach ($f in $files) {
        if ((Invoke-SignTool @("verify", "/pa", "/tw", "/q", $f)) -ne 0) { $failed += $f }
    }
    if ($failed.Count -gt 0) {
        $failed | ForEach-Object { Write-Host "::error::not signed and timestamped: $_" }
        $null = Invoke-SignTool @("verify", "/pa", "/tw", "/v", $failed[0])
        throw "$($failed.Count) of $($files.Count) files are not signed and timestamped"
    }
    $signer = (Get-AuthenticodeSignature -LiteralPath $files[0]).SignerCertificate.Subject
    Write-Host "verified $($files.Count) files (signtool verify /pa /tw); signer: $signer"
}

switch ($Action) {
    "install" { Install-Tools }
    "sign" { Sign-Files }
    "verify" { Verify-Files @(Get-Targets) }
}
