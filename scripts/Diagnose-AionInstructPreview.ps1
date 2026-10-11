# Diagnose-AionInstructPreview.ps1 -- first-launch hang diagnostic for AionInstructPreview.Chat.
#
# When the app sits on the "Loading Aion Instruct Preview model..." screen longer than
# expected for cold NPU compilation, run this script to figure out
# which prerequisite is missing or which EP path the SDK is being driven down.
#
# Usage:
#     .\Diagnose-AionInstructPreview.ps1                   # full diagnostic; auto-launches AionInstructPreview.Chat for ODS capture
#     .\Diagnose-AionInstructPreview.ps1 -SkipLaunch       # don't launch the app (capture whatever is already running)
#     .\Diagnose-AionInstructPreview.ps1 -CaptureSeconds 120
#
# Prints a colored pass/fail line per check plus a summary at the end. No
# persistent side effects (a brief AionInstructPreview.Chat launch is the only externally
# visible action, and only when -SkipLaunch is not set).
#
# EP reporting: section 4b reads the selected EP from the cache when available;
# section 6 falls back to a live OutputDebugString capture.

[CmdletBinding()]
param(
    [switch]$SkipLaunch,
    [int]$CaptureSeconds = 90
)

$ErrorActionPreference = 'Continue'

$script:passes = 0
$script:warns  = 0
$script:fails  = 0

# Detect the native machine architecture so package checks match the hardware,
# even when PowerShell is running under emulation.
$emulatedArch = $env:PROCESSOR_ARCHITECTURE
$nativeArch   = $env:PROCESSOR_ARCHITEW6432
if ($nativeArch) {
    $rawArch = $nativeArch
} else {
    $rawArch = $emulatedArch
}

$arch = switch ($rawArch) {
    'ARM64' { 'ARM64' }
    'AMD64' { 'x64' }
    default { $null }
}

