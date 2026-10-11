# Bootstrap.ps1 -- one-shot setup for AionInstructPreview.Chat.
#
# Picks up where 'git clone' leaves off:
#   1. Verifies prereqs (PS arch, Developer Mode) and auto-installs the
#      WAR 2 runtime via winget when it's missing.
#   2. Downloads the matching public framework and SDK NuGet from GitHub releases,
#      or uses an explicitly supplied local artifact pair for release validation.
#   3. Drops the SDK NuGet into ./nuget-local/.
#   4. On ARM64 the framework acquires catalog QNN during first model creation.
#      On supported x64 devices it acquires catalog OpenVINO.
#   5. Builds and launches AionInstructPreview.Chat via 'dotnet run' (which
#      registers the loose build-output layout as a development package).
#
# Re-running is idempotent: the framework at the matching version is detected
# and skipped, and already-present runtimes are left as-is. Older frameworks
# are updated in place without removing dependent applications; downgrades and
# ambiguous same-architecture registrations are rejected.
#
# Usage:
#     .\Bootstrap.ps1
#     .\Bootstrap.ps1 -SkipLaunch    # prepare prereqs only, do not build/launch the chat app
#     .\Bootstrap.ps1 -Verbose       # show every step
#
# Stuck after Bootstrap finishes? Run scripts\Diagnose-AionInstructPreview.ps1 -- it
# captures the SDK's own EP decision log line via OutputDebugString.

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipLaunch,
    [string]$NuGetConfig,
    [string]$FrameworkMsixPath,
    [string]$SdkNuGetPath
)

$ErrorActionPreference = 'Stop'
$restoreArgs = @()
$restoreDisplay = ''
$configPath = $null
if ($PSBoundParameters.ContainsKey('FrameworkMsixPath') -ne
    $PSBoundParameters.ContainsKey('SdkNuGetPath')) {
    throw 'Specify -FrameworkMsixPath and -SdkNuGetPath together.'
}
$useLocalAssets = $PSBoundParameters.ContainsKey('FrameworkMsixPath')
if ($useLocalAssets) {
    $FrameworkMsixPath = (Get-Item -LiteralPath $FrameworkMsixPath -ErrorAction Stop).FullName
    $SdkNuGetPath = (Get-Item -LiteralPath $SdkNuGetPath -ErrorAction Stop).FullName
}
if ($PSBoundParameters.ContainsKey('NuGetConfig')) {
    $configPath = (Get-Item -LiteralPath $NuGetConfig -ErrorAction Stop).FullName
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'NuGetConfig must be a file.' }
    $restoreArgs = @("-p:RestoreConfigFile=$configPath")
    $restoreDisplay = " `"-p:RestoreConfigFile=$configPath`""
}
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RepoOwner       = 'microsoft'
$RepoName        = 'Aion-Instruct-Preview-Sample'
$FrameworkPkgId  = 'Microsoft.AionInstructPreview.Framework.1.0'
$ConsumerPkgId   = 'AionInstructPreviewChat'
$ConsumerVersion = '1.0.0.0'
$WarPkgId        = 'Microsoft.WindowsAppRuntime.2'
$SdkNuGetSignerFingerprint = '9A1B131BEE0605433056A4EA3815478A8E177961A968C6C0027C1093D1FEB630'

function Assert-SdkNuGetCacheMatches {
    param(
        [string]$PackagePath,
        [string]$Version,
        [string]$ConfigFile,
        [string]$ProjectDirectory = $PSScriptRoot
    )

    $settingsArgs = @()
    if ($ConfigFile) { $settingsArgs += "-p:RestoreConfigFile=$ConfigFile" }
    Push-Location $ProjectDirectory
    try {
        # Query NuGet's own settings resolution without restoring packages or building.
        $location = & dotnet msbuild AionInstructPreview.Chat.csproj -nologo `
            '-target:_GetRestoreProjectStyle;_GetRestoreSettings' `
            -getProperty:_OutputPackagesPath @settingsArgs
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($location -join "`n"))) {
            throw 'Could not resolve the sample project NuGet package cache.'
        }
        $cacheRoot = ($location -join "`n").Trim()
        if (-not [IO.Path]::IsPathRooted($cacheRoot)) {
            throw "NuGet returned an invalid package cache location: $cacheRoot"
        }
    } finally {
        Pop-Location
    }
    $cached = Join-Path $cacheRoot (
        "aioninstructpreview.text.framework\$Version\aioninstructpreview.text.framework.$Version.nupkg")
    if ((Test-Path -LiteralPath $cached -PathType Leaf) -and
        (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash) {
        throw "The NuGet cache contains a different Aion SDK $Version at '$cached'. " +
            'NuGet treats package versions as immutable and would restore the stale contract. ' +
            'Use a new SDK package version, or set NUGET_PACKAGES to an existing empty directory ' +
            'for this validation and rerun Bootstrap.ps1.'
    }
}

