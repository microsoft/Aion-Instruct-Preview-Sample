# Run.ps1 -- build and run the unpackaged CONSOLE chat sample.
#
# Same model/runtime prerequisites as the WPF sample. This app streams the
# model's reply to stdout so terminal output can be captured directly.
#
# Usage:
#   .\Run.ps1                       # default prompt, output to the console
#   .\Run.ps1 "your prompt here"    # custom prompt
#   .\Run.ps1 -CaptureLog out.log   # tee stdout+stderr (merged) to a file for
#                                   # grepping native noise non-interactively
#
# Use -CaptureLog to save stdout and stderr for inspection.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Prompt,
    [string] $CaptureLog,
    [string] $NuGetConfig
)

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

$csproj = Join-Path $here "AionInstructPreview.Chat.Console.csproj"
Assert-UnpackagedSdkCacheMatches -PackagePath $sdkNupkg[0].FullName -Version '1.0.1' `
    -ConfigFile $configPath -ProjectPath $csproj

# Build first so build output never pollutes the captured run.
dotnet build $csproj -c Release @restoreArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Console sample build failed (exit $LASTEXITCODE); no executable was launched."
}

# Resolve this build's output rather than selecting a stale or wrong-architecture executable.
$targetPath = & dotnet msbuild $csproj -nologo -p:Configuration=Release -getProperty:TargetPath @restoreArgs
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($targetPath)) {
    throw "Could not resolve the console sample build output (exit $LASTEXITCODE)."
}
$exePath = [IO.Path]::ChangeExtension($targetPath.Trim(), '.exe')
$exe = Get-Item -LiteralPath $exePath -ErrorAction Stop

$argList = @()
if ($Prompt) { $argList = $Prompt }

if ($CaptureLog) {
    Write-Host "Capturing stdout+stderr to $CaptureLog ..."
    & $exe.FullName @argList *> $CaptureLog
    Write-Host "--- captured output ---"
    Get-Content $CaptureLog
} else {
    & $exe.FullName @argList
}