function Write-Check {
    param(
        [ValidateSet('PASS','WARN','FAIL','INFO')] [string]$Status,
        [string]$Label,
        [string]$Detail = ''
    )
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'INFO' { 'Cyan' }
    }
    Write-Host ('[{0}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Label
    if ($Detail) {
        foreach ($line in $Detail -split "`r?`n") {
            Write-Host ('       ' + $line) -ForegroundColor DarkGray
        }
    }
    switch ($Status) {
        'PASS' { $script:passes++ }
        'WARN' { $script:warns++  }
        'FAIL' { $script:fails++  }
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===') -ForegroundColor White
}

Write-Host ''
Write-Host 'AionInstructPreview.Chat first-launch diagnostic' -ForegroundColor White
Write-Host ('Host: {0}  User: {1}  Date: {2}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date -Format 'u')) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Hardware sanity
# ---------------------------------------------------------------------------
Write-Section '1. Hardware'

$ci = Get-ComputerInfo -Property CsManufacturer, CsModel, CsProcessors -ErrorAction SilentlyContinue
$procName = '(unknown)'
if ($ci) {
    $proc = $ci.CsProcessors | Select-Object -First 1
    $procName = if ($proc) { $proc.Name } else { '(unknown)' }
    # PROCESSOR_ARCHITEW6432 is only set under WOW64, so on a native 64-bit shell it is
    # legitimately empty. Say so rather than printing a blank next to two populated lines,
    # which reads like a detection failure.
    $nativeArchDisplay = if ($nativeArch) { $nativeArch } else { '(not set -- native 64-bit shell, not WOW64)' }
    $detail = "Manufacturer: $($ci.CsManufacturer)`nModel: $($ci.CsModel)`nProcessor: $procName`nProcess architecture: $emulatedArch`nNative architecture: $nativeArchDisplay`nResolved architecture: $rawArch"

    if ($arch -eq 'ARM64' -and $procName -match 'Snapdragon|Qualcomm|Hexagon|Oryon') {
        Write-Check PASS 'Snapdragon ARM64 (Copilot+ PC class) -- QNN NPU path expected' $detail
    } elseif ($arch -eq 'ARM64') {
        Write-Check WARN 'ARM64 but processor name doesn''t match a known Snapdragon SKU' $detail
    } elseif ($arch -eq 'x64' -and $procName -match 'Intel|Core\s*Ultra|Lunar|Arrow|Meteor') {
        Write-Check PASS 'Intel x64 -- catalog OpenVINO NPU path expected' $detail
    } elseif ($arch -eq 'x64' -and $procName -match 'AMD|Ryzen|Strix') {
        Write-Check WARN 'AMD support is coming soon' $detail
    } elseif ($arch -eq 'x64') {
        Write-Check WARN 'x64 host, but the processor name does not match a supported Intel NPU' $detail
    } else {
        Write-Check WARN ('Unexpected architecture: ' + $rawArch) $detail
    }
} else {
    Write-Check WARN 'Get-ComputerInfo returned nothing -- can''t determine host class'
}

# NPU device presence
$npuDevices = @()
try {
    $npuDevices += Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            # Word boundaries to avoid "Input Device" matching "NPU" (i-NPU-t).
            $_.FriendlyName -match '\b(Hexagon|NPU|Neural Processor|AI Boost|VPU)\b' -and
            $_.Class -notin @('HIDClass','USB','Mouse','Keyboard','Bluetooth')
        }
} catch {}
if ($npuDevices.Count -gt 0) {
    $detail = ($npuDevices | ForEach-Object { '{0}  [{1}]' -f $_.FriendlyName, $_.Status }) -join "`n"
    $badStatus = $npuDevices | Where-Object Status -ne 'OK'
    if ($badStatus) {
        Write-Check WARN 'NPU device(s) found but not all healthy' $detail
    } else {
        Write-Check PASS 'NPU device visible to OS' $detail
    }
} else {
    Write-Check WARN 'No NPU-like device found in PnP enumeration (Hexagon / NPU / Neural / AI Boost)'
}

# ---------------------------------------------------------------------------
# 2. AppX prerequisites
# ---------------------------------------------------------------------------
Write-Section '2. AppX packages'

function Check-Package {
    param(
        [string]$Name,
        [string]$Friendly,
        [string]$MinVersion = '',
        [bool]$Required = $true
    )
    $pkgs = @(Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Architecture -eq $arch })
    if ($pkgs.Count -eq 0) {
        if ($Required) {
            Write-Check FAIL ("$Friendly not installed (Get-AppxPackage $Name returned nothing)")
        } else {
            Write-Check WARN ("$Friendly not installed (optional)")
        }
        return
    }
    foreach ($pkg in $pkgs) {
        $detail = "PackageFullName: $($pkg.PackageFullName)`nArchitecture: $($pkg.Architecture)  Version: $($pkg.Version)"
        if ($MinVersion -and [version]$pkg.Version -lt [version]$MinVersion) {
            $status = if ($Required) { 'FAIL' } else { 'WARN' }
            Write-Check $status ("$Friendly installed but older than required (need >= $MinVersion)") $detail
        } else {
            Write-Check PASS "$Friendly installed" $detail
        }
    }
}

Check-Package -Name 'Microsoft.AionInstructPreview.Framework.1.0' `
              -Friendly 'Aion Instruct Preview framework MSIX' -MinVersion '1.0.0.3'
Check-Package -Name 'Microsoft.WindowsAppRuntime.2' -Friendly 'Windows App Runtime 2' -MinVersion '2.0.1.0'
if ($arch -eq 'ARM64') {
    $qnn = @(Get-AppxPackage -Name '*WinML.Qualcomm.QNN.EP*.2*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Architecture -eq $arch })
    if ($qnn.Count -eq 0) {
        Write-Check INFO 'QNN EP 2 is not installed yet; the framework will acquire it on first model load'
    } else {
        Check-Package -Name '*WinML.Qualcomm.QNN.EP*.2*' `
                      -Friendly 'Qualcomm QNN execution provider 2' -MinVersion '2.2480.49.0'
    }
} elseif ($arch -eq 'x64' -and $procName -match 'Intel') {
    Check-Package -Name '*WinML.Intel.OpenVINO.EP.Framework.2*' `
                  -Friendly 'Intel OpenVINO catalog execution provider' `
                  -MinVersion '1.8.95.0'
} elseif ($arch -eq 'x64' -and $procName -match 'AMD|Ryzen|Strix') {
    Write-Check WARN 'AMD support is coming soon; provider readiness was not evaluated'
}
# The packaged WinUI app is optional: the console and WPF samples are equally valid
# consumers, and a developer using only those should not get a hard failure here.
Check-Package -Name 'AionInstructPreviewChat' -Friendly 'AionInstructPreview.Chat consumer app' -Required $false