function Assert-LocalFrameworkMatches {
    param([string]$MsixPath, [string]$InstallLocation)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($MsixPath)
    try {
        $entry = $archive.GetEntry('AppxBlockMap.xml')
        $installedBlockMap = Join-Path $InstallLocation 'AppxBlockMap.xml'
        if (-not $entry -or -not (Test-Path -LiteralPath $installedBlockMap -PathType Leaf)) {
            throw 'Cannot verify local framework identity: a package block map is missing.'
        }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $suppliedHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        } finally {
            $stream.Dispose()
            $sha.Dispose()
        }
        if ($suppliedHash -ne (Get-FileHash -LiteralPath $installedBlockMap -Algorithm SHA256).Hash) {
            throw 'The installed framework has the same version but different contents from the supplied MSIX. ' +
                'Build the SDK with a new framework version and rerun bootstrap. No installed apps were removed.'
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-FrameworkMsixIdentity {
    param([string]$MsixPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($MsixPath)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw "$(Split-Path $MsixPath -Leaf) has no AppxManifest.xml." }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $manifest = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{
            Name = "$($manifest.Package.Identity.Name)"
            Architecture = "$($manifest.Package.Identity.ProcessorArchitecture)"
            Version = [version]"$($manifest.Package.Identity.Version)"
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-FrameworkMsixIdentity {
    param(
        [string]$MsixPath,
        [string]$ExpectedArchitecture,
        [version]$ExpectedVersion
    )
    $identity = Get-FrameworkMsixIdentity $MsixPath
    if ($identity.Name -ne $FrameworkPkgId -or
        $identity.Architecture -ine $ExpectedArchitecture) {
        throw "$(Split-Path $MsixPath -Leaf) is not the Aion $ExpectedArchitecture framework."
    }
    if ($ExpectedVersion -and $identity.Version -ne $ExpectedVersion) {
        throw "$(Split-Path $MsixPath -Leaf) contains framework $($identity.Version), expected $ExpectedVersion."
    }
    return $identity
}

function Assert-MicrosoftSignedPackage {
    param(
        [string]$MsixPath,
        [string[]]$AllowedRoots = @('8F43288AD272F3103B6FB1428485EA3014C0BCFE')
    )
    $signature = Get-AuthenticodeSignature -LiteralPath $MsixPath
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '<none>' }
    if ($signature.Status -ne 'Valid' -or $subject -notlike 'CN=Microsoft Corporation,*') {
        throw "$(Split-Path $MsixPath -Leaf) is not validly signed by Microsoft Corporation " +
            "(status $($signature.Status), signer $subject)."
    }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    $chain.ChainPolicy.RevocationMode =
        [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    # Get-AuthenticodeSignature validates the timestamped signature. Build the
    # chain only to enforce the production root, even after the signer expires.
    $chain.ChainPolicy.VerificationFlags =
        [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
    try {
        if (-not $chain.Build($signature.SignerCertificate) -or $chain.ChainElements.Count -eq 0) {
            $details = @($chain.ChainStatus | ForEach-Object StatusInformation) -join '; '
            throw "$(Split-Path $MsixPath -Leaf) signer chain did not validate: $details"
        }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        if ($AllowedRoots -notcontains $root.Thumbprint) {
            throw "$(Split-Path $MsixPath -Leaf) signer chain ends at unapproved root " +
                "'$($root.Subject)' ($($root.Thumbprint))."
        }
    } finally {
        $chain.Dispose()
    }
}

function Assert-MicrosoftSignedNuGet {
    param([string]$PackagePath)
    $output = @(& dotnet nuget verify $PackagePath --all `
        --certificate-fingerprint $SdkNuGetSignerFingerprint 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path $PackagePath -Leaf) does not have the expected Microsoft NuGet signature:`n" +
            ($output -join "`n")
    }
}

function Write-Step  { param([string]$Msg) Write-Host "[bootstrap] $Msg" -ForegroundColor Cyan }
function Write-OK    { param([string]$Msg) Write-Host "[bootstrap] $Msg" -ForegroundColor Green }
function Write-Skip  { param([string]$Msg) Write-Host "[bootstrap] $Msg" -ForegroundColor DarkGray }
function Write-Fail  { param([string]$Msg) Write-Host "[bootstrap] $Msg" -ForegroundColor Red }

function Stop-WithRecovery {
    param([string]$Title, [string[]]$Recovery)
    Write-Host ''
    Write-Fail "FAIL: $Title"
    Write-Host ''
    Write-Host 'Recovery:' -ForegroundColor Yellow
    foreach ($line in $Recovery) { Write-Host "    $line" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'After fixing, re-run .\Bootstrap.ps1' -ForegroundColor Yellow
    exit 1
}

function Get-X64ProviderRequirement {
    param([string]$ProcessorName)
    if ($ProcessorName -match 'AMD') {
        Stop-WithRecovery `
            -Title 'AMD support is coming soon' `
            -Recovery @(
                'Use a supported ARM64 Snapdragon or x64 Intel Lunar Lake Copilot+ PC for this preview.',
                'Check a future release for AMD availability.'
            )
    }
    if ($ProcessorName -match 'Intel') {
        return [pscustomobject]@{
            Label = 'OpenVINO'
            Pattern = '*WinML.Intel.OpenVINO.EP.Framework.2*'
            Minimum = [version]'1.8.95.0'
        }
    }
    return $null
}

function Select-FrameworkRegistration {
    param(
        [object[]]$Packages,
        [version]$TargetVersion
    )
    $ordered = @($Packages | Sort-Object { [version]$_.Version } -Descending)
    return [pscustomobject]@{
        Target = $ordered |
            Where-Object { [version]$_.Version -eq $TargetVersion } |
            Select-Object -First 1
        Highest = $ordered | Select-Object -First 1
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Stop-WithRecovery -Title '.NET SDK was not found' -Recovery @(
        'Install the .NET 9 SDK, then open a new PowerShell and re-run:',
        '    winget install --id Microsoft.DotNet.SDK.9',
        'Confirm with: dotnet --info'
    )
}
$installedDotnetSdks = @(& dotnet --list-sdks 2>$null)
$dotnet9Sdk = $installedDotnetSdks |
    Where-Object { $_ -match '^\s*9\.0\.' } |
    Select-Object -Last 1
if ($LASTEXITCODE -ne 0 -or -not $dotnet9Sdk) {
    Stop-WithRecovery -Title '.NET 9 SDK was not found' -Recovery @(
        'Install the .NET 9 SDK, then open a new PowerShell and re-run:',
        '    winget install --id Microsoft.DotNet.SDK.9',
        'Confirm that a 9.0 SDK is listed with: dotnet --list-sdks'
    )
}
Write-OK ".NET 9 SDK installed ($dotnet9Sdk)"

# Ensure a Windows App Runtime is present for $Arch (optionally at/above
# $MinVersion). If missing, install it with winget and re-check. winget's exit
# code is deliberately ignored -- "already installed" and several success-ish
# states return non-zero, so the AppX re-check is the source of truth. Falls
# back to manual recovery instructions if winget is unavailable or the runtime
# still isn't present afterward.
function Ensure-Runtime {
    param(
        [string]$Label,
        [string]$PkgId,
        [string]$WingetId,
        [string]$Arch,
        [string]$MinVersion
    )

    $find = {
        Get-AppxPackage -Name $PkgId -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Architecture -eq $Arch -and
                (-not $MinVersion -or [version]$_.Version -ge [version]$MinVersion)
            }
    }

    $pkg = & $find
    if ($pkg) {
        Write-OK "$Label ($Arch) v$($pkg[0].Version) installed"
        return
    }

    $manualRecovery = @(
        '# winget is the fast path:',
        "    winget install --id $WingetId",
        '# or grab the installer:',
        '    https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads'
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Stop-WithRecovery `
            -Title "$Label ($Arch) is not installed, and winget (App Installer) is unavailable to install it automatically" `
            -Recovery $manualRecovery
    }

    Write-Step "$Label ($Arch) not found -- installing with winget (may prompt for elevation) ..."
    # Exit code intentionally not checked; the re-check below is authoritative.
    winget install --id $WingetId --exact --accept-package-agreements --accept-source-agreements | Out-Host

    $pkg = & $find
    if (-not $pkg) {
        Stop-WithRecovery `
            -Title "$Label ($Arch) still not present after the winget install attempt" `
            -Recovery $manualRecovery
    }
    Write-OK "$Label ($Arch) v$($pkg[0].Version) installed"
}

# --- 0. Banner --------------------------------------------------------------
Write-Host ''
Write-Host '=== AionInstructPreview.Chat Bootstrap ===' -ForegroundColor Cyan
Write-Host ''

# --- 1. Arch detection ------------------------------------------------------
# Detect the native machine architecture so the installed framework and app
# match the hardware, even when PowerShell is running under emulation.
$emulatedArch = $env:PROCESSOR_ARCHITECTURE
$nativeArch   = $env:PROCESSOR_ARCHITEW6432
if ($nativeArch) {
    $rawArch = $nativeArch
    Write-Step "Running under emulation/WOW64 (process arch $emulatedArch); using native arch $nativeArch"
} else {
    $rawArch = $emulatedArch
}

$arch = switch ($rawArch) {
    'ARM64' { 'ARM64' }
    'AMD64' { 'x64' }
    default { $null }
}
if (-not $arch) {
    Stop-WithRecovery `
        -Title "Unsupported processor architecture=$rawArch (process arch $emulatedArch, native arch '$nativeArch')" `
        -Recovery @(
            'AionInstructPreview.Chat ships ARM64 and x64 builds.',
            'Launch a 64-bit PowerShell on a supported ARM64 Snapdragon or x64 Intel Copilot+ PC and re-run.'
        )
}
Write-Step "Architecture: $arch"

$x64Requirement = $null
if ($arch -eq 'x64') {
    $processorName = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Name)
    $x64Requirement = Get-X64ProviderRequirement $processorName
}

# --- 2. WAR 2 runtime check -------------------------------------------------
Ensure-Runtime -Label 'WAR 2' -PkgId $WarPkgId -WingetId 'Microsoft.WindowsAppRuntime.2.0' `
    -Arch $arch -MinVersion '2.0.1.0'

# --- 2a. Developer Mode check -----------------------------------------------
# dotnet run registers the loose build-output layout as a development package,
# which requires Developer Mode.
$devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = $null
try {
    $devMode = (Get-ItemProperty -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
} catch {}
if ($devMode -ne 1) {
    Write-Step 'Developer Mode is not enabled -- enabling now (UAC prompt) ...'
    $regCmd = 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
    Start-Process -FilePath powershell -ArgumentList '-NoProfile', '-Command', $regCmd -Verb RunAs -Wait
    $devMode = $null
    try {
        $devMode = (Get-ItemProperty -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
    } catch {}
    if ($devMode -ne 1) {
        Stop-WithRecovery `
            -Title 'Developer Mode could not be enabled' `
            -Recovery @(
                'Enable it manually:',
                '    Settings -> Privacy & security -> For developers -> Developer Mode -> On',
                'Or via an elevated PowerShell:',
                "    $regCmd"
            )
    }
}
Write-OK 'Developer Mode enabled'

# --- 2c. NuGet cache/package path env var validation ------------------------
# NuGet honors NUGET_HTTP_CACHE_PATH and NUGET_PACKAGES for restore. If a user
# points either at a path that doesn't exist, restore fails deep in the build
# with a confusing error -- validate up front and fail fast with recovery steps.
# Each variable is checked independently; an unset variable is not an error.
function Test-NuGetPathEnvVar {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return
    }

    if (-not (Test-Path -LiteralPath $value -PathType Container)) {
        Stop-WithRecovery `
            -Title "$Name is set to '$value', which is not accessible" `
            -Recovery @(
                'Please point the variable at an existing directory, create it, or clear it:',
                "    New-Item -ItemType Directory -Force -Path '$value'",
                '# or clear it for this session:',
                "    Remove-Item Env:\$Name",
                '# or fix it permanently under:',
                '    Settings -> System -> About -> Advanced system settings -> Environment Variables'
            )
    }

    Write-OK "$Name -> $value"
}

Test-NuGetPathEnvVar -Name 'NUGET_HTTP_CACHE_PATH'
Test-NuGetPathEnvVar -Name 'NUGET_PACKAGES'

# --- 3. Discover latest release via the public GitHub Releases API ----------
# This repo is public, so the latest signed release is fetched straight from
# the unauthenticated GitHub REST API over HTTPS -- no GitHub CLI, no token,
# no sign-in. api.github.com requires a User-Agent header on every request.
$ProgressPreference = 'SilentlyContinue'  # speeds up Invoke-WebRequest ~100x on PS 5.1
$ghHeaders = @{
    'User-Agent' = 'AionInstructPreview-Bootstrap'
    'Accept'     = 'application/vnd.github+json'
}
$latestUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"

$release = $null
if ($useLocalAssets) {
    $identity = Assert-FrameworkMsixIdentity -MsixPath $FrameworkMsixPath `
        -ExpectedArchitecture $arch
    $targetFwVersion = $identity.Version
    $tag = "v$targetFwVersion"
    Write-OK "Using local $arch framework v$targetFwVersion"
} else {
    Write-Step "Discovering latest release from $latestUrl ..."
    try {
        $release = Invoke-RestMethod -Uri $latestUrl -Headers $ghHeaders -ErrorAction Stop
    } catch {
        Stop-WithRecovery `
            -Title "Could not query the latest release ($($_.Exception.Message))" `
            -Recovery @(
                "Visit https://github.com/$RepoOwner/$RepoName/releases in a browser to confirm a release exists.",
                'Check your internet connection / proxy, then re-run.'
            )
    }
    if (-not $release -or -not $release.tag_name) {
        Stop-WithRecovery `
            -Title 'No published release found' `
            -Recovery @(
                "Visit https://github.com/$RepoOwner/$RepoName/releases in a browser to confirm a release exists.",
                'If the page is empty, the SDK pipeline has not published a release yet.'
            )
    }
    $tag = $release.tag_name
    $targetFwVersion = $tag -replace '^v', ''
    Write-OK "Latest release: $tag ($($release.name))"
    Write-Host ''
    Write-Host 'Pre-release license terms:' -ForegroundColor Yellow
    Write-Host '    https://github.com/microsoft/Aion-Instruct-Preview-Sample/blob/main/docs/Aion-Instruct-Preview-Pre-Release-EULA.docx' -ForegroundColor Yellow
    Write-Host 'Review these terms before using the pre-release validation package.' -ForegroundColor Yellow
}
if ([version]$targetFwVersion -lt [version]'1.0.0.3') {
    Stop-WithRecovery `
        -Title "Release $tag predates this sample's required catalog framework (framework 1.0.0.3 / SDK 1.0.1)" `
        -Recovery @(
            'Use a release containing framework 1.0.0.3 or newer and SDK NuGet 1.0.1 from the same build.',
            'For local development, build/install the matching SDK and launch the sample manually.'
        )
}
$assets = if ($release) { @($release.assets) } else { @() }

# Resolve a release asset's download URL by exact file name. Returns the
# browser_download_url (a plain HTTPS link served without auth on a public repo).
function Get-AssetUrl {
    param([string]$Name)
    $asset = $assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $asset) {
        Stop-WithRecovery `
            -Title "Release $tag has no asset named '$Name'" `
            -Recovery @(
                "Visit https://github.com/$RepoOwner/$RepoName/releases/tag/$tag and check the asset list.",
                "Expected asset name: $Name"
            )
    }
    return $asset.browser_download_url
}

# Asset names follow a fixed pattern: AionInstructPreview.LanguageModel.Framework_<ver>_<arch>.msix
# and AionInstructPreview.Text.Framework.<nupkgVer>.nupkg.
# The contract NuGet is pinned independently of the framework release version.
$expectedMsixName = "AionInstructPreview.LanguageModel.Framework_${targetFwVersion}_${arch}.msix"
[xml]$sampleProject = Get-Content (Join-Path $PSScriptRoot 'AionInstructPreview.Chat.csproj') -Raw
$nupkgVersion = ($sampleProject.Project.ItemGroup.PackageReference |
    Where-Object { $_.Include -eq 'AionInstructPreview.Text.Framework' }).Version.Trim('[', ']')
$expectedNupkgName = "AionInstructPreview.Text.Framework.${nupkgVersion}.nupkg"
if ($useLocalAssets -and (Split-Path $SdkNuGetPath -Leaf) -ne $expectedNupkgName) {
    throw "Expected local SDK NuGet $expectedNupkgName, got $(Split-Path $SdkNuGetPath -Leaf)."
}

# --- 4. Framework MSIX state -----------------------------------------------
$frameworks = @(Get-AppxPackage -Name $FrameworkPkgId -ErrorAction SilentlyContinue |
    Where-Object { $_.Architecture -eq $arch })
$frameworkSelection = Select-FrameworkRegistration `
    -Packages $frameworks -TargetVersion ([version]$targetFwVersion)
$fw = $frameworkSelection.Target
if (-not $fw -and $frameworkSelection.Highest -and
    [version]$frameworkSelection.Highest.Version -gt [version]$targetFwVersion) {
    Stop-WithRecovery -Title "Installed framework $($frameworkSelection.Highest.Version) is newer than $targetFwVersion" -Recovery @(
        'Use an SDK release at least as new as the installed framework; downgrade is not automatic.'
    )
}
if ($fw) {
    if ($useLocalAssets) {
        Assert-LocalFrameworkMatches -MsixPath $FrameworkMsixPath -InstallLocation $fw.InstallLocation
    } else {
        Assert-MicrosoftSignedPackage -MsixPath (Join-Path $fw.InstallLocation 'AionInstructPreview.Text.dll')
    }
    Write-Skip "Aion Instruct Preview framework MSIX already installed at v$($fw.Version) -- skipping download/install"
} else {
    $msixPath = $FrameworkMsixPath
    if (-not $useLocalAssets) {
        $stage = Join-Path $env:TEMP "Aion Instruct Preview-bootstrap-$tag"
        if (-not (Test-Path $stage)) { New-Item -ItemType Directory -Path $stage | Out-Null }
        Write-Step "Downloading $expectedMsixName (several GB; this may take a while) ..."
        $msixPath = Join-Path $stage $expectedMsixName
        $msixUrl = Get-AssetUrl -Name $expectedMsixName
        try {
            Invoke-WebRequest -Uri $msixUrl -Headers $ghHeaders -OutFile $msixPath -ErrorAction Stop
        } catch {
            Stop-WithRecovery `
                -Title "Download failed for $expectedMsixName ($($_.Exception.Message))" `
                -Recovery @(
                    "Visit https://github.com/$RepoOwner/$RepoName/releases/tag/$tag and check the asset list.",
                    "Expected asset name: $expectedMsixName"
                )
        }
        try {
            Assert-MicrosoftSignedPackage -MsixPath $msixPath
            Assert-FrameworkMsixIdentity -MsixPath $msixPath -ExpectedArchitecture $arch `
                -ExpectedVersion ([version]$targetFwVersion) | Out-Null
        } catch {
            Stop-WithRecovery -Title $_.Exception.Message -Recovery @(
                'Do not install this package. Report the release and preserve this error.',
                "Delete the downloaded file: Remove-Item -LiteralPath '$msixPath'"
            )
        }
    }
    Write-Step "Installing framework MSIX ..."
    Add-AppxPackage -Path $msixPath -ForceUpdateFromAnyVersion
    $frameworks = @(Get-AppxPackage -Name $FrameworkPkgId -ErrorAction SilentlyContinue |
        Where-Object { $_.Architecture -eq $arch })
    $fw = (Select-FrameworkRegistration `
        -Packages $frameworks -TargetVersion ([version]$targetFwVersion)).Target
    if (-not $fw) {
        Stop-WithRecovery `
            -Title "Framework MSIX install did not register expected version $targetFwVersion." `
            -Recovery @(
                'Inspect with:',
                "    Add-AppxPackage -Path '$msixPath'",
                'Watch its error output. Common causes: cert chain, mismatched arch, side-by-side conflict.'
            )
    }
    Write-OK "Installed framework v$($fw.Version)"
}

# --- 5. SDK nupkg in nuget-local/ ------------------------------------------
$nugetLocal = Join-Path $PSScriptRoot 'nuget-local'
Ensure-Directory $nugetLocal
$expectedNupkg = Join-Path $nugetLocal $expectedNupkgName
if (Test-Path $expectedNupkg) {
    if (-not $useLocalAssets -or
        (Get-FileHash $expectedNupkg).Hash -eq (Get-FileHash $SdkNuGetPath).Hash) {
        Write-Skip "$expectedNupkgName already in nuget-local/ -- skipping download"
    } else {
        Copy-Item -LiteralPath $SdkNuGetPath -Destination $expectedNupkg -Force
        Write-OK "Updated $expectedNupkgName from the local SDK build"
    }
} else {
    # Wipe stale older-version nupkgs so NuGet restore picks the new one cleanly.
    Get-ChildItem $nugetLocal -Filter 'AionInstructPreview.Text.Framework*.nupkg' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Skip "Removing stale $($_.Name) from nuget-local/"
            Remove-Item $_.FullName -Force
        }
    if ($useLocalAssets) {
        Copy-Item -LiteralPath $SdkNuGetPath -Destination $expectedNupkg
    } else {
        Write-Step "Downloading $expectedNupkgName ..."
        $nupkgUrl = Get-AssetUrl -Name $expectedNupkgName
        try {
            Invoke-WebRequest -Uri $nupkgUrl -Headers $ghHeaders -OutFile $expectedNupkg -ErrorAction Stop
        } catch {
            Stop-WithRecovery `
                -Title "Download failed for $expectedNupkgName ($($_.Exception.Message))" `
                -Recovery @(
                    "Visit https://github.com/$RepoOwner/$RepoName/releases/tag/$tag and check the asset list.",
                    "Expected asset name: $expectedNupkgName"
                )
        }
    }
    Write-OK "Dropped $expectedNupkgName in nuget-local/"
}
if (-not $useLocalAssets) {
    try {
        Assert-MicrosoftSignedNuGet $expectedNupkg
    } catch {
        Remove-Item -LiteralPath $expectedNupkg -Force -ErrorAction SilentlyContinue
        Stop-WithRecovery -Title $_.Exception.Message -Recovery @(
            'Do not build with this package. Re-run Bootstrap to download the signed SDK package again.',
            "Verify the release assets at https://github.com/$RepoOwner/$RepoName/releases/tag/$tag"
        )
    }
}
Assert-SdkNuGetCacheMatches -PackagePath $expectedNupkg -Version $nupkgVersion -ConfigFile $configPath

# --- 5a. Execution-provider provisioning -----------------------------------
# The framework uses its bundled WinML catalog to acquire the hardware provider during
# first model creation. Report whether a compatible provider is already installed.
if ($arch -eq 'ARM64') {
    $qnnPackages = @(Get-AppxPackage -Name '*WinML.Qualcomm.QNN.EP*.2*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Architecture -eq $arch -and [version]$_.Version -ge [version]'2.2480.49.0' })
    if ($qnnPackages.Count -eq 0) {
        Write-Step 'QNN EP 2 will be acquired by the framework when the model first loads (network access may be required).'
    } else {
        Write-OK 'Compatible QNN EP 2 is already installed'
    }
} else {
    if ($x64Requirement) {
        $providerPackages = @(Get-AppxPackage -Name $x64Requirement.Pattern -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Architecture)" -eq 'X64' })
        $compatible = @($providerPackages |
            Where-Object { [version]$_.Version -ge $x64Requirement.Minimum })
        if ($compatible.Count -gt 0) {
            Write-OK "Compatible catalog $($x64Requirement.Label) provider is already installed"
        } elseif ($providerPackages.Count -gt 0) {
            $installed = $providerPackages | Sort-Object { [version]$_.Version } -Descending |
                Select-Object -First 1 -ExpandProperty Version
            Write-Step (("Installed catalog {0} version {1} is below required {2}; " +
                "WinML will try Store acquisition on first model load.") -f
                $x64Requirement.Label, $installed, $x64Requirement.Minimum)
        } else {
            Write-Step ("Catalog $($x64Requirement.Label) $($x64Requirement.Minimum) or newer will be " +
                'acquired when the model first loads (network access may be required).')
        }
    }
}

# --- 6. Build, register (loose layout) and launch via dotnet run ------------
# dotnet run builds, registers the loose-layout development package, and launches the app.
$csproj = Join-Path $PSScriptRoot 'AionInstructPreview.Chat.csproj'

if ($SkipLaunch) {
    Write-Host ''
    Write-OK 'Bootstrap complete (skipped chat app build/launch).'
    Write-Host 'Build and run manually:' -ForegroundColor Cyan
    Write-Host "    dotnet run --project `"$csproj`" --launch-profile `"AionInstructPreview.Chat`" -c Release -p:Platform=$arch$restoreDisplay" -ForegroundColor Cyan
    return
}

# Remove any installed consumer MSIX before registering the loose-layout app.
$existing = Get-AppxPackage -Name $ConsumerPkgId -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Removing previously-installed $ConsumerPkgId (dotnet run uses a development registration) ..."
    $existing | Remove-AppxPackage
}

