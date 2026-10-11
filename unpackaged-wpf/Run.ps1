# Run.ps1 -- build and run the unpackaged WPF chat sample.
#
# Prereqs (same model dependency as the packaged AionInstructPreview.Chat):
#   - The Aion Instruct Preview SDK framework MSIX is installed
#     (Microsoft.AionInstructPreview.Framework.1.0). See the repo root README
#     for how to install it.
#   - Windows App Runtime 2 is installed
#     (winget install --id Microsoft.WindowsAppRuntime.2.0).
#   - .NET SDK 9 or later.
#
# Unlike the packaged sample, nothing is copied locally: the winmd comes from
# the SDK NuGet at build time, and the model files + native DLLs are consumed
# in place from the installed framework package at runtime.

param([string]$NuGetConfig)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) 'scripts\UnpackagedPrerequisites.ps1')
$restoreArgs = @()
if ($PSBoundParameters.ContainsKey('NuGetConfig')) {
    $configPath = (Get-Item -LiteralPath $NuGetConfig -ErrorAction Stop).FullName
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'NuGetConfig must be a file.' }
    $restoreArgs = @("-p:RestoreConfigFile=$configPath")
}

Write-Host "Checking for the installed Aion Instruct Preview framework package..."
$arch = Get-NativeAionArchitecture
$pkg = Get-AionFrameworkPackage -Architecture $arch

Write-Host ("Using framework {0} {1} ({2})." -f $pkg.Name, $pkg.Version, $pkg.Architecture)

# Inference uses bundled WinML/ORT; WAR 2 supplies the remaining Windows App SDK types.
Assert-WindowsAppRuntime2 -Architecture $arch
$nugetLocal = Join-Path (Split-Path $here -Parent) "nuget-local"
$sdkNupkg = @(Get-ChildItem -Path $nugetLocal -Filter "AionInstructPreview.Text.Framework.1.0.1.nupkg" -ErrorAction SilentlyContinue)
if ($sdkNupkg.Count -ne 1) {
    Write-Error "SDK NuGet package not found in $nugetLocal. Run .\Bootstrap.ps1 from the repo root first (it downloads the SDK), or follow the 'Getting the SDK NuGet' section of the README."
    exit 1
}

$csproj = Join-Path $here "AionInstructPreview.Chat.Wpf.csproj"
Assert-UnpackagedSdkCacheMatches -PackagePath $sdkNupkg[0].FullName -Version '1.0.1' `
    -ConfigFile $configPath -ProjectPath $csproj
dotnet run --project $csproj -c Release @restoreArgs