# Wider EP package sweep -- informational only.
#
# Deliberately INFO, never PASS. This is a loose name match that also catches unrelated
# packages (Microsoft.Windows.Apprep.ChxApp, the various *.Framework.* companions), so a
# non-zero count says nothing about whether the SDK can actually run. It previously
# reported PASS on a machine whose required OpenVINO EP was missing and where the SDK
# could not start at all. The pinned per-architecture checks above are the real gate;
# this list is here to help a human see what is present.
Write-Host ''
Write-Host '       (scanning for execution-provider packages...)' -ForegroundColor DarkGray
$epPackages = @(Get-AppxPackage | Where-Object {
    $_.Name -match 'Qnn|Qualcomm|AMD|Vitis|WindowsWorkload|EP\.|ExecutionProvider|OnnxRuntime|MachineLearning|OpenVINO'
})
if ($epPackages.Count -gt 0) {
    $detail = ($epPackages | ForEach-Object { '{0,-65} {1,-12} {2}' -f $_.Name, $_.Architecture, $_.Version }) -join "`n"
    Write-Check INFO ("$($epPackages.Count) EP-related package(s) present (informational -- see the pinned check above)") $detail
} else {
    Write-Check INFO 'No EP-related packages found via AppX (informational -- see the pinned check above)'
}

# ---------------------------------------------------------------------------
# 3. Files on disk inside the Aion Instruct Preview framework MSIX
# ---------------------------------------------------------------------------
Write-Section '3. Aion Instruct Preview framework MSIX contents'

$aionPkg = Get-AppxPackage Microsoft.AionInstructPreview.Framework.1.0 -ErrorAction SilentlyContinue |
    Where-Object { $_.Architecture -eq $arch } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($aionPkg) {
    $installRoot = $aionPkg.InstallLocation
    Write-Check INFO ('Install location: ' + $installRoot)

    $expected = @{
        'AionInstructPreview.Text.dll'              = $true
        'muffinapi.dll'                   = $true
        'Models'                          = $true
    }
    $missing = @()
    foreach ($name in $expected.Keys) {
        if (-not (Test-Path (Join-Path $installRoot $name))) {
            $missing += $name
        }
    }
    if ($missing.Count -eq 0) {
        Write-Check PASS 'Required framework runtime and model files present'
    } else {
        Write-Check FAIL ('Missing in framework MSIX: ' + ($missing -join ', '))
    }

    # Models sub-dir contents
    $modelsDir = Join-Path $installRoot 'Models'
    if (Test-Path $modelsDir) {
        $modelFiles = Get-ChildItem $modelsDir -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'muffinformer|head_emb' } |
            ForEach-Object { '{0,-55} {1:N0} bytes' -f $_.Name, $_.Length }
        if ($modelFiles) {
            Write-Check PASS 'Model files present' (($modelFiles) -join "`n")
        } else {
            Write-Check FAIL 'Models\ folder exists but contains no expected model files'
        }
    }
} else {
    Write-Check FAIL 'Cannot inspect framework MSIX -- package not installed (see section 2)'
}

# ---------------------------------------------------------------------------
# 4. Compiled model cache (populated after first successful load)
# ---------------------------------------------------------------------------
Write-Section '4. Compiled model cache'

