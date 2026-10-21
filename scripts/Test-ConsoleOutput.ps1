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
    # Windows PowerShell 5.1 returns a Process that holds no handle, so its ExitCode is $null
    # once the process exits. Reading Handle here keeps one open: don't remove this line or move
    # it after WaitForExit, even though it looks unused.
    $null = $process.Handle
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
    $conversationPath = Join-Path $temporary 'conversation.json'
    [IO.File]::WriteAllText($conversationPath,
        '[{"participant":"Alex","message":"The planning meeting is Tuesday at ten."},{"participant":"Robin","message":"I will bring the project schedule."}]',
        [Text.UTF8Encoding]::new($false))
    $conversation = Invoke-ConsoleCheck -Arguments @('--text-intelligence', 'SummarizeConversation', "`"$conversationPath`"") `
        -Name 'conversation' -ExpectedExitCode 0
    if ([string]::IsNullOrWhiteSpace($conversation.Output) -or
        $conversation.Output -match '\AV=[01](?:\r?\n|$)' -or
        $conversation.Error -notmatch 'Text intelligence status: Complete') {
        throw 'Conversation summaries must contain summary text, not a leading native RAI protocol line.'
    }
    [IO.File]::WriteAllText($inputPath, 'Apples cost 3 dollars and weigh 1 kilogram. Pears cost 4 dollars and weigh 2 kilograms.',
        [Text.UTF8Encoding]::new($false))
    $table = Invoke-ConsoleCheck -Arguments @('--text-intelligence', 'TextToTable', "`"$inputPath`"") `
        -Name 'table' -ExpectedExitCode 0
    if ([string]::IsNullOrWhiteSpace($table.Output) -or $table.Output.StartsWith("`r") -or
        $table.Output.StartsWith("`n") -or $table.Error -notmatch 'Text intelligence status: Complete') {
        throw 'Table output must start with the header row, not an empty text result.'
    }
    $invalidAdapter = Join-Path $temporary 'corrupt.safetensors'
    [IO.File]::WriteAllText($invalidAdapter, 'not a safetensors adapter', [Text.UTF8Encoding]::new($false))
    $adapterFailure = Invoke-ConsoleCheck -Arguments @('--text-intelligence', 'GenerateWithLoRA',
        "`"$inputPath`"", "`"$invalidAdapter`"") -Name 'invalid-adapter' -ExpectedExitCode 1
    if ($adapterFailure.Error -notmatch 'InvalidAdapter' -or
        $adapterFailure.Error -notmatch 'Adapter load failed \(HRESULT=0x8007000D\)' -or
        -not [string]::IsNullOrWhiteSpace($adapterFailure.Output)) {
        throw 'Failed adapter loads must retain the SDK-authored diagnostic without output.'
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
    Write-Output 'PASS: redirected chat/TI outputs and post-disposal errors survive; conversation metadata is removed; diagnostics use stderr; invalid arguments do not load the model.'
} finally {
    foreach ($file in (Get-ChildItem -LiteralPath $temporary -File)) { [IO.File]::Delete($file.FullName) }
    [IO.Directory]::Delete($temporary, $false)
}
