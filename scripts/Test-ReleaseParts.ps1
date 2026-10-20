<#
.SYNOPSIS
    Tests joining verified release parts and rejecting corrupt or unsafe manifests.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReleaseParts.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('AionJoinPartsTests-' + [guid]::NewGuid())
function Assert-Throws {
    param([scriptblock]$Action)
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw 'Expected an explicit validation failure.' }
}
try {
    [void][IO.Directory]::CreateDirectory($root)
    $first = Join-Path $root 'test.msix.001'
    $last = Join-Path $root 'test.msix.002'
    $whole = Join-Path $root 'source.bin'
    [IO.File]::WriteAllBytes($first, [byte[]](1..5))
    [IO.File]::WriteAllBytes($last, [byte[]](6..7))
    [IO.File]::WriteAllBytes($whole, [byte[]](1..7))
    $manifest = [pscustomobject]@{
        schemaVersion = 1; fileName = 'test.msix'; length = 7; partSize = 5
        sha256 = (Get-FileHash $whole -Algorithm SHA256).Hash
        parts = @(
            [pscustomobject]@{ name = 'test.msix.001'; length = 5; sha256 = (Get-FileHash $first -Algorithm SHA256).Hash },
            [pscustomobject]@{ name = 'test.msix.002'; length = 2; sha256 = (Get-FileHash $last -Algorithm SHA256).Hash }
        )
    }
    $validLastPartHash = $manifest.parts[1].sha256
    $output = Join-Path $root 'test.msix'
    Join-ReleaseParts -Manifest $manifest -PartDirectory $root -OutputPath $output
    if ((Get-FileHash $output).Hash -ne $manifest.sha256) { throw 'Round trip differs.' }
    $expectedHash = (Get-FileHash $output).Hash
    [IO.File]::WriteAllBytes($last, [byte[]](8..9))
    Assert-Throws { Join-ReleaseParts -Manifest $manifest -PartDirectory $root -OutputPath $output }
    if ((Get-FileHash $output).Hash -ne $expectedHash) { throw 'Failure replaced a good output.' }
    if (@(Get-ChildItem $root -Filter '*.joining-*').Count) { throw 'Failure left a temporary file.' }
    $manifest.parts[0].name = '..\test.msix.001'
    Assert-Throws { Assert-ReleasePartsManifest -Manifest $manifest -ExpectedFileName 'test.msix' }
    $manifest.parts[0].name = 'test.msix.002'
    Assert-Throws { Assert-ReleasePartsManifest -Manifest $manifest -ExpectedFileName 'test.msix' }
    $manifest.parts[0].name = 'test.msix.001'
    $manifest.sha256 = 'invalid'
    Assert-Throws { Assert-ReleasePartsManifest -Manifest $manifest -ExpectedFileName 'test.msix' }
    $manifest.sha256 = $expectedHash
    $script:failDownload = $false
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $Headers, $OutFile, [switch]$UseBasicParsing)
        if ($Uri -eq 'manifest') { return [pscustomobject]@{ Content = $script:manifestContent } }
        if ($script:failDownload -and $Uri -eq 'test.msix.002') { throw 'Simulated download failure.' }
        $bytes = if ($Uri -eq 'test.msix.001') { [byte[]](1..5) } else { [byte[]](6..7) }
        [IO.File]::WriteAllBytes($OutFile, $bytes)
    }
    $resolveUrl = { param($name) $name }
    Receive-ReleaseParts -Manifest $manifest -OutputPath $output -Headers @{} -ResolvePartUrl $resolveUrl
    if ((Get-FileHash $output).Hash -ne $expectedHash) { throw 'Downloaded parts did not rejoin correctly.' }
    if (@(Get-ChildItem $root -Directory -Filter 'parts-*').Count) { throw 'Success retained download parts.' }
    $script:failDownload = $true
    Assert-Throws { Receive-ReleaseParts -Manifest $manifest -OutputPath $output -Headers @{} -ResolvePartUrl $resolveUrl }
    if (@(Get-ChildItem $root -Directory -Filter 'parts-*').Count) { throw 'Failed download retained partial parts.' }
    if ((Get-FileHash $output).Hash -ne $expectedHash) { throw 'Download failure replaced the previous package.' }
    $script:failDownload = $false
    $manifest.parts[1].sha256 = ('0' * 64)
    Assert-Throws { Receive-ReleaseParts -Manifest $manifest -OutputPath $output -Headers @{} -ResolvePartUrl $resolveUrl }
    if (@(Get-ChildItem $root -Directory -Filter 'parts-*').Count) { throw 'Hash failure retained download parts.' }
    $manifest.parts[1].sha256 = $validLastPartHash
    $json = $manifest | ConvertTo-Json -Depth 6
    foreach ($asBytes in $true, $false) {
        if ($asBytes) { $script:manifestContent = [Text.Encoding]::UTF8.GetBytes($json) }
        else { $script:manifestContent = $json }
        $parsed = Get-ReleasePartsManifest -Uri 'manifest' -Headers @{}
        Assert-ReleasePartsManifest -Manifest $parsed -ExpectedFileName 'test.msix'
    }
    $script:manifestContent = 'not-json'
    Assert-Throws { Get-ReleasePartsManifest -Uri 'manifest' -Headers @{} }
    function Remove-Item {
        [CmdletBinding()]
        param($LiteralPath, [switch]$Recurse, [switch]$Force)
        if ((Split-Path $LiteralPath -Leaf) -like 'parts-*') { throw 'Simulated locked download directory.' }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
    $cleanupWarnings = @()
    Receive-ReleaseParts -Manifest $manifest -OutputPath $output -Headers @{} -ResolvePartUrl $resolveUrl `
        -WarningVariable cleanupWarnings
    if (-not $cleanupWarnings.Count -or (Get-FileHash $output).Hash -ne $expectedHash) {
        throw 'Cleanup failure replaced a successful download result or was not reported.'
    }
    $script:failDownload = $true
    $failure = ''
    try {
        Receive-ReleaseParts -Manifest $manifest -OutputPath $output -Headers @{} -ResolvePartUrl $resolveUrl
    } catch { $failure = $_.Exception.Message }
    if ($failure -ne 'Simulated download failure.') { throw 'Cleanup error replaced the original download failure.' }
    Write-Output 'PASS: manifest JSON/octet-stream, verified join, safe cleanup, output preservation and cleanup-error reporting.'
} finally { [IO.Directory]::Delete($root, $true) }