# Check the SDK's canonical cache path. The framework SDK 1.0 writes the compiled
# NPU context cache machine-wide under ProgramData (shared across users), keyed by
# <CacheRoot>\<framework-version>\<EP>\<arch>\.
$cacheLocations = @(
    @{ Path = (Join-Path $env:ProgramData 'Aion Instruct Preview\Cache'); Label = 'Canonical (machine-wide ProgramData)' }
)
$cacheFound = $false
foreach ($loc in $cacheLocations) {
    if (-not (Test-Path $loc.Path)) { continue }
    $files = @(Get-ChildItem $loc.Path -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { continue }
    $cacheFound = $true
    $totalMB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
    $sample = $files | Select-Object -First 8 | ForEach-Object {
        '{0,12:N0} bytes  {1}' -f $_.Length, $_.FullName.Substring($loc.Path.Length).TrimStart('\')
    }
    $detail = ($sample) -join "`n"
    Write-Check PASS ("$($loc.Label): $($files.Count) files, $totalMB MB at $($loc.Path)") $detail
}
if (-not $cacheFound) {
    Write-Check INFO 'No prior cache artifacts -- first launch may take several minutes to compile on the NPU'
}

# ---------------------------------------------------------------------------
# 4b. EP inferred from the on-disk cache layout (no relaunch required)
# ---------------------------------------------------------------------------
# The cache layout includes <CacheRoot>\<ver>\<EP>\<arch>\. Use the newest
# state file to infer the EP selected by the most recent load.
$script:cachedEp        = $null
$script:cachedEpArch    = $null
$script:cachedEpSource  = $null   # 'log-contents' or 'cache-path'
$script:cachedEpStateFile = $null

$stateFiles = @()
foreach ($loc in $cacheLocations) {
    if (-not (Test-Path $loc.Path)) { continue }
    $stateFiles += Get-ChildItem $loc.Path -Recurse -File -Filter '.aion-instruct-preview-cache-state.log' -ErrorAction SilentlyContinue |
        ForEach-Object { [PSCustomObject]@{ File = $_; Root = $loc.Path } }
}

if ($stateFiles.Count -gt 0) {
    $newest = $stateFiles | Sort-Object { $_.File.LastWriteTimeUtc } -Descending | Select-Object -First 1
    $stateFile = $newest.File
    $script:cachedEpStateFile = $stateFile.FullName

    # Path-segment parse: <root>\<ver>\<EP>\<arch>\.aion-instruct-preview-cache-state.log
    $rel = $stateFile.FullName.Substring($newest.Root.Length).TrimStart('\')
    $segs = $rel -split '\\'
    if ($segs.Count -ge 4) {
        # segs[0]=ver, segs[1]=EP, segs[2]=arch, segs[3]=filename
        $script:cachedEp     = $segs[1]
        $script:cachedEpArch = $segs[2]
        $script:cachedEpSource = 'cache-path'
    }

    # Prefer an explicit EP marker from the log contents if the SDK writes one.
    # Accept a few likely spellings for future SDK log formats.
    try {
        $logText = Get-Content $stateFile.FullName -Raw -ErrorAction Stop
        $m = [regex]::Match($logText, '(?im)\b(?:selected\s*)?EP\s*[=:]\s*([A-Za-z0-9_.\-]+)')
        if ($m.Success) {
            $script:cachedEp = $m.Groups[1].Value.Trim()
            $script:cachedEpSource = 'log-contents'
        }
    } catch {}

    if ($script:cachedEp) {
        $detail = "State file: $($stateFile.FullName)`nLast written: $($stateFile.LastWriteTime)`nSource: $($script:cachedEpSource)"
        if ($script:cachedEpArch) { $detail += "`nCache arch: $($script:cachedEpArch)" }
        Write-Check PASS ("EP from cache (no relaunch needed): $($script:cachedEp)") $detail
    } else {
        Write-Check INFO ('Found .aion-instruct-preview-cache-state.log but could not infer the EP from it.') "State file: $($stateFile.FullName)"
    }
} else {
    Write-Check INFO 'No .aion-instruct-preview-cache-state.log on disk yet -- EP can only come from a live capture (section 6) on first run.'
}

# ---------------------------------------------------------------------------
# 5. Is AionInstructPreview.Chat.exe currently running, and what's it doing?
# ---------------------------------------------------------------------------
# EP decision data comes from the SDK's OutputDebugString log line captured
# from the packaged AionInstructPreview.Chat process.
Write-Section '5. Live AionInstructPreview.Chat process snapshot'

$running = Get-Process -Name 'AionInstructPreview.Chat' -ErrorAction SilentlyContinue
if ($running) {
    foreach ($p in $running) {
        $detail = ("PID: {0}`nCPU(s) consumed: {1:N1}`nWorking set: {2:N0} KB`nThreads: {3}`nStart time: {4}" -f `
            $p.Id, $p.CPU, ($p.WorkingSet64 / 1KB), $p.Threads.Count, $p.StartTime)
        Write-Check INFO 'AionInstructPreview.Chat is running' $detail
    }
    Write-Check INFO 'Open Task Manager > Performance > NPU while loading. Sustained NPU activity = the model is compiling/running on the NPU as expected. Flat 0% NPU with a CPU core pegged means no NPU EP was selected -- check the EP decision in section 6.'
} else {
    Write-Check INFO 'AionInstructPreview.Chat is not currently running'
}

# ---------------------------------------------------------------------------
# 6. Live OutputDebugString capture -- launches AionInstructPreview.Chat (unless -SkipLaunch)
#    and tails the Win32 OutputDebugString stream looking for the SDK's
#    "Aion Instruct Preview: EP decision=..." line. Same data DebugView would show, captured
#    in-process via the DBWIN_* shared-memory protocol.
# ---------------------------------------------------------------------------
Write-Section '6. Live OutputDebugString capture'

# Inline C# capturer for the standard Win32 OutputDebugString listener protocol.
# Only one listener can drain the buffer at a time.
$capturerType = @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;

public class OdsCapture
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateEventW(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetEvent(IntPtr hEvent);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileMappingW(IntPtr hFile, IntPtr lpFileMappingAttributes, uint flProtect, uint dwMaximumSizeHigh, uint dwMaximumSizeLow, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, IntPtr dwNumberOfBytesToMap);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);

    private const uint PAGE_READWRITE = 0x04;
    private const uint FILE_MAP_READ  = 0x0004;
    private const uint WAIT_OBJECT_0  = 0x00000000;
    private const uint WAIT_TIMEOUT   = 0x00000102;
    private const int  ERROR_ALREADY_EXISTS = 183;

    private Thread _thread;
    private volatile bool _stop;
    private IntPtr _bufferReady, _dataReady, _fileMap, _buffer;

    // Keep this compatible with the C# compiler used by Windows PowerShell 5.1.
    private readonly ConcurrentQueue<Tuple<DateTime,int,string>> _events;
    public ConcurrentQueue<Tuple<DateTime,int,string>> Events { get { return _events; } }
    public string LastError { get; private set; }
    public bool BufferAlreadyExisted { get; private set; }

    public OdsCapture()
    {
        _events = new ConcurrentQueue<Tuple<DateTime,int,string>>();
    }

    // PowerShell-friendly wrapper around ConcurrentQueue.TryDequeue(out T).
    public Tuple<DateTime,int,string> TryDequeueOne()
    {
        Tuple<DateTime,int,string> t;
        return Events.TryDequeue(out t) ? t : null;
    }

    public bool Start()
    {
        _bufferReady = CreateEventW(IntPtr.Zero, /*manual*/ false, /*signaled*/ true, "DBWIN_BUFFER_READY");
        _dataReady   = CreateEventW(IntPtr.Zero, /*manual*/ false, /*signaled*/ false, "DBWIN_DATA_READY");
        _fileMap     = CreateFileMappingW((IntPtr)(-1), IntPtr.Zero, PAGE_READWRITE, 0, 4096, "DBWIN_BUFFER");
        if (Marshal.GetLastWin32Error() == ERROR_ALREADY_EXISTS) { BufferAlreadyExisted = true; }
        _buffer = MapViewOfFile(_fileMap, FILE_MAP_READ, 0, 0, (IntPtr)4096);

        if (_bufferReady == IntPtr.Zero || _dataReady == IntPtr.Zero || _fileMap == IntPtr.Zero || _buffer == IntPtr.Zero)
        {
            LastError = "Failed to acquire DBWIN_* objects (Win32 err=" + Marshal.GetLastWin32Error() + ")";
            return false;
        }

        _thread = new Thread(() => {
            while (!_stop)
            {
                SetEvent(_bufferReady);
                uint r = WaitForSingleObject(_dataReady, 250);
                if (r == WAIT_OBJECT_0)
                {
                    int pid = Marshal.ReadInt32(_buffer);
                    string msg = Marshal.PtrToStringAnsi(IntPtr.Add(_buffer, 4)) ?? "";
                    Events.Enqueue(Tuple.Create(DateTime.Now, pid, msg.TrimEnd('\r','\n')));
                }
            }
        });
        _thread.IsBackground = true;
        _thread.Start();
        return true;
    }

    public void Stop()
    {
        _stop = true;
        if (_thread != null) { _thread.Join(2000); }
        if (_buffer      != IntPtr.Zero) { UnmapViewOfFile(_buffer); }
        if (_fileMap     != IntPtr.Zero) { CloseHandle(_fileMap); }
        if (_dataReady   != IntPtr.Zero) { CloseHandle(_dataReady); }
        if (_bufferReady != IntPtr.Zero) { CloseHandle(_bufferReady); }
    }
}
'@

try {
    Add-Type -TypeDefinition $capturerType -Language CSharp -ErrorAction Stop
} catch {
    # Add-Type fails on second invocation in same session because type already
    # exists -- that's fine, the existing type is reusable.
    if (-not ($_.Exception.Message -match 'already exists')) {
        Write-Check WARN ('Could not compile ODS capturer: ' + $_.Exception.Message)
    }
}

# Warn if DebugView is already listening to the same buffer.
$dbgView = Get-Process -Name 'Dbgview*','DebugView*' -ErrorAction SilentlyContinue
if ($dbgView) {
    Write-Check WARN 'DebugView is running -- close it first, otherwise it will drain the OutputDebugString buffer and this section will see nothing'
}

# OutputDebugString capture only sees lines written while this script is listening.
$alreadyRunning = Get-Process -Name 'AionInstructPreview.Chat' -ErrorAction SilentlyContinue
if ($alreadyRunning -and $script:cachedEp) {
    # Use the cached EP value and skip live capture.
    Write-Check INFO ("AionInstructPreview.Chat is already running; EP already known from cache: $($script:cachedEp). Skipping live ODS capture (no relaunch needed). Pass -SkipLaunch to force a passive capture anyway.")
} elseif ($alreadyRunning -and -not $SkipLaunch) {
    Write-Check WARN 'AionInstructPreview.Chat is already running and no cached EP was found on disk -- its EP decision line has already fired and won''t be re-emitted. Close the app and rerun, or pass -SkipLaunch to capture passively.'
}

# Skip live capture only when the app is already running and the cache already
# identifies the selected EP.
$skipLiveCapture = $alreadyRunning -and $script:cachedEp -and -not $SkipLaunch

# Also skip when there is nothing that could possibly emit: the packaged app is not
# installed and we were not asked to wait for a manual launch. Otherwise the script spends
# its full capture window waiting for an app it has already reported it cannot start --
# which is the normal case for a developer using only the console or WPF sample.
$noAppToCapture = -not $SkipLaunch -and -not $alreadyRunning -and
                  -not (Get-AppxPackage AionInstructPreviewChat -ErrorAction SilentlyContinue)

if ($noAppToCapture) {
    $msg = 'Live capture skipped -- AionInstructPreview.Chat is not installed, so nothing would emit. '
    $msg += if ($script:cachedEp) {
        "EP is already known from the cache above: $($script:cachedEp)."
    } else {
        'Run one of the samples, then rerun with -SkipLaunch to capture passively.'
    }
    Write-Check INFO $msg
} elseif ($skipLiveCapture) {
    Write-Check INFO ('Live capture skipped -- EP already reported from cache above. Use -SkipLaunch for a passive live capture, or close the app and rerun for a fresh cold-launch capture.')
} elseif (-not ($capture = New-Object OdsCapture) -or -not $capture.Start()) {
    Write-Check FAIL ('Could not start ODS capture: ' + $(if ($capture) { $capture.LastError } else { 'capturer type unavailable' }))
} else {
    if ($capture.BufferAlreadyExisted) {
        Write-Check INFO 'DBWIN_BUFFER already existed -- another listener may compete for messages'
    }
    Write-Check INFO 'OutputDebugString capture started; tailing DBWIN_BUFFER...'

    # Launch through shell:AppsFolder so the app starts with packaged identity.
    $launchedProc = $null
    if (-not $SkipLaunch -and -not $alreadyRunning) {
        $AionInstructPreviewChat = Get-AppxPackage AionInstructPreviewChat -ErrorAction SilentlyContinue
        if ($AionInstructPreviewChat) {
            $aumid = "$($AionInstructPreviewChat.PackageFamilyName)!App"
            Write-Check INFO ("Launching $aumid ...")
            Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$aumid"
        } else {
            Write-Check WARN 'AionInstructPreviewChat package not installed -- cannot launch automatically. Pass -SkipLaunch and start the app yourself.'
        }
    } elseif ($SkipLaunch) {
        Write-Check INFO 'Skipping app launch (-SkipLaunch). Trigger AionInstructPreview.Chat manually now.'
    }

    # Print matching lines and keep a short drain window after the EP decision.
    $deadline = (Get-Date).AddSeconds($CaptureSeconds)
    $drainDeadline = $null   # set after the EP decision line appears
    $drainSeconds = 5
    $printedEvents = 0
    $sawEpDecision = $false
    $aionLines = New-Object System.Collections.ArrayList
    Write-Host ("       capturing up to {0} sec -- will short-circuit a few seconds after the 'Aion Instruct Preview: selected EP=' line..." -f $CaptureSeconds) -ForegroundColor DarkGray

    while ((Get-Date) -lt $deadline) {
        if ($sawEpDecision -and $drainDeadline -and (Get-Date) -ge $drainDeadline) { break }
        while ($null -ne ($evt = $capture.TryDequeueOne())) {
            $ts        = $evt.Item1.ToString('HH:mm:ss.fff')
            $eventPid  = $evt.Item2   # $pid is an automatic PS variable; don't shadow it
            $msg       = $evt.Item3
            $printedEvents++

            # Filter to lines from AionInstructPreview.Chat (or anything mentioning "Aion Instruct Preview").
            $procName = ''
            try { $procName = (Get-Process -Id $eventPid -ErrorAction Stop).ProcessName } catch {}
            $isAion = ($procName -eq 'AionInstructPreview.Chat') -or ($msg -match 'Aion Instruct Preview')

            if ($isAion) {
                Write-Host ('       ' + $ts + '  [' + $procName + '/' + $eventPid + ']  ' + $msg) -ForegroundColor Gray
                [void]$aionLines.Add($msg)
                # EP decision line: "Aion Instruct Preview: selected EP=..., Device=..., reason=..."
                if ($msg -match 'Aion Instruct Preview:\s*selected EP=' -and -not $sawEpDecision) {
                    $sawEpDecision = $true
                    $drainDeadline = (Get-Date).AddSeconds($drainSeconds)
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }

    $capture.Stop()

    if ($aionLines.Count -eq 0) {
        Write-Check WARN ("No Aion Instruct Preview OutputDebugString lines captured in $CaptureSeconds sec (total ODS events seen: $printedEvents). " +
            "If the app was already loaded, its EP decision line fired before capture started -- close and rerun. " +
            "If DebugView is running, it stole the messages.")
    } else {
        # Parse the EP decision line emitted by the SDK.
        $epLine = $aionLines | Where-Object { $_ -match 'Aion Instruct Preview:\s*selected EP=' } | Select-Object -First 1
        if ($epLine) {
            $ep      = if ($epLine -match 'EP=([^,]+)')     { $matches[1].Trim() } else { '?' }
            $device  = if ($epLine -match 'Device=([^,]+)') { $matches[1].Trim() } else { '?' }
            $reason  = if ($epLine -match 'reason=([^,]+)') { $matches[1].Trim() } else { '?' }

            switch -Regex ($reason) {
                '^catalog-certified$' {
                    Write-Check PASS "SDK selected $ep for $device -- cold NPU compilation may take several minutes"
                }
                '^no-npu-ep-available$' {
                    Write-Check FAIL ("SDK found no compatible NPU EP; CPU fallback is not supported. " +
                        'Verify the catalog provider version and NPU driver: QNN 2.2480.49+, ' +
                        'OpenVINO 1.8.95+. AMD support is coming soon.')
                }
                '^no-catalog$' {
                    Write-Check FAIL ('SDK could not enumerate the WinML catalog; CPU fallback is not supported. ' +
                        'Inspect the bundled WinML runtime and reinstall the Aion framework if needed.')
                }
                default {
                    Write-Check WARN ("Captured EP decision but reason='$reason' is unrecognized (newer SDK?). EP=$ep Device=$device")
                }
            }
            Write-Host ('       ' + $epLine) -ForegroundColor DarkGray

            # The verifier line confirms the selected EP backend DLL is loaded.
            $verifiedLine = $aionLines | Where-Object { $_ -match 'Aion Instruct Preview:\s*verified backend=' } | Select-Object -First 1
            if ($verifiedLine) {
                Write-Check PASS 'EP backend DLL verified loaded in-process'
                Write-Host ('       ' + $verifiedLine) -ForegroundColor DarkGray
            }

            # Cache outcome indicates whether this load is cold or warm.
            $cacheLine = $aionLines | Where-Object { $_ -match 'Aion Instruct Preview:\s*cache (hit|miss|skipped|rebuilt)' } | Select-Object -First 1
            if ($cacheLine) {
                Write-Check INFO ('Cache outcome: ' + $cacheLine)
            }
        } else {
            Write-Check INFO ('Captured ' + $aionLines.Count + ' Aion Instruct Preview line(s) but no "selected EP=" marker yet -- capture window may have ended before EP resolution finished. Try -CaptureSeconds 120.')
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor White
Write-Host ("Passes: {0}   Warnings: {1}   Failures: {2}" -f $script:passes, $script:warns, $script:fails)
Write-Host ''
Write-Host 'Tip: section 4b reports the EP from the on-disk cache layout when one exists, so an' -ForegroundColor White
Write-Host '     already-running app does not need to be closed + relaunched. Section 6 falls back to'
Write-Host '     a live OutputDebugString capture for the first (cold) run when no cache is present yet.'
Write-Host '     If you need to dig deeper, run' -ForegroundColor White
Write-Host '     DebugView (sysinternals) elevated with "Capture Win32" + "Capture Global Win32" enabled --'
Write-Host '     it shows the same stream plus everything else the SDK and ORT emit (Init progress,'
Write-Host '     QNN compile checkpoints, cache hit/miss). Close DebugView before re-running this script,'
Write-Host '     otherwise the two listeners race for the same buffer.'
Write-Host ''

# Exit with a code reflecting the pass/fail tally.
if ($script:fails -gt 0) { exit 1 } else { exit 0 }
