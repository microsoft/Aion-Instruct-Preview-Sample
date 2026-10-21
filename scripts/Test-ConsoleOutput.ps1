<#
.SYNOPSIS
    Checks redirected chat/TI output and loading diagnostics against an installed SDK.
.PARAMETER ExecutablePath
    Path to the built console sample for this device architecture.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$ExecutablePath = (Get-Item -LiteralPath $ExecutablePath -ErrorAction Stop).FullName
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('AionConsoleOutputTests-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temporary)
function Invoke-ConsoleCheck {
    param([string[]]$Arguments, [string]$Name, [int]$ExpectedExitCode)
    $stdout = Join-Path $temporary ($Name + '.stdout')
    $stderr = Join-Path $temporary ($Name + '.stderr')
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList $Arguments `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
    try {
        if (-not $process.WaitForExit(600000)) {
            Stop-Process -Id $process.Id -Force
            throw "$Name exceeded the ten-minute test limit."
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne $ExpectedExitCode) {
            throw "$Name returned $($process.ExitCode), expected $ExpectedExitCode. stderr: $([IO.File]::ReadAllText($stderr))"
        }
        return [pscustomobject]@{
            Output = [IO.File]::ReadAllText($stdout, [Text.Encoding]::UTF8)
            Error = [IO.File]::ReadAllText($stderr, [Text.Encoding]::UTF8)
        }
    } finally { $process.Dispose() }
}
try {
    $inputPath = Join-Path $temporary 'input.txt'
    [IO.File]::WriteAllText($inputPath,
        'The library reopened on Monday. It has new reading rooms and additional study desks.',
        [Text.UTF8Encoding]::new($false))
    $chat = Invoke-ConsoleCheck -Arguments @('"Say hello in one short sentence."') -Name 'chat' -ExpectedExitCode 0
    if ($chat.Output -notmatch 'Aion Instruct Preview: \S' -or
        $chat.Error -notmatch 'Loading model \(first run may take several minutes\)' -or
        $chat.Error -notmatch '\[Aion Instruct Preview-console\] Complete\.') {
        throw 'Chat must retain stdout generation and stderr diagnostics after native initialization.'
    }
    $summary = Invoke-ConsoleCheck -Arguments @('--text-intelligence', 'Summarize', "`"$inputPath`"") `
        -Name 'summary' -ExpectedExitCode 0
    if ([string]::IsNullOrWhiteSpace($summary.Output) -or
        $summary.Error -notmatch 'Loading model \(first run may take several minutes\)' -or
        $summary.Error -notmatch 'Text intelligence status: Complete' -or
        $summary.Output -match 'Loading model|Text intelligence status:') {
        throw 'TI must retain result-only stdout and loading/completion stderr after native initialization.'
    }
    $invalid = Invoke-ConsoleCheck -Arguments @('--text-intelligence', 'Summarize', "`"$inputPath`"", 'adapter.safetensors') `
        -Name 'invalid' -ExpectedExitCode 1
    if ($invalid.Error -notmatch 'Adapter paths are only used with GenerateWithLoRA' -or
        $invalid.Error -match 'Loading model' -or -not [string]::IsNullOrWhiteSpace($invalid.Output)) {
        throw 'Invalid TI arguments must fail before loading a model and leave stdout empty.'
    }
    [IO.File]::WriteAllText($inputPath, "Invalid`0text", [Text.UTF8Encoding]::new($false))
    $nativeFailure = Invoke-ConsoleCheck -Arguments @('--text-intelligence', 'Summarize', "`"$inputPath`"") `
        -Name 'native-failure' -ExpectedExitCode 1
    if ($nativeFailure.Error -notmatch 'Loading model' -or
        $nativeFailure.Error -notmatch 'The operation failed \(0x80070057\)' -or
        -not [string]::IsNullOrWhiteSpace($nativeFailure.Output)) {
        throw 'TI must preserve the operational diagnostic after native model disposal on failure.'
    }
    Write-Output 'PASS: redirected chat/TI outputs and post-disposal errors survive; loading/status diagnostics use stderr; invalid arguments do not load the model.'
} finally {
    foreach ($file in (Get-ChildItem -LiteralPath $temporary -File)) { [IO.File]::Delete($file.FullName) }
    [IO.Directory]::Delete($temporary, $false)
}
