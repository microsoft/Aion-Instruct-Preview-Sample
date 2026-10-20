<#
.SYNOPSIS
    Validates release-part manifests and rejoins the original signed MSIX.
#>
function Assert-ReleasePartsManifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$ExpectedFileName)
    if ($Manifest.schemaVersion -ne 1 -or $Manifest.fileName -cne $ExpectedFileName -or
        $Manifest.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        $Manifest.length -le 0 -or $Manifest.length -ne [long]$Manifest.length -or
        $Manifest.partSize -lt 1 -or $Manifest.partSize -gt (2GB - 256KB) -or
        $Manifest.partSize -ne [long]$Manifest.partSize) {
        throw 'Invalid release-parts manifest header.'
    }
    $parts = @($Manifest.parts)
    if ($parts.Count -lt 1 -or $parts.Count -gt 999) { throw 'Invalid release-parts count.' }
    $total = [long]0
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $part = $parts[$index]
        $expectedName = '{0}.{1:D3}' -f $ExpectedFileName, ($index + 1)
        if ($part.name -cne $expectedName -or $part.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            $part.length -le 0 -or $part.length -gt $Manifest.partSize -or
            $part.length -ne [long]$part.length -or
            ($index -lt $parts.Count - 1 -and $part.length -ne $Manifest.partSize)) {
            throw "Invalid release-part entry $($index + 1)."
        }
        $total += [long]$part.length
    }
    if ($total -ne $Manifest.length) { throw 'Release-part lengths do not match the original file.' }
}

function Join-ReleaseParts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$PartDirectory,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $ErrorActionPreference = 'Stop'
    Assert-ReleasePartsManifest -Manifest $Manifest -ExpectedFileName ([IO.Path]::GetFileName($OutputPath))
    $temporary = $OutputPath + '.joining-' + [guid]::NewGuid()
    try {
        $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            foreach ($part in $Manifest.parts) {
                $path = Join-Path $PartDirectory $part.name
                $file = Get-Item -LiteralPath $path -ErrorAction Stop
                if ($file.Length -ne $part.length -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $part.sha256) {
                    throw "Release-part length or SHA-256 mismatch: $($part.name)"
                }

                $partStream = [IO.File]::OpenRead($path)
                try { $partStream.CopyTo($output) } finally { $partStream.Dispose() }
            }
        } finally { $output.Dispose() }
        if ((Get-Item -LiteralPath $temporary).Length -ne $Manifest.length -or
            (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $Manifest.sha256) {
            throw 'Rejoined MSIX length or SHA-256 mismatch.'
        }
        Move-Item -LiteralPath $temporary -Destination $OutputPath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            try { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop }
            catch { Write-Warning "Could not remove temporary joined file '$temporary'. Remove it once no process holds it." }
        }
    }
}

function Receive-ReleaseParts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][scriptblock]$ResolvePartUrl,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $ErrorActionPreference = 'Stop'
    Assert-ReleasePartsManifest -Manifest $Manifest -ExpectedFileName ([IO.Path]::GetFileName($OutputPath))
    # Only this invocation owns the download directory. Do not delete a shared staging folder.
    $partsDirectory = Join-Path (Split-Path $OutputPath -Parent) ('parts-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($partsDirectory)
    try {
        foreach ($part in $Manifest.parts) {
            $url = & $ResolvePartUrl $part.name
            Invoke-WebRequest -Uri $url -Headers $Headers `
                -OutFile (Join-Path $partsDirectory $part.name) -ErrorAction Stop
        }
        Join-ReleaseParts -Manifest $Manifest -PartDirectory $partsDirectory -OutputPath $OutputPath
    } finally {
        try { Remove-Item -LiteralPath $partsDirectory -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Could not remove temporary download parts '$partsDirectory'. Remove them once no process holds them." }
    }
}

function Get-ReleasePartsManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -ErrorAction Stop
    # Release assets may use application/octet-stream rather than application/json.
    $text = if ($response.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($response.Content)
    } else { [string]$response.Content }
    return ($text.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
}
