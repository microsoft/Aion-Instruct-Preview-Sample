<#
.SYNOPSIS
    Tests bootstrap artifact identity and effective NuGet cache selection without deployment.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'Bootstrap.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Bootstrap.ps1 contains syntax errors.' }
foreach ($name in @('Assert-SdkNuGetCacheMatches', 'Assert-LocalFrameworkMatches',
        'Assert-FrameworkMsixIdentity', 'Get-FrameworkMsixIdentity',
        'Assert-MicrosoftSignedPackage', 'Assert-MicrosoftSignedNuGet',
        'Get-X64ProviderRequirement', 'Select-FrameworkRegistration', 'Ensure-Directory')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing bootstrap function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$signatureDefinition = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Assert-MicrosoftSignedPackage'
}, $true)
if ($signatureDefinition.Extent.Text -notmatch 'IgnoreNotTimeValid' -or
    $signatureDefinition.Extent.Text -notmatch '8F43288AD272F3103B6FB1428485EA3014C0BCFE') {
    throw 'Downloaded release signature validation must pin the production root and permit timestamped signer expiry.'
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Message*") { return }
        throw
    }
    throw "Expected rejection: $Message"
}

function Stop-WithRecovery {
    param([string]$Title, [string[]]$Recovery)
    throw $Title
}

$intelRequirement = Get-X64ProviderRequirement 'Intel Core Ultra'
if ($intelRequirement.Label -ne 'OpenVINO' -or
    $intelRequirement.Minimum -ne [version]'1.8.95.0') {
    throw 'Intel provider requirements are incorrect.'
}
Assert-Rejected { Get-X64ProviderRequirement 'AMD Ryzen AI' } 'AMD support is coming soon'

$registrations = @(
    [pscustomobject]@{ Version = '1.0.0.2'; InstallLocation = 'old' },
    [pscustomobject]@{ Version = '1.0.0.3'; InstallLocation = 'target' },
    [pscustomobject]@{ Version = '1.0.0.4'; InstallLocation = 'newest' }
)
$selection = Select-FrameworkRegistration -Packages $registrations -TargetVersion '1.0.0.3'
if ($selection.Target.InstallLocation -ne 'target' -or
    $selection.Highest.InstallLocation -ne 'newest') {
    throw 'Side-by-side framework selection did not select the exact target and highest version.'
}

