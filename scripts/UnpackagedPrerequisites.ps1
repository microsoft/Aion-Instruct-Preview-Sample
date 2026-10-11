function Get-NativeAionArchitecture {
    $raw = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    switch ($raw) {
        'ARM64' { return 'ARM64' }
        'AMD64' { return 'x64' }
        default { throw "Unsupported native architecture '$raw'. Use a 64-bit ARM64 or x64 PowerShell." }
    }
}

function Get-AionFrameworkPackage {
    param([string]$Architecture, [version]$MinimumVersion = [version]'1.0.0.3')
    $packages = @(Get-AppxPackage 'Microsoft.AionInstructPreview.Framework.1.0' |
        Where-Object { "$($_.Architecture)" -eq $Architecture } |
        Sort-Object { [version]$_.Version } -Descending)
    if ($packages.Count -eq 0 -or [version]$packages[0].Version -lt $MinimumVersion) {
        throw "Install the $Architecture Aion Instruct Preview framework $MinimumVersion or newer."
    }
    return $packages[0]
}

function Assert-WindowsAppRuntime2 {
    param(
        [Parameter(Mandatory)]
        [string]$Architecture,
        [version]$MinimumVersion = [version]'2.0.1.0'
    )
    $packages = @(Get-AppxPackage 'Microsoft.WindowsAppRuntime.2*' |
        Where-Object { "$($_.Architecture)" -eq $Architecture } |
        Sort-Object { [version]$_.Version } -Descending)
    if ($packages.Count -eq 0 -or [version]$packages[0].Version -lt $MinimumVersion) {
        throw "Install the $Architecture Windows App Runtime 2 $MinimumVersion or newer: winget install --id Microsoft.WindowsAppRuntime.2.0"
    }
}

function Assert-UnpackagedSdkCacheMatches {
    param(
        [string]$PackagePath,
        [string]$Version,
        [string]$ConfigFile,
        [string]$ProjectPath
    )
    $settingsArgs = @()
    if ($ConfigFile) { $settingsArgs += "-p:RestoreConfigFile=$ConfigFile" }
    $location = & dotnet msbuild $ProjectPath -nologo `
        '-target:_GetRestoreProjectStyle;_GetRestoreSettings' `
        -getProperty:_OutputPackagesPath @settingsArgs
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($location -join "`n"))) {
        throw 'Could not resolve the project NuGet package cache.'
    }
    $cacheRoot = ($location -join "`n").Trim()
    if (-not [IO.Path]::IsPathRooted($cacheRoot)) {
        throw "NuGet returned an invalid package cache location: $cacheRoot"
    }
    $cached = Join-Path $cacheRoot (
        "aioninstructpreview.text.framework\$Version\aioninstructpreview.text.framework.$Version.nupkg")
    if ((Test-Path $cached -PathType Leaf) -and
        (Get-FileHash $cached -Algorithm SHA256).Hash -ne
        (Get-FileHash $PackagePath -Algorithm SHA256).Hash) {
        throw "The effective NuGet cache contains a different Aion SDK $Version at '$cached'. " +
            'Set NUGET_PACKAGES to an existing empty directory and rerun.'
    }
}