Write-Step "Building and launching AionInstructPreview.Chat ($arch, Release) via dotnet run ..."
& dotnet run --project "$csproj" --launch-profile "AionInstructPreview.Chat" -c Release -p:Platform=$arch @restoreArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    Stop-WithRecovery `
        -Title 'dotnet run failed' `
        -Recovery @(
            'Re-run directly for full output:',
            "    dotnet run --project `"$csproj`" --launch-profile `"AionInstructPreview.Chat`" -c Release -p:Platform=$arch$restoreDisplay",
            'Most likely causes:',
            '  - Developer Mode is off (Settings -> Privacy & security -> For developers).',
            '  - The .NET 9 SDK is not installed (run: dotnet --info to confirm).',
            '  - Building under C:\Windows\System32 -- UAC file virtualization redirects the',
            '    obj\ codegen writes. Clone and build under your user profile (e.g. C:\repos)',
            '    from a normal (non-elevated) PowerShell; building does not require admin.'
        )
}

Write-Host ''
Write-OK 'Bootstrap complete. Aion Instruct Preview Chat is loading.'
Write-Host 'First launch on a cold cache can take several minutes for NPU compilation.' -ForegroundColor DarkGray
Write-Host 'Stuck longer than that? Run: .\scripts\Diagnose-AionInstructPreview.ps1' -ForegroundColor DarkGray