$bootstrapText = [IO.File]::ReadAllText((Join-Path $root 'Bootstrap.ps1'))
$amdGate = $bootstrapText.IndexOf('$x64Requirement = Get-X64ProviderRequirement')
$frameworkDownload = $bootstrapText.IndexOf('# --- 4. Framework MSIX state')
if ($amdGate -lt 0 -or $frameworkDownload -lt 0 -or $amdGate -gt $frameworkDownload) {
    throw 'The unsupported-AMD gate must run before framework download and installation.'
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('AionBootstrapTests-' + [guid]::NewGuid())
$previousCache = $env:NUGET_PACKAGES
try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    $missingDirectory = Join-Path $temporary 'clean-export\nuget-local'
    Ensure-Directory $missingDirectory
    if (-not (Test-Path -LiteralPath $missingDirectory -PathType Container)) {
        throw 'Bootstrap did not create the missing local NuGet feed directory.'
    }
    $env:NUGET_PACKAGES = $null
    $config = Join-Path $temporary 'nuget.config'
    [IO.File]::WriteAllText($config,
        '<configuration><config><add key="globalPackagesFolder" value="configured-cache" /></config></configuration>')
    $package = Join-Path $temporary 'input.nupkg'
    [IO.File]::WriteAllText($package, 'new SDK')
    $cacheRelative = 'aioninstructpreview.text.framework\1.0.1\aioninstructpreview.text.framework.1.0.1.nupkg'
    $cached = Join-Path (Join-Path $temporary 'configured-cache') $cacheRelative
    New-Item -ItemType Directory -Path (Split-Path $cached -Parent) -Force | Out-Null
    $check = @{
        PackagePath = $package
        Version = '1.0.1'
        ConfigFile = $config
        ProjectDirectory = $root
    }
    Assert-SdkNuGetCacheMatches @check
    [IO.File]::WriteAllText($cached, 'stale SDK')
    Assert-Rejected { Assert-SdkNuGetCacheMatches @check } 'contains a different Aion SDK'
    Copy-Item -LiteralPath $package -Destination $cached -Force
    Assert-SdkNuGetCacheMatches @check

    $env:NUGET_PACKAGES = Join-Path $temporary 'environment-cache'
    [IO.File]::WriteAllText($cached, 'stale config SDK ignored by environment override')
    Assert-SdkNuGetCacheMatches @check
    $environmentPackage = Join-Path $env:NUGET_PACKAGES $cacheRelative
    New-Item -ItemType Directory -Path (Split-Path $environmentPackage -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($environmentPackage, 'stale environment SDK')
    Assert-Rejected { Assert-SdkNuGetCacheMatches @check } 'contains a different Aion SDK'
    Copy-Item -LiteralPath $package -Destination $environmentPackage -Force
    Assert-SdkNuGetCacheMatches @check

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $layout = Join-Path $temporary 'layout'
    $installed = Join-Path $temporary 'installed'
    New-Item -ItemType Directory -Path $layout, $installed | Out-Null
    $blockMap = Join-Path $layout 'AppxBlockMap.xml'
    [IO.File]::WriteAllText($blockMap, '<BlockMap>build A</BlockMap>')
    [IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), @'
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="AionInstructPreview.LanguageModel.Framework"
            Publisher="CN=Microsoft Corporation"
            Version="1.0.0.3"
            ProcessorArchitecture="x64" />
</Package>
'@)
    $msix = Join-Path $temporary 'framework.msix'
    [IO.Compression.ZipFile]::CreateFromDirectory($layout, $msix)
    $script:FrameworkPkgId = 'AionInstructPreview.LanguageModel.Framework'
    $identity = Assert-FrameworkMsixIdentity -MsixPath $msix `
        -ExpectedArchitecture x64 -ExpectedVersion ([version]'1.0.0.3')
    if ($identity.Version -ne [version]'1.0.0.3') {
        throw 'Framework identity validation returned the wrong version.'
    }
    Assert-Rejected {
        Assert-FrameworkMsixIdentity -MsixPath $msix `
            -ExpectedArchitecture ARM64 -ExpectedVersion ([version]'1.0.0.3')
    } 'is not the Aion ARM64 framework'
    Assert-Rejected {
        Assert-FrameworkMsixIdentity -MsixPath $msix `
            -ExpectedArchitecture x64 -ExpectedVersion ([version]'1.0.0.4')
    } 'expected 1.0.0.4'

    Assert-Rejected { Assert-LocalFrameworkMatches $msix $installed } 'block map is missing'
    Copy-Item $blockMap $installed
    Assert-LocalFrameworkMatches -MsixPath $msix -InstallLocation $installed
    [IO.File]::WriteAllText((Join-Path $installed 'AppxBlockMap.xml'), '<BlockMap>build B</BlockMap>')
    Assert-Rejected { Assert-LocalFrameworkMatches $msix $installed } 'same version but different contents'
    Assert-Rejected { Assert-MicrosoftSignedPackage $msix } 'not validly signed by Microsoft Corporation'

    $script:SdkNuGetSignerFingerprint = '9A1B131BEE0605433056A4EA3815478A8E177961A968C6C0027C1093D1FEB630'
    $script:nugetVerifyExitCode = 0
    $script:nugetVerifyArguments = $null
    function dotnet {
        $script:nugetVerifyArguments = @($args)
        $global:LASTEXITCODE = $script:nugetVerifyExitCode
        if ($script:nugetVerifyExitCode) { 'NU3001: signature mismatch' }
    }
    Assert-MicrosoftSignedNuGet $package
    if (($script:nugetVerifyArguments -join ' ') -notlike
        "*--certificate-fingerprint $script:SdkNuGetSignerFingerprint*") {
        throw 'NuGet verification did not enforce the expected signer fingerprint.'
    }
    $script:nugetVerifyExitCode = 1
    Assert-Rejected { Assert-MicrosoftSignedNuGet $package } 'does not have the expected Microsoft NuGet signature'

    Write-Output 'PASS: cache, framework identity/content, MSIX signature, and NuGet signer checks; no packages deployed.'
} finally {
    $env:NUGET_PACKAGES = $previousCache
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
