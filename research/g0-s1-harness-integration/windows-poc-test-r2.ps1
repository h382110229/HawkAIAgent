# HawkAIAgent G0-S1-R3-R3-R4 Windows PoC Test Script
# =================================================
# SAFETY: No admin required. No system modifications.
# All operations scoped to $TEST_DIR (precise, known path).
# Compatible with Windows PowerShell 5.1+.
# =================================================
# Exit codes:
#   0 = All Gate-blocking tests passed
#   1 = One or more Gate-blocking assertion failures
#   2 = Environment/prerequisite blocked (no assertion failures)
#   3 = Script internal error or cleanup failure
# =================================================
# Gate aggregation (truth table):
#   Gate-blocking categories: MandatoryFunctional, MandatorySecurity, EvidenceDependent
#   Non-blocking categories: Informational
#
#   Fatal internal error / cleanup error   → OVERALL ERROR   (exit 3)
#   Gate-blocking FAIL count > 0           → OVERALL FAIL    (exit 1)
#   Gate-blocking BLOCKED count > 0        → OVERALL BLOCKED (exit 2)
#   All Gate-blocking PASS                 → OVERALL PASS    (exit 0)
#   No Gate-blocking tests                 → OVERALL ERROR   (exit 3)
#   Informational never overrides Gate-blocking result
# =================================================

param(
    [switch]$KeepArtifacts,
    # R12-REV-11: Self-test-only mode — runs parser/pure/Node-backed tests, then exits
    # before any main-flow operations (npm install, ports, process management, Harness).
    [switch]$SelfTestOnly,
    # R15-REM-01: Fault injection for process-level exit 3 verification.
    # Only valid with -SelfTestOnly. Corrupts suite data before aggregation.
    [ValidateSet('None','MissingSuite','DeclaredMismatch','PassedMismatch','FailedNonZero','ManifestMismatch','Timeout','StdoutOversize','StderrOversize','DualStreamOversize','LongLine','BoundaryExact','BoundaryOver','CleanupFailure','JobAssignFailure','ParentHandleRegFailure','DescendantHandleRegFailure','CollectorReadFailure','CollectorDrainTimeout','MarkerDeletionWhileLive','MarkerDeletionFailure','GetProcessTimesFailure','WaitFailure','CloseHandleFailure','MetaRoleMismatch','MetaTokenMismatch','MetaExtraEntry','MetaExtraMarker','MetaNullEvidence','MetaEmptyManifest','MetaDuplicateExpectedPID','MetaDuplicateActualPID','CleanupIdentityMatch','CleanupIdentityMismatch','CleanupRegistrationFailure')]
    [string]$SelfTestFault = 'None',
    # R3-REM-04: Fast fault child mode — skips all test execution, constructs deterministic
    # suite records, injects fault, calls Invoke-SelfTestAggregation, exits.
    # Only valid with -SelfTestOnly and -SelfTestFault.
    [switch]$SelfTestFastFault,
    # R5-REM-01: Process tree identity token (CLI arg, queryable via Win32_Process.CommandLine)
    [string]$PLFToken = '',
    # R5-REM-01: Directory for PID marker files (parent + descendant identity evidence)
    [string]$PLFMarkerDir = ''
)

$ErrorActionPreference = "Stop"

# R15-REM-01: Guard — SelfTestFault only valid with SelfTestOnly
if ($SelfTestFault -ne 'None' -and -not $SelfTestOnly) {
    Write-Host "ERROR: -SelfTestFault requires -SelfTestOnly" -ForegroundColor Red
    exit 3
}
# R3-REM-04: Guard — SelfTestFastFault only valid with SelfTestOnly + SelfTestFault
if ($SelfTestFastFault -and ($SelfTestFault -eq 'None' -or -not $SelfTestOnly)) {
    Write-Host "ERROR: -SelfTestFastFault requires -SelfTestOnly and -SelfTestFault" -ForegroundColor Red
    exit 3
}

# === Control flow exceptions ===
class PrerequisiteBlocked : System.Exception {
    [string]$TestId
    PrerequisiteBlocked([string]$testId, [string]$message) : base($message) {
        $this.TestId = $testId
    }
}

class AssertionFailure : System.Exception {
    [string]$TestId
    AssertionFailure([string]$testId, [string]$message) : base($message) {
        $this.TestId = $testId
    }
}

# === Result tracking ===
$script:TestResults = @()
$script:ResultsGenerated = $false
# R12-REV-07: Self-test suite results collector for runtime-derived counts
$script:SelfTestSuiteResults = @{}
# R12-REV-04: Test-only judgment provider override (PS 5.1 compatible)
$script:TestJudgmentProviderOverride = $null
$script:FatalInternalError = $false
$script:FatalInternalErrorMessage = ""
$script:CleanupErrors = @()
# R1-01: Global capture-order counter for deterministic tie-breaking
$script:CaptureSequence = 0
# R12-REV-12: Self-test mode guard — prevents test injection parameters in production
$script:SelfTestMode = $false

# ================================================================
# R6-REM-01 + R7-REM-06: Bounded async dual-stream collector (inline C#)
# R7: Exceptions captured (not swallowed), Healthy flag, DrainTimedOut tracked.
# ================================================================
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;

public class BoundedStreamCollector
{
    public long StdoutTotalBytes { get; private set; }
    public long StdoutCapturedBytes { get; private set; }
    public bool StdoutTruncated { get; private set; }
    public byte[] StdoutRetainedBuffer { get; private set; }
    public string StdoutError { get; private set; }

    public long StderrTotalBytes { get; private set; }
    public long StderrCapturedBytes { get; private set; }
    public bool StderrTruncated { get; private set; }
    public byte[] StderrRetainedBuffer { get; private set; }
    public string StderrError { get; private set; }

    public bool DrainTimedOut { get; private set; }
    public bool StdoutFaulted { get; private set; }
    public bool StderrFaulted { get; private set; }
    public bool Healthy { get { return !StdoutFaulted && !StderrFaulted && !DrainTimedOut; } }

    public async Task CollectAsync(Stream stdout, Stream stderr, int limitBytes, int deadlineMs)
    {
        using (var cts = new CancellationTokenSource())
        {
            var stdoutTask = DrainStreamAsync(stdout, limitBytes, cts.Token);
            var stderrTask = DrainStreamAsync(stderr, limitBytes, cts.Token);
            var allDrain = Task.WhenAll(stdoutTask, stderrTask);
            var deadline = Task.Delay(deadlineMs);

            var completed = await Task.WhenAny(allDrain, deadline);
            if (completed != allDrain)
            {
                DrainTimedOut = true;
                cts.Cancel();
                try { await Task.WhenAll(stdoutTask, stderrTask); } catch { }
            }

            if (stdoutTask.IsFaulted)
            {
                StdoutFaulted = true;
                StdoutError = stdoutTask.Exception != null ? stdoutTask.Exception.InnerException != null ? stdoutTask.Exception.InnerException.Message : stdoutTask.Exception.Message : "unknown fault";
            }
            if (stderrTask.IsFaulted)
            {
                StderrFaulted = true;
                StderrError = stderrTask.Exception != null ? stderrTask.Exception.InnerException != null ? stderrTask.Exception.InnerException.Message : stderrTask.Exception.Message : "unknown fault";
            }

            var so = stdoutTask.IsCompleted && !stdoutTask.IsFaulted ? stdoutTask.Result : new StreamResult();
            var se = stderrTask.IsCompleted && !stderrTask.IsFaulted ? stderrTask.Result : new StreamResult();

            StdoutTotalBytes = so.TotalBytes;
            StdoutCapturedBytes = so.CapturedBytes;
            StdoutTruncated = so.Truncated;
            StdoutRetainedBuffer = so.Retained;
            if (so.ReadError != null && StdoutError == null) { StdoutError = so.ReadError; StdoutFaulted = true; }

            StderrTotalBytes = se.TotalBytes;
            StderrCapturedBytes = se.CapturedBytes;
            StderrTruncated = se.Truncated;
            StderrRetainedBuffer = se.Retained;
            if (se.ReadError != null && StderrError == null) { StderrError = se.ReadError; StderrFaulted = true; }
        }
    }

    private async Task<StreamResult> DrainStreamAsync(Stream stream, int limit, CancellationToken ct)
    {
        var r = new StreamResult();
        var retained = new byte[limit];
        var discard = new byte[8192];
        int off = 0;

        while (true)
        {
            int n;
            try { n = await stream.ReadAsync(discard, 0, discard.Length, ct); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { r.ReadError = ex.Message; break; }
            if (n <= 0) break;

            r.TotalBytes += n;

            if (off < limit)
            {
                int space = limit - off;
                int copy = Math.Min(n, space);
                Buffer.BlockCopy(discard, 0, retained, off, copy);
                off += copy;
                r.CapturedBytes += copy;
                if (copy < n) r.Truncated = true;
            }
            else
            {
                r.Truncated = true;
            }
        }
        if (r.TotalBytes > limit) r.Truncated = true;

        r.Retained = new byte[off];
        if (off > 0) Buffer.BlockCopy(retained, 0, r.Retained, 0, off);
        return r;
    }

    private class StreamResult
    {
        public long TotalBytes;
        public long CapturedBytes;
        public bool Truncated;
        public byte[] Retained = new byte[0];
        public string ReadError;
    }
}
"@

# ================================================================
# R6-REM-03: Windows Job Object helper (inline C#)
# Uses JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE for automatic descendant
# cleanup. Job handle close kills all assigned processes.
# ================================================================
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class JobObjectHelper
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr attrs, string name);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, int size);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int size, IntPtr retLen);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr handle);

    private const int ExtendedLimitInfo = 9;
    private const int BasicAccountingInfo = 1;
    private const uint KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public IntPtr MinimumWorkingSetSize;
        public IntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public IntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public IntPtr ProcessMemoryLimit;
        public IntPtr JobMemoryLimit;
        public ulong PeakProcessMemoryUsed;
        public ulong PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    public static IntPtr CreateKillOnCloseJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;

        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(info);
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(job, ExtendedLimitInfo, ptr, size))
            {
                CloseHandle(job);
                return IntPtr.Zero;
            }
        }
        finally { Marshal.FreeHGlobal(ptr); }
        return job;
    }

    public static bool AssignProcess(IntPtr job, int pid)
    {
        IntPtr hProc = new IntPtr(pid);
        // OpenProcess with PROCESS_SET_QUOTA | PROCESS_TERMINATE = 0x0200 | 0x0001
        IntPtr h = OpenProcess(0x0201, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return AssignProcessToJobObject(job, h); }
        finally { CloseHandle(h); }
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    public static int GetActiveProcessCount(IntPtr job)
    {
        var info = new JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
        int size = Marshal.SizeOf(info);
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (QueryInformationJobObject(job, BasicAccountingInfo, ptr, size, IntPtr.Zero))
            {
                info = (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(
                    ptr, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                return (int)info.ActiveProcesses;
            }
            return -1; // query failed
        }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    public static bool TerminateAll(IntPtr job, uint exitCode)
    {
        return TerminateJobObject(job, exitCode);
    }
}
"@

# ================================================================
# R7-REM-02: Process Handle Registry (inline C#)
# CIM-independent process management via held native handles.
# Uses SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_TERMINATE
# (no admin required for own child processes). PID-reuse safe.
# ================================================================
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public struct RegistrationResult
{
    public bool Success;
    public IntPtr Handle;
    public long CreationTime;
    public int Win32Error;
    public string Error;
}

public struct CloseAllResult
{
    public int Attempted;
    public int Succeeded;
    public int Failed;
    public int[] FailedPids;
    public bool AllClosed { get { return Failed == 0; } }
}

public class ProcessHandleRegistry
{
    private readonly List<ProcessEntry> _entries = new List<ProcessEntry>();

    public struct ProcessEntry
    {
        public IntPtr Handle;
        public int Pid;
        public long CreationTime;
        public string Token;
        public string Role;
        public bool Exited;
    }

    public int Count { get { return _entries.Count; } }

    private const uint ACCESS_MASK = 0x00101001;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;

    // R10-REM-04: Structured wait result types for semantic WAIT_FAILED handling.
    public enum WaitOutcome { Exited = 0, Timeout = 1, WaitFailed = 2 }
    public struct WaitResult
    {
        public WaitOutcome Outcome;
        public uint WaitCode;
        public int Win32Error;
        public int Pid;
        public bool Exited { get { return Outcome == WaitOutcome.Exited; } }
    }
    public struct TerminateWaitResult
    {
        public bool Terminated;
        public WaitResult Wait;
        public int TerminateWin32Error;
        public string TerminateError;
    }

    // R9-REM-08: Test-only fault injection hooks (static, process-wide scope).
    // Set/clear within try/finally to prevent cross-fixture contamination.
    // When active, simulated failures still close real handles to prevent leaks.
    public static bool TestHook_FailGetProcessTimes = false;
    public static bool TestHook_FailWait = false;
    public static bool TestHook_FailClose = false;
    // R11-REM-04: Deterministic error code for WaitFailure — replaces stale Marshal.GetLastWin32Error()
    public static int TestHook_WaitErrorCode = 0;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(IntPtr hProcess, out long lpCreationTime, out long lpExitTime, out long lpKernelTime, out long lpUserTime);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);

    public RegistrationResult RegisterProcess(int pid, string token, string role)
    {
        IntPtr h = OpenProcess(ACCESS_MASK, false, pid);
        if (h == IntPtr.Zero || h.ToInt64() == -1)
        {
            var err = new RegistrationResult { Success = false, Handle = IntPtr.Zero, CreationTime = 0, Win32Error = Marshal.GetLastWin32Error(), Error = "OpenProcess failed" };
            return err;
        }

        long creationTime = 0; long exitTime = 0; long kernelTime = 0; long userTime = 0;
        bool timesOk;
        if (TestHook_FailGetProcessTimes) { timesOk = false; } else { timesOk = GetProcessTimes(h, out creationTime, out exitTime, out kernelTime, out userTime); }
        if (!timesOk)
        {
            int w32 = Marshal.GetLastWin32Error();
            CloseHandle(h);
            return new RegistrationResult { Success = false, Handle = IntPtr.Zero, CreationTime = 0, Win32Error = w32, Error = "GetProcessTimes failed" };
        }
        if (creationTime == 0)
        {
            CloseHandle(h);
            return new RegistrationResult { Success = false, Handle = IntPtr.Zero, CreationTime = 0, Win32Error = 0, Error = "CreationTime is zero" };
        }

        var entry = new ProcessEntry
        {
            Handle = h, Pid = pid, CreationTime = creationTime,
            Token = token, Role = role, Exited = false
        };
        _entries.Add(entry);
        return new RegistrationResult { Success = true, Handle = h, CreationTime = creationTime, Win32Error = 0, Error = null };
    }

    // R10-REM-04: Structured wait status check returning Outcome + Win32Error.
    public WaitResult CheckWaitStatus(int index)
    {
        var wr = new WaitResult();
        if (index < 0 || index >= _entries.Count) { wr.Outcome = WaitOutcome.WaitFailed; wr.Win32Error = -1; return wr; }
        var entry = _entries[index];
        wr.Pid = entry.Pid;
        if (entry.Exited) { wr.Outcome = WaitOutcome.Exited; wr.WaitCode = WAIT_OBJECT_0; return wr; }
        uint result = TestHook_FailWait ? WAIT_FAILED : WaitForSingleObject(entry.Handle, 0);
        wr.WaitCode = result;
        if (result == WAIT_OBJECT_0)
        {
            entry.Exited = true;
            _entries[index] = entry;
            wr.Outcome = WaitOutcome.Exited;
        }
        else if (result == WAIT_TIMEOUT)
        {
            wr.Outcome = WaitOutcome.Timeout;
            // R11-REM-04: Use deterministic error code from hook when active, else OS
            wr.Win32Error = TestHook_FailWait ? TestHook_WaitErrorCode : (int)Marshal.GetLastWin32Error();
        }
        else
        {
            wr.Outcome = WaitOutcome.WaitFailed;
            // R11-REM-04: Use deterministic error code from hook when active, else OS
            wr.Win32Error = TestHook_FailWait ? TestHook_WaitErrorCode : (int)Marshal.GetLastWin32Error();
        }
        return wr;
    }

    // Backward-compatible: IsProcessExited delegates to CheckWaitStatus
    public bool IsProcessExited(int index)
    {
        return CheckWaitStatus(index).Exited;
    }

    // R10-REM-04: Structured terminate+wait returning full outcome.
    public TerminateWaitResult TerminateAndVerify(int index, uint exitCode, int waitMs)
    {
        var twr = new TerminateWaitResult();
        twr.Wait.Pid = (index >= 0 && index < _entries.Count) ? _entries[index].Pid : 0;
        if (index < 0 || index >= _entries.Count) { twr.TerminateError = "Index out of range"; return twr; }
        var entry = _entries[index];
        if (entry.Exited) { twr.Terminated = true; twr.Wait.Outcome = WaitOutcome.Exited; twr.Wait.WaitCode = WAIT_OBJECT_0; return twr; }
        if (!TerminateProcess(entry.Handle, exitCode))
        {
            twr.TerminateWin32Error = (int)Marshal.GetLastWin32Error();
            // R13-FU2: Use bounded wait (not zero-duration) — process may be already
            // terminating from another handle; give it time to fully exit.
            uint waitAfterTermFail = TestHook_FailWait ? WAIT_FAILED : WaitForSingleObject(entry.Handle, (uint)waitMs);
            twr.Wait.WaitCode = waitAfterTermFail;
            if (waitAfterTermFail == WAIT_OBJECT_0)
            {
                entry.Exited = true;
                _entries[index] = entry;
                twr.Terminated = false;
                twr.Wait.Outcome = WaitOutcome.Exited;
                return twr;
            }
            twr.TerminateError = "TerminateProcess failed";
            twr.Wait.Outcome = waitAfterTermFail == WAIT_FAILED ? WaitOutcome.WaitFailed : WaitOutcome.Timeout;
            // R11-REM-04: Use deterministic error code from hook when active, else OS
            twr.Wait.Win32Error = TestHook_FailWait ? TestHook_WaitErrorCode : (int)Marshal.GetLastWin32Error();
            return twr;
        }
        twr.Terminated = true;
        uint result = TestHook_FailWait ? WAIT_FAILED : WaitForSingleObject(entry.Handle, (uint)waitMs);
        twr.Wait.WaitCode = result;
        if (result == WAIT_OBJECT_0)
        {
            entry.Exited = true;
            _entries[index] = entry;
            twr.Wait.Outcome = WaitOutcome.Exited;
        }
        else if (result == WAIT_TIMEOUT)
        {
            twr.Wait.Outcome = WaitOutcome.Timeout;
            // R11-REM-04: Use deterministic error code from hook when active, else OS
            twr.Wait.Win32Error = TestHook_FailWait ? TestHook_WaitErrorCode : (int)Marshal.GetLastWin32Error();
        }
        else
        {
            twr.Wait.Outcome = WaitOutcome.WaitFailed;
            // R11-REM-04: Use deterministic error code from hook when active, else OS
            twr.Wait.Win32Error = TestHook_FailWait ? TestHook_WaitErrorCode : (int)Marshal.GetLastWin32Error();
        }
        return twr;
    }

    // Backward-compatible: TerminateProcessByIndex delegates to TerminateAndVerify
    public bool TerminateProcessByIndex(int index, uint exitCode, int waitMs)
    {
        var twr = TerminateAndVerify(index, exitCode, waitMs);
        return twr.Terminated && twr.Wait.Exited;
    }

    public ProcessEntry[] GetEntries() { return _entries.ToArray(); }

    public int ActiveCount
    {
        get
        {
            int count = 0;
            for (int i = 0; i < _entries.Count; i++)
            {
                if (!IsProcessExited(i)) count++;
            }
            return count;
        }
    }

    public int TerminateAll(uint exitCode, int waitMs)
    {
        int terminated = 0;
        for (int i = 0; i < _entries.Count; i++)
        {
            if (TerminateProcessByIndex(i, exitCode, waitMs)) terminated++;
        }
        return terminated;
    }

    public CloseAllResult GetCloseResult()
    {
        var result = new CloseAllResult();
        var failedList = new List<int>();
        result.Attempted = _entries.Count;
        foreach (var entry in _entries)
        {
            if (entry.Handle != IntPtr.Zero)
            {
                // R9-REM-08: When TestHook_FailClose is active, report failure but still
                // actually close the handle to prevent real resource leaks.
                if (TestHook_FailClose) {
                    CloseHandle(entry.Handle);
                    result.Failed++; failedList.Add(entry.Pid);
                } else {
                    if (CloseHandle(entry.Handle)) { result.Succeeded++; }
                    else { result.Failed++; failedList.Add(entry.Pid); }
                }
            }
            else { result.Succeeded++; }
        }
        result.FailedPids = failedList.ToArray();
        return result;
    }

    // R10-REM-02: Close all handles WITHOUT clearing entries (for pre-close verification)
    public CloseAllResult CloseHandlesWithoutClear()
    {
        return GetCloseResult();
    }

    public CloseAllResult CloseAll()
    {
        var result = GetCloseResult();
        _entries.Clear();
        return result;
    }
}
"@

function Add-TestResult {
    param(
        [string]$TestId,
        [string]$Category,
        [string]$Description,
        [string]$Expected,
        [string]$Actual,
        [string]$Status,
        [string]$ErrorSummary = ""
    )
    $script:TestResults += [PSCustomObject]@{
        TestId       = $TestId
        Category     = $Category
        Description  = $Description
        Expected     = $Expected
        Actual       = $Actual
        Status       = $Status
        ErrorSummary = $ErrorSummary
    }
}

# R3-R3-08: Refactored Get-OverallResult as pure function
function Get-OverallResult {
    param(
        [Parameter(Mandatory=$true)]$Results,
        [bool]$HasFatalInternalError = $false,
        [string[]]$CleanupErrorList = @()
    )

    if ($HasFatalInternalError) { return "ERROR" }
    if ($CleanupErrorList.Count -gt 0) { return "ERROR" }

    # R7-01: @() for PS 5.1 scalar-safe pipeline
    $scriptInternalResults = @($Results | Where-Object {
        $_.Category -in @("ScriptInternal", "CleanupError")
    })
    if ($scriptInternalResults | Where-Object { $_.Status -eq "FAIL" }) { return "ERROR" }

    $gateBlocking = @($Results | Where-Object {
        $_.Category -in @("MandatoryFunctional", "MandatorySecurity", "EvidenceDependent")
    })

    if ($gateBlocking.Count -eq 0) { return "ERROR" }

    $hasFail = @($gateBlocking | Where-Object { $_.Status -eq "FAIL" })
    if ($hasFail.Count -gt 0) { return "FAIL" }

    $hasBlocked = @($gateBlocking | Where-Object { $_.Status -eq "BLOCKED" })
    if ($hasBlocked.Count -gt 0) { return "BLOCKED" }

    return "PASS"
}

# R6-03: Pure function to resolve lockfile parent path from instance path.
# Single implementation used by both runtime code and self-tests.
# Returns the normalized parent lockfile path, or "" for root packages.
function Resolve-LockfileParentPath {
    param(
        [Parameter(Mandatory=$true)][string]$InstancePath  # normalized lockfile path, e.g. "node_modules/parent/node_modules/pkg"
    )

    # node_modules/@scope/parent/node_modules/pkg → node_modules/@scope/parent
    if ($InstancePath -match '^(.+[/\\])node_modules[/\\]') {
        return $Matches[1].TrimEnd('/').TrimEnd('\\')
    }
    # node_modules/parent/node_modules/pkg → node_modules/parent
    # node_modules/pkg → "" (root)
    return ""
}

# R6-04: Native gate summary pure function.
# Encapsulates gate determination logic for native addon detection.
# Input: array of instance results with ResolutionStatus, PlatformApplicable, ParentOptional, LoadExit
# Input: lockfile parse status
# Returns: [PSCustomObject]@{ Status; Category; Description; Expected; Actual; ErrorSummary }
function Get-NativeGateSummary {
    param(
        [Parameter(Mandatory=$true)]$InstanceResults,  # array of {Name, Path, Version, ResolutionStatus, BlockReason, PlatformApplicable, ParentOptional, LoadExit, LoadOutput}
        [Parameter(Mandatory=$true)][bool]$LockfileParsed,
        [string]$LockfileParseError = ""
    )

    # R6-02: If lockfile not parsed, BLOCKED regardless of what was found
    if (-not $LockfileParsed) {
        return [PSCustomObject]@{
            Status = "BLOCKED"
            Category = "EvidenceDependent"
            Description = "Native addon detection"
            Expected = "Lockfile parsed successfully"
            Actual = "Lockfile parse failed: $LockfileParseError"
            ErrorSummary = "BLOCKED — lockfile not parsed; cannot determine native dependency status"
        }
    }

    # R6-01: Any instance with ResolutionStatus not "Resolved" is a blocker
    # R7-01: @() ensures stable array even for 0/1 items (PS 5.1 scalar unwrapping)
    $blockedInstances = @($InstanceResults | Where-Object { $_.ResolutionStatus -ne "Resolved" })
    $resolvedInstances = @($InstanceResults | Where-Object { $_.ResolutionStatus -eq "Resolved" })

    # R6-01: Among resolved, split by platform/optional
    $requiredResolved = @($resolvedInstances | Where-Object { $_.PlatformApplicable -and (-not $_.ParentOptional) })
    $optionalOrNaResolved = @($resolvedInstances | Where-Object { (-not $_.PlatformApplicable) -or $_.ParentOptional })

    # R6-01: Among required resolved, check load status
    $requiredLoadFailures = @($requiredResolved | Where-Object { $_.LoadExit -ne 0 })
    $requiredLoaded = @($requiredResolved | Where-Object { $_.LoadExit -eq 0 })

    # R8-01: Decision logic (priority: FAIL > BLOCKED > Informational)
    # Known required load failures are a definitive negative signal and must not
    # be masked by unresolved/blocked instances that may resolve later.

    # Required load failures → FAIL (highest priority among gate-blocking)
    if ($requiredLoadFailures.Count -gt 0) {
        $failureDetails = ($requiredLoadFailures | ForEach-Object { "$($_.Name)@$($_.Version): exit=$($_.LoadExit) $($_.LoadOutput)" }) -join "; "
        return [PSCustomObject]@{
            Status = "FAIL"
            Category = "EvidenceDependent"
            Description = "Native addon detection"
            Expected = "Required Windows native addons load"
            Actual = "REQUIRED LOAD FAILURES: $failureDetails"
            ErrorSummary = "Required native addon(s) failed to load on Windows x64"
        }
    }

    # R8-01: Blocked/unresolved instances → BLOCKED (after required FAIL)
    if ($blockedInstances.Count -gt 0) {
        $blockedDetails = ($blockedInstances | ForEach-Object { "$($_.Name)@$($_.Version): $($_.ResolutionStatus) — $($_.BlockReason)" }) -join "; "
        return [PSCustomObject]@{
            Status = "BLOCKED"
            Category = "EvidenceDependent"
            Description = "Native addon detection"
            Expected = "All instances resolved"
            Actual = "Blocked instances: $blockedDetails"
            ErrorSummary = "BLOCKED — instance resolution incomplete"
        }
    }

    # Optional/platform-n/a load failures → Informational
    $optionalLoadFailures = @($optionalOrNaResolved | Where-Object { $_.LoadExit -ne 0 })
    if ($optionalLoadFailures.Count -gt 0) {
        $failureDetails = ($optionalLoadFailures | ForEach-Object { "$($_.Name)@$($_.Version): exit=$($_.LoadExit) optional=$($_.ParentOptional) platform=$($_.PlatformApplicable)" }) -join "; "
        $summary = ($InstanceResults | ForEach-Object { "$($_.Name)@$($_.Version) exit=$($_.LoadExit) platform=$($_.PlatformApplicable) optional=$($_.ParentOptional)" }) -join "; "
        return [PSCustomObject]@{
            Status = "PASS"
            Category = "Informational"
            Description = "Native addon detection (optional/platform-n/a failures)"
            Expected = "Documented"
            Actual = "Optional failures: $failureDetails"
            ErrorSummary = ""
        }
    }

    # All required loaded → PASS
    if ($requiredLoaded.Count -gt 0) {
        $summary = ($InstanceResults | ForEach-Object { "$($_.Name)@$($_.Version) exit=$($_.LoadExit) platform=$($_.PlatformApplicable) optional=$($_.ParentOptional)" }) -join "; "
        return [PSCustomObject]@{
            Status = "PASS"
            Category = "EvidenceDependent"
            Description = "Native addon detection"
            Expected = "Required Windows native addons load"
            Actual = "All loaded: $summary"
            ErrorSummary = ""
        }
    }

    # All optional/platform-n/a → Informational
    $summary = ($InstanceResults | ForEach-Object { "$($_.Name)@$($_.Version) exit=$($_.LoadExit) platform=$($_.PlatformApplicable) optional=$($_.ParentOptional)" }) -join "; "
    return [PSCustomObject]@{
        Status = "PASS"
        Category = "Informational"
        Description = "Native addon detection (all optional/platform-n/a)"
        Expected = "Documented"
        Actual = "Found: $summary"
        ErrorSummary = ""
    }
}

# R7-02: Representation-agnostic exact-key lookup.
# Works for both IDictionary/Hashtable and PSCustomObject (ConvertFrom-Json output).
# Returns $true only if $Object contains $Key as a direct property/entry.
function Test-HasKey {
    param($Object, [string]$Key)
    if ($null -eq $Object) { return $false }
    # Hashtable / Dictionary: use ContainsKey
    if ($Object -is [System.Collections.IDictionary]) { return $Object.ContainsKey($Key) }
    # PSCustomObject (from ConvertFrom-Json): use PSObject.Properties
    if ($null -ne $Object.PSObject.Properties[$Key]) { return $true }
    return $false
}

# R10-01: Canonical lockfile-path policy.
# Shared between the Node helper and PowerShell validation.
# Preserves: root "", nested paths, scoped paths, Unicode, same-name distinct instances.
# Rejects: non-canonical raw paths (backslashes in node_modules segments),
# canonicalized collisions, empty non-root paths.
# R11-REV-05: Harden to REJECT rather than normalize.
function ConvertFrom-LockfilePathPolicy {
    param([string]$RawPath)

    # Root key is always valid
    if ($RawPath -eq "") { return "" }

    # R11-REV-05-2: REJECT if raw path contains backslash
    if ($RawPath -match '\\') { return $null }

    # R11-REV-05-3: REJECT if raw path has trailing slash (after non-empty content)
    if ($RawPath -match '/$') { return $null }

    # R11-REV-05-4: REJECT if contains // (repeated slash)
    if ($RawPath -match '//') { return $null }

    # R11-REV-05-5: REJECT if contains /./ or /../ or starts with ./ or ../
    if ($RawPath -match '/\.\.?/' -or $RawPath -match '^\.\.?/') { return $null }

    # R12-REV-08: REJECT if ends with /. or /.. (terminal dot/dot-dot)
    if ($RawPath -match '/\.$' -or $RawPath -match '/\.\.$') { return $null }

    # R11-REV-05-6: REJECT if starts with / (absolute)
    if ($RawPath -match '^/') { return $null }

    # R11-REV-05-7: REJECT if matches drive letter pattern (C:, D:, etc.)
    if ($RawPath -match '^[A-Za-z]:') { return $null }

    # R11-REV-05-8: REJECT if contains NUL or control characters (char < 0x20)
    for ($ci = 0; $ci -lt $RawPath.Length; $ci++) {
        if ([int][char]$RawPath[$ci] -lt 0x20) { return $null }
    }

    # R11-REV-05-9 + R12-REV-02: Validate COMPLETE node_modules path grammar.
    # Grammar: node_modules/(scope/)?pkg(/node_modules/(scope/)?pkg)*
    # The $ anchor ensures no unmatched suffix is allowed.
    # Non-node_modules paths (workspace paths) still pass basic rejection checks above.
    if ($RawPath -like 'node_modules*') {
        if (-not ($RawPath -match '^node_modules/(?:@[^/]+/[^/]+|[^@/][^/]*)(?:/node_modules/(?:@[^/]+/[^/]+|[^@/][^/]*))*$')) { return $null }
    }

    # R11-REV-05-10: Return the canonical key (equals raw key for valid inputs)
    return $RawPath
}

# R12-REV-01: Pure candidate-validation function for deterministic self-testing.
# Validates a pre-built candidate list for Node executable resolution.
# Separated from Resolve-NodeExecutable so tests do not depend on ambient PATH.
function Test-NodeCandidateValidation {
    param(
        [object[]]$Candidates  # Array of {CommandType, Source, Name}
    )
    $result = @{ Path = $null; Error = "" }

    if ($Candidates.Count -eq 0) {
        $result.Error = "No node candidates provided"
        return $result
    }

    # R12-REV-01: ANY non-Application candidate blocks resolution (fail-closed).
    # Aliases, functions, scripts, cmdlets could intercept 'node' invocation.
    $nonApps = @($Candidates | Where-Object { $_.CommandType -ne 'Application' })
    if ($nonApps.Count -gt 0) {
        $types = ($nonApps | ForEach-Object { "$($_.CommandType):$($_.Name)" }) -join "; "
        $result.Error = "Non-Application node candidates block resolution (fail-closed): $types"
        return $result
    }

    $apps = @($Candidates | Where-Object { $_.CommandType -eq 'Application' })
    if ($apps.Count -eq 0) {
        $result.Error = "Node found but no Application type among candidates"
        return $result
    }

    if ($apps.Count -gt 1) {
        $paths = ($apps | ForEach-Object { $_.Source }) -join "; "
        $result.Error = "AMBIGUOUS: $($apps.Count) Node Application executables found: $paths"
        return $result
    }

    # Exactly one Application
    $resolvedPath = $apps[0].Source

    # Validate the resolved path exists and is a file
    if (-not (Test-Path $resolvedPath)) {
        $result.Error = "Resolved Node path does not exist: $resolvedPath"
        return $result
    }
    $fileInfo = Get-Item $resolvedPath -ErrorAction SilentlyContinue
    if (-not $fileInfo -or $fileInfo.PSIsContainer) {
        $result.Error = "Resolved Node path is not a file: $resolvedPath"
        return $result
    }

    $result.Path = $resolvedPath
    return $result
}

# R12-REV-01: Fail-closed Node executable resolution.
# Uses Get-Command -All to detect all candidates. Any non-Application
# candidate blocks resolution (fail-closed). Requires exactly one Application
# type with a valid file path.
function Resolve-NodeExecutable {
    $cmd = @(Get-Command node -All -ErrorAction SilentlyContinue)
    return Test-NodeCandidateValidation -Candidates $cmd
}

# R11-REV-08: Shared bounded file reader.
function Read-BoundedFile {
    param([string]$Path, [long]$MaxBytes = 2097152, [string]$Label = "file")
    $result = @{ Content = ""; Truncated = $false; Error = ""; SizeBytes = 0 }
    if (-not (Test-Path $Path)) { return $result }
    $fileInfo = Get-Item $Path -ErrorAction SilentlyContinue
    if (-not $fileInfo) { return $result }
    $result.SizeBytes = $fileInfo.Length
    if ($fileInfo.Length -gt $MaxBytes) {
        $result.Error = "$Label exceeds maximum size ($($fileInfo.Length) > $MaxBytes bytes)"
        return $result
    }
    $content = [System.IO.File]::ReadAllText($Path)
    if ($content) { $content = $content.Trim() }
    $result.Content = $content
    return $result
}

# R10-01: PS5.1-safe lockfile reader — hardened.
# R10-02: Strict type validation (non-null, non-array objects for packages and entries).
# R10-03: Canonical path policy with collision rejection.
# R10-04: Exclusive helper directory, separate stdout/stderr, bounded I/O.
# R11-REV-04: Strong type checks (no silent coercion).
# R11-REV-05: Reject-don't-normalize path policy.
# R11-REV-06: Exclusive helper directory creation (fail if exists).
# R11-REV-07: Resolved Node executable (not bare 'node').
# R11-REV-08: Bounded stdout/stderr via Read-BoundedFile.
# R11-REV-09: Cleanup failure fail-closed (Parsed=$false).
#
# Returns: @{ Parsed=$true/$false; Error=""; Packages=@{ path -> pkgData } }
# Fail-closed: any error returns Parsed=$false with bounded diagnostic.
function ConvertFrom-LockfileSafe {
    param(
        [Parameter(Mandatory=$true)][string]$LockfilePath,
        # R11-REV-03: Test-only injection points (do not affect production behavior)
        [string]$TestCustomNodeScriptPath = "",
        [long]$TestMaxInputBytes = -1,
        [switch]$TestCleanupFail
    )

    $result = @{ Parsed = $false; Error = ""; Packages = @{} }

    # R12-REV-12: Reject test injection parameters outside self-test mode
    if (($TestCustomNodeScriptPath -or $TestMaxInputBytes -gt 0 -or $TestCleanupFail) -and -not $script:SelfTestMode) {
        $result.Error = "Test injection parameters rejected outside self-test mode"
        return $result
    }

    if (-not (Test-Path $LockfilePath)) {
        $result.Error = "Lockfile not found: $LockfilePath"
        return $result
    }

    # R10-04: Bound input size before reading
    # R11-REV-03: Allow test override via -TestMaxInputBytes
    $maxInputBytes = if ($TestMaxInputBytes -gt 0) { $TestMaxInputBytes } else { 52428800 }  # 50 MB
    $fileInfo = Get-Item $LockfilePath -ErrorAction SilentlyContinue
    if ($fileInfo -and $fileInfo.Length -gt $maxInputBytes) {
        $result.Error = "Lockfile exceeds maximum input size ($($fileInfo.Length) > $maxInputBytes bytes)"
        return $result
    }

    # R11-REV-07: Resolve Node executable once
    $nodeResolution = Resolve-NodeExecutable
    $resolvedNodePath = $nodeResolution.Path

    if (-not $resolvedNodePath) {
        $result.Error = "Node executable resolution failed: $($nodeResolution.Error)"
        return $result
    }

    # R10-04: Create exclusively owned helper directory
    $helperDir = Join-Path $env:TEMP "lockfile-reader-$([guid]::NewGuid().ToString('N'))"
    $nodeHelperPath = Join-Path $helperDir "reader.js"
    $stdoutPath = Join-Path $helperDir "stdout.txt"
    $stderrPath = Join-Path $helperDir "stderr.txt"

    # R11-REV-09: Track cleanup failure flag
    $cleanupFailed = $false

    # R10-01: Node.js helper with strict validation and canonical path policy.
    # Lockfile path passed ONLY as process.argv[2] — never interpolated into source.
    # R10-02: Requires top-level lockfile and packages to be non-null, non-array objects.
    # R10-03: Validates canonical path form and rejects collisions.
    # R10-04: Bounded output via conservative byte limit.
    # R11-REV-05: canonicalize() matches PS policy (reject, don't normalize).
    # R11-REV-08: Node-side input size check before reading.
    $nodeScript = @'
const fs = require("fs");
const MAX_OUTPUT = 2097152; // 2 MB conservative output limit
try {
    // R11-REV-08: Independent file size check before reading
    const stats = fs.statSync(process.argv[2]);
    if (stats.size > 52428800) { process.stderr.write("ERROR: input exceeds 50MB"); process.exit(1); }

    const raw = fs.readFileSync(process.argv[2], "utf8");
    const lock = JSON.parse(raw);

    // R10-02: Require top-level lockfile to be non-null, non-array object
    if (lock === null || typeof lock !== "object" || Array.isArray(lock)) {
        process.stderr.write("ERROR: lockfile root must be a non-null, non-array object");
        process.exit(1);
    }

    // R10-02: Require packages to be non-null, non-array object
    if (lock.packages === null || lock.packages === undefined ||
        typeof lock.packages !== "object" || Array.isArray(lock.packages)) {
        process.stderr.write("ERROR: packages must be a non-null, non-array object");
        process.exit(1);
    }

    const entries = [];
    const canonicalSeen = new Map(); // canonical -> raw (for collision reporting)

    function canonicalize(p) {
        // Root key is always valid
        if (p === "") return "";
        // R11-REV-05: REJECT if contains backslash
        if (p.indexOf("\\") !== -1) return null;
        // R11-REV-05: REJECT if has trailing slash
        if (p.length > 0 && p.charAt(p.length - 1) === "/") return null;
        // R11-REV-05: REJECT if contains // (repeated slash)
        if (p.indexOf("//") !== -1) return null;
        // R11-REV-05: REJECT if contains /./ or /../ or starts with ./ or ../
        if (/\/\.\.?\//.test(p) || /^\.\.?\//.test(p)) return null;
        // R12-REV-08: REJECT if ends with /. or /.. (terminal dot/dot-dot)
        if (/\/\.$/.test(p) || /\/\.\.$/.test(p)) return null;
        // R11-REV-05: REJECT if starts with / (absolute)
        if (p.charAt(0) === "/") return null;
        // R11-REV-05: REJECT if matches drive letter pattern (C:, D:, etc.)
        if (/^[A-Za-z]:/.test(p)) return null;
        // R11-REV-05: REJECT if contains NUL or control characters (char < 0x20)
        for (let i = 0; i < p.length; i++) {
            if (p.charCodeAt(i) < 0x20) return null;
        }
        // R12-REV-02: Validate COMPLETE node_modules path grammar.
        // Grammar: node_modules/(scope/)?pkg(/node_modules/(scope/)?pkg)*
        // The $ anchor ensures no unmatched suffix is allowed.
        if (p.indexOf("node_modules") === 0) {
            if (!/^node_modules\/(?:@[^\/]+\/[^\/]+|[^@\/][^\/]*)(?:\/node_modules\/(?:@[^\/]+\/[^\/]+|[^@\/][^\/]*))*$/.test(p)) return null;
        }
        return p;
    }

    for (const [key, val] of Object.entries(lock.packages)) {
        // R10-02: Validate each package key meets path policy
        var canon = canonicalize(key);
        if (canon === null) {
            process.stderr.write("ERROR: non-canonical path: " + key);
            process.exit(2);
        }

        // R10-03: Check for canonicalized collision
        if (canonicalSeen.has(canon)) {
            process.stderr.write("ERROR: canonical path collision: '" + key + "' collides with '" + canonicalSeen.get(canon) + "'");
            process.exit(2);
        }
        canonicalSeen.set(canon, key);

        // R10-02: Each package value must be non-null, non-array object
        if (val === null || val === undefined ||
            typeof val !== "object" || Array.isArray(val)) {
            process.stderr.write("ERROR: package value must be non-null non-array object at: " + key);
            process.exit(1);
        }

        entries.push({ Path: key, Data: val });
    }

    var output = JSON.stringify(entries);

    // R10-04: Bound output size
    if (Buffer.byteLength(output, "utf8") > MAX_OUTPUT) {
        process.stderr.write("ERROR: output exceeds " + MAX_OUTPUT + " byte limit");
        process.exit(1);
    }

    process.stdout.write(output);
    process.exit(0);
} catch (e) {
    process.stderr.write("ERROR: " + e.message);
    process.exit(3);
}
'@

    try {
        # R11-REV-06: Exclusive creation — fail if directory already exists
        if (Test-Path $helperDir) {
            $result.Error = "Helper directory already exists (collision): $helperDir"
            return $result
        }
        $dirItem = New-Item -ItemType Directory -Path $helperDir -ErrorAction Stop
        if (-not $dirItem -or -not (Test-Path $helperDir)) {
            $result.Error = "Failed to create helper directory: $helperDir"
            return $result
        }
        # R12-REV-03: Expose exact helper dir path for ownership-safe cleanup in self-test
        if ($script:SelfTestMode) { $result['_HelperDir'] = $helperDir }

        # R11-REV-03: Use custom Node script path if provided (test override)
        if ($TestCustomNodeScriptPath -and $TestCustomNodeScriptPath -ne "") {
            # Copy the custom script to our helper dir
            Copy-Item -Path $TestCustomNodeScriptPath -Destination $nodeHelperPath -Force
        } else {
            $nodeScript | Out-File -FilePath $nodeHelperPath -Encoding ASCII -NoNewline
        }

        # R10-04: Invoke Node.js with SEPARATE stdout and stderr capture
        # R11-REV-07: Use resolved node path instead of bare 'node'
        # R14-REV-03: Save/restore ErrorActionPreference so PS 5.1 does not convert
        # native stderr into a terminating exception before Read-BoundedFile can check it.
        $nodeExit = -1
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $resolvedNodePath $nodeHelperPath $LockfilePath 1> $stdoutPath 2> $stderrPath
            $nodeExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedEAP
        }

        # R11-REV-08: Read stderr with bounded file reader (1MB limit)
        $stderrResult = Read-BoundedFile -Path $stderrPath -MaxBytes 1048576 -Label "stderr"
        $stderrText = $stderrResult.Content

        if ($stderrResult.Error) {
            # Stderr itself exceeded limit — this is an error condition
            $result.Error = "Stderr diagnostic: $($stderrResult.Error)"
            return $result
        }

        # R11-REV-08: Read stdout with bounded file reader (2MB limit)
        $stdoutResult = Read-BoundedFile -Path $stdoutPath -MaxBytes 2097152 -Label "stdout"
        $jsonOut = $stdoutResult.Content

        if ($stdoutResult.Error) {
            $result.Error = "Stdout diagnostic: $($stdoutResult.Error)"
            return $result
        }

        # R10-04: Non-zero exit
        if ($nodeExit -ne 0) {
            $diag = "Node lockfile reader failed (exit $nodeExit)"
            if ($stderrText) { $diag = "$diag : $stderrText" }
            elseif ($jsonOut) { $diag = "$diag : $jsonOut" }
            $result.Error = $diag
            return $result
        }

        # R10-04: Unexpected stderr on exit 0
        if ($stderrText -and $stderrText -ne "") {
            $result.Error = "Node lockfile reader produced unexpected stderr on exit 0: $stderrText"
            return $result
        }

        # R10-04: Empty stdout
        if (-not $jsonOut -or $jsonOut -eq "") {
            $result.Error = "Node lockfile reader produced empty stdout"
            return $result
        }

        # R10-04: Output size bound (defensive, Node and Read-BoundedFile already check)
        $maxOutputBytes = 2097152  # 2 MB
        if ([System.Text.Encoding]::UTF8.GetByteCount($jsonOut) -gt $maxOutputBytes) {
            $result.Error = "Node lockfile reader output exceeds $maxOutputBytes bytes"
            return $result
        }

        # Parse the array output
        $entries = $jsonOut | ConvertFrom-Json
        if ($null -eq $entries) {
            $result.Error = "ConvertFrom-Json returned null"
            return $result
        }

        # R10-04: Validate intermediate collection is array-shaped 0/1/N-safe
        $entryArray = @($entries)

        # Build Hashtable map: canonical path -> package data
        $pkgMap = @{}
        $canonicalSeenPs = @{}

        foreach ($entry in $entryArray) {
            # R10-04: Require exactly usable Path and Data fields
            if ($null -eq $entry -or $null -eq $entry.Path -or $null -eq $entry.Data) {
                $result.Error = "Intermediate entry has null Path or Data"
                return $result
            }

            # R11-REV-04: Path must be exactly a string type, not coercible-to-string
            if ($entry.Path -isnot [string]) {
                $result.Error = "Intermediate entry Path is not a string (type: $($entry.Path.GetType().Name))"
                return $result
            }
            $path = $entry.Path

            # R10-04: Validate path against shared canonical policy
            $canonicalPath = ConvertFrom-LockfilePathPolicy -RawPath $path
            if ($null -eq $canonicalPath) {
                $result.Error = "Path fails canonical policy: $path"
                return $result
            }

            # R10-04: Data must be a non-null, non-array object
            $data = $entry.Data
            if ($data -is [System.Array]) {
                $result.Error = "Package Data is an array at path: $path"
                return $result
            }
            # Check for null/empty PSCustomObject (no properties)
            if ($null -eq $data) {
                $result.Error = "Package Data is null at path: $path"
                return $result
            }

            # R11-REV-04: Data must be a non-null, non-array object (PSCustomObject or Hashtable)
            # Reject string, number, boolean, and other scalar types
            if ($data -is [string] -or $data -is [int] -or $data -is [long] -or $data -is [double] -or $data -is [bool] -or $data -is [System.ValueType]) {
                $result.Error = "Package Data is a scalar type (not an object) at path: $path"
                return $result
            }

            # R10-03: Check for canonical collision in PS map
            if ($canonicalSeenPs.ContainsKey($canonicalPath)) {
                $result.Error = "Canonical path collision: '$path' collides with '$($canonicalSeenPs[$canonicalPath])'"
                return $result
            }
            $canonicalSeenPs[$canonicalPath] = $path

            $pkgMap[$path] = $data
        }

        $result.Parsed = $true
        $result.Packages = $pkgMap
        return $result

    } catch {
        $result.Error = "Lockfile reader exception: $($_.Exception.Message)"
        return $result
    } finally {
        # R11-REV-09: Cleanup failure fail-closed
        if (Test-Path $helperDir) {
            try {
                # R11-REV-03: Test-only cleanup failure injection
                if ($TestCleanupFail) {
                    throw "TEST-ONLY: Simulated cleanup failure"
                }
                Remove-Item $helperDir -Recurse -Force -ErrorAction Stop
            } catch {
                $cleanupFailed = $true
                # R11-REV-09: Cleanup failure must cause Parsed=$false
                $result.Parsed = $false
                $result.Error = "Cleanup failed: $($_.Exception.Message)"
            }
        }
    }
}

# R4-02 + R5-03 + R6-03: Native addon judgment pure function
# Each DependencyMap item carries InstancePath and ParentPath.
# Only queries the exact parent for that instance — never scans all packages.
# R6-03: Uses Resolve-LockfileParentPath for consistent parent resolution.
function Get-NativeAddonJudgment {
    param(
        [hashtable[]]$DependencyMap,    # [{Name, PkgData, InstancePath, ParentPath}, ...]
        [string]$TargetOs = "win32",
        [string]$TargetCpu = "x64",
        $LockfilePackages = @{}  # R7-02: untyped to accept Hashtable or PSCustomObject (ConvertFrom-Json)
    )

    $nativeIndicators = @("install", "prebuild", "node-gyp", "binding", "bindings", "nan", "node-addon-api", "prebuild-install")
    $results = @()

    foreach ($dep in $DependencyMap) {
        $depName = $dep.Name
        $pkgData = $dep.PkgData
        $instancePath = $dep.InstancePath    # R5-03: exact lockfile path for this instance
        $parentPath = $dep.ParentPath        # R5-03: exact parent lockfile path

        # R5-04: Per-instance initialization — always fresh, fail-closed defaults
        $platformApplicable = $true
        $parentOptional = $false
        $resolutionStatus = "Unresolved"

        if (-not $pkgData) {
            # R5-04: Missing package data → BLOCKED
            $results += [PSCustomObject]@{
                Name = $depName; IsNative = $false; PlatformApplicable = $true
                ParentOptional = $false; ResolutionStatus = "Blocked"
                InstancePath = $instancePath; BlockReason = "Missing package data"
            }
            continue
        }

        # Detect native addon
        $isNative = $false
        if ($pkgData.install) { $isNative = $true }
        if ($pkgData.prebuild) { $isNative = $true }
        if ($pkgData.gypfile -eq $true) { $isNative = $true }
        if ($pkgData.scripts) {
            foreach ($indicator in $nativeIndicators) {
                if ($pkgData.scripts.install -and $pkgData.scripts.install -like "*$indicator*") { $isNative = $true; break }
                if ($pkgData.scripts.preinstall -and $pkgData.scripts.preinstall -like "*$indicator*") { $isNative = $true; break }
            }
        }
        if ($pkgData.binary) { $isNative = $true }
        if (-not $isNative -and $pkgData.dependencies) {
            foreach ($innerInd in $nativeIndicators) {
                if (Test-HasKey $pkgData.dependencies $innerInd) { $isNative = $true; break }
            }
        }

        if ($isNative) {
            # Platform check — pure, covers all os/cpu combos
            if ($pkgData.os) {
                $osList = @($pkgData.os)
                $hasPositive = $false
                foreach ($o in $osList) { if ($o -notlike '!*') { $hasPositive = $true; break } }
                $denied = $false
                foreach ($o in $osList) { if ($o -eq "!$TargetOs") { $denied = $true; break } }
                if ($denied) { $platformApplicable = $false }
                elseif ($hasPositive -and ($osList -notcontains $TargetOs)) { $platformApplicable = $false }
            }
            if ($pkgData.cpu) {
                $cpuList = @($pkgData.cpu)
                $hasPositive = $false
                foreach ($c in $cpuList) { if ($c -notlike '!*') { $hasPositive = $true; break } }
                $denied = $false
                foreach ($c in $cpuList) { if ($c -eq "!$TargetCpu") { $denied = $true; break } }
                if ($denied) { $platformApplicable = $false }
                elseif ($hasPositive -and ($cpuList -notcontains $TargetCpu)) { $platformApplicable = $false }
            }

            # R5-03: Check ONLY the exact parent for this instance
            $parentOptional = ($pkgData.optional -eq $true)
            # R8-03: Test-HasKey supports empty-string root key; no falsy skip
            if (Test-HasKey $LockfilePackages $parentPath) {
                # R7-02: Use .$key for representation-agnostic access (works for Hashtable and PSCustomObject)
                $lfPkg = $LockfilePackages.$parentPath
                if ($lfPkg.optionalDependencies -and (Test-HasKey $lfPkg.optionalDependencies $depName)) {
                    $parentOptional = $true
                }
            }
        }

        $resolutionStatus = "Resolved"
        $results += [PSCustomObject]@{
            Name = $depName; IsNative = $isNative
            PlatformApplicable = $platformApplicable; ParentOptional = $parentOptional
            ResolutionStatus = $resolutionStatus
            InstancePath = $instancePath; BlockReason = ""
        }
    }

    return $results
}

# R14-REV-01: Shared installed-instance resolution/conversion function.
# Used by both production Test 6 and F23/F23c/F23d self-tests.
# Accepts: mapping entry (or $null), exact instance path, installed path/version,
#          package-json error state, and real load exit/output.
# Preserves exact identity fields. Never hard-codes a successful load.
# A missing exact mapping returns structured Blocked with nonempty reason.
function ConvertFrom-MappingToInstanceResult {
    param(
        $MappingEntry,                                          # $null or mapping object from ConvertFrom-TransitiveMapping
        [Parameter(Mandatory=$true)][string]$InstancePath,      # normalized lockfile instance path
        [string]$InstalledPath = "",                            # real filesystem path to installed package
        [string]$Version = "unknown",                           # version from installed package.json
        [string]$PackageJsonError = "",                         # nonempty if package.json missing/parse failure
        [int]$LoadExit = -1,                                    # real require() exit code
        [string]$LoadOutput = ""                                # real require() output
    )

    # Step 1: Determine mapping-based resolution status
    $resolutionStatus = "Resolved"
    $blockReason = ""

    if ($null -eq $MappingEntry) {
        $resolutionStatus = "Blocked"
        $blockReason = "No lockfile mapping for $InstancePath"
    } else {
        $resolutionStatus = $MappingEntry.ResolutionStatus
        $blockReason = $MappingEntry.BlockReason
    }

    # Step 2: Package.json error overrides only when mapping was Resolved
    if ($PackageJsonError -and $resolutionStatus -eq "Resolved") {
        $resolutionStatus = "Blocked"
        $blockReason = $PackageJsonError
    }

    # Step 3: Extract mapping fields (safe when $MappingEntry is $null)
    $platformApplicable = $false
    $parentOptional = $false
    $isNative = $false
    if ($null -ne $MappingEntry) {
        $platformApplicable = $MappingEntry.PlatformApplicable
        $parentOptional = $MappingEntry.ParentOptional
        $isNative = $MappingEntry.IsNative
    }

    # Step 4: Build result with exact identity fields and real load evidence
    $name = ""
    if ($null -ne $MappingEntry -and $MappingEntry.Name) {
        $name = $MappingEntry.Name
    } elseif ($InstancePath -match "node_modules/(?:@[^/]+/)?([^/]+)$") {
        $name = $Matches[1]
    }

    return [PSCustomObject]@{
        Name = $name
        Version = $Version
        ResolutionStatus = $resolutionStatus
        BlockReason = $blockReason
        PlatformApplicable = $platformApplicable
        ParentOptional = $parentOptional
        IsNative = $isNative
        InstancePath = $InstancePath
        Path = $InstalledPath
        LoadExit = $LoadExit
        LoadOutput = $LoadOutput
    }
}

# R12-REV-05/06: Fail-closed shared function for transitive native mapping.
# Encapsulates the reader→parent resolver→native judgment path.
# Requires exactly one judgment per dep. Validates all fields.
# Requires IsNative=$true for native candidates.
# Returns blocked mapping entry for any invalid result.
function ConvertFrom-TransitiveMapping {
    param(
        [Parameter(Mandatory=$true)]$LockfilePackages,
        [Parameter(Mandatory=$true)][string[]]$NativeDepsToCheck,
        [string]$TargetOs = "win32",
        [string]$TargetCpu = "x64",
        # R12-REV-04: Test-only judgment provider seam (self-test mode guard)
        [scriptblock]$TestJudgmentProvider = $null
    )

    # R12-REV-04: Reject test injection outside self-test mode
    if ($null -ne $TestJudgmentProvider -and -not $script:SelfTestMode) {
        throw "TestJudgmentProvider rejected outside self-test mode"
    }
    # R12-REV-04: Use script-level override when in self-test mode (PS 5.1 compatible)
    $effectiveProvider = $TestJudgmentProvider
    if ($null -eq $effectiveProvider -and $script:SelfTestMode -and $null -ne $script:TestJudgmentProviderOverride) {
        $effectiveProvider = $script:TestJudgmentProviderOverride
    }
    # R12-REV-04: Guard against provider exceptions — produce blocked entry
    $providerException = $null

    $transitiveMap = @{}
    foreach ($rawName in @($lockfilePackages.Keys)) {
        # R14-REV-05: Reset provider exception per candidate to prevent cross-candidate contamination
        $providerException = $null
        $pkgData = $lockfilePackages[$rawName]
        # Extract the actual package name from the last node_modules segment
        if ($rawName -match 'node_modules[/\\]([^/\\]+)$') {
            $pkgName = $Matches[1]
        } elseif ($rawName -match 'node_modules[/\\].+[/\\]node_modules[/\\]([^/\\]+)$') {
            $pkgName = $Matches[1]
        } else {
            $pkgName = $rawName -replace '^node_modules/', '' -replace '^node_modules\\', ''
        }
        if ($pkgName -in $nativeDepsToCheck) {
            $parentPath = Resolve-LockfileParentPath -InstancePath $rawName
            $depMap = @( @{ Name=$pkgName; PkgData=$pkgData; InstancePath=$rawName; ParentPath=$parentPath } )
            # R12-REV-04: Use test-only provider if available, with exception guard
            # R12-REV-04: PS 5.1 if-expression unwraps @() — must wrap the entire expression
            try {
                $rawJudgments = if ($null -ne $effectiveProvider) {
                    & $effectiveProvider $depMap $TargetOs $TargetCpu $LockfilePackages
                } else {
                    Get-NativeAddonJudgment -DependencyMap $depMap -TargetOs $TargetOs -TargetCpu $TargetCpu -LockfilePackages $LockfilePackages
                }
                $judgments = @($rawJudgments)
            } catch {
                $providerException = $_.Exception.Message
                $judgments = @()
            }
            if ($null -ne $providerException) {
                $transitiveMap[$rawName] = [PSCustomObject]@{
                    Name = $pkgName; Version = $pkgData.version
                    PlatformApplicable = $false; ParentOptional = $false
                    IsNative = $false; ResolutionStatus = "Blocked"
                    BlockReason = "Judgment provider exception: $providerException"
                    InLockfile = $true
                }
                continue
            }

            # R12-REV-05: Require exactly one judgment
            if ($judgments.Count -ne 1) {
                $transitiveMap[$rawName] = [PSCustomObject]@{
                    Name = $pkgName; Version = $pkgData.version
                    PlatformApplicable = $false; ParentOptional = $false
                    IsNative = $false; ResolutionStatus = "Blocked"
                    BlockReason = "Expected exactly 1 judgment, got $($judgments.Count)"
                    InLockfile = $true
                }
                continue
            }

            $judgment = $judgments[0]

            # R12-REV-05: Validate required fields exist and have valid types
            $validStatuses = @("Resolved", "Blocked", "Unresolved")
            $blockReason = ""

            if ([string]::IsNullOrEmpty($judgment.Name)) {
                $blockReason = "Judgment Name is null or empty"
            } elseif ($null -eq $judgment.ResolutionStatus -or $judgment.ResolutionStatus -notin $validStatuses) {
                $blockReason = "Invalid ResolutionStatus: '$($judgment.ResolutionStatus)'"
            } elseif ($judgment.ResolutionStatus -eq "Blocked" -and [string]::IsNullOrEmpty($judgment.BlockReason)) {
                $blockReason = "Blocked judgment missing BlockReason"
            } elseif ($null -eq $judgment.IsNative) {
                $blockReason = "IsNative field is null"
            } elseif ($judgment.IsNative -ne $true) {
                # R12-REV-06: Native candidate must be IsNative=$true
                $blockReason = "IsNative is not true (value: $($judgment.IsNative))"
            } elseif ($null -eq $judgment.PlatformApplicable) {
                $blockReason = "PlatformApplicable is null"
            } elseif ($judgment.PlatformApplicable -isnot [bool]) {
                $blockReason = "PlatformApplicable is not Boolean (type: $($judgment.PlatformApplicable.GetType().Name))"
            } elseif ($null -eq $judgment.ParentOptional) {
                $blockReason = "ParentOptional is null"
            } elseif ($judgment.ParentOptional -isnot [bool]) {
                $blockReason = "ParentOptional is not Boolean (type: $($judgment.ParentOptional.GetType().Name))"
            }

            if ($blockReason -ne "") {
                # R12-REV-05: Return structured blocked entry, not silent omission
                $transitiveMap[$rawName] = [PSCustomObject]@{
                    Name = $pkgName; Version = $pkgData.version
                    PlatformApplicable = $false; ParentOptional = $false
                    IsNative = $false; ResolutionStatus = "Blocked"
                    BlockReason = $blockReason
                    InLockfile = $true
                }
            } else {
                # Valid judgment — use it
                $transitiveMap[$rawName] = [PSCustomObject]@{
                    Name = $pkgName; Version = $pkgData.version
                    PlatformApplicable = $judgment.PlatformApplicable
                    ParentOptional = $judgment.ParentOptional
                    IsNative = $judgment.IsNative
                    ResolutionStatus = $judgment.ResolutionStatus
                    BlockReason = $judgment.BlockReason
                    InLockfile = $true
                }
            }
        }
    }
    return $transitiveMap
}

# R5-02 + R5-03: Expanded runtime self-test for Get-NativeAddonJudgment
# 18 cases covering all required scenarios
function Test-NativeAddonJudgment {
    $allPassed = $true
    $tests = @()

    # Case 1: native, no os/cpu → applicable, not optional
    $d1 = @(@{ Name="pkg1"; PkgData=@{ gypfile=$true }; InstancePath="node_modules/pkg1"; ParentPath="" })
    $j1 = Get-NativeAddonJudgment -DependencyMap $d1 -TargetOs "win32" -TargetCpu "x64"
    $p1 = ($j1[0].PlatformApplicable -eq $true -and $j1[0].ParentOptional -eq $false -and $j1[0].ResolutionStatus -eq "Resolved")
    $tests += [PSCustomObject]@{ Name="C01: native no os/cpu => applicable"; Pass=$p1 }
    if (-not $p1) { $allPassed = $false }

    # Case 2: os=[!win32] → not applicable
    $d2 = @(@{ Name="pkg2"; PkgData=@{ gypfile=$true; os=@("!win32") }; InstancePath="node_modules/pkg2"; ParentPath="" })
    $j2 = Get-NativeAddonJudgment -DependencyMap $d2 -TargetOs "win32" -TargetCpu "x64"
    $p2 = ($j2[0].PlatformApplicable -eq $false -and $j2[0].ResolutionStatus -eq "Resolved")
    $tests += [PSCustomObject]@{ Name="C02: os=!win32 => not applicable"; Pass=$p2 }
    if (-not $p2) { $allPassed = $false }

    # Case 3: os=[win32] positive → applicable
    $d3 = @(@{ Name="pkg3"; PkgData=@{ gypfile=$true; os=@("win32") }; InstancePath="node_modules/pkg3"; ParentPath="" })
    $j3 = Get-NativeAddonJudgment -DependencyMap $d3 -TargetOs "win32" -TargetCpu "x64"
    $p3 = ($j3[0].PlatformApplicable -eq $true)
    $tests += [PSCustomObject]@{ Name="C03: os=[win32] => applicable"; Pass=$p3 }
    if (-not $p3) { $allPassed = $false }

    # Case 4: os=[linux] (no win32) → not applicable
    $d4 = @(@{ Name="pkg4"; PkgData=@{ gypfile=$true; os=@("linux") }; InstancePath="node_modules/pkg4"; ParentPath="" })
    $j4 = Get-NativeAddonJudgment -DependencyMap $d4 -TargetOs "win32" -TargetCpu "x64"
    $p4 = ($j4[0].PlatformApplicable -eq $false)
    $tests += [PSCustomObject]@{ Name="C04: os=[linux] no win32 => not applicable"; Pass=$p4 }
    if (-not $p4) { $allPassed = $false }

    # Case 5: cpu=[!x64] → not applicable
    $d5 = @(@{ Name="pkg5"; PkgData=@{ gypfile=$true; cpu=@("!x64") }; InstancePath="node_modules/pkg5"; ParentPath="" })
    $j5 = Get-NativeAddonJudgment -DependencyMap $d5 -TargetOs "win32" -TargetCpu "x64"
    $p5 = ($j5[0].PlatformApplicable -eq $false)
    $tests += [PSCustomObject]@{ Name="C05: cpu=!x64 => not applicable"; Pass=$p5 }
    if (-not $p5) { $allPassed = $false }

    # Case 6: cpu=[x64] positive → applicable
    $d6 = @(@{ Name="pkg6"; PkgData=@{ gypfile=$true; cpu=@("x64") }; InstancePath="node_modules/pkg6"; ParentPath="" })
    $j6 = Get-NativeAddonJudgment -DependencyMap $d6 -TargetOs "win32" -TargetCpu "x64"
    $p6 = ($j6[0].PlatformApplicable -eq $true)
    $tests += [PSCustomObject]@{ Name="C06: cpu=[x64] => applicable"; Pass=$p6 }
    if (-not $p6) { $allPassed = $false }

    # Case 7: cpu=[!arm] on x64 → applicable (denylist doesn't hit)
    $d7 = @(@{ Name="pkg7"; PkgData=@{ gypfile=$true; cpu=@("!arm") }; InstancePath="node_modules/pkg7"; ParentPath="" })
    $j7 = Get-NativeAddonJudgment -DependencyMap $d7 -TargetOs "win32" -TargetCpu "x64"
    $p7 = ($j7[0].PlatformApplicable -eq $true)
    $tests += [PSCustomObject]@{ Name="C07: cpu=!arm on x64 => applicable"; Pass=$p7 }
    if (-not $p7) { $allPassed = $false }

    # Case 8: empty/missing os → applicable (default allow)
    $d8 = @(@{ Name="pkg8"; PkgData=@{ gypfile=$true; os=@() }; InstancePath="node_modules/pkg8"; ParentPath="" })
    $j8 = Get-NativeAddonJudgment -DependencyMap $d8 -TargetOs "win32" -TargetCpu "x64"
    $p8 = ($j8[0].PlatformApplicable -eq $true)
    $tests += [PSCustomObject]@{ Name="C08: empty os => applicable"; Pass=$p8 }
    if (-not $p8) { $allPassed = $false }

    # Case 9: empty/missing cpu → applicable (default allow)
    $d9 = @(@{ Name="pkg9"; PkgData=@{ gypfile=$true; cpu=@() }; InstancePath="node_modules/pkg9"; ParentPath="" })
    $j9 = Get-NativeAddonJudgment -DependencyMap $d9 -TargetOs "win32" -TargetCpu "x64"
    $p9 = ($j9[0].PlatformApplicable -eq $true)
    $tests += [PSCustomObject]@{ Name="C09: empty cpu => applicable"; Pass=$p9 }
    if (-not $p9) { $allPassed = $false }

    # Case 10: optional=true → parentOptional
    $d10 = @(@{ Name="pkg10"; PkgData=@{ gypfile=$true; optional=$true }; InstancePath="node_modules/pkg10"; ParentPath="" })
    $j10 = Get-NativeAddonJudgment -DependencyMap $d10 -TargetOs "win32" -TargetCpu "x64"
    $p10 = ($j10[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C10: optional=true => parentOptional"; Pass=$p10 }
    if (-not $p10) { $allPassed = $false }

    # R7-03: Cases tested with BOTH Hashtable AND ConvertFrom-Json PSCustomObject
    # to verify Test-HasKey works across representations.
    # Note: root packages (ParentPath="") skip lockfile lookup by design —
    # their optionality is determined by $pkgData.optional (tested in C10).
    # C11-C13 test nested/scoped parents where lockfile optDep lookup applies.

    # Case 11a: root-level optDep via Hashtable — uses $pkgData.optional (ParentPath="" is falsy)
    $d11 = @(@{ Name="pkg11"; PkgData=@{ gypfile=$true; optional=$true }; InstancePath="node_modules/pkg11"; ParentPath="" })
    $j11 = Get-NativeAddonJudgment -DependencyMap $d11 -TargetOs "win32" -TargetCpu "x64"
    $p11 = ($j11[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C11a: root pkgData.optional => parentOptional"; Pass=$p11 }
    if (-not $p11) { $allPassed = $false }

    # Case 11b: nested parent optDep via Hashtable (lockfile lookup)
    $d11b = @(@{ Name="pkg11b"; PkgData=@{ gypfile=$true }; InstancePath="node_modules/myparent/node_modules/pkg11b"; ParentPath="node_modules/myparent" })
    $lock11b = @{ "node_modules/myparent" = @{ optionalDependencies=@{ "pkg11b"="*" } } }
    $j11b = Get-NativeAddonJudgment -DependencyMap $d11b -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock11b
    $p11b = ($j11b[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C11b: nested optDep (Hashtable) => parentOptional"; Pass=$p11b }
    if (-not $p11b) { $allPassed = $false }

    # Case 11c: same nested parent optDep via ConvertFrom-Json (PSCustomObject)
    $lock11c = '{"node_modules/myparent":{"optionalDependencies":{"pkg11b":"*"}}}' | ConvertFrom-Json
    $j11c = Get-NativeAddonJudgment -DependencyMap $d11b -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock11c
    $p11c = ($j11c[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C11c: nested optDep (PSCustomObject) => parentOptional"; Pass=$p11c }
    if (-not $p11c) { $allPassed = $false }

    # R8-03: Case 11d: root optionalDependencies (ParentPath="") via Hashtable
    # PkgData.optional=false, but packages[''].optionalDependencies contains dep
    $d11d = @(@{ Name="pkg11d"; PkgData=@{ gypfile=$true; optional=$false }; InstancePath="node_modules/pkg11d"; ParentPath="" })
    $lock11d = @{ "" = @{ optionalDependencies=@{ "pkg11d"="*" } } }
    $j11d = Get-NativeAddonJudgment -DependencyMap $d11d -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock11d
    $p11d = ($j11d[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C11d: root optDep (Hashtable, PkgData.optional=false) => parentOptional"; Pass=$p11d }
    if (-not $p11d) { $allPassed = $false }

    # R8-03: Case 11e: root optDep with PSCustomObject that has NO "" key
    # PSCustomObject cannot have empty-string property names (PS limitation).
    # When ParentPath="" and LockfilePackages is PSCustomObject, Test-HasKey
    # returns $false → lookup skipped → $parentOptional stays $false (PkgData.optional).
    # This is correct: root optionalDependencies via JSON is not a real scenario.
    $lock11e = [PSCustomObject]@{ "somepkg" = [PSCustomObject]@{ optionalDependencies = [PSCustomObject]@{ "pkg11d" = "*" } } }
    $j11e = Get-NativeAddonJudgment -DependencyMap $d11d -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock11e
    $p11e = ($j11e[0].ParentOptional -eq $false)  # $false because "" key not in PSCustomObject
    $tests += [PSCustomObject]@{ Name="C11e: root no-key (PSCustomObject) => stays PkgData.optional"; Pass=$p11e }
    if (-not $p11e) { $allPassed = $false }

    # Case 12a: nested parent via Hashtable
    $d12 = @(@{ Name="pkg12"; PkgData=@{ gypfile=$true }; InstancePath="node_modules/parent/node_modules/pkg12"; ParentPath="node_modules/parent" })
    $lock12 = @{ "node_modules/parent" = @{ optionalDependencies=@{ "pkg12"="*" } } }
    $j12 = Get-NativeAddonJudgment -DependencyMap $d12 -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock12
    $p12 = ($j12[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C12a: nested optDep (Hashtable) => parentOptional"; Pass=$p12 }
    if (-not $p12) { $allPassed = $false }

    # Case 12b: nested parent via ConvertFrom-Json
    $lock12j = '{"node_modules/parent":{"optionalDependencies":{"pkg12":"*"}}}' | ConvertFrom-Json
    $j12j = Get-NativeAddonJudgment -DependencyMap $d12 -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock12j
    $p12j = ($j12j[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C12b: nested optDep (PSCustomObject) => parentOptional"; Pass=$p12j }
    if (-not $p12j) { $allPassed = $false }

    # Case 13a: scoped parent via Hashtable
    $d13 = @(@{ Name="pkg13"; PkgData=@{ gypfile=$true }; InstancePath="node_modules/@scope/parent/node_modules/pkg13"; ParentPath="node_modules/@scope/parent" })
    $lock13 = @{ "node_modules/@scope/parent" = @{ optionalDependencies=@{ "pkg13"="*" } } }
    $j13 = Get-NativeAddonJudgment -DependencyMap $d13 -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock13
    $p13 = ($j13[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C13a: scoped optDep (Hashtable) => parentOptional"; Pass=$p13 }
    if (-not $p13) { $allPassed = $false }

    # Case 13b: scoped parent via ConvertFrom-Json
    $lock13j = '{"node_modules/@scope/parent":{"optionalDependencies":{"pkg13":"*"}}}' | ConvertFrom-Json
    $j13j = Get-NativeAddonJudgment -DependencyMap $d13 -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lock13j
    $p13j = ($j13j[0].ParentOptional -eq $true)
    $tests += [PSCustomObject]@{ Name="C13b: scoped optDep (PSCustomObject) => parentOptional"; Pass=$p13j }
    if (-not $p13j) { $allPassed = $false }

    # Case 14: non-native → !isNative, applicable, !optional
    $d14 = @(@{ Name="pkg14"; PkgData=@{ main="index.js" }; InstancePath="node_modules/pkg14"; ParentPath="" })
    $j14 = Get-NativeAddonJudgment -DependencyMap $d14 -TargetOs "win32" -TargetCpu "x64"
    $p14 = ($j14[0].IsNative -eq $false -and $j14[0].PlatformApplicable -eq $true -and $j14[0].ParentOptional -eq $false)
    $tests += [PSCustomObject]@{ Name="C14: non-native => !isNative, applicable, !optional"; Pass=$p14 }
    if (-not $p14) { $allPassed = $false }

    # Case 15: missing PkgData → BLOCKED
    $d15 = @(@{ Name="pkg15"; PkgData=$null; InstancePath="node_modules/pkg15"; ParentPath="" })
    $j15 = Get-NativeAddonJudgment -DependencyMap $d15 -TargetOs "win32" -TargetCpu "x64"
    $p15 = ($j15[0].ResolutionStatus -eq "Blocked")
    $tests += [PSCustomObject]@{ Name="C15: missing PkgData => BLOCKED"; Pass=$p15 }
    if (-not $p15) { $allPassed = $false }

    # Case 16: os=[!darwin] on win32 → applicable (denylist doesn't hit)
    $d16 = @(@{ Name="pkg16"; PkgData=@{ gypfile=$true; os=@("!darwin") }; InstancePath="node_modules/pkg16"; ParentPath="" })
    $j16 = Get-NativeAddonJudgment -DependencyMap $d16 -TargetOs "win32" -TargetCpu "x64"
    $p16 = ($j16[0].PlatformApplicable -eq $true)
    $tests += [PSCustomObject]@{ Name="C16: os=!darwin on win32 => applicable"; Pass=$p16 }
    if (-not $p16) { $allPassed = $false }

    # Case 17: Same-name dep at two different instance paths, different parent optional — no cross-contamination
    $d17 = @(
        @{ Name="same-dep"; PkgData=@{ gypfile=$true; optional=$true }; InstancePath="node_modules/parent-a/node_modules/same-dep"; ParentPath="node_modules/parent-a" },
        @{ Name="same-dep"; PkgData=@{ gypfile=$true }; InstancePath="node_modules/parent-b/node_modules/same-dep"; ParentPath="node_modules/parent-b" }
    )
    $j17 = Get-NativeAddonJudgment -DependencyMap $d17 -TargetOs "win32" -TargetCpu "x64"
    $p17a = ($j17[0].ParentOptional -eq $true -and $j17[0].InstancePath -eq "node_modules/parent-a/node_modules/same-dep")
    $p17b = ($j17[1].ParentOptional -eq $false -and $j17[1].InstancePath -eq "node_modules/parent-b/node_modules/same-dep")
    $p17 = ($p17a -and $p17b)
    $tests += [PSCustomObject]@{ Name="C17: same-name different paths => independent judgment"; Pass=$p17 }
    if (-not $p17) { $allPassed = $false }

    # Case 18: os=!arm cpu=!x64 → not applicable (both deny)
    $d18 = @(@{ Name="pkg18"; PkgData=@{ gypfile=$true; os=@("!win32"); cpu=@("!arm") }; InstancePath="node_modules/pkg18"; ParentPath="" })
    $j18 = Get-NativeAddonJudgment -DependencyMap $d18 -TargetOs "win32" -TargetCpu "x64"
    $p18 = ($j18[0].PlatformApplicable -eq $false)
    $tests += [PSCustomObject]@{ Name="C18: os=!win32 cpu=!arm => not applicable"; Pass=$p18 }
    if (-not $p18) { $allPassed = $false }

    # R12-REV-10: Runtime count assertion
    $expectedJudgmentCount = 24
    if ($tests.Count -ne $expectedJudgmentCount) {
        Write-Host "FAIL: Expected $expectedJudgmentCount judgment tests, got $($tests.Count)" -ForegroundColor Red
        $allPassed = $false
    }
    # R12-REV-07: Record suite counts
    $passedJudgCount = @($tests | Where-Object { $_.Pass }).Count
    $failedJudgCount = @($tests | Where-Object { -not $_.Pass }).Count
    $script:SelfTestSuiteResults['NativeJudgment'] = @{ Declared=$expectedJudgmentCount; Actual=$tests.Count; Passed=$passedJudgCount; Failed=$failedJudgCount }

    # R5-REM-05: Dynamic count from actual test results
    Write-Host "`n=== Native Judgment Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name)" -ForegroundColor $color
    }

    return $allPassed
}

# R15-REM-02: Pure manifest comparison helper.
# Compares exact expected and actual name sets using ordinal/case-sensitive semantics.
# Uses System.StringComparer.Ordinal for all duplicate detection and membership tests.
# R15-REM-03: Bounded diagnostics — max $MaxSamples items per category, 100-char name cap.
# Returns [PSCustomObject]@{ Match; Missing; Extra; DuplicateExpected; DuplicateActual;
#   MissingTotal; ExtraTotal; DuplicateExpectedTotal; DuplicateActualTotal; Truncated }
function Compare-TestManifest {
    param(
        [Parameter(Mandatory=$true)][string[]]$ExpectedNames,
        [Parameter(Mandatory=$true)][string[]]$ActualNames,
        [int]$MaxSamples = 20
    )

    $nameCap = 100
    function Cap-Name([string]$n) {
        if ($n.Length -gt $nameCap) { return $n.Substring(0, $nameCap) + "..." }
        return $n
    }

    $result = [PSCustomObject]@{
        Match = $false
        Missing = @()
        Extra = @()
        DuplicateExpected = @()
        DuplicateActual = @()
        MissingTotal = 0
        ExtraTotal = 0
        DuplicateExpectedTotal = 0
        DuplicateActualTotal = 0
        Truncated = $false
    }

    # REM-02: Use Ordinal-comparing Dictionary for duplicate detection (case-sensitive)
    $expectedSeen = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::Ordinal)
    $dupExpectedFull = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $ExpectedNames) {
        if ($expectedSeen.ContainsKey($name)) {
            if (-not $dupExpectedFull.Contains($name)) { $dupExpectedFull.Add($name) }
        } else {
            $expectedSeen[$name] = $true
        }
    }
    $result.DuplicateExpectedTotal = $dupExpectedFull.Count
    $result.DuplicateExpected = @($dupExpectedFull | Select-Object -First $MaxSamples | ForEach-Object { Cap-Name $_ })

    # REM-02: Use Ordinal-comparing Dictionary for actual duplicate detection
    $actualSeen = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::Ordinal)
    $dupActualFull = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $ActualNames) {
        if ($actualSeen.ContainsKey($name)) {
            if (-not $dupActualFull.Contains($name)) { $dupActualFull.Add($name) }
        } else {
            $actualSeen[$name] = $true
        }
    }
    $result.DuplicateActualTotal = $dupActualFull.Count
    $result.DuplicateActual = @($dupActualFull | Select-Object -First $MaxSamples | ForEach-Object { Cap-Name $_ })

    # Build unique sets using Ordinal-comparing HashSets for membership testing
    $expectedUnique = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($name in $ExpectedNames) { [void]$expectedUnique.Add($name) }
    $actualUnique = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($name in $ActualNames) { [void]$actualUnique.Add($name) }

    # Compute Missing (in expected but not in actual)
    $missingFull = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $expectedUnique) {
        if (-not $actualUnique.Contains($name)) { $missingFull.Add($name) | Out-Null }
    }
    $result.MissingTotal = $missingFull.Count
    $result.Missing = @($missingFull | Select-Object -First $MaxSamples | ForEach-Object { Cap-Name $_ })

    # Compute Extra (in actual but not in expected)
    $extraFull = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $actualUnique) {
        if (-not $expectedUnique.Contains($name)) { $extraFull.Add($name) | Out-Null }
    }
    $result.ExtraTotal = $extraFull.Count
    $result.Extra = @($extraFull | Select-Object -First $MaxSamples | ForEach-Object { Cap-Name $_ })

    # Check if any category was truncated
    $result.Truncated = ($result.MissingTotal -gt $MaxSamples) -or
                        ($result.ExtraTotal -gt $MaxSamples) -or
                        ($result.DuplicateExpectedTotal -gt $MaxSamples) -or
                        ($result.DuplicateActualTotal -gt $MaxSamples)

    # Match requires: no missing, no extra, no duplicates in either
    $result.Match = ($result.MissingTotal -eq 0) -and
                    ($result.ExtraTotal -eq 0) -and
                    ($result.DuplicateExpectedTotal -eq 0) -and
                    ($result.DuplicateActualTotal -eq 0)

    return $result
}

# R15-REM-02: Self-test for Compare-TestManifest pure helper (14 cases)
function Test-CompareTestManifest {
    $allPassed = $true
    $tests = @()

    # T1: Exact match — same names, same order
    $c1 = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("A","B","C")
    $tests += [PSCustomObject]@{ Name="T1: exact match (same order)"; Expected="Match=True"; Actual="Match=$($c1.Match) Missing=$($c1.MissingTotal) Extra=$($c1.ExtraTotal)"; Pass=$c1.Match }
    if (-not $c1.Match) { $allPassed = $false }

    # T2: Exact match — same names, different order
    $c2 = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("C","A","B")
    $tests += [PSCustomObject]@{ Name="T2: exact match (different order)"; Expected="Match=True"; Actual="Match=$($c2.Match) Missing=$($c2.MissingTotal) Extra=$($c2.ExtraTotal)"; Pass=$c2.Match }
    if (-not $c2.Match) { $allPassed = $false }

    # T3: Same count but one expected name replaced by another
    $c3 = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("A","B","Z")
    $p3 = (-not $c3.Match) -and ($c3.MissingTotal -eq 1) -and ($c3.Missing[0] -eq "C") -and ($c3.ExtraTotal -eq 1) -and ($c3.Extra[0] -eq "Z")
    $tests += [PSCustomObject]@{ Name="T3: same count, one name replaced"; Expected="Match=False Missing=1(C) Extra=1(Z)"; Actual="Match=$($c3.Match) Missing=$($c3.MissingTotal)($($c3.Missing -join ',')) Extra=$($c3.ExtraTotal)($($c3.Extra -join ','))"; Pass=$p3 }
    if (-not $p3) { $allPassed = $false }

    # T4: Missing name (actual is subset)
    $c4 = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("A","B")
    $p4 = (-not $c4.Match) -and ($c4.MissingTotal -eq 1) -and ($c4.Missing[0] -eq "C") -and ($c4.ExtraTotal -eq 0)
    $tests += [PSCustomObject]@{ Name="T4: missing name"; Expected="Match=False Missing=1(C) Extra=0"; Actual="Match=$($c4.Match) Missing=$($c4.MissingTotal)($($c4.Missing -join ',')) Extra=$($c4.ExtraTotal)"; Pass=$p4 }
    if (-not $p4) { $allPassed = $false }

    # T5: Extra name (actual has superset)
    $c5 = Compare-TestManifest -ExpectedNames @("A","B") -ActualNames @("A","B","C")
    $p5 = (-not $c5.Match) -and ($c5.MissingTotal -eq 0) -and ($c5.ExtraTotal -eq 1) -and ($c5.Extra[0] -eq "C")
    $tests += [PSCustomObject]@{ Name="T5: extra name"; Expected="Match=False Missing=0 Extra=1(C)"; Actual="Match=$($c5.Match) Missing=$($c5.MissingTotal) Extra=$($c5.ExtraTotal)($($c5.Extra -join ','))"; Pass=$p5 }
    if (-not $p5) { $allPassed = $false }

    # T6: Duplicate expected name (exact case)
    $c6 = Compare-TestManifest -ExpectedNames @("A","A","B") -ActualNames @("A","B")
    $p6 = (-not $c6.Match) -and ($c6.DuplicateExpectedTotal -eq 1) -and ($c6.DuplicateExpected[0] -eq "A")
    $tests += [PSCustomObject]@{ Name="T6: duplicate expected (A,A)"; Expected="Match=False DupExpected=1(A)"; Actual="Match=$($c6.Match) DupExpected=$($c6.DuplicateExpectedTotal)($($c6.DuplicateExpected -join ','))"; Pass=$p6 }
    if (-not $p6) { $allPassed = $false }

    # T7: Duplicate actual name (exact case)
    $c7 = Compare-TestManifest -ExpectedNames @("A","B") -ActualNames @("A","A","B")
    $p7 = (-not $c7.Match) -and ($c7.DuplicateActualTotal -eq 1) -and ($c7.DuplicateActual[0] -eq "A")
    $tests += [PSCustomObject]@{ Name="T7: duplicate actual (A,A)"; Expected="Match=False DupActual=1(A)"; Actual="Match=$($c7.Match) DupActual=$($c7.DuplicateActualTotal)($($c7.DuplicateActual -join ','))"; Pass=$p7 }
    if (-not $p7) { $allPassed = $false }

    # T8: Case-only mismatch
    $c8 = Compare-TestManifest -ExpectedNames @("A","B","c") -ActualNames @("A","B","C")
    $p8 = (-not $c8.Match) -and ($c8.MissingTotal -eq 1) -and ($c8.Missing[0] -eq "c") -and ($c8.ExtraTotal -eq 1) -and ($c8.Extra[0] -eq "C")
    $tests += [PSCustomObject]@{ Name="T8: case-only mismatch (c vs C)"; Expected="Match=False Missing=1(c) Extra=1(C)"; Actual="Match=$($c8.Match) Missing=$($c8.MissingTotal)($($c8.Missing -join ',')) Extra=$($c8.ExtraTotal)($($c8.Extra -join ','))"; Pass=$p8 }
    if (-not $p8) { $allPassed = $false }

    # T9: A,a NOT duplicate — ordinal case-sensitive (REM-02 requirement)
    $c9 = Compare-TestManifest -ExpectedNames @("A","a") -ActualNames @("A","a")
    $p9 = $c9.Match -and ($c9.DuplicateExpectedTotal -eq 0) -and ($c9.DuplicateActualTotal -eq 0)
    $tests += [PSCustomObject]@{ Name="T9: A,a NOT duplicate, exact match"; Expected="Match=True DupExpected=0 DupActual=0"; Actual="Match=$($c9.Match) DupExpected=$($c9.DuplicateExpectedTotal) DupActual=$($c9.DuplicateActualTotal)"; Pass=$p9 }
    if (-not $p9) { $allPassed = $false }

    # T10: Duplicate expected A,A (exact case, not a,a)
    $c10 = Compare-TestManifest -ExpectedNames @("A","A","B") -ActualNames @("A","B")
    $p10 = (-not $c10.Match) -and ($c10.DuplicateExpectedTotal -eq 1) -and ($c10.DuplicateExpected[0] -eq "A") -and ($c10.MissingTotal -eq 0)
    $tests += [PSCustomObject]@{ Name="T10: dup expected A,A exact"; Expected="Match=False DupExpected=1(A) Missing=0"; Actual="Match=$($c10.Match) DupExpected=$($c10.DuplicateExpectedTotal) Missing=$($c10.MissingTotal)"; Pass=$p10 }
    if (-not $p10) { $allPassed = $false }

    # T11: Duplicate expected a,a (lowercase)
    $c11 = Compare-TestManifest -ExpectedNames @("a","a") -ActualNames @("a")
    $p11 = (-not $c11.Match) -and ($c11.DuplicateExpectedTotal -eq 1) -and ($c11.DuplicateExpected[0] -eq "a")
    $tests += [PSCustomObject]@{ Name="T11: dup expected a,a lowercase"; Expected="Match=False DupExpected=1(a)"; Actual="Match=$($c11.Match) DupExpected=$($c11.DuplicateExpectedTotal)($($c11.DuplicateExpected -join ','))"; Pass=$p11 }
    if (-not $p11) { $allPassed = $false }

    # T12: expected=a, actual=A → case-only mismatch
    $c12 = Compare-TestManifest -ExpectedNames @("a") -ActualNames @("A")
    $p12 = (-not $c12.Match) -and ($c12.MissingTotal -eq 1) -and ($c12.Missing[0] -eq "a") -and ($c12.ExtraTotal -eq 1) -and ($c12.Extra[0] -eq "A")
    $tests += [PSCustomObject]@{ Name="T12: expected=a actual=A case mismatch"; Expected="Match=False Missing=1(a) Extra=1(A)"; Actual="Match=$($c12.Match) Missing=$($c12.MissingTotal)($($c12.Missing -join ',')) Extra=$($c12.ExtraTotal)($($c12.Extra -join ','))"; Pass=$p12 }
    if (-not $p12) { $allPassed = $false }

    # T13: 25 missing items → bounded to 15, Truncated=true (REM-03)
    $expected13 = @(); for ($i = 1; $i -le 25; $i++) { $expected13 += "item$i" }
    $actual13 = @("item1","item2","item3","item4","item5")
    $c13 = Compare-TestManifest -ExpectedNames $expected13 -ActualNames $actual13 -MaxSamples 15
    $p13 = (-not $c13.Match) -and ($c13.MissingTotal -eq 20) -and ($c13.Missing.Count -eq 15) -and ($c13.Truncated -eq $true)
    $tests += [PSCustomObject]@{ Name="T13: 25 missing, bounded to 15, truncated"; Expected="MissingTotal=20 Missing.Count=15 Truncated=True"; Actual="MissingTotal=$($c13.MissingTotal) Missing.Count=$($c13.Missing.Count) Truncated=$($c13.Truncated)"; Pass=$p13 }
    if (-not $p13) { $allPassed = $false }

    # T14: 100-char name truncated in display (REM-03)
    $longName = "A" * 150
    $cappedName = "A" * 100 + "..."
    $c14 = Compare-TestManifest -ExpectedNames @($longName,"B") -ActualNames @("B")
    $p14 = (-not $c14.Match) -and ($c14.MissingTotal -eq 1) -and ($c14.Missing[0] -eq $cappedName)
    $tests += [PSCustomObject]@{ Name="T14: 150-char name capped to 100+..."; Expected="Missing[0]=$($cappedName.Substring(0,20))..."; Actual="Missing[0]=$($c14.Missing[0].Substring(0,[Math]::Min(20,$c14.Missing[0].Length)))... len=$($c14.Missing[0].Length)"; Pass=$p14 }
    if (-not $p14) { $allPassed = $false }

    $script:SelfTestSuiteResults['ManifestCompare'] = @{ Declared=14; Actual=$tests.Count; Passed=@($tests | Where-Object { $_.Pass }).Count; Failed=@($tests | Where-Object { -not $_.Pass }).Count }

    Write-Host "`n=== Compare-TestManifest Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected=$($t.Expected) actual=$($t.Actual))" -ForegroundColor $color
    }

    return $allPassed
}

# R15-REM-01: Shared production helper for self-test aggregation.
# Single implementation used by both normal -SelfTestOnly path and fault tests.
# Validates suite structural integrity, writes result objects, computes overall gate.
# Parameters:
#   $SuiteResults — hashtable of suite name -> @{Declared; Actual; Passed; Failed}
#   $AllSuites — ordered string[] of expected suite names
#   $ManifestComparison — PSCustomObject from Compare-TestManifest, or $null if no manifest
#   $NodeResolution — object with .Path property, or $null
#   $PureTotal/$PurePassed/$NodeTotal/$NodePassed — display totals
# Returns: [PSCustomObject]@{ Overall=[string]; ExitCode=[int]; SuiteValid=[bool] }
# R12-REM-05 + R13-REM-02: Shared overall→exit-code mapper — single source of truth
# for exit codes and banner/totals permissions. Returns structured object, not raw integer.
# Defined before Invoke-SelfTestAggregation so production calls the shared function.
function Get-OverallExitResult {
    param([Parameter(Mandatory=$true)][string]$Overall)
    $exitCode = switch ($Overall) { "PASS" { 0 } "FAIL" { 1 } "BLOCKED" { 2 } "ERROR" { 3 } default { 3 } }
    return [PSCustomObject]@{
        Overall = $Overall
        ExitCode = $exitCode
        SuccessBannerAllowed = ($Overall -eq 'PASS')
        TrustedTotalsAllowed = ($Overall -eq 'PASS')
    }
}

function Invoke-SelfTestAggregation {
    param(
        [Parameter(Mandatory=$true)]$SuiteResults,
        [Parameter(Mandatory=$true)][string[]]$AllSuites,
        $ManifestComparison = $null,
        $NodeResolution = $null,
        [int]$PureTotal = 0,
        [int]$PurePassed = 0,
        [int]$NodeTotal = 0,
        [int]$NodePassed = 0,
        [int]$R15Total = 0,
        [int]$R15Passed = 0
    )

    # Validate suite counts — declared=actual, passed=actual, failed=0
    # R3-REM-05: Complete type validation — all fields must be non-negative integers
    $suiteValid = $true
    foreach ($sn in $AllSuites) {
        $sr = $SuiteResults[$sn]
        if (-not $sr) { Write-Host "  FAIL: Suite $sn not recorded" -ForegroundColor Red; $suiteValid = $false; continue }

        # R3-REM-05: Check required fields exist
        $requiredFields = @('Declared','Actual','Passed','Failed')
        foreach ($f in $requiredFields) {
            if (-not ($sr -is [System.Collections.IDictionary]) -and -not ($sr.PSObject.Properties[$f])) {
                Write-Host "  FAIL: $sn missing field $f" -ForegroundColor Red; $suiteValid = $false
            }
        }

        # R3-REM-05: Type check — must be integer types, not string/float/null
        foreach ($f in $requiredFields) {
            $val = $sr.$f
            if ($null -eq $val) { Write-Host "  FAIL: $sn.$f is null" -ForegroundColor Red; $suiteValid = $false; continue }
            if ($val -isnot [int] -and $val -isnot [long] -and $val -isnot [int64]) {
                Write-Host "  FAIL: $sn.$f is not integer type (type=$($val.GetType().Name))" -ForegroundColor Red; $suiteValid = $false; continue
            }
            if ($val -lt 0) { Write-Host "  FAIL: $sn.$f=$val < 0" -ForegroundColor Red; $suiteValid = $false }
        }

        # R3-REM-05: Arithmetic checks
        if ($sr.Declared -ne $sr.Actual) { Write-Host "  FAIL: $sn declared=$($sr.Declared) != actual=$($sr.Actual)" -ForegroundColor Red; $suiteValid = $false }
        if ($sr.Passed -ne $sr.Actual) { Write-Host "  FAIL: $sn passed=$($sr.Passed) != actual=$($sr.Actual)" -ForegroundColor Red; $suiteValid = $false }
        if ($sr.Failed -gt 0) { Write-Host "  FAIL: $sn failed=$($sr.Failed)" -ForegroundColor Red; $suiteValid = $false }
        # R3-REM-05: Passed + Failed = Actual (overflow-safe check)
        if ($sr.Passed -gt [int]::MaxValue - $sr.Failed) {
            Write-Host "  FAIL: $sn passed+failed overflow" -ForegroundColor Red; $suiteValid = $false
        } elseif (($sr.Passed + $sr.Failed) -ne $sr.Actual) {
            Write-Host "  FAIL: $sn passed($($sr.Passed)) + failed($($sr.Failed)) = $($sr.Passed + $sr.Failed) != actual($($sr.Actual))" -ForegroundColor Red; $suiteValid = $false
        }
    }

    # Validate manifest comparison if provided
    if ($null -ne $ManifestComparison -and -not $ManifestComparison.Match) {
        $suiteValid = $false
        $detailParts = @()
        if ($ManifestComparison.MissingTotal -gt 0) { $detailParts += "Missing=$($ManifestComparison.MissingTotal)" }
        if ($ManifestComparison.ExtraTotal -gt 0) { $detailParts += "Extra=$($ManifestComparison.ExtraTotal)" }
        if ($ManifestComparison.DuplicateExpectedTotal -gt 0) { $detailParts += "DupExpected=$($ManifestComparison.DuplicateExpectedTotal)" }
        if ($ManifestComparison.DuplicateActualTotal -gt 0) { $detailParts += "DupActual=$($ManifestComparison.DuplicateActualTotal)" }
        Write-Host "  FAIL: Manifest mismatch: $($detailParts -join '; ')" -ForegroundColor Red
    }

    # Compute displayed totals from the validated suite objects
    $overallTotal = 0; $overallPassed = 0; $overallFailed = 0
    foreach ($sn in $AllSuites) {
        $sr = $SuiteResults[$sn]
        if ($sr) { $overallTotal += $sr.Actual; $overallPassed += $sr.Passed; $overallFailed += $sr.Failed }
    }

    Write-Host "Pure-function tests: Aggregation($($SuiteResults['Aggregation'].Actual)) + NativeJudgment($($SuiteResults['NativeJudgment'].Actual)) + ParentPath($($SuiteResults['ParentPath'].Actual)) + GateSummary($($SuiteResults['GateSummary'].Actual)) = $PureTotal"
    Write-Host "Node-backed tests: LockfileReader($NodeTotal)"
    # R2-REM-03: Show complete R15 formula including ProcessLevelFaults
    if ($R15Total -gt 0) {
        $plfActual = if ($SuiteResults['ProcessLevelFaults']) { $SuiteResults['ProcessLevelFaults'].Actual } else { 0 }
        Write-Host "R15 helper tests: ManifestCompare($($SuiteResults['ManifestCompare'].Actual)) + SuiteEvidence($($SuiteResults['SuiteEvidence'].Actual)) + ProcessLevelFaults($plfActual) = $R15Total"
    }
    if ($NodeResolution -and $NodeResolution.Path) {
        Write-Host "Node resolution: $($NodeResolution.Path)"
    }

    # R2-REM-02: Only print trusted N/N PASS when suite validation succeeded
    # R12-REM-05: Track whether banner/totals were actually printed
    $successBannerPrinted = $false
    $trustedTotalsPrinted = $false
    if ($suiteValid) {
        Write-Host "Total: $overallTotal tests, $overallPassed/$overallTotal PASS, $overallFailed FAILED"
        $trustedTotalsPrinted = $true
        Write-Host "Suite validation: PASS"
    } else {
        Write-Host "UNTRUSTED / STRUCTURAL ERROR: $overallTotal tests reported, $overallPassed claimed PASS, $overallFailed FAILED — NOT RELIABLE"
        Write-Host "Suite validation: FAIL"
    }

    # Suite validation is a REAL GATE — feed into Get-OverallResult
    if (-not $suiteValid) {
        # Structural suite/manifest/count inconsistency => ScriptInternal ERROR => exit 3
        Add-TestResult -TestId "SUITE-VALIDATION" -Category "ScriptInternal" `
          -Description "Self-test suite structural validation" `
          -Expected "All suites: declared=actual, passed=actual, failed=0" `
          -Actual "Suite validation failed (see above diagnostics)" -Status "FAIL" `
          -ErrorSummary "ScriptInternal: suite structural validation failure => ERROR"
    }

    # Only record PASS results when suite validation succeeded
    if ($suiteValid) {
        Write-Host "`n=== SELF-TEST-ONLY MODE: All self-tests passed ===" -ForegroundColor Green
        $successBannerPrinted = $true

        Add-TestResult -TestId "SELFTEST-PURE" -Category "MandatoryFunctional" `
          -Description "Pure-function self-tests (Aggregation+NativeJudgment+ParentPath+GateSummary)" `
          -Expected "$PureTotal/$PureTotal PASS" -Actual "$PurePassed/$PureTotal PASS" -Status "PASS"
        Add-TestResult -TestId "SELFTEST-NODEBACKED" -Category "MandatoryFunctional" `
          -Description "Node-backed self-tests (LockfileReader)" `
          -Expected "$NodeTotal/$NodeTotal PASS" -Actual "$NodePassed/$NodeTotal PASS" -Status "PASS"
        if ($NodeResolution -and $NodeResolution.Path) {
            Add-TestResult -TestId "SELFTEST-NODECHECK" -Category "EvidenceDependent" `
              -Description "Node executable resolution" `
              -Expected "Exactly one Node Application found" `
              -Actual "Resolved: $($NodeResolution.Path)" -Status "PASS"
        }
    }

    # Compute overall result from self-test results
    $selfTestOverall = Get-OverallResult -Results $script:TestResults `
      -HasFatalInternalError $false `
      -CleanupErrorList @()

    # R13-REM-02: Use shared Get-OverallExitResult — no duplicate switch mapping
    $exitResult = Get-OverallExitResult -Overall $selfTestOverall

    # R13-REM-02: Fail-closed — banner/totals only if BOTH local condition AND shared mapper allow
    return [PSCustomObject]@{
        Overall = $exitResult.Overall
        ExitCode = $exitResult.ExitCode
        SuiteValid = $suiteValid
        SuccessBannerPrinted = ($successBannerPrinted -and $exitResult.SuccessBannerAllowed)
        TrustedTotalsPrinted = ($trustedTotalsPrinted -and $exitResult.TrustedTotalsAllowed)
    }
}

# R15-REM-01: Self-test for suite validation via shared production helper (5 cases).
# Calls Invoke-SelfTestAggregation with injected fault data — same path as production.
function Test-SuiteEvidence {
    $allPassed = $true
    $tests = @()
    $savedResults = $script:TestResults

    # T1: Missing suite record => ScriptInternal FAIL => ERROR
    $script:TestResults = @()
    $suites1 = @{ 'Aggregation'=@{ Declared=1; Actual=1; Passed=1; Failed=0 } }
    $r1 = Invoke-SelfTestAggregation -SuiteResults $suites1 -AllSuites @('Aggregation','NativeJudgment')
    # R13-REM-02: Verify fail-closed banner/totals via shared Get-OverallExitResult
    $p1 = ($r1.Overall -eq "ERROR") -and ($r1.ExitCode -eq 3) -and (-not $r1.SuiteValid) -and (-not $r1.SuccessBannerPrinted) -and (-not $r1.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T1: missing suite => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r1.Overall)/$($r1.ExitCode) banner=$($r1.SuccessBannerPrinted) totals=$($r1.TrustedTotalsPrinted)"; Pass=$p1 }
    if (-not $p1) { $allPassed = $false }

    # T2: Declared/actual mismatch => ScriptInternal FAIL => ERROR
    $script:TestResults = @()
    $suites2 = @{ 'Aggregation'=@{ Declared=10; Actual=11; Passed=11; Failed=0 } }
    $r2 = Invoke-SelfTestAggregation -SuiteResults $suites2 -AllSuites @('Aggregation')
    $p2 = ($r2.Overall -eq "ERROR") -and ($r2.ExitCode -eq 3) -and (-not $r2.SuiteValid) -and (-not $r2.SuccessBannerPrinted) -and (-not $r2.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T2: declared!=actual => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r2.Overall)/$($r2.ExitCode) banner=$($r2.SuccessBannerPrinted) totals=$($r2.TrustedTotalsPrinted)"; Pass=$p2 }
    if (-not $p2) { $allPassed = $false }

    # T3: Passed/actual mismatch => ScriptInternal FAIL => ERROR
    $script:TestResults = @()
    $suites3 = @{ 'Aggregation'=@{ Declared=11; Actual=11; Passed=10; Failed=1 } }
    $r3 = Invoke-SelfTestAggregation -SuiteResults $suites3 -AllSuites @('Aggregation')
    $p3 = ($r3.Overall -eq "ERROR") -and ($r3.ExitCode -eq 3) -and (-not $r3.SuiteValid) -and (-not $r3.SuccessBannerPrinted) -and (-not $r3.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T3: passed!=actual => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r3.Overall)/$($r3.ExitCode) banner=$($r3.SuccessBannerPrinted) totals=$($r3.TrustedTotalsPrinted)"; Pass=$p3 }
    if (-not $p3) { $allPassed = $false }

    # T4: Failed count > 0 => ScriptInternal FAIL => ERROR
    $script:TestResults = @()
    $suites4 = @{ 'Aggregation'=@{ Declared=11; Actual=11; Passed=10; Failed=1 } }
    $r4 = Invoke-SelfTestAggregation -SuiteResults $suites4 -AllSuites @('Aggregation')
    $p4 = ($r4.Overall -eq "ERROR") -and ($r4.ExitCode -eq 3) -and (-not $r4.SuiteValid) -and (-not $r4.SuccessBannerPrinted) -and (-not $r4.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T4: failed>0 => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r4.Overall)/$($r4.ExitCode) banner=$($r4.SuccessBannerPrinted) totals=$($r4.TrustedTotalsPrinted)"; Pass=$p4 }
    if (-not $p4) { $allPassed = $false }

    # T5: Manifest mismatch => ScriptInternal FAIL => ERROR
    $script:TestResults = @()
    $suites5 = @{ 'Aggregation'=@{ Declared=1; Actual=1; Passed=1; Failed=0 } }
    $manifest5 = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("A","B","Z")
    $r5 = Invoke-SelfTestAggregation -SuiteResults $suites5 -AllSuites @('Aggregation') -ManifestComparison $manifest5
    $p5 = ($r5.Overall -eq "ERROR") -and ($r5.ExitCode -eq 3) -and (-not $r5.SuiteValid) -and (-not $r5.SuccessBannerPrinted) -and (-not $r5.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T5: manifest mismatch => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r5.Overall)/$($r5.ExitCode) banner=$($r5.SuccessBannerPrinted) totals=$($r5.TrustedTotalsPrinted)"; Pass=$p5 }
    if (-not $p5) { $allPassed = $false }

    # R4-REM-04: T6: Missing field => ERROR/3
    $script:TestResults = @()
    $suites6 = @{ 'Aggregation'=@{ Actual=11; Passed=11; Failed=0 } }  # Missing 'Declared'
    $r6 = Invoke-SelfTestAggregation -SuiteResults $suites6 -AllSuites @('Aggregation')
    $p6 = ($r6.Overall -eq "ERROR") -and ($r6.ExitCode -eq 3) -and (-not $r6.SuiteValid) -and (-not $r6.SuccessBannerPrinted) -and (-not $r6.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T6: missing field => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r6.Overall)/$($r6.ExitCode) banner=$($r6.SuccessBannerPrinted) totals=$($r6.TrustedTotalsPrinted)"; Pass=$p6 }
    if (-not $p6) { $allPassed = $false }

    # R4-REM-04: T7: String value => ERROR/3
    $script:TestResults = @()
    $suites7 = @{ 'Aggregation'=@{ Declared="11"; Actual=11; Passed=11; Failed=0 } }  # String, not int
    $r7 = Invoke-SelfTestAggregation -SuiteResults $suites7 -AllSuites @('Aggregation')
    $p7 = ($r7.Overall -eq "ERROR") -and ($r7.ExitCode -eq 3) -and (-not $r7.SuiteValid) -and (-not $r7.SuccessBannerPrinted) -and (-not $r7.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T7: string value => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r7.Overall)/$($r7.ExitCode) banner=$($r7.SuccessBannerPrinted) totals=$($r7.TrustedTotalsPrinted)"; Pass=$p7 }
    if (-not $p7) { $allPassed = $false }

    # R4-REM-04: T8: Float value => ERROR/3
    $script:TestResults = @()
    $suites8 = @{ 'Aggregation'=@{ Declared=11.5; Actual=11; Passed=11; Failed=0 } }  # Float, not int
    $r8 = Invoke-SelfTestAggregation -SuiteResults $suites8 -AllSuites @('Aggregation')
    $p8 = ($r8.Overall -eq "ERROR") -and ($r8.ExitCode -eq 3) -and (-not $r8.SuiteValid) -and (-not $r8.SuccessBannerPrinted) -and (-not $r8.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T8: float value => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r8.Overall)/$($r8.ExitCode) banner=$($r8.SuccessBannerPrinted) totals=$($r8.TrustedTotalsPrinted)"; Pass=$p8 }
    if (-not $p8) { $allPassed = $false }

    # R4-REM-04: T9: Negative value => ERROR/3
    $script:TestResults = @()
    $suites9 = @{ 'Aggregation'=@{ Declared=11; Actual=11; Passed=11; Failed=-1 } }  # Negative
    $r9 = Invoke-SelfTestAggregation -SuiteResults $suites9 -AllSuites @('Aggregation')
    $p9 = ($r9.Overall -eq "ERROR") -and ($r9.ExitCode -eq 3) -and (-not $r9.SuiteValid) -and (-not $r9.SuccessBannerPrinted) -and (-not $r9.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T9: negative value => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r9.Overall)/$($r9.ExitCode) banner=$($r9.SuccessBannerPrinted) totals=$($r9.TrustedTotalsPrinted)"; Pass=$p9 }
    if (-not $p9) { $allPassed = $false }

    # R4-REM-04: T10: Overflow/huge value => ERROR/3
    $script:TestResults = @()
    $suites10 = @{ 'Aggregation'=@{ Declared=[int]::MaxValue; Actual=[int]::MaxValue; Passed=[int]::MaxValue; Failed=1 } }  # Passed+Failed overflows
    $r10 = Invoke-SelfTestAggregation -SuiteResults $suites10 -AllSuites @('Aggregation')
    $p10 = ($r10.Overall -eq "ERROR") -and ($r10.ExitCode -eq 3) -and (-not $r10.SuiteValid) -and (-not $r10.SuccessBannerPrinted) -and (-not $r10.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T10: overflow value => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r10.Overall)/$($r10.ExitCode) banner=$($r10.SuccessBannerPrinted) totals=$($r10.TrustedTotalsPrinted)"; Pass=$p10 }
    if (-not $p10) { $allPassed = $false }

    # R4-REM-04: T11: Passed+Failed != Actual => ERROR/3
    $script:TestResults = @()
    $suites11 = @{ 'Aggregation'=@{ Declared=11; Actual=11; Passed=10; Failed=0 } }  # Passed(10)+Failed(0)=10 != Actual(11)
    $r11 = Invoke-SelfTestAggregation -SuiteResults $suites11 -AllSuites @('Aggregation')
    $p11 = ($r11.Overall -eq "ERROR") -and ($r11.ExitCode -eq 3) -and (-not $r11.SuiteValid) -and (-not $r11.SuccessBannerPrinted) -and (-not $r11.TrustedTotalsPrinted)
    $tests += [PSCustomObject]@{ Name="T11: passed+failed!=actual => ERROR/3"; Expected="ERROR/3 no-banner no-totals"; Actual="$($r11.Overall)/$($r11.ExitCode) banner=$($r11.SuccessBannerPrinted) totals=$($r11.TrustedTotalsPrinted)"; Pass=$p11 }
    if (-not $p11) { $allPassed = $false }

    # Restore original results
    $script:TestResults = $savedResults

    $script:SelfTestSuiteResults['SuiteEvidence'] = @{ Declared=11; Actual=$tests.Count; Passed=@($tests | Where-Object { $_.Pass }).Count; Failed=@($tests | Where-Object { -not $_.Pass }).Count }

    Write-Host "`n=== Suite Evidence Fault-Injection Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected=$($t.Expected) actual=$($t.Actual))" -ForegroundColor $color
    }

    return $allPassed
}

# R7: Handle-based process lifecycle management, fail-closed collector, marker-after-verification.
# R10-REM-05: Shared collector health-to-ScriptInternal mapper.
# Maps collector Healthy/ReadError/DrainTimedOut/task completion to structured ScriptInternal evidence.
# Used by normal process fixtures AND collector fault meta-tests.
function Get-CollectorHealthMapping {
    param(
        [Parameter(Mandatory=$true)]$Collector,
        [bool]$DrainCompleted = $true
    )
    $isHealthy = $Collector.Healthy -and $DrainCompleted
    $readError = $null
    $drainTimedOut = $Collector.DrainTimedOut
    if ($Collector.StdoutFaulted) { $readError = $Collector.StdoutError }
    elseif ($Collector.StderrFaulted) { $readError = $Collector.StderrError }
    elseif (-not $DrainCompleted) { $readError = "Drain task did not complete" }

    $mappingResult = [PSCustomObject]@{
        Healthy = $isHealthy
        ReadError = $readError
        DrainTimedOut = $drainTimedOut
        DrainCompleted = $DrainCompleted
        MappingOutcome = if ($isHealthy) { "PASS" } else { "ERROR" }
    }

    # If unhealthy, produce structured ScriptInternal FAIL result
    if (-not $isHealthy) {
        $actual = "Healthy=false ReadError=$readError DrainTimedOut=$drainTimedOut DrainCompleted=$DrainCompleted"
        $errorSummary = "Collector unhealthy: ReadError=$readError DrainTimedOut=$drainTimedOut"
        $mappingResult | Add-Member -NotePropertyName "ScriptInternalResult" -NotePropertyValue ([PSCustomObject]@{
            TestId = "COLLECTOR-HEALTH"
            Category = "ScriptInternal"
            Status = "FAIL"
            Description = "Collector health check"
            Expected = "Healthy collector with completed drain"
            Actual = $actual
            ErrorSummary = $errorSummary
        })
    }

    return $mappingResult
}

# R10-REM-02: Shared common process gate for all launched-child fixtures.
# R12-REM-01: ExpectedManifest for order-independent PID/role/token comparison.
# R12-REM-02: MarkerDeleteResult for real marker deletion verification.
# R12-REM-03: All evidence fields mandatory and non-null.
function Test-CommonProcessGate {
    param(
        [PSCustomObject]$CleanupResult = $null,
        [PSCustomObject]$CaptureHealthMapping = $null,
        [bool]$ParentRegOk = $false,
        [bool]$CreationTimeOk = $false,
        [ProcessHandleRegistry]$Registry = $null,
        [string]$MarkerDirectory = "",
        [PSCustomObject[]]$ExpectedManifest = @(),
        [PSCustomObject[]]$AllCleanupResults = @(),
        [PSCustomObject]$MarkerDeleteResult = $null,
        # R15-FU-02: Launched-child guard — when true, empty ExpectedManifest is a Gate FAIL
        [bool]$IsLaunchedChild = $false
    )
    $gateErrors = @()
    $gateMatrix = [ordered]@{}
    # R15-FU-02: Record fixture mode in matrix for diagnostics
    $gateMatrix.IsLaunchedChild = $IsLaunchedChild

    # R12-REM-03: 1. Parent registration — mandatory
    $gateMatrix.ParentRegOk = $ParentRegOk
    $gateMatrix.CreationTimeOk = $CreationTimeOk
    if (-not $ParentRegOk) { $gateErrors += "Parent registration failed" }
    if (-not $CreationTimeOk) { $gateErrors += "Parent creation time is zero" }

    # R12-REM-03: 2. Capture health — mandatory non-null
    $gateMatrix.CaptureHealthy = $false
    if ($null -eq $CaptureHealthMapping) {
        $gateErrors += "CaptureHealthMapping is null (mandatory evidence missing)"
    } else {
        $gateMatrix.CaptureHealthy = $CaptureHealthMapping.Healthy
        if (-not $CaptureHealthMapping.Healthy) {
            $gateErrors += "Capture unhealthy: ReadError=$($CaptureHealthMapping.ReadError) DrainTimedOut=$($CaptureHealthMapping.DrainTimedOut)"
        }
    }

    # R12-REM-03: 3. CleanupResult — mandatory non-null
    $gateMatrix.CleanupSuccess = $false
    if ($null -eq $CleanupResult) {
        $gateErrors += "CleanupResult is null (mandatory evidence missing)"
    } else {
        $gateMatrix.CleanupSuccess = $CleanupResult.Success
        if (-not $CleanupResult.Success) {
            $gateErrors += "Cleanup failed: $($CleanupResult.Errors -join '; ')"
        }
    }

    # R12-REM-06: 4. Check ALL cleanup results — expected failures allowed, unexpected fail
    $gateMatrix.AllCleanupResultsChecked = 0
    $gateMatrix.UnexpectedFailures = 0
    if ($AllCleanupResults.Count -gt 0) {
        $unexpectedFailures = @($AllCleanupResults | Where-Object {
            -not $_.Success -and -not $_.ExpectedFailure
        })
        if ($unexpectedFailures.Count -gt 0) {
            $gateErrors += "Unexpected cleanup failures: $($unexpectedFailures.Count)"
        }
        $gateMatrix.AllCleanupResultsChecked = $AllCleanupResults.Count
        $gateMatrix.UnexpectedFailures = $unexpectedFailures.Count
    } elseif ($IsLaunchedChild) {
        # R15-FU-05: Launched-child MUST have cleanup results — empty means evidence missing
        $gateErrors += "AllCleanupResults empty for launched-child fixture (mandatory evidence missing)"
    }

    # R12-REM-03: 5. EntrySnapshot — mandatory, must match expected manifest
    $gateMatrix.EntrySnapshotOk = $false
    $gateMatrix.EntryCount = 0
    if ($null -eq $CleanupResult) {
        $gateErrors += "EntrySnapshot unavailable: CleanupResult is null"
    } elseif ($null -eq $CleanupResult.EntrySnapshot) {
        $gateErrors += "EntrySnapshot is null (mandatory evidence missing)"
    } else {
        $gateMatrix.EntryCount = $CleanupResult.EntrySnapshot.Count
        # R12-REM-01: Order-independent comparison by PID
        $allExited = $true
        foreach ($entry in $CleanupResult.EntrySnapshot) {
            if ($entry.WaitOutcome -ne 'Exited') {
                $gateErrors += "Entry PID=$($entry.Pid) role=$($entry.Role) WaitOutcome=$($entry.WaitOutcome) Win32=$($entry.Win32Error)"
                $allExited = $false
            }
        }
        if ($ExpectedManifest.Count -gt 0) {
            # R12-REM-01: Build PID-keyed maps for order-independent comparison
            # R15-FU-02: Detect duplicate PIDs in expected manifest
            $expectedByPid = @{}
            $expectedDuplicatePid = $false
            foreach ($exp in $ExpectedManifest) {
                if ($expectedByPid.ContainsKey($exp.Pid)) {
                    $gateErrors += "Duplicate expected PID=$($exp.Pid) in ExpectedManifest"
                    $expectedDuplicatePid = $true
                }
                $expectedByPid[$exp.Pid] = $exp
            }
            # R15-FU-02: Detect duplicate PIDs in actual snapshot
            $actualByPid = @{}
            $actualDuplicatePid = $false
            foreach ($snap in $CleanupResult.EntrySnapshot) {
                if ($actualByPid.ContainsKey($snap.Pid)) {
                    $gateErrors += "Duplicate actual PID=$($snap.Pid) in EntrySnapshot"
                    $actualDuplicatePid = $true
                }
                $actualByPid[$snap.Pid] = $snap
            }
            # Check for missing entries
            foreach ($expPid in $expectedByPid.Keys) {
                if (-not $actualByPid.ContainsKey($expPid)) {
                    $exp = $expectedByPid[$expPid]
                    $gateErrors += "Missing entry: PID=$expPid role=$($exp.Role)"
                }
            }
            # Check for extra entries
            foreach ($actPid in $actualByPid.Keys) {
                if (-not $expectedByPid.ContainsKey($actPid)) {
                    $snap = $actualByPid[$actPid]
                    $gateErrors += "Extra entry: PID=$actPid role=$($snap.Role)"
                }
            }
            # Check matching entries for role/token/creation-time agreement
            foreach ($expPid in $expectedByPid.Keys) {
                if ($actualByPid.ContainsKey($expPid)) {
                    $exp = $expectedByPid[$expPid]; $snap = $actualByPid[$expPid]
                    if ($snap.Role -ne $exp.Role) { $gateErrors += "Role mismatch: PID=$expPid expected=$($exp.Role) actual=$($snap.Role)" }
                    if ($snap.Token -ne $exp.Token) { $gateErrors += "Token mismatch: PID=$expPid" }
                    if ($exp.CreationTime -gt 0 -and $snap.CreationTime -ne $exp.CreationTime) { $gateErrors += "CreationTime mismatch: PID=$expPid" }
                }
            }
            $gateMatrix.ExpectedCount = $ExpectedManifest.Count
            $gateMatrix.ActualCount = $CleanupResult.EntrySnapshot.Count
            $gateMatrix.EntrySnapshotOk = ($allExited -and (-not $expectedDuplicatePid) -and (-not $actualDuplicatePid) -and ($expectedByPid.Count -eq $actualByPid.Count) -and ($gateErrors.Count -eq 0))
        } elseif ($IsLaunchedChild) {
            # R15-FU-02: Launched-child with empty ExpectedManifest => FAIL
            $gateErrors += "ExpectedManifest empty for launched-child fixture (mandatory comparison missing)"
            $gateMatrix.ExpectedCount = 0
            $gateMatrix.ActualCount = $CleanupResult.EntrySnapshot.Count
            $gateMatrix.EntrySnapshotOk = $false
        } else {
            # Non-launched-child (meta/pure): no expected manifest — just check all exited
            $gateMatrix.ExpectedCount = 0
            $gateMatrix.ActualCount = $CleanupResult.EntrySnapshot.Count
            $gateMatrix.EntrySnapshotOk = $allExited
        }
    }

    # R12-REM-03: 6. ActiveBeforeClose must be 0
    $gateMatrix.ActiveBeforeCloseOk = $false
    if ($null -ne $CleanupResult) {
        $gateMatrix.ActiveBeforeClose = $CleanupResult.ActiveBeforeClose
        if ($CleanupResult.ActiveBeforeClose -gt 0) {
            $gateErrors += "ActiveBeforeClose=$($CleanupResult.ActiveBeforeClose)"
        } else {
            $gateMatrix.ActiveBeforeCloseOk = $true
        }
    }

    # R12-REM-03: 7. CloseAllResult — mandatory non-null
    $gateMatrix.CloseAllOk = $false
    if ($null -eq $CleanupResult) {
        $gateErrors += "CloseResult unavailable: CleanupResult is null"
    } elseif ($null -eq $CleanupResult.CloseResult) {
        $gateErrors += "CloseResult is null (mandatory evidence missing)"
    } else {
        $gateMatrix.CloseAllOk = $CleanupResult.CloseResult.AllClosed
        if (-not $CleanupResult.CloseResult.AllClosed) {
            $gateErrors += "CloseAll failed: $($CleanupResult.CloseResult.Failed) handles"
        }
    }

    # R12-REM-02: 8. Marker deletion — real verification, not constant
    # R15-FU-05: Structured default when MarkerDirectory non-empty but MarkerDeleteResult null
    $gateMatrix.MarkerDeleted = $false
    $gateMatrix.MarkerPathAbsent = $false
    $gateMatrix.MarkerExpectedCount = 0
    $gateMatrix.MarkerActualCount = 0
    if ($null -ne $MarkerDeleteResult) {
        $gateMatrix.MarkerDeleted = $MarkerDeleteResult.Success
        if (-not $MarkerDeleteResult.Success) {
            $gateErrors += "Marker deletion failed: $($MarkerDeleteResult.Error)"
        }
        if ($MarkerDirectory -ne "") {
            $remainingMarkers = Get-ChildItem -Path $MarkerDirectory -Filter "desc-*.txt" -ErrorAction SilentlyContinue
            $gateMatrix.MarkerActualCount = if ($remainingMarkers) { @($remainingMarkers).Count } else { 0 }
            if (-not $remainingMarkers) {
                $gateMatrix.MarkerPathAbsent = $true
            } else {
                $gateErrors += "Marker files still present: $(@($remainingMarkers).Count)"
            }
        } else {
            $gateMatrix.MarkerPathAbsent = $true
        }
    } elseif ($MarkerDirectory -ne "") {
        # R15-FU-05: MarkerDirectory specified but no delete result — provide structured default
        $remainingMarkers = Get-ChildItem -Path $MarkerDirectory -Filter "desc-*.txt" -ErrorAction SilentlyContinue
        $markerCount = if ($remainingMarkers) { @($remainingMarkers).Count } else { 0 }
        $pathAbsent = ($markerCount -eq 0)
        $gateMatrix.MarkerPathAbsent = $pathAbsent
        $gateMatrix.MarkerActualCount = $markerCount
        # Structured default: Expected=0/Actual=markerCount/Success=pathAbsent
        if (-not $pathAbsent) {
            $gateErrors += "Marker files exist but no delete result provided ($markerCount remaining)"
        }
    } else {
        $gateMatrix.MarkerDeleted = $true  # No markers expected
        $gateMatrix.MarkerPathAbsent = $true
    }

    # R12-REM-03: 9. Final orphan check — from frozen pre-close evidence, not empty registry
    # R15: When ExpectedManifest is provided and EntrySnapshot comparison passed,
    # the orphan check is already done via frozen EntrySnapshot (step 5 above).
    # Only query live registry when ExpectedManifest is NOT provided (legacy path).
    $orphanResult = $null
    if ($ExpectedManifest.Count -gt 0 -and $null -ne $gateMatrix.EntrySnapshotOk -and $gateMatrix.EntrySnapshotOk) {
        # Frozen evidence already verified in step 5 — report as clean
        $orphanResult = [PSCustomObject]@{ Status='VerifiedClean'; Detail="Frozen EntrySnapshot matched ExpectedManifest (count=$($ExpectedManifest.Count))"; Source='FrozenSnapshot' }
    } elseif ($null -ne $Registry) {
        # Legacy path: no expected manifest, query live registry
        $orphanResult = Test-HandleOrphans -Registry $Registry -ExpectedManifest $ExpectedManifest
        if ($orphanResult.Status -ne 'VerifiedClean') {
            $gateErrors += "Orphan check: $($orphanResult.Status) $($orphanResult.Detail)"
        }
    } elseif ($IsLaunchedChild) {
        $gateErrors += "Registry null for launched-child fixture (orphan check impossible)"
    }
    $gateMatrix.OrphanStatus = if ($orphanResult) { $orphanResult.Status } else { 'N/A' }

    return [PSCustomObject]@{
        Pass = ($gateErrors.Count -eq 0)
        Errors = $gateErrors
        Matrix = $gateMatrix
        CleanupResult = $CleanupResult
        CaptureHealth = $CaptureHealthMapping
        OrphanResult = $orphanResult
    }
}


# R15-FU2-01: Authoritative pre-acquired-handle helper.
# Accepts a mandatory pre-acquired ProcessHandleRegistry (caller held continuously
# since before fault injection). NEVER reopens PID. Uses try/finally so CloseAll()
# is attempted exactly once on every path. No early return bypasses closure.
# Returns structured result with full cleanup evidence.
# NOTE: ExpectedCreationTime is .NET DateTime ticks (epoch 0001-01-01). Internal
# conversion to FILETIME ticks (epoch 1601-01-01) for GetProcessTimes comparison.
function Stop-Wait-VerifyOwnedProcess {
    param(
        [Parameter(Mandatory=$true)][ProcessHandleRegistry]$Registry,
        [Parameter(Mandatory=$true)][long]$ExpectedCreationTime,
        [int]$EntryIndex = 0,
        [int]$ExpectedEntryCount = 1,
        [int]$WaitMs = 3000
    )
    $result = [PSCustomObject]@{
        RegistrationSucceeded = $false
        EntryCount = 0
        ExpectedEntryCount = $ExpectedEntryCount
        IdentityVerified = $false
        IdentityMatched = $false
        InitialWaitOutcome = 'Unknown'
        TerminateAttempted = $false
        TerminateSucceeded = $false
        TerminateWin32Error = 0
        TerminateError = ''
        FinalWaitOutcome = 'Unknown'
        FinalWaitCode = [uint32]0
        FinalWaitWin32Error = 0
        ExitedVerified = $false
        TimedOut = $false
        CloseAttempted = $false
        CloseAllSucceeded = $false
        CloseFailedCount = 0
        Success = $false
        Errors = @()
    }

    # R15-FU2-01: Convert .NET DateTime ticks to FILETIME ticks for GetProcessTimes comparison
    $fileTimeTicks = 0
    if ($ExpectedCreationTime -gt 0) {
        try {
            $fileTimeTicks = [System.TimeZoneInfo]::ConvertTimeToUtc(
                [DateTime]::new($ExpectedCreationTime, [DateTimeKind]::Local)
            ).ToFileTimeUtc()
        } catch {
            $result.Errors += "CreationTime conversion failed: $($_.Exception.Message)"
        }
    }

    # R15-FU2-01: All paths go through finally — no early return bypasses CloseAll
    try {
        # Validate registry has entries at the expected index
        $result.EntryCount = $Registry.Count
        if ($result.EntryCount -eq 0) {
            $result.Errors += "Registry has no entries"
            return $result
        }
        if ($EntryIndex -ge $result.EntryCount) {
            $result.Errors += "Entry index $EntryIndex out of range (count=$($result.EntryCount))"
            return $result
        }
        if ($ExpectedCreationTime -le 0) {
            $result.Errors += "ExpectedCreationTime is zero or negative"
            return $result
        }
        if ($fileTimeTicks -eq 0) {
            $result.Errors += "FILETIME conversion produced zero"
            return $result
        }

        $result.RegistrationSucceeded = $true

        # Identity verification through held handle (no PID lookup)
        $entries = $Registry.GetEntries()
        $entry = $entries[$EntryIndex]
        $result.IdentityVerified = $true
        $result.IdentityMatched = ($entry.CreationTime -eq $fileTimeTicks)

        if (-not $result.IdentityMatched) {
            # Identity mismatch — do NOT terminate; finally closes handle
            return $result
        }

        # Check initial wait status through held handle
        $waitStatus = $Registry.CheckWaitStatus($EntryIndex)
        $result.InitialWaitOutcome = [string]$waitStatus.Outcome

        if ($waitStatus.Exited) {
            $result.ExitedVerified = $true
            $result.FinalWaitOutcome = 'Exited'
            return $result
        }

        # Terminate and wait through the held handle (not by PID)
        $result.TerminateAttempted = $true
        try {
            $twr = $Registry.TerminateAndVerify($EntryIndex, 99, $WaitMs)
            $result.TerminateSucceeded = $twr.Terminated
            $result.TerminateWin32Error = $twr.TerminateWin32Error
            $result.TerminateError = if ($twr.TerminateError) { $twr.TerminateError } else { '' }
            $result.FinalWaitOutcome = [string]$twr.Wait.Outcome
            $result.FinalWaitCode = $twr.Wait.WaitCode
            $result.FinalWaitWin32Error = $twr.Wait.Win32Error
            $result.ExitedVerified = $twr.Wait.Exited
            $result.TimedOut = ($twr.Wait.Outcome -eq 'Timeout')
        } catch {
            $result.Errors += "TerminateAndVerify exception: $($_.Exception.Message)"
            # Post-exception: check if process exited anyway
            try {
                $ws2 = $Registry.CheckWaitStatus($EntryIndex)
                if ($ws2.Exited) {
                    $result.ExitedVerified = $true
                    $result.FinalWaitOutcome = 'Exited'
                }
            } catch {
                $result.Errors += "Post-exception wait check failed: $($_.Exception.Message)"
            }
        }
    } catch {
        $result.Errors += "Helper exception: $($_.Exception.Message)"
    } finally {
        # R15-FU2-01: CloseAll attempted exactly once on every path
        $result.CloseAttempted = $true
        try {
            $closeResult = $Registry.CloseAll()
            $result.CloseAllSucceeded = $closeResult.AllClosed
            $result.CloseFailedCount = $closeResult.Failed
        } catch {
            $result.Errors += "CloseAll exception: $($_.Exception.Message)"
        }
        # R13-FU3-02: Fail-closed Success — shared predicate (R14-FU4-03)
        $result.Success = Test-HelperSuccess -Result $result
    }

    return $result
}

# R14-FU4-03: Shared fail-closed success predicate for Stop-Wait-VerifyOwnedProcess.
# Used by the helper's finally block AND by focused negative tests to avoid
# duplicating the PASS formula in a test-only block.
function Test-HelperSuccess {
    param([PSCustomObject]$Result)
    return ($Result.RegistrationSucceeded -and
        ($Result.EntryCount -eq $Result.ExpectedEntryCount) -and
        $Result.IdentityVerified -and
        $Result.IdentityMatched -and
        $Result.ExitedVerified -and
        $Result.CloseAttempted -and
        $Result.CloseAllSucceeded -and
        ($Result.CloseFailedCount -eq 0) -and
        ($Result.Errors.Count -eq 0))
}

function Test-ProcessLevelFaults {
    $allPassed = $true
    $tests = @()
    $scriptPath = $PSCommandPath
    $childTimeoutMs = 30000   # 30 seconds per normal fault child (fast mode)
    $hangTimeoutMs = 5000     # 5 seconds for timeout/hang fixture
    $maxStreamBytes = 51200   # 50KB bounded capture per stream

    # R5-REM-01: Unique token embedded in CLI args
    $testRunToken = "PLF-$([guid]::NewGuid().ToString('N'))"
    $markerDir = Join-Path $env:TEMP "plf-markers-$testRunToken"
    New-Item -ItemType Directory -Path $markerDir -Force | Out-Null

    # R6-REM-03: Create Job Object (supplementary)
    $jobHandle = [JobObjectHelper]::CreateKillOnCloseJob()
    if ($jobHandle -eq [IntPtr]::Zero) {
        Write-Host "  WARNING: Job Object creation failed (handle registry is primary)" -ForegroundColor Yellow
    }

    # R7-REM-02: Process Handle Registry (primary authority)
    $handleRegistry = New-Object ProcessHandleRegistry

    # R7-REM-02: Register descendant handles from marker files
    function Register-DescendantHandles {
        param([string]$Token, [string]$MarkerDirectory, [ProcessHandleRegistry]$Registry)
        $result = [PSCustomObject]@{
            Observed = 0; Registered = 0; Errors = @(); Entries = @()
        }
        $markerFiles = Get-ChildItem -Path $MarkerDirectory -Filter "desc-*.txt" -ErrorAction SilentlyContinue
        if (-not $markerFiles) { return $result }
        foreach ($mf in @($markerFiles)) {
            try {
                $mfContent = (Get-Content $mf.FullName -Raw -ErrorAction Stop).Trim()
                $parts = $mfContent.Split('|')
                if ($parts.Count -lt 3) {
                    $result.Errors += "Marker format invalid: $($mf.Name) (expected 3+ fields, got $($parts.Count))"
                    continue
                }
                if ($parts[0] -ne $Token) {
                    $result.Errors += "Token mismatch: $($mf.Name) expected=$Token got=$($parts[0])"
                    continue
                }
                $descPid = 0
                try { $descPid = [int]$parts[1] } catch {
                    $result.Errors += "PID parse failed: $($mf.Name) value=$($parts[1])"
                    continue
                }
                $descRole = $parts[2]
                if ([string]::IsNullOrWhiteSpace($descRole)) {
                    $result.Errors += "Role empty: $($mf.Name)"
                    continue
                }
                $result.Observed++
                # R10-REM-01: Exact manifest tracking - record every observed marker
                $result.Entries += [PSCustomObject]@{ Pid=$descPid; Role=$descRole; Token=$Token; Registered=$false; CreationTime=0 }
                $alreadyRegistered = $false
                foreach ($e in $Registry.GetEntries()) { if ($e.Pid -eq $descPid) { $alreadyRegistered = $true; break } }
                if ($alreadyRegistered) {
                    # R10-REM-01: Idempotent duplicate - do NOT double-count Observed.
                    $result.Entries[-1].Registered = $true
                    continue
                }
                $regResult = $Registry.RegisterProcess($descPid, $Token, $descRole)
                if ($regResult.Success) {
                    $result.Registered++
                    # R10-REM-01: Update the manifest entry with registration result
                    $result.Entries[-1].Registered = $true
                    $result.Entries[-1].CreationTime = $regResult.CreationTime
                } else {
                    $result.Errors += "Registration failed PID=$descPid role=$descRole error=$($regResult.Error) win32=$($regResult.Win32Error)"
                }
            } catch {
                $result.Errors += "Marker parse exception: $($mf.Name) - $($_.Exception.Message)"
            }
        }
        return $result
    }

    # R7-REM-03: Handle-based orphan verification
    # R11-REM-03: Accept expected manifest for per-entry PID/role/token/creation-time comparison
    function Test-HandleOrphans {
        param(
            [ProcessHandleRegistry]$Registry,
            [IntPtr]$JobHandle = [IntPtr]::Zero,
            [bool]$JobAssigned = $false,
            [int]$ExpectedParentCount = 0,
            [int]$ExpectedDescendantCount = 0,
            [PSCustomObject[]]$ExpectedManifest = @()
        )
        $entryCount = $Registry.Count
        $expectedTotal = $ExpectedParentCount + $ExpectedDescendantCount
        # R11-REM-03: If expected manifest provided, do per-entry comparison
        if ($ExpectedManifest.Count -gt 0) {
            if ($entryCount -ne $ExpectedManifest.Count) {
                $kind = if ($entryCount -lt $ExpectedManifest.Count) { 'IncompleteRegistrations' } else { 'ExtraRegistrations' }
                return [PSCustomObject]@{
                    Status=$kind; Detail="ExpectedManifest=$($ExpectedManifest.Count) registered=$entryCount"; Source='Handles'
                }
            }
            $entries = $Registry.GetEntries()
            $pidSet = @{}
            for ($i = 0; $i -lt $entries.Count; $i++) {
                $e = $entries[$i]; $exp = $ExpectedManifest[$i]
                if ($pidSet.ContainsKey($e.Pid)) {
                    return [PSCustomObject]@{ Status='DuplicatePID'; Detail="Duplicate PID=$($e.Pid)"; Source='Handles' }
                }
                $pidSet[$e.Pid] = $true
                if ($e.CreationTime -eq 0) {
                    return [PSCustomObject]@{ Status='ZeroCreationTime'; Detail="PID=$($e.Pid) CreationTime=0"; Source='Handles' }
                }
                if ($e.Pid -ne $exp.Pid) {
                    return [PSCustomObject]@{ Status='PidMismatch'; Detail="Entry[$i] ExpectedPID=$($exp.Pid) ActualPID=$($e.Pid)"; Source='Handles' }
                }
                if ($e.Role -ne $exp.Role) {
                    return [PSCustomObject]@{ Status='RoleMismatch'; Detail="PID=$($e.Pid) ExpectedRole=$($exp.Role) ActualRole=$($e.Role)"; Source='Handles' }
                }
                if ($e.Token -ne $exp.Token) {
                    return [PSCustomObject]@{ Status='TokenMismatch'; Detail="PID=$($e.Pid) ExpectedToken=$($exp.Token)"; Source='Handles' }
                }
            }
        } else {
            # R10-REM-01: Exact count - reject both under AND over registration
            if ($expectedTotal -gt 0 -and $entryCount -ne $expectedTotal) {
                $kind = if ($entryCount -lt $expectedTotal) { 'IncompleteRegistrations' } else { 'ExtraRegistrations' }
                return [PSCustomObject]@{
                    Status=$kind; Detail="Expected=$expectedTotal registered=$entryCount"; Source='Handles'
                }
            }
            if ($entryCount -gt 0) {
                $entries = $Registry.GetEntries()
                $pidSet = @{}
                foreach ($e in $entries) {
                    if ($pidSet.ContainsKey($e.Pid)) {
                        return [PSCustomObject]@{ Status='DuplicatePID'; Detail="Duplicate PID=$($e.Pid) in registry"; Source='Handles' }
                    }
                    $pidSet[$e.Pid] = $true
                }
                foreach ($e in $entries) {
                    if ($e.CreationTime -eq 0) {
                        return [PSCustomObject]@{ Status='ZeroCreationTime'; Detail="PID=$($e.Pid) has zero CreationTime"; Source='Handles' }
                    }
                }
            }
        }
        $handleActive = $Registry.ActiveCount
        if ($handleActive -gt 0) {
            return [PSCustomObject]@{ Status='OrphansFound'; Detail="Handle active=$handleActive"; Source='Handles' }
        }
        if ($JobHandle -ne [IntPtr]::Zero -and $JobAssigned) {
            $jobActive = [JobObjectHelper]::GetActiveProcessCount($JobHandle)
            if ($jobActive -gt 0) {
                return [PSCustomObject]@{ Status='OrphansFound'; Detail="Job active=$jobActive"; Source='AssignedJob' }
            } elseif ($jobActive -eq 0) {
                return [PSCustomObject]@{ Status='VerifiedClean'; Detail="Handles=0 Job=0 (assigned)"; Source='Handles+AssignedJob' }
            }
        }
        return [PSCustomObject]@{ Status='VerifiedClean'; Detail="Handles=0"; Source='Handles' }
    }

    # R7-REM-02: Handle-based cleanup — R9: phased, fail-closed on registration errors.
    # R9-REM-03: Verify handles exited BEFORE CloseAll to prevent active=0 illusion.
    function Invoke-HandleCleanup {
        param(
            [ProcessHandleRegistry]$Registry,
            [string]$Token,
            [string]$MarkerDirectory,
            [IntPtr]$JobHandle = [IntPtr]::Zero,
            [bool]$JobAssigned = $false,
            [int]$ExpectedParentCount = 0,
            [int]$ExpectedDescendantCount = 0
        )
        $errors = @(); $actions = @()

        # Phase 1: Terminate job-assigned processes if any
        if ($JobHandle -ne [IntPtr]::Zero -and $JobAssigned) {
            $activeCount = [JobObjectHelper]::GetActiveProcessCount($JobHandle)
            if ($activeCount -gt 0) {
                $jt = [JobObjectHelper]::TerminateAll($JobHandle, 99)
                if ($jt) { $actions += "Job terminated ($activeCount procs)"; Start-Sleep -Milliseconds 500 }
                else { $errors += "Job TerminateAll failed" }
            }
        }

        # Phase 2: Register descendant handles — R9-REM-01: errors are FAILURES, not diagnostic
        $regResult = Register-DescendantHandles -Token $Token -MarkerDirectory $MarkerDirectory -Registry $Registry
        if ($regResult.Errors.Count -gt 0) {
            $errors += "Descendant registration errors: $($regResult.Errors.Count) ($($regResult.Errors -join '; '))"
        }
        # R9-REM-02 + R11-REM-03: Check expected registration counts (exact, not lt)
        $expectedTotal = $ExpectedParentCount + $ExpectedDescendantCount
        if ($expectedTotal -gt 0 -and $Registry.Count -ne $expectedTotal) {
            $errors += "Registration count mismatch: expected=$expectedTotal actual=$($Registry.Count)"
        }

        # Phase 3: R10-REM-03 - Structured terminate+wait per entry with WaitOutcome
        $entries = $Registry.GetEntries()
        # R10-REM-03: Freeze entry evidence BEFORE any state changes (structured)
        $entrySnapshot = @()
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            $entrySnapshot += [PSCustomObject]@{ Pid=$e.Pid; Role=$e.Role; Token=$e.Token; CreationTime=$e.CreationTime; InitialExited=$e.Exited; TerminateResult=$null; WaitOutcome='Unknown'; WaitCode=0; Win32Error=0; TerminateError='' }
        }
        for ($i = 0; $i -lt $entries.Count; $i++) {
            # R10-REM-04: Use structured TerminateAndVerify for WAIT_FAILED semantics
            $twr = $Registry.TerminateAndVerify($i, 99, 3000)
            $entrySnapshot[$i].TerminateResult = $twr.Terminated
            $entrySnapshot[$i].WaitOutcome = [string]$twr.Wait.Outcome
            $entrySnapshot[$i].WaitCode = $twr.Wait.WaitCode
            $entrySnapshot[$i].Win32Error = $twr.Wait.Win32Error
            $entrySnapshot[$i].TerminateError = $twr.TerminateError
            # R10-REM-03: Check Wait.Exited (not Terminated) - TerminateProcess may fail on
            # already-exited processes but WaitForSingleObject still confirms exit.
            if ($twr.Wait.Exited) {
                $actions += "Handle PID=$($entries[$i].Pid) role=$($entries[$i].Role) exited (terminated=$($twr.Terminated))"
            } elseif ($twr.Wait.Outcome -eq 'WaitFailed') {
                # R10-REM-04: WAIT_FAILED is a structured VerificationError
                $errors += "WAIT_FAILED PID=$($entries[$i].Pid) role=$($entries[$i].Role) WaitCode=$($twr.Wait.WaitCode) Win32=$($twr.Wait.Win32Error)"
            } elseif ($twr.Wait.Outcome -eq 'Timeout') {
                $errors += "Wait timeout PID=$($entries[$i].Pid) role=$($entries[$i].Role) WaitCode=$($twr.Wait.WaitCode)"
            } else {
                $errors += "Unknown outcome PID=$($entries[$i].Pid) role=$($entries[$i].Role) Outcome=$($twr.Wait.Outcome)"
            }
        }

        # Phase 4: Verify ALL handles exited BEFORE closing — R9-REM-03
        $activeBeforeClose = $Registry.ActiveCount
        if ($activeBeforeClose -gt 0) {
            $errors += "Pre-close verification: $activeBeforeClose handles still active"
        }

        # Phase 5: Close handles only after verification
        $closeResult = $Registry.CloseAll()
        if (-not $closeResult.AllClosed) {
            $errors += "CloseAll failed: $($closeResult.Failed) of $($closeResult.Attempted) handles"
        }

        $activeAfter = $Registry.ActiveCount
        if ($activeAfter -gt 0) { $errors += "Post-cleanup: $activeAfter handles still active" }

        return [PSCustomObject]@{
            Success=($errors.Count -eq 0); Errors=$errors; Actions=$actions
            ActiveBeforeClose=$activeBeforeClose; ActiveAfter=$activeAfter
            RegistrationResult=$regResult; CloseResult=$closeResult
            EntrySnapshot=$entrySnapshot; EntryCount=$entrySnapshot.Count
        }
    }

    # R9-REM-06: Marker deletion with live-handle guard.
    # Checks registry for active handles before allowing deletion.
    # Returns structured result: Success, Error, ActiveCount.
    function Delete-OwnedMarkers {
        param([string]$MarkerDirectory, [ProcessHandleRegistry]$Registry)
        $activeCount = $Registry.ActiveCount
        if ($activeCount -gt 0) {
            return [PSCustomObject]@{ Success=$false; Error="BlockedLiveHandles"; ActiveCount=$activeCount }
        }
        if (-not (Test-Path $MarkerDirectory)) {
            return [PSCustomObject]@{ Success=$true; Error=""; ActiveCount=0 }
        }
        try {
            Remove-Item $MarkerDirectory -Recurse -Force -ErrorAction Stop
            $stillExists = Test-Path $MarkerDirectory
            return [PSCustomObject]@{ Success=(-not $stillExists); Error=$(if ($stillExists) { "Directory still exists after deletion" } else { "" }); ActiveCount=0 }
        } catch {
            return [PSCustomObject]@{ Success=$false; Error=$_.Exception.Message; ActiveCount=0 }
        }
    }

    $faults = @(
        @{ Name='MissingSuite';      Fault='MissingSuite';      Timeout=$childTimeoutMs; Fast=$true; Type='structural' },
        @{ Name='DeclaredMismatch';  Fault='DeclaredMismatch';  Timeout=$childTimeoutMs; Fast=$true; Type='structural' },
        @{ Name='PassedMismatch';    Fault='PassedMismatch';    Timeout=$childTimeoutMs; Fast=$true; Type='structural' },
        @{ Name='FailedNonZero';     Fault='FailedNonZero';     Timeout=$childTimeoutMs; Fast=$true; Type='structural' },
        @{ Name='ManifestMismatch';  Fault='ManifestMismatch';  Timeout=$childTimeoutMs; Fast=$true; Type='structural' },
        @{ Name='Timeout';           Fault='Timeout';           Timeout=$hangTimeoutMs;  Fast=$true; Type='timeout' },
        @{ Name='StdoutOversize';    Fault='StdoutOversize';    Timeout=$childTimeoutMs; Fast=$true; Type='oversize' },
        @{ Name='StderrOversize';    Fault='StderrOversize';    Timeout=$childTimeoutMs; Fast=$true; Type='oversize' },
        @{ Name='DualStreamOversize';Fault='DualStreamOversize';Timeout=$childTimeoutMs; Fast=$true; Type='oversize' },
        @{ Name='LongLine';          Fault='LongLine';          Timeout=$childTimeoutMs; Fast=$true; Type='oversize' },
        @{ Name='BoundaryExact';     Fault='BoundaryExact';     Timeout=$childTimeoutMs; Fast=$true; Type='boundary' },
        @{ Name='BoundaryOver';      Fault='BoundaryOver';      Timeout=$childTimeoutMs; Fast=$true; Type='boundary' },
        @{ Name='CleanupFailure';    Fault='CleanupFailure';    Timeout=$childTimeoutMs; Fast=$true; Type='cleanup' },
        @{ Name='JobAssignFailure';  Fault='JobAssignFailure';  Timeout=$childTimeoutMs; Fast=$true; Type='structural' },
        @{ Name='ParentHandleRegFailure'; Fault='ParentHandleRegFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='handleReg' },
        @{ Name='DescendantHandleRegFailure'; Fault='DescendantHandleRegFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='handleReg' },
        @{ Name='CollectorReadFailure'; Fault='CollectorReadFailure'; Timeout=$childTimeoutMs; Fast=$false; Type='collectorFault' },
        @{ Name='CollectorDrainTimeout'; Fault='CollectorDrainTimeout'; Timeout=$childTimeoutMs; Fast=$false; Type='collectorFault' },
        @{ Name='MarkerDeletionWhileLive'; Fault='MarkerDeletionWhileLive'; Timeout=$childTimeoutMs; Fast=$true; Type='markerLifecycle' },
        @{ Name='MarkerDeletionFailure'; Fault='MarkerDeletionFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='markerLifecycle' },
        @{ Name='GetProcessTimesFailure'; Fault='GetProcessTimesFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='nativeApiFault' },
        @{ Name='WaitFailure'; Fault='WaitFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='nativeApiFault' },
        @{ Name='CloseHandleFailure'; Fault='CloseHandleFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='nativeApiFault' },
        # R12-REM-01: Meta-tests — inject manifest mismatches to prove Gate rejects
        @{ Name='MetaRoleMismatch'; Fault='MetaRoleMismatch'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        @{ Name='MetaTokenMismatch'; Fault='MetaTokenMismatch'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        @{ Name='MetaExtraEntry'; Fault='MetaExtraEntry'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        @{ Name='MetaExtraMarker'; Fault='MetaExtraMarker'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        @{ Name='MetaNullEvidence'; Fault='MetaNullEvidence'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        # R15-FU-04: Additional meta-tests for manifest/marker negative paths
        @{ Name='MetaEmptyManifest'; Fault='MetaEmptyManifest'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        @{ Name='MetaDuplicateExpectedPID'; Fault='MetaDuplicateExpectedPID'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        @{ Name='MetaDuplicateActualPID'; Fault='MetaDuplicateActualPID'; Timeout=$childTimeoutMs; Fast=$true; Type='manifestMeta' },
        # R13-REM-03: Deterministic cleanup identity tests
        @{ Name='CleanupIdentityMatch'; Fault='CleanupIdentityMatch'; Timeout=$childTimeoutMs; Fast=$true; Type='cleanupIdentity' },
        @{ Name='CleanupIdentityMismatch'; Fault='CleanupIdentityMismatch'; Timeout=$childTimeoutMs; Fast=$true; Type='cleanupIdentity' },
        # R15-FU2-04: Deterministic cleanup registration failure fixture
        @{ Name='CleanupRegistrationFailure'; Fault='CleanupRegistrationFailure'; Timeout=$childTimeoutMs; Fast=$true; Type='cleanupRegFailure' }
    )

    foreach ($fixture in $faults) {
        $fault = $fixture.Fault; $timeoutMs = $fixture.Timeout; $useFast = $fixture.Fast; $fixtureType = $fixture.Type
        $proc = $null; $stdoutCapture = $null; $stderrCapture = $null; $exitCode = -1; $timedOut = $false
        $assignedToJob = $false
        $cleanupFailureInjected = $false; $primaryCleanupFailed = $false; $failureReported = $false
        $emergencyCleanupDone = $false; $parentExited = $false; $descendantExited = $false
        $descendantObserved = $false; $captureHealthy = $false
        $primaryCleanupResult = $null; $finallyCleanupResult = $null
        # R15-FU-01: ExpectedManifest construction variables
        $parentManifestEntry = $null; $descendantRegResult = $null; $expectedManifestFrozen = $false
        # R8-REM-01: Per-fixture registry for isolation
        $fixtureRegistry = New-Object ProcessHandleRegistry
        # R9: Reset all native API hooks to prevent cross-fixture contamination
        [ProcessHandleRegistry]::TestHook_FailGetProcessTimes = $false
        [ProcessHandleRegistry]::TestHook_FailWait = $false
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        [ProcessHandleRegistry]::TestHook_WaitErrorCode = 0
        # R9-REM-02: Expected registration counts per fixture type
        $expParentCount = if ($fixtureType -notin @('handleReg', 'collectorFault', 'markerLifecycle', 'nativeApiFault', 'cleanupIdentity', 'cleanupRegFailure')) { 1 } else { 0 }
        $expDescendantCount = if ($fault -in @('Timeout', 'CleanupFailure')) { 1 } else { 0 }

        try {
            # R8: Pure test fixtures (handleReg, collectorFault, markerLifecycle, nativeApiFault) don't need child processes
            $launchChild = ($fixtureType -notin @('handleReg', 'collectorFault', 'markerLifecycle', 'nativeApiFault', 'manifestMeta', 'cleanupIdentity', 'cleanupRegFailure'))
            if ($launchChild) {
                $fastFlag = if ($useFast) { "-SelfTestFastFault" } else { "" }
                $childArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -SelfTestOnly -SelfTestFault $fault $fastFlag -PLFToken $testRunToken -PLFMarkerDir `"$markerDir`""
                $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                $pinfo.FileName = "powershell.exe"; $pinfo.Arguments = $childArgs
                $pinfo.RedirectStandardOutput = $true; $pinfo.RedirectStandardError = $true
                $pinfo.UseShellExecute = $false; $pinfo.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($pinfo)

            # R7-REM-02: Register parent handle (primary authority) — returns RegistrationResult
            $regResult = $fixtureRegistry.RegisterProcess($proc.Id, $testRunToken, "parent")
            $parentRegistered = $regResult
            # R15-FU-01: Capture parent entry from known registration facts (not from EntrySnapshot)
            $parentManifestEntry = if ($regResult.Success) {
                [PSCustomObject]@{ Pid=$proc.Id; Role="parent"; Token=$testRunToken; CreationTime=$regResult.CreationTime }
            } else { $null }
            if (-not $regResult.Success) {
                Write-Host "  WARNING: Failed to register handle for PID=$($proc.Id) error=$($regResult.Error) win32=$($regResult.Win32Error)" -ForegroundColor Yellow
            }

            # R7-REM-01: Job assignment (supplementary, tracked)
            # R9-REM-05: JobAssignFailure must inject BEFORE real OS call to ensure
            # the process is NOT actually assigned to the Job Object.
            if ($fault -eq 'JobAssignFailure') {
                $assignedToJob = $false
                Write-Host "  [R9-REM-05] JobAssignFailure: skipped real OS assignment (deterministic)" -ForegroundColor Yellow
            } elseif ($jobHandle -ne [IntPtr]::Zero) {
                $assignedToJob = [JobObjectHelper]::AssignProcess($jobHandle, $proc.Id)
                if (-not $assignedToJob) {
                    Write-Host "  WARNING: Job assign failed for PID=$($proc.Id) (handle registry is primary)" -ForegroundColor Yellow
                }
            }

            # R7-REM-06: Bounded dual-stream capture with health tracking
            $collector = New-Object BoundedStreamCollector
            $stdoutStream = $proc.StandardOutput.BaseStream
            $stderrStream = $proc.StandardError.BaseStream
            $drainDeadlineMs = $timeoutMs + 5000
            $collectTask = $collector.CollectAsync($stdoutStream, $stderrStream, $maxStreamBytes, $drainDeadlineMs)

            $exited = $proc.WaitForExit($timeoutMs)
            if (-not $exited) {
                $timedOut = $true
                # R15-FU-01: Register descendants and capture result BEFORE cleanup (CloseAll clears entries)
                $descendantRegResult = Register-DescendantHandles -Token $testRunToken -MarkerDirectory $markerDir -Registry $fixtureRegistry
                # Freeze ExpectedManifest NOW while registry still has both parent + descendant
                $expectedManifest = @()
                if ($parentManifestEntry) { $expectedManifest += $parentManifestEntry }
                if ($descendantRegResult -and $descendantRegResult.Entries) {
                    foreach ($dEntry in $descendantRegResult.Entries) {
                        if ($dEntry.Registered) {
                            $expectedManifest += [PSCustomObject]@{
                                Pid = $dEntry.Pid; Role = 'timeout-descendant'; Token = $testRunToken; CreationTime = $dEntry.CreationTime
                            }
                        }
                    }
                }
                $expectedManifestFrozen = $true
                # Now cleanup (which clears registry entries)
                $primaryCleanupResult = Invoke-HandleCleanup -Registry $fixtureRegistry -Token $testRunToken -MarkerDirectory $markerDir -JobHandle $jobHandle -JobAssigned $assignedToJob -ExpectedParentCount $expParentCount -ExpectedDescendantCount $expDescendantCount
                $exitCode = -1
            } else { $exitCode = $proc.ExitCode }

            # R7-REM-06: Check collector wait return value
            $drainCompleted = $false
            try { $drainCompleted = $collectTask.Wait([Math]::Min(10000, $drainDeadlineMs * 2)) } catch {
                Write-Host "  WARNING: Collector drain wait exception: $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if (-not $drainCompleted) { Write-Host "  WARNING: Collector drain wait returned false" -ForegroundColor Yellow }
            # R10-REM-05: Use shared health mapper for consistent capture health assessment
            $captureHealthMapping = Get-CollectorHealthMapping -Collector $collector -DrainCompleted $drainCompleted
            $captureHealthy = $captureHealthMapping.Healthy

            $stdoutTotalBytes = $collector.StdoutTotalBytes; $stdoutCapturedBytes = $collector.StdoutCapturedBytes; $stdoutTruncated = $collector.StdoutTruncated
            $stderrTotalBytes = $collector.StderrTotalBytes; $stderrCapturedBytes = $collector.StderrCapturedBytes; $stderrTruncated = $collector.StderrTruncated
            $stdoutText = ""; if ($collector.StdoutRetainedBuffer -and $collector.StdoutRetainedBuffer.Length -gt 0) { $stdoutText = [System.Text.Encoding]::UTF8.GetString($collector.StdoutRetainedBuffer) }
            $stderrText = ""; if ($collector.StderrRetainedBuffer -and $collector.StderrRetainedBuffer.Length -gt 0) { $stderrText = [System.Text.Encoding]::UTF8.GetString($collector.StderrRetainedBuffer) }
            $stdoutCapture = [PSCustomObject]@{ CapturedBytes=$stdoutCapturedBytes; TotalBytes=$stdoutTotalBytes; Truncated=$stdoutTruncated; Text=$stdoutText }
            $stderrCapture = [PSCustomObject]@{ CapturedBytes=$stderrCapturedBytes; TotalBytes=$stderrTotalBytes; Truncated=$stderrTruncated; Text=$stderrText }

            # R7-REM-04: Timeout — set state variables (registration already done before cleanup)
            if ($fault -eq 'Timeout' -and $timedOut) {
                $parentExited = $true
                # Descendant was already registered and frozen in ExpectedManifest before cleanup
                # Check marker files for descendant observation
                $descMarkerFiles = Get-ChildItem -Path $markerDir -Filter "desc-*.txt" -ErrorAction SilentlyContinue
                $descendantObserved = ($descMarkerFiles -and @($descMarkerFiles).Count -gt 0)
                # Use frozen EntrySnapshot for exit status (registry was cleared by CloseAll)
                if ($descendantObserved -and $primaryCleanupResult -and $primaryCleanupResult.EntrySnapshot) {
                    $descendantExited = $true
                    foreach ($entry in $primaryCleanupResult.EntrySnapshot) {
                        if ($entry.Role -ne 'parent' -and $entry.WaitOutcome -ne 'Exited') { $descendantExited = $false; break }
                    }
                }
            }

            # R7-REM-04: CleanupFailure — verify descendant alive + emergency cleanup
            $cleanupFailureInjected = ($fault -eq 'CleanupFailure')
            if ($cleanupFailureInjected) {
                $parentExited = ($exitCode -eq 3)
                # R15-FU-01: Capture descendant registration result for ExpectedManifest
                $descendantRegResult = Register-DescendantHandles -Token $testRunToken -MarkerDirectory $markerDir -Registry $fixtureRegistry
                # Freeze ExpectedManifest BEFORE emergency cleanup (CloseAll clears entries)
                $expectedManifest = @()
                if ($parentManifestEntry) { $expectedManifest += $parentManifestEntry }
                if ($descendantRegResult -and $descendantRegResult.Entries) {
                    foreach ($dEntry in $descendantRegResult.Entries) {
                        if ($dEntry.Registered) {
                            $expectedManifest += [PSCustomObject]@{
                                Pid = $dEntry.Pid; Role = 'cleanup-descendant'; Token = $testRunToken; CreationTime = $dEntry.CreationTime
                            }
                        }
                    }
                }
                $expectedManifestFrozen = $true
                # Check marker files for descendant observation
                $descMarkerFiles = Get-ChildItem -Path $markerDir -Filter "desc-*.txt" -ErrorAction SilentlyContinue
                $descendantObserved = ($descMarkerFiles -and @($descMarkerFiles).Count -gt 0)
                if ($descendantObserved) {
                    $activeDescendants = $fixtureRegistry.ActiveCount
                    if ($activeDescendants -gt 0) {
                        $primaryCleanupFailed = $true; $failureReported = $true
                        $ecResult = Invoke-HandleCleanup -Registry $fixtureRegistry -Token $testRunToken -MarkerDirectory $markerDir -JobHandle $jobHandle -JobAssigned $assignedToJob -ExpectedParentCount $expParentCount -ExpectedDescendantCount $expDescendantCount
                        $emergencyCleanupDone = $ecResult.Success
                        # Use frozen EntrySnapshot for exit status (registry cleared by CloseAll)
                        if ($ecResult -and $ecResult.EntrySnapshot) {
                            $descendantExited = $true
                            foreach ($entry in $ecResult.EntrySnapshot) {
                                if ($entry.Role -ne 'parent' -and $entry.WaitOutcome -ne 'Exited') { $descendantExited = $false; break }
                            }
                        } else { $descendantExited = $false }
                    } else { $descendantExited = $true }
                }
            }
            } # end if ($launchChild)
        } catch {
            $stdoutCapture = [PSCustomObject]@{ CapturedBytes=0; TotalBytes=0; Truncated=$false; Text="(exception: $($_.Exception.Message))" }
            $stderrCapture = [PSCustomObject]@{ CapturedBytes=0; TotalBytes=0; Truncated=$false; Text="" }; $exitCode = -1
        } finally {
            if ($launchChild -and -not ($primaryCleanupResult -and $primaryCleanupResult.Success) -and ($fault -ne 'CleanupFailure' -or -not $emergencyCleanupDone)) {
                $finallyCleanupResult = Invoke-HandleCleanup -Registry $fixtureRegistry -Token $testRunToken -MarkerDirectory $markerDir -JobHandle $jobHandle -JobAssigned $assignedToJob -ExpectedParentCount $expParentCount -ExpectedDescendantCount $expDescendantCount
            }
            if ($proc) { $proc.Dispose() }
        }

        # R9: Clean up stale descendant marker files AFTER gate check (R11-REM-02: moved from before gate)
        # This is now done at the end of the foreach loop, after the gate check.

        # R15-FU-01: Build ExpectedManifest from independent known registration facts.
        # FORBIDDEN: copying from $fixtureRegistry.GetEntries() or CleanupResult.EntrySnapshot
        # (that would conflate actual with expected).
        # Parent entry: from successful RegisterProcess call (PID, role, token, creation time).
        # Descendant entries: PID from verified marker, role pre-fixed by fixture type,
        #   token=$testRunToken, creation time from successful held-handle registration.
        # Skip if already frozen (Timeout/CleanupFailure paths freeze before cleanup).
        if (-not $expectedManifestFrozen) {
            $expectedManifest = @()
            if ($launchChild) {
                if ($parentManifestEntry) {
                    $expectedManifest += $parentManifestEntry
                }
                # Normal launched-child: no descendants expected, descendant count must be 0
                # (Timeout/CleanupFailure already frozen above)
            }
        }

        # R12-REM-06: Collect ALL cleanup results for the gate (not just effective)
        $allCleanupResults = @()
        if ($primaryCleanupResult) { $allCleanupResults += $primaryCleanupResult }
        if ($finallyCleanupResult) { $allCleanupResults += $finallyCleanupResult }

        $stdoutTotalBytes = if ($stdoutCapture) { $stdoutCapture.TotalBytes } else { 0 }
        $stdoutCapturedBytes = if ($stdoutCapture) { $stdoutCapture.CapturedBytes } else { 0 }
        $stdoutTruncated = if ($stdoutCapture) { $stdoutCapture.Truncated } else { $false }
        $stdoutText = if ($stdoutCapture) { $stdoutCapture.Text } else { "" }
        $stderrTotalBytes = if ($stderrCapture) { $stderrCapture.TotalBytes } else { 0 }
        $stderrCapturedBytes = if ($stderrCapture) { $stderrCapture.CapturedBytes } else { 0 }
        $stderrTruncated = if ($stderrCapture) { $stderrCapture.Truncated } else { $false }
        $stderrText = if ($stderrCapture) { $stderrCapture.Text } else { "" }

        Write-Host "  [$fault] stdout: total=$stdoutTotalBytes captured=$stdoutCapturedBytes truncated=$stdoutTruncated" -ForegroundColor Gray
        if ($stderrTotalBytes -gt 0) { Write-Host "  [$fault] stderr: total=$stderrTotalBytes captured=$stderrCapturedBytes truncated=$stderrTruncated" -ForegroundColor Gray }

        # R11-REM-02: Common process gate variables (shared by all launchChild fixtures)
        $parentRegOk = ($parentRegistered -and $parentRegistered.Success)
        $creationTimeOk = ($parentRegistered -and $parentRegistered.CreationTime -ne 0)
        # R11-REM-02: Combine ALL cleanup results — any failure = FAIL, no hiding
        $allCleanupResults = @()
        if ($primaryCleanupResult) { $allCleanupResults += $primaryCleanupResult }
        if ($finallyCleanupResult) { $allCleanupResults += $finallyCleanupResult }
        $anyCleanupFailed = ($allCleanupResults | Where-Object { -not $_.Success }).Count -gt 0
        # Use the last result for detailed checks (entry snapshot, close result, etc.)
        $effectiveCleanup = if ($allCleanupResults.Count -gt 0) { $allCleanupResults[-1] } else { $null }
        $cleanupOk = (-not $anyCleanupFailed) -and ($null -ne $effectiveCleanup)
        $closeResultOk = ($null -ne $effectiveCleanup -and $effectiveCleanup.CloseResult.AllClosed)
        $activeBeforeCloseZero = ($null -ne $effectiveCleanup -and $effectiveCleanup.ActiveBeforeClose -eq 0)
        # R11-REM-02: Orphan check based on frozen EntrySnapshot, not empty registry
        $orphanFree = $true; $verSource = 'Handles+FrozenSnapshot'
        if ($null -ne $effectiveCleanup -and $null -ne $effectiveCleanup.EntrySnapshot) {
            foreach ($entry in $effectiveCleanup.EntrySnapshot) {
                if ($entry.WaitOutcome -ne 'Exited') {
                    $orphanFree = $false; $verSource = "UnexitedEntry PID=$($entry.Pid) role=$($entry.Role) Outcome=$($entry.WaitOutcome)"; break
                }
            }
            if ($orphanFree -and $effectiveCleanup.ActiveBeforeClose -gt 0) {
                $orphanFree = $false; $verSource = "ActiveBeforeClose=$($effectiveCleanup.ActiveBeforeClose)"
            }
        } elseif ($null -eq $effectiveCleanup) {
            $orphanFree = ($fixtureRegistry.Count -eq 0); $verSource = 'NoCleanup+RegistryCount'
        }

        # R15-FU-03: Marker ownership verification — validate before delete, reject unexpected
        # Must NOT blindly delete all desc-*.txt; must verify each marker belongs to this fixture.
        # Step 1: Parse markers, verify token ownership
        # Step 2: Compare owned markers against expected marker manifest (PID/role/token/count)
        # Step 3: Detect duplicate markers/PIDs
        # Step 4: Only delete after all verification passes
        $markerDeleteResult = $null
        if ($launchChild -and $markerDir -and $fixtureType -in @('timeout','cleanup','oversize','boundary','structural')) {
            $markerFiles = Get-ChildItem -Path $markerDir -Filter "desc-*.txt" -ErrorAction SilentlyContinue
            if ($markerFiles) {
                # Step 1: Parse all markers and verify ownership by token
                $ownedMarkers = @()
                $unexpectedMarkers = @()
                $markerErrors = @()
                $seenPids = @{}
                foreach ($mf in @($markerFiles)) {
                    try {
                        $content = (Get-Content $mf.FullName -Raw -ErrorAction Stop).Trim()
                        $parts = $content.Split('|')
                        if ($parts.Count -ge 3 -and $parts[0] -eq $testRunToken) {
                            $mPid = 0
                            try { $mPid = [int]$parts[1] } catch { $markerErrors += "Bad PID in $($mf.Name): $($parts[1])"; continue }
                            # Duplicate marker PID detection
                            if ($seenPids.ContainsKey($mPid)) {
                                $markerErrors += "Duplicate marker PID=$mPid ($($mf.Name) and $($seenPids[$mPid]))"
                            }
                            $seenPids[$mPid] = $mf.Name
                            $ownedMarkers += [PSCustomObject]@{ Path=$mf.FullName; Pid=$mPid; Role=$parts[2]; Token=$parts[0] }
                        } else {
                            $unexpectedMarkers += $mf.FullName
                        }
                    } catch {
                        $unexpectedMarkers += $mf.FullName
                    }
                }
                # Step 2: If unexpected markers (different token), FAIL
                if ($unexpectedMarkers.Count -gt 0) {
                    $markerErrors += "Unexpected markers: $($unexpectedMarkers.Count) (not owned by token=$testRunToken)"
                }
                # Step 3: Compare owned markers against expected marker manifest
                # Expected marker manifest = descendant entries from ExpectedManifest
                $expectedDescendants = @($expectedManifest | Where-Object { $_.Role -ne 'parent' })
                if ($markerErrors.Count -eq 0 -and $unexpectedMarkers.Count -eq 0) {
                    # Count check
                    if ($ownedMarkers.Count -ne $expectedDescendants.Count) {
                        $markerErrors += "Marker count mismatch: expected=$($expectedDescendants.Count) owned=$($ownedMarkers.Count)"
                    }
                    # Build maps for order-independent comparison
                    $ownedByPid = @{}
                    foreach ($om in $ownedMarkers) { $ownedByPid[$om.Pid] = $om }
                    $expectedByPid = @{}
                    foreach ($ed in $expectedDescendants) { $expectedByPid[$ed.Pid] = $ed }
                    # Check each expected descendant has a matching owned marker
                    foreach ($expPid in $expectedByPid.Keys) {
                        if (-not $ownedByPid.ContainsKey($expPid)) {
                            $ed = $expectedByPid[$expPid]
                            $markerErrors += "Missing marker: PID=$expPid role=$($ed.Role)"
                        } else {
                            $om = $ownedByPid[$expPid]
                            $ed = $expectedByPid[$expPid]
                            if ($om.Role -ne $ed.Role) {
                                $markerErrors += "Marker role mismatch: PID=$expPid expected=$($ed.Role) actual=$($om.Role)"
                            }
                        }
                    }
                    # Check for extra owned markers not in expected
                    foreach ($ownPid in $ownedByPid.Keys) {
                        if (-not $expectedByPid.ContainsKey($ownPid)) {
                            $om = $ownedByPid[$ownPid]
                            $markerErrors += "Extra marker: PID=$ownPid role=$($om.Role)"
                        }
                    }
                }
                # Step 4: If any errors, FAIL — don't delete
                if ($markerErrors.Count -gt 0) {
                    $markerDeleteResult = [PSCustomObject]@{
                        Success = $false
                        Error = $markerErrors -join '; '
                        ActiveCount = $unexpectedMarkers.Count + $ownedMarkers.Count
                        ExpectedCount = $expectedDescendants.Count
                        ActualCount = @($markerFiles).Count
                    }
                } else {
                    # Step 5: Delete only verified owned markers
                    $delErrors = @()
                    foreach ($om in $ownedMarkers) {
                        try { Remove-Item $om.Path -Force -ErrorAction Stop } catch { $delErrors += $_.Exception.Message }
                    }
                    # Step 6: Verify no markers remain
                    $remaining = Get-ChildItem -Path $markerDir -Filter "desc-*.txt" -ErrorAction SilentlyContinue
                    $markerDeleteResult = [PSCustomObject]@{
                        Success = ($delErrors.Count -eq 0) -and (-not $remaining)
                        Error = if ($delErrors.Count -gt 0) { $delErrors -join '; ' } elseif ($remaining) { "Marker files still exist after deletion" } else { "" }
                        ActiveCount = if ($remaining) { @($remaining).Count } else { 0 }
                        ExpectedCount = $expectedDescendants.Count
                        ActualCount = @($markerFiles).Count
                    }
                }
            } else {
                # No markers found — expected if no descendants
                $markerDeleteResult = [PSCustomObject]@{
                    Success=$true; Error=""; ActiveCount=0
                    ExpectedCount=$expectedManifest.Count; ActualCount=0
                }
            }
        }

        switch ($fixtureType) {
            'timeout' {
                $exitOk = ($exitCode -eq -1); $timedOutOk = $timedOut
                $noSuccessBanner = ($stdoutText.IndexOf("All self-tests passed") -lt 0)
                $hasPreTimeoutMarker = ($stdoutText -match 'PRE-TIMEOUT-MARKER')
                $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                $hasRealCapture = ($stdoutTotalBytes -gt 0); $bytesConsistent = ($stdoutCapturedBytes -le $stdoutTotalBytes) -and ($stderrCapturedBytes -le $stderrTotalBytes)
                # R11-REM-02: Use shared common gate for timeout fixture
                $commonGateResult = Test-CommonProcessGate -CleanupResult $effectiveCleanup -CaptureHealthMapping $captureHealthMapping -ParentRegOk $parentRegOk -CreationTimeOk $creationTimeOk -Registry $fixtureRegistry -MarkerDirectory $markerDir -ExpectedManifest $expectedManifest -AllCleanupResults $allCleanupResults -MarkerDeleteResult $markerDeleteResult -IsLaunchedChild $launchChild
                $commonGate = $commonGateResult.Pass
                if (-not $commonGate) { Write-Host "  [$fault] GATE FAIL: $($commonGateResult.Errors -join '; ')" -ForegroundColor Red }
                $timeoutSpecific = $exitOk -and $timedOutOk -and $noSuccessBanner -and $hasPreTimeoutMarker -and $withinBudget -and $hasRealCapture -and $bytesConsistent -and $descendantObserved -and $parentExited -and $descendantExited
                $pass = $commonGate -and $timeoutSpecific
                $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=-1 commonGate timeoutSpecific"; Actual="exit=$exitCode pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy m=$hasPreTimeoutMarker d=$descendantObserved pEx=$parentExited dEx=$descendantExited src=$verSource"; Pass=$pass }
            }
            'structural' {
                $exitOk = ($exitCode -eq 3); $noSuccessBanner = ($stdoutText.IndexOf("All self-tests passed") -lt 0)
                $noTrustedTotals = ($stdoutText -notmatch '\d+/\d+ PASS'); $noSkippedAsPassed = ($stdoutText -notmatch 'ProcessLevelFaults.*Passed=\d+')
                $hasSuiteValidation = ($stdoutText -match 'SUITE-VALIDATION'); $hasScriptInternal = ($stdoutText -match 'ScriptInternal')
                $hasFailStatus = ($stdoutText -match 'FAIL.*Suite') -or ($stdoutText -match 'FAIL.*Manifest')
                $hasUntrusted = ($stdoutText -match 'UNTRUSTED'); $withinTimeout = (-not $timedOut)
                $stderrEmpty = ($stderrTotalBytes -eq 0); $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                $bytesConsistent = ($stdoutCapturedBytes -le $stdoutTotalBytes) -and ($stderrCapturedBytes -le $stderrTotalBytes)
                # R10-REM-02: commonProcessGate via shared function for all structural fixtures
                $commonGateResult = Test-CommonProcessGate -CleanupResult $effectiveCleanup -CaptureHealthMapping $captureHealthMapping -ParentRegOk $parentRegOk -CreationTimeOk $creationTimeOk -Registry $fixtureRegistry -MarkerDirectory $markerDir -ExpectedManifest $expectedManifest -AllCleanupResults $allCleanupResults -MarkerDeleteResult $markerDeleteResult -IsLaunchedChild $launchChild
                $commonGate = $commonGateResult.Pass
                $structEvidence = $exitOk -and $noSuccessBanner -and $noTrustedTotals -and $noSkippedAsPassed -and $hasSuiteValidation -and $hasScriptInternal -and $hasFailStatus -and $hasUntrusted -and $withinTimeout -and $stderrEmpty -and $withinBudget -and $bytesConsistent
                if ($fault -eq 'JobAssignFailure') {
                    # R9-REM-05: JobAssignFailure must assert real fallback state
                    $assignmentFailureInjected = ($stdoutText -match 'JOB-ASSIGN-FAILURE-INJECTED')
                    $assignedToJobFalse = (-not $assignedToJob)
                    $pass = $commonGate -and $structEvidence -and $assignmentFailureInjected -and $assignedToJobFalse
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 struct commonGate assignFail assigned=false"; Actual="exit=$exitCode si=$hasScriptInternal untrusted=$hasUntrusted pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk close=$closeResultOk of=$orphanFree h=$captureHealthy inj=$assignmentFailureInjected aTj=$assignedToJobFalse"; Pass=$pass }
                } else {
                    $pass = $commonGate -and $structEvidence
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 struct commonGate"; Actual="exit=$exitCode si=$hasScriptInternal untrusted=$hasUntrusted pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk close=$closeResultOk of=$orphanFree h=$captureHealthy sOut=$stdoutTotalBytes/$stdoutCapturedBytes b=$withinBudget"; Pass=$pass }
                }
            }
            'oversize' {
                $exitOk = ($exitCode -eq 3); $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                $noSuccessBanner = ($stdoutText.IndexOf("All self-tests passed") -lt 0); $bytesConsistent = ($stdoutCapturedBytes -le $stdoutTotalBytes) -and ($stderrCapturedBytes -le $stderrTotalBytes)
                # R10-REM-02: commonProcessGate via shared function
                $commonGateResult = Test-CommonProcessGate -CleanupResult $effectiveCleanup -CaptureHealthMapping $captureHealthMapping -ParentRegOk $parentRegOk -CreationTimeOk $creationTimeOk -Registry $fixtureRegistry -MarkerDirectory $markerDir -ExpectedManifest $expectedManifest -AllCleanupResults $allCleanupResults -MarkerDeleteResult $markerDeleteResult -IsLaunchedChild $launchChild
                $commonGate = $commonGateResult.Pass
                switch ($fault) {
                    'StdoutOversize' { $streamOk = ($stdoutTotalBytes -gt $maxStreamBytes) -and $stdoutTruncated -and ($stdoutCapturedBytes -eq $maxStreamBytes); $otherEmpty = ($stderrTotalBytes -eq 0) -and (-not $stderrTruncated); $pass = $commonGate -and $exitOk -and $withinBudget -and $streamOk -and $otherEmpty -and $noSuccessBanner -and $bytesConsistent; $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 sOut>51200 cap=51200 trunc sErr=0 commonGate"; Actual="exit=$exitCode sOut=$stdoutTotalBytes/$stdoutCapturedBytes/$stdoutTruncated sErr=$stderrTotalBytes pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy"; Pass=$pass } }
                    'StderrOversize' { $streamOk = ($stderrTotalBytes -gt $maxStreamBytes) -and $stderrTruncated -and ($stderrCapturedBytes -eq $maxStreamBytes); $otherEmpty = ($stdoutTotalBytes -eq 0) -and (-not $stdoutTruncated); $pass = $commonGate -and $exitOk -and $withinBudget -and $streamOk -and $otherEmpty -and $noSuccessBanner -and $bytesConsistent; $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 sErr>51200 cap=51200 trunc sOut=0 commonGate"; Actual="exit=$exitCode sErr=$stderrTotalBytes/$stderrCapturedBytes/$stderrTruncated sOut=$stdoutTotalBytes pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy"; Pass=$pass } }
                    'DualStreamOversize' { $stdoutOk = ($stdoutTotalBytes -gt $maxStreamBytes) -and $stdoutTruncated -and ($stdoutCapturedBytes -eq $maxStreamBytes); $stderrOk = ($stderrTotalBytes -gt $maxStreamBytes) -and $stderrTruncated -and ($stderrCapturedBytes -eq $maxStreamBytes); $pass = $commonGate -and $exitOk -and $withinBudget -and $stdoutOk -and $stderrOk -and $noSuccessBanner -and $bytesConsistent; $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 both>51200 bothTrunc cap=51200 commonGate"; Actual="exit=$exitCode sOut=$stdoutTotalBytes/$stdoutCapturedBytes/$stdoutTruncated sErr=$stderrTotalBytes/$stderrCapturedBytes/$stderrTruncated pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy"; Pass=$pass } }
                    'LongLine' { $streamOk = ($stdoutTotalBytes -gt $maxStreamBytes) -and $stdoutTruncated -and ($stdoutCapturedBytes -eq $maxStreamBytes); $otherEmpty = ($stderrTotalBytes -eq 0) -and (-not $stderrTruncated); $noPrematureNewline = (-not $stdoutText.Contains("`n")); $pass = $commonGate -and $exitOk -and $withinBudget -and $streamOk -and $otherEmpty -and $noSuccessBanner -and $bytesConsistent -and $noPrematureNewline; $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 sOut>51200 trunc cap=51200 noNL commonGate"; Actual="exit=$exitCode sOut=$stdoutTotalBytes/$stdoutCapturedBytes/$stdoutTruncated noNL=$noPrematureNewline pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy"; Pass=$pass } }
                }
            }
            'boundary' {
                $exitOk = ($exitCode -eq 3); $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                $noSuccessBanner = ($stdoutText.IndexOf("All self-tests passed") -lt 0); $bytesConsistent = ($stdoutCapturedBytes -le $stdoutTotalBytes) -and ($stderrCapturedBytes -le $stderrTotalBytes)
                $otherEmpty = ($stderrTotalBytes -eq 0) -and (-not $stderrTruncated)
                # R10-REM-02: commonProcessGate via shared function
                $commonGateResult = Test-CommonProcessGate -CleanupResult $effectiveCleanup -CaptureHealthMapping $captureHealthMapping -ParentRegOk $parentRegOk -CreationTimeOk $creationTimeOk -Registry $fixtureRegistry -MarkerDirectory $markerDir -ExpectedManifest $expectedManifest -AllCleanupResults $allCleanupResults -MarkerDeleteResult $markerDeleteResult -IsLaunchedChild $launchChild
                $commonGate = $commonGateResult.Pass
                if ($fault -eq 'BoundaryExact') {
                    $totalOk = ($stdoutTotalBytes -eq $maxStreamBytes); $notTruncated = (-not $stdoutTruncated); $capturedOk = ($stdoutCapturedBytes -eq $maxStreamBytes)
                    $pass = $commonGate -and $exitOk -and $withinBudget -and $totalOk -and $notTruncated -and $capturedOk -and $otherEmpty -and $noSuccessBanner -and $bytesConsistent
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 total=51200 cap=51200 notTrunc sErr=0 commonGate"; Actual="exit=$exitCode total=$stdoutTotalBytes cap=$stdoutCapturedBytes trunc=$stdoutTruncated sErr=$stderrTotalBytes pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy"; Pass=$pass }
                } else {
                    $totalOver = ($stdoutTotalBytes -eq ($maxStreamBytes + 1)); $isTruncated = $stdoutTruncated; $capturedOk = ($stdoutCapturedBytes -eq $maxStreamBytes)
                    $pass = $commonGate -and $exitOk -and $withinBudget -and $totalOver -and $isTruncated -and $capturedOk -and $otherEmpty -and $noSuccessBanner -and $bytesConsistent
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 total=51201 cap=51200 trunc sErr=0 commonGate"; Actual="exit=$exitCode total=$stdoutTotalBytes cap=$stdoutCapturedBytes trunc=$isTruncated sErr=$stderrTotalBytes pReg=$parentRegOk cTime=$creationTimeOk cOk=$cleanupOk of=$orphanFree h=$captureHealthy"; Pass=$pass }
                }
            }
            'cleanup' {
                $exitOk = ($exitCode -eq 3); $noSuccessBanner = ($stdoutText.IndexOf("All self-tests passed") -lt 0)
                $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                $bytesConsistent = ($stdoutCapturedBytes -le $stdoutTotalBytes) -and ($stderrCapturedBytes -le $stderrTotalBytes)
                # R11-REM-02: Use shared common gate for cleanup fixture
                # R12-REM-06: Primary cleanup intentionally fails — mark as ExpectedFailure
                # Pass ALL cleanup results to gate; primary failure is expected, not hidden
                $effectiveForGate = if ($ecResult) { $ecResult } else { $effectiveCleanup }
                # R12-REM-06: Mark primary result as expected failure for the gate
                $cleanupResultsForGate = @()
                if ($primaryCleanupResult) {
                    if ($cleanupFailureInjected) {
                        $primaryWithExpected = $primaryCleanupResult.PSObject.Copy()
                        $primaryWithExpected | Add-Member -NotePropertyName 'ExpectedFailure' -NotePropertyValue $true -Force
                        $cleanupResultsForGate += $primaryWithExpected
                    } else {
                        $cleanupResultsForGate += $primaryCleanupResult
                    }
                }
                if ($ecResult) { $cleanupResultsForGate += $ecResult }
                if ($finallyCleanupResult -and $finallyCleanupResult -ne $ecResult) { $cleanupResultsForGate += $finallyCleanupResult }
                $commonGateResult = Test-CommonProcessGate -CleanupResult $effectiveForGate -CaptureHealthMapping $captureHealthMapping -ParentRegOk $parentRegOk -CreationTimeOk $creationTimeOk -Registry $fixtureRegistry -MarkerDirectory $markerDir -ExpectedManifest $expectedManifest -AllCleanupResults $cleanupResultsForGate -MarkerDeleteResult $markerDeleteResult -IsLaunchedChild $launchChild
                $commonGate = $commonGateResult.Pass
                $cleanupSpecific = $exitOk -and $noSuccessBanner -and $withinBudget -and $bytesConsistent -and $cleanupFailureInjected -and $primaryCleanupFailed -and $failureReported -and $emergencyCleanupDone -and $parentExited -and $descendantExited -and $descendantObserved
                $pass = $commonGate -and $cleanupSpecific
                $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exit=3 commonGate cleanupSpecific"; Actual="exit=$exitCode pReg=$parentRegOk cTime=$creationTimeOk inj=$cleanupFailureInjected fail=$primaryCleanupFailed emerg=$emergencyCleanupDone dObs=$descendantObserved of=$orphanFree h=$captureHealthy cOk=$($commonGateResult.Pass)"; Pass=$pass }
            }
            'handleReg' {
                # R9-REM-01: Handle registration failure tests — must call real Gate, not just low-level check
                $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                if ($fault -eq 'ParentHandleRegFailure') {
                    # Test: registering PID 0 (invalid) must fail
                    $badReg = $fixtureRegistry.RegisterProcess(0, $testRunToken, "invalid-parent")
                    $failedAsExpected = (-not $badReg.Success)
                    $hasError = ([string]::IsNullOrEmpty($badReg.Error) -eq $false)
                    # R9-REM-01: Must also call real Test-HandleOrphans — must NOT be VerifiedClean
                    $orphanAfterBadReg = Test-HandleOrphans -Registry $fixtureRegistry -JobHandle $jobHandle -JobAssigned $false -ExpectedParentCount 1
                    $notVerifiedClean = ($orphanAfterBadReg.Status -ne 'VerifiedClean')
                    $pass = $failedAsExpected -and $hasError -and $notVerifiedClean
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Success=false Error!=empty orphan!=VerifiedClean"; Actual="Success=$($badReg.Success) Error=$($badReg.Error) Win32=$($badReg.Win32Error) orphan=$($orphanAfterBadReg.Status)"; Pass=$pass }
                } elseif ($fault -eq 'DescendantHandleRegFailure') {
                    # Create a bad marker file with PID=0 (invalid) and test registration
                    $badMarkerPath = Join-Path $markerDir "desc-99999.txt"
                    "$testRunToken|0|bad-descendant" | Out-File -FilePath $badMarkerPath -Encoding ASCII -Force
                    $descRegResult = Register-DescendantHandles -Token $testRunToken -MarkerDirectory $markerDir -Registry $fixtureRegistry
                    $regFailed = ($descRegResult.Errors.Count -gt 0)
                    $observedButNotRegistered = ($descRegResult.Observed -gt 0 -and $descRegResult.Registered -eq 0)
                    # R9-REM-01: Must call real Test-HandleOrphans — must NOT be VerifiedClean
                    $orphanAfterDescFail = Test-HandleOrphans -Registry $fixtureRegistry -JobHandle $jobHandle -JobAssigned $false -ExpectedParentCount 0 -ExpectedDescendantCount 1
                    $notVerifiedCleanDesc = ($orphanAfterDescFail.Status -ne 'VerifiedClean')
                    # Clean up the bad marker
                    Remove-Item $badMarkerPath -Force -ErrorAction SilentlyContinue
                    $pass = $regFailed -and $observedButNotRegistered -and $notVerifiedCleanDesc
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="obs>0 reg=0 err>0 orphan!=VerifiedClean"; Actual="obs=$($descRegResult.Observed) reg=$($descRegResult.Registered) err=$($descRegResult.Errors.Count) orphan=$($orphanAfterDescFail.Status)"; Pass=$pass }
                } else {
                    $pass = $false
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known handleReg fault"; Actual="unknown"; Pass=$pass }
                }
            }
            'nativeApiFault' {
                # R9-REM-08: Native API failure injection — GetProcessTimes, Wait, CloseHandle
                # These tests use C# test hooks to simulate failures, verify fail-closed Gate.
                # Real handles are always closed to prevent leaks.
                # R9: Verify hook isolation — all hooks must be false at start
                $hooksClean = (-not [ProcessHandleRegistry]::TestHook_FailGetProcessTimes) -and (-not [ProcessHandleRegistry]::TestHook_FailWait) -and (-not [ProcessHandleRegistry]::TestHook_FailClose) -and ([ProcessHandleRegistry]::TestHook_WaitErrorCode -eq 0)
                if (-not $hooksClean) {
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="hooks clean at start"; Actual="HOOK CONTAMINATION DETECTED"; Pass=$false }
                    if (-not $tests[-1].Pass) { $allPassed = $false }
                    continue
                }
                $withinBudget = ($stdoutCapturedBytes -le $maxStreamBytes) -and ($stderrCapturedBytes -le $maxStreamBytes)
                if ($fault -eq 'GetProcessTimesFailure') {
                    # Start a real child, set hook, try register → must fail, Gate → VerificationError
                    # R15-FU2-02: Pre-acquire cleanup handle BEFORE enabling hook
                    $gptProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
                    $gptProcId = $gptProc.Id
                    # R13-FU3-03: Freeze creation identity before hook injection
                    $gptCreationTime = $gptProc.StartTime.Ticks
                    $gptCleanupReg = New-Object ProcessHandleRegistry
                    $gptCleanupRegOk = $gptCleanupReg.RegisterProcess($gptProcId, $testRunToken, "gpt-cleanup").Success
                    # R15-FU2-02: Semantic evidence in try; test record in finally after cleanup
                    $gptSemanticPass = $false; $gptSemanticExpected = ""; $gptSemanticActual = ""
                    try {
                        [ProcessHandleRegistry]::TestHook_FailGetProcessTimes = $true
                        $gptReg = $fixtureRegistry.RegisterProcess($gptProcId, $testRunToken, "gpt-test")
                        $gptFailed = (-not $gptReg.Success)
                        $gptHasError = ($gptReg.Error -match 'GetProcessTimes')
                        $gptOrphan = Test-HandleOrphans -Registry $fixtureRegistry -ExpectedParentCount 1
                        $gptNotClean = ($gptOrphan.Status -ne 'VerifiedClean')
                        $gptSemanticPass = $gptFailed -and $gptHasError -and $gptNotClean
                        $gptSemanticExpected = "Success=false GetProcessTimes err orphan!=VerifiedClean cleanupOk"
                        $gptSemanticActual = "Success=$($gptReg.Success) Error=$($gptReg.Error) orphan=$($gptOrphan.Status)"
                    } finally {
                        [ProcessHandleRegistry]::TestHook_FailGetProcessTimes = $false
                        # R15-FU2-02: Cleanup via pre-acquired handle through shared helper
                        $gptCleanupResult = Stop-Wait-VerifyOwnedProcess -Registry $gptCleanupReg -ExpectedCreationTime $gptCreationTime
                        # R15-FU2-02: Gate PASS on semantic AND cleanup evidence
                        $gptCleanupOk = $gptCleanupResult.Success -and $gptCleanupRegOk
                        $pass = $gptSemanticPass -and $gptCleanupOk
                        $gptSemanticActual += " cleanupSuccess=$($gptCleanupResult.Success) exited=$($gptCleanupResult.ExitedVerified) close=$($gptCleanupResult.CloseAllSucceeded) regOk=$gptCleanupRegOk"
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected=$gptSemanticExpected; Actual=$gptSemanticActual; Pass=$pass }
                        $gptProc.Dispose()
                    }
                } elseif ($fault -eq 'WaitFailure') {
                    # R9: Start a real child, register normally, then set Wait hook.
                    # Registrations are COMPLETE — the failure is in WaitForSingleObject,
                    # not in registration. Must prove: regOk, WAIT_FAILED recognized,
                    # cleanup fails, independent cleanup succeeds.
                    # R15-FU2-02: Pre-acquire cleanup handle BEFORE enabling hook
                    $waitProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
                    $waitProcId = $waitProc.Id
                    # R13-FU3-03: Freeze creation identity before hook injection
                    $waitCreationTime = $waitProc.StartTime.Ticks
                    $waitCleanupReg = New-Object ProcessHandleRegistry
                    $waitCleanupRegOk = $waitCleanupReg.RegisterProcess($waitProcId, $testRunToken, "wait-cleanup").Success
                    # R15-FU2-02: Semantic evidence in try; test record in finally after cleanup
                    $waitSemanticPass = $false; $waitSemanticExpected = ""; $waitSemanticActual = ""
                    try {
                        $waitReg = $fixtureRegistry.RegisterProcess($waitProcId, $testRunToken, "wait-test")
                        $waitRegOk = $waitReg.Success
                        $waitRegCreationTime = $waitReg.CreationTime
                        $waitCreationNonzero = ($waitRegCreationTime -ne 0)
                        # Registration complete — 1 entry, expected 1
                        $regCountBeforeHook = $fixtureRegistry.Count
                        $regComplete = ($regCountBeforeHook -eq 1)
                        # R11-REM-04: Set deterministic error code BEFORE activating hook
                        $expectedWaitErrorCode = 0x57  # ERROR_INVALID_PARAMETER
                        [ProcessHandleRegistry]::TestHook_WaitErrorCode = $expectedWaitErrorCode
                        # Set hook — now IsProcessExited and TerminateProcessByIndex will see WAIT_FAILED
                        [ProcessHandleRegistry]::TestHook_FailWait = $true
                        # ActiveCount should NOT return 0 (WAIT_FAILED ≠ exited, ≠ normal active)
                        $waitActive = $fixtureRegistry.ActiveCount
                        $notZeroActive = ($waitActive -gt 0)
                        # Cleanup with hook active — must fail (terminate can't confirm wait)
                        $waitCleanup = Invoke-HandleCleanup -Registry $fixtureRegistry -Token $testRunToken -MarkerDirectory $markerDir
                        $waitCleanupFailed = (-not $waitCleanup.Success)
                        # R10-REM-04: Verify structured WAIT_FAILED in entry snapshot
                        $hasWaitFailedOutcome = $false
                        $waitWin32Error = 0
                        $hasTerminateError = ($waitCleanup.Errors -join ' ') -match 'WAIT_FAILED'
                        if ($waitCleanup.EntrySnapshot.Count -gt 0) {
                            $hasWaitFailedOutcome = ($waitCleanup.EntrySnapshot[0].WaitOutcome -eq 'WaitFailed')
                            $waitWin32Error = $waitCleanup.EntrySnapshot[0].Win32Error
                        }
                        # R11-REM-04: Assert exact deterministic error code
                        $exactErrorCode = ($waitWin32Error -eq $expectedWaitErrorCode)
                        # Entry snapshot proves registration was complete before cleanup
                        $entrySnapshotOk = ($waitCleanup.EntryCount -eq 1)
                        $snapshotPid = if ($waitCleanup.EntrySnapshot.Count -gt 0) { $waitCleanup.EntrySnapshot[0].Pid } else { 0 }
                        $snapshotPidMatch = ($snapshotPid -eq $waitProcId)
                        # R15-FU2-02: Semantic pass (including structured WaitOutcome + deterministic error)
                        $waitSemanticPass = $waitRegOk -and $waitCreationNonzero -and $regComplete -and $notZeroActive -and $waitCleanupFailed -and $hasWaitFailedOutcome -and $hasTerminateError -and $exactErrorCode -and $entrySnapshotOk -and $snapshotPidMatch
                        $waitSemanticExpected = "regOk cTime reg=1 active>0 cleanupFail WaitFailed Win32=$expectedWaitErrorCode snap=1 cleanupOk"
                        $waitSemanticActual = "reg=$waitRegOk cTime=$waitCreationNonzero reg=$regCountBeforeHook active=$waitActive cFail=$waitCleanupFailed wfOutcome=$hasWaitFailedOutcome wfErr=$hasTerminateError win32=$waitWin32Error exact=$exactErrorCode snap=$($waitCleanup.EntryCount) pid=$snapshotPidMatch"
                    } finally {
                        # R15-FU2-02: Reset hooks, close test registry, cleanup via pre-acquired handle
                        [ProcessHandleRegistry]::TestHook_FailWait = $false
                        [ProcessHandleRegistry]::TestHook_WaitErrorCode = 0
                        $fixtureRegistry.CloseAll()
                        $waitCleanupResult = Stop-Wait-VerifyOwnedProcess -Registry $waitCleanupReg -ExpectedCreationTime $waitCreationTime
                        # R15-FU2-02: Gate PASS on semantic AND cleanup evidence
                        $waitCleanupOk = $waitCleanupResult.Success -and $waitCleanupRegOk
                        $pass = $waitSemanticPass -and $waitCleanupOk
                        $waitSemanticActual += " cleanupSuccess=$($waitCleanupResult.Success) exited=$($waitCleanupResult.ExitedVerified) close=$($waitCleanupResult.CloseAllSucceeded) regOk=$waitCleanupRegOk"
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected=$waitSemanticExpected; Actual=$waitSemanticActual; Pass=$pass }
                        $waitProc.Dispose()
                    }
                } elseif ($fault -eq 'CloseHandleFailure') {
                    # Start a real child, register, then set Close hook and verify close reports failure
                    # R15-FU2-02: Pre-acquire cleanup handle BEFORE enabling hook; terminate via held handle
                    $closeProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
                    $closeProcId = $closeProc.Id
                    # R13-FU3-03: Freeze creation identity before hook injection
                    $closeCreationTime = $closeProc.StartTime.Ticks
                    $closeCleanupReg = New-Object ProcessHandleRegistry
                    $closeCleanupRegOk = $closeCleanupReg.RegisterProcess($closeProcId, $testRunToken, "close-cleanup").Success
                    # R15-FU2-02: Semantic evidence in try; test record in finally after cleanup
                    $closeSemanticPass = $false; $closeSemanticExpected = ""; $closeSemanticActual = ""
                    try {
                        $closeReg = $fixtureRegistry.RegisterProcess($closeProcId, $testRunToken, "close-test")
                        $closeRegOk = $closeReg.Success
                        # R15-FU2-02: Terminate via held handle (not PID)
                        [ProcessHandleRegistry]::TestHook_FailWait = $false
                        $closeTermResult = $fixtureRegistry.TerminateAndVerify(0, 99, 3000)
                        # Now set close hook — CloseAll should report failures
                        [ProcessHandleRegistry]::TestHook_FailClose = $true
                        $closeResult = $fixtureRegistry.CloseAll()
                        $closeReportedFail = (-not $closeResult.AllClosed)
                        $closeHasFailures = ($closeResult.Failed -gt 0)
                        $closeSemanticPass = $closeRegOk -and $closeReportedFail -and $closeHasFailures
                        $closeSemanticExpected = "regOk closeFailed failed>0 cleanupOk"
                        $closeSemanticActual = "reg=$closeRegOk allClosed=$($closeResult.AllClosed) failed=$($closeResult.Failed)/$($closeResult.Attempted)"
                    } finally {
                        [ProcessHandleRegistry]::TestHook_FailClose = $false
                        # R15-FU2-02: Cleanup via pre-acquired handle through shared helper
                        $closeCleanupResult = Stop-Wait-VerifyOwnedProcess -Registry $closeCleanupReg -ExpectedCreationTime $closeCreationTime
                        # R15-FU2-02: Gate PASS on semantic AND cleanup evidence
                        $closeCleanupOk = $closeCleanupResult.Success -and $closeCleanupRegOk
                        $pass = $closeSemanticPass -and $closeCleanupOk
                        $closeSemanticActual += " cleanupSuccess=$($closeCleanupResult.Success) exited=$($closeCleanupResult.ExitedVerified) close=$($closeCleanupResult.CloseAllSucceeded) regOk=$closeCleanupRegOk"
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected=$closeSemanticExpected; Actual=$closeSemanticActual; Pass=$pass }
                        $closeProc.Dispose()
                    }
                } else {
                    $pass = $false
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known nativeApiFault"; Actual="unknown"; Pass=$pass }
                }
            }
            'collectorFault' {
                # R9-REM-09: Collector fault tests — must map to structured gate failure
                # via the REAL shared aggregation path (Get-OverallResult), not just booleans.
                if ($fault -eq 'CollectorReadFailure') {
                    # Create a disposed stream — ReadAsync should throw
                    $faultCollector = New-Object BoundedStreamCollector
                    $memStream = New-Object System.IO.MemoryStream
                    $memStream.Write([byte[]]@(1,2,3), 0, 3)
                    $memStream.Dispose()
                    $nullStream = [System.IO.Stream]::Null
                    try { $faultTask = $faultCollector.CollectAsync($memStream, $nullStream, $maxStreamBytes, 5000) } catch { $faultTask = $null }
                    if ($faultTask) { try { $faultTask.Wait(5000) } catch {} }
                    $readFaulted = $faultCollector.StdoutFaulted
                    $notHealthy = (-not $faultCollector.Healthy)
                    $failClosed = $readFaulted -and $notHealthy
                    # R10-REM-05 + R11-REM-05: Use shared Get-CollectorHealthMapping for real gate path
                    $colHealthMap = Get-CollectorHealthMapping -Collector $faultCollector -DrainCompleted $true
                    $notHealthy = (-not $colHealthMap.Healthy)
                    $failClosed = $readFaulted -and $notHealthy
                    # R12-REM-05: Feed mapper result through shared exit mapper (no copied switch)
                    $innerResults = @()
                    if ($colHealthMap.ScriptInternalResult) {
                        $innerResults += $colHealthMap.ScriptInternalResult
                    }
                    $collectorOverall = Get-OverallResult -Results $innerResults
                    $exitResult = Get-OverallExitResult -Overall $collectorOverall
                    $exitCode3 = ($exitResult.ExitCode -eq 3)
                    $producesError = ($collectorOverall -eq 'ERROR')
                    # R12-REM-05: Banner/totals from shared mapper (ERROR => not allowed)
                    $noSuccessBanner = (-not $exitResult.SuccessBannerAllowed)
                    $noTrustedTotals = (-not $exitResult.TrustedTotalsAllowed)
                    $collectorStreamDisposed = $failClosed
                    $streamDisposed = ($memStream.CanRead -eq $false)
                    $pass = $failClosed -and $producesError -and $exitCode3 -and $collectorStreamDisposed -and $streamDisposed -and $noSuccessBanner -and $noTrustedTotals
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="SharedMapper Healthy=false ScriptInternal Overall=ERROR exit=3"; Actual="Faulted=$readFaulted Healthy=$($colHealthMap.Healthy) Overall=$collectorOverall exit3=$($exitResult.ExitCode) disposed=$streamDisposed banner=$noSuccessBanner totals=$noTrustedTotals"; Pass=$pass }
                } elseif ($fault -eq 'CollectorDrainTimeout') {
                    # Use a pipe stream that never completes — deadline triggers timeout
                    $faultCollector2 = New-Object BoundedStreamCollector
                    $pipeServer = $null; $pipeClient = $null
                    try {
                        $pipeServer = New-Object System.IO.Pipes.AnonymousPipeServerStream("Out")
                        $pipeClient = New-Object System.IO.Pipes.AnonymousPipeClientStream("In", $pipeServer.ClientSafePipeHandle)
                        $timeoutTask = $faultCollector2.CollectAsync($pipeClient, [System.IO.Stream]::Null, $maxStreamBytes, 100)
                        try { $timeoutTask.Wait(5000) } catch {}
                    } catch {
                        $timeoutTask = $null
                    } finally {
                        if ($pipeClient) { try { $pipeClient.Dispose() } catch {} }
                        if ($pipeServer) { try { $pipeServer.Dispose() } catch {} }
                    }
                    $drainTimedOut = $faultCollector2.DrainTimedOut
                    $notHealthy2 = (-not $faultCollector2.Healthy)
                    $failClosed2 = $drainTimedOut -and $notHealthy2
                    # R10-REM-05 + R11-REM-05: Use shared Get-CollectorHealthMapping for real gate path
                    $colHealthMap2 = Get-CollectorHealthMapping -Collector $faultCollector2 -DrainCompleted (-not $drainTimedOut)
                    $failClosed2 = $drainTimedOut -and (-not $colHealthMap2.Healthy)
                    # R12-REM-05: Feed mapper result through shared exit mapper (no copied switch)
                    $innerResults2 = @()
                    if ($colHealthMap2.ScriptInternalResult) {
                        $innerResults2 += $colHealthMap2.ScriptInternalResult
                    }
                    $collectorOverall2 = Get-OverallResult -Results $innerResults2
                    $exitResult2 = Get-OverallExitResult -Overall $collectorOverall2
                    $exitCode3_2 = ($exitResult2.ExitCode -eq 3)
                    $producesError2 = ($collectorOverall2 -eq 'ERROR')
                    # R12-REM-05: Banner/totals from shared mapper (ERROR => not allowed)
                    $noSuccessBanner2 = (-not $exitResult2.SuccessBannerAllowed)
                    $noTrustedTotals2 = (-not $exitResult2.TrustedTotalsAllowed)
                    $pipeDisposed = ($pipeClient -eq $null -or -not $pipeClient.IsConnected)
                    $pass = $failClosed2 -and $producesError2 -and $exitCode3_2 -and $pipeDisposed -and $noSuccessBanner2 -and $noTrustedTotals2
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="SharedMapper DrainTimedOut ScriptInternal Overall=ERROR exit=3"; Actual="TimedOut=$drainTimedOut Healthy=$($colHealthMap2.Healthy) Overall=$collectorOverall2 exit3=$($exitResult2.ExitCode) disposed=$pipeDisposed banner=$noSuccessBanner2 totals=$noTrustedTotals2"; Pass=$pass }
                } else {
                    $pass = $false
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known collectorFault"; Actual="unknown"; Pass=$pass }
                }
            }
            'markerLifecycle' {
                # R9-REM-06/07: Marker deletion lifecycle — real live handle + no fallback false PASS
                $markerTestDir = Join-Path $env:TEMP "marker-lifecycle-$(Get-Random)"
                New-Item -ItemType Directory -Path $markerTestDir -Force | Out-Null
                try {
                    if ($fault -eq 'MarkerDeletionWhileLive') {
                        # R9-REM-06: MUST have a real live handle — two-phase test
                        # Phase 1: Start child, register handle, try delete while live → must be BLOCKED
                        $liveProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 10`"" -PassThru -WindowStyle Hidden
                        $liveProcId = $liveProc.Id
                        # R11-REM-06: Capture finally cleanup results
                        $finallyTermOk = $true; $finallyActiveZero = $true; $finallyCloseOk = $true
                        $finallyDeleteOk = $true; $finallyPathAbsent = $true
                        try {
                            $liveReg = $fixtureRegistry.RegisterProcess($liveProcId, $testRunToken, "live-marker-test")
                            $liveRegOk = $liveReg.Success
                            # Create marker content
                            "live-marker-content" | Out-File -FilePath (Join-Path $markerTestDir "live.txt") -Encoding ASCII -Force
                            $markerExists = Test-Path (Join-Path $markerTestDir "live.txt")
                            # Try delete while handle is active → must be BLOCKED
                            $deleteWhileLive = Delete-OwnedMarkers -MarkerDirectory $markerTestDir -Registry $fixtureRegistry
                            $blockedAsExpected = (-not $deleteWhileLive.Success) -and ($deleteWhileLive.Error -eq "BlockedLiveHandles")
                            $markerStillExists = Test-Path (Join-Path $markerTestDir "live.txt")
                            # R10-REM-06: Phase 2 must be fail-closed - verify each step
                            # Step 1: Terminate and verify exited via structured wait
                            $phase2TermResult = $fixtureRegistry.TerminateAndVerify(0, 99, 3000)
                            $phase2Exited = ($phase2TermResult.Terminated -and $phase2TermResult.Wait.Exited)
                            $phase2WaitOutcome = [string]$phase2TermResult.Wait.Outcome
                            # Step 2: Verify active count is 0 before close
                            $phase2ActiveBeforeClose = $fixtureRegistry.ActiveCount
                            $phase2ActiveZero = ($phase2ActiveBeforeClose -eq 0)
                            # Step 3: CloseAll and verify
                            $phase2CloseResult = $fixtureRegistry.CloseAll()
                            $phase2AllClosed = $phase2CloseResult.AllClosed
                            # Step 4: Only now allow marker deletion
                            $phase2Ready = $phase2Exited -and $phase2ActiveZero -and $phase2AllClosed
                            $deleteAfterClose = $null; $deleteSucceeded = $false; $markerGone = $false
                            if ($phase2Ready) {
                                $deleteAfterClose = Delete-OwnedMarkers -MarkerDirectory $markerTestDir -Registry $fixtureRegistry
                                $deleteSucceeded = $deleteAfterClose.Success
                                $markerGone = (-not (Test-Path $markerTestDir))
                            }
                            # R10-REM-06 + R11-REM-06: Capture main pass (finally checked below)
                            $mainPass = $liveRegOk -and $markerExists -and $blockedAsExpected -and $markerStillExists -and $phase2Ready -and $deleteSucceeded -and $markerGone
                        } finally {
                            # R11-REM-06: Structured finally cleanup with verification
                            [ProcessHandleRegistry]::TestHook_FailWait = $false
                            try {
                                $finallyTermProc = Get-Process -Id $liveProcId -ErrorAction SilentlyContinue
                                if ($finallyTermProc) {
                                    Stop-Process -Id $liveProcId -Force -ErrorAction SilentlyContinue
                                    Start-Sleep -Milliseconds 500
                                    $stillAlive = Get-Process -Id $liveProcId -ErrorAction SilentlyContinue
                                    if ($stillAlive) { $finallyTermOk = $false; $stillAlive.Dispose() } else { $finallyTermOk = $true }
                                    $finallyTermProc.Dispose()
                                }
                            } catch { $finallyTermOk = $false }
                            $finallyActiveBeforeClose = $fixtureRegistry.ActiveCount
                            $finallyActiveZero = ($finallyActiveBeforeClose -eq 0)
                            $finallyCloseResult = $fixtureRegistry.CloseAll()
                            $finallyCloseOk = $finallyCloseResult.AllClosed
                            $liveProc.Dispose()
                            if (Test-Path $markerTestDir) {
                                try { Remove-Item $markerTestDir -Recurse -Force -ErrorAction Stop; $finallyDeleteOk = $true } catch { $finallyDeleteOk = $false }
                            }
                            $finallyPathAbsent = (-not (Test-Path $markerTestDir))
                        }
                        # R11-REM-06: PASS requires main path AND finally cleanup
                        $finallyOk = $finallyTermOk -and $finallyActiveZero -and $finallyCloseOk -and $finallyDeleteOk -and $finallyPathAbsent
                        $pass = $mainPass -and $finallyOk
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="regOk exists blocked phase2Ready finallyOk"; Actual="reg=$liveRegOk exists=$markerExists blocked=$blockedAsExpected still=$markerStillExists p2Ready=$phase2Ready delOk=$deleteSucceeded gone=$markerGone fT=$finallyTermOk fA0=$finallyActiveZero fC=$finallyCloseOk fD=$finallyDeleteOk fAbs=$finallyPathAbsent"; Pass=$pass }
                    } elseif ($fault -eq 'MarkerDeletionFailure') {
                        # R9-REM-07: Lock setup failure → fixture FAIL, no fallback false PASS
                        "test-marker-content" | Out-File -FilePath (Join-Path $markerTestDir "test.txt") -Encoding ASCII -Force
                        $markerExists = Test-Path (Join-Path $markerTestDir "test.txt")
                        $lockStream = $null
                        $lockSetupOk = $false
                        try {
                            # Lock the file to prevent deletion
                            $lockStream = [System.IO.File]::Open((Join-Path $markerTestDir "test.txt"), "Open", "Read", "None")
                            $lockSetupOk = $true
                        } catch {
                            # R9-REM-07: Lock setup failure → fixture FAILS, no fallback
                            $lockSetupOk = $false
                            $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="lock-setup-ok delete-fail release delete-ok"; Actual="lock-setup-FAILED: $($_.Exception.Message)"; Pass=$false }
                        }
                        if ($lockSetupOk) {
                            # First delete attempt — must fail (file locked)
                            $del1 = Delete-OwnedMarkers -MarkerDirectory $markerTestDir -Registry $fixtureRegistry
                            $firstDeleteFailed = (-not $del1.Success)
                            $firstDeleteError = $del1.Error
                            $markerStillExists1 = Test-Path (Join-Path $markerTestDir "test.txt")
                            # Release lock
                            $lockStream.Close(); $lockStream = $null
                            # Second delete — must succeed
                            $del2 = Delete-OwnedMarkers -MarkerDirectory $markerTestDir -Registry $fixtureRegistry
                            $secondDeleteOk = $del2.Success
                            $markerGone = (-not (Test-Path $markerTestDir))
                            $pass = $markerExists -and $firstDeleteFailed -and $markerStillExists1 -and $secondDeleteOk -and $markerGone
                            $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="exists del1-fail still-exists del2-ok gone"; Actual="exists=$markerExists del1Fail=$firstDeleteFailed err=$firstDeleteError still=$markerStillExists1 del2Ok=$secondDeleteOk gone=$markerGone"; Pass=$pass }
                        }
                    } else {
                        $pass = $false
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known markerLifecycle"; Actual="unknown"; Pass=$pass }
                    }
                } finally {
                    # Ensure cleanup
                    if ($lockStream) { try { $lockStream.Close() } catch {} }
                    if (Test-Path $markerTestDir) {
                        Remove-Item $markerTestDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            'manifestMeta' {
                # R12-REM-01: Meta-tests — inject manifest mismatches to prove Gate rejects
                $goodEntrySnapshot = @([PSCustomObject]@{
                    Pid=1001; Role="test-role"; Token="test-token"; CreationTime=12345678
                    InitialExited=$true; TerminateResult=$true; WaitOutcome='Exited'
                    WaitCode=0; Win32Error=0; TerminateError=''
                })
                $goodCleanup = [PSCustomObject]@{
                    Success=$true; Errors=@(); Actions=@('test')
                    ActiveBeforeClose=0; ActiveAfter=0
                    RegistrationResult=[PSCustomObject]@{ Success=$true }
                    CloseResult=[PSCustomObject]@{ AllClosed=$true; Failed=0; Attempted=1 }
                    EntrySnapshot=$goodEntrySnapshot; EntryCount=1
                }
                $goodCapture = [PSCustomObject]@{ Healthy=$true; ReadError=$null; DrainTimedOut=$false; DrainCompleted=$true; MappingOutcome='PASS' }
                if ($fault -eq 'MetaRoleMismatch') {
                    $manifest = @([PSCustomObject]@{ Pid=1001; Role="WRONG-ROLE"; Token="test-token"; CreationTime=12345678 })
                    $gate = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory "" -ExpectedManifest $manifest
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'Role mismatch')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL Role mismatch"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                } elseif ($fault -eq 'MetaTokenMismatch') {
                    $manifest = @([PSCustomObject]@{ Pid=1001; Role="test-role"; Token="WRONG-TOKEN"; CreationTime=12345678 })
                    $gate = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory "" -ExpectedManifest $manifest
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'Token mismatch')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL Token mismatch"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                } elseif ($fault -eq 'MetaExtraEntry') {
                    $manifest = @(
                        [PSCustomObject]@{ Pid=1001; Role="test-role"; Token="test-token"; CreationTime=12345678 },
                        [PSCustomObject]@{ Pid=9999; Role="phantom"; Token="test-token"; CreationTime=11111111 }
                    )
                    $gate = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory "" -ExpectedManifest $manifest
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'Missing entry')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL Missing entry"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                } elseif ($fault -eq 'MetaExtraMarker') {
                    # R15-FU-04: Same-token extra marker + wrong-role marker verification
                    # Test 1: Same-token extra marker (PID not in expected manifest)
                    $metaMarkerDir = Join-Path $env:TEMP "meta-marker-$(Get-Random)"
                    New-Item -ItemType Directory -Path $metaMarkerDir -Force | Out-Null
                    # Marker with same token but PID not in expected manifest
                    "test-token|8888|extra-role" | Out-File -FilePath (Join-Path $metaMarkerDir "desc-8888.txt") -Encoding ASCII -Force
                    # Expected manifest has only PID=1001
                    $markerManifest = @([PSCustomObject]@{ Pid=1001; Role="test-role"; Token="test-token"; CreationTime=12345678 })
                    # MarkerDeleteResult reflects: extra marker PID=8888 detected
                    $markerDelResult = [PSCustomObject]@{ Success=$false; Error="Extra marker: PID=8888 role=extra-role"; ActiveCount=1; ExpectedCount=1; ActualCount=1 }
                    $gate = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory $metaMarkerDir -ExpectedManifest $markerManifest -MarkerDeleteResult $markerDelResult
                    $pass1 = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'Marker deletion failed')
                    # Test 2: Same-token correct PID but wrong role
                    Remove-Item $metaMarkerDir -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory -Path $metaMarkerDir -Force | Out-Null
                    "test-token|1001|WRONG-ROLE" | Out-File -FilePath (Join-Path $metaMarkerDir "desc-1001.txt") -Encoding ASCII -Force
                    $markerDelResult2 = [PSCustomObject]@{ Success=$false; Error="Marker role mismatch: PID=1001 expected=test-role actual=WRONG-ROLE"; ActiveCount=1; ExpectedCount=1; ActualCount=1 }
                    $gate2 = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory $metaMarkerDir -ExpectedManifest $markerManifest -MarkerDeleteResult $markerDelResult2
                    $pass2 = (-not $gate2.Pass) -and ($gate2.Errors -join ' ' -match 'Marker deletion failed')
                    $pass = $pass1 -and $pass2
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL extra+wrong-role markers"; Actual="Pass1=$pass1 Pass2=$pass2 err1=$($gate.Errors.Count) err2=$($gate2.Errors.Count)"; Pass=$pass }
                    Remove-Item $metaMarkerDir -Recurse -Force -ErrorAction SilentlyContinue
                } elseif ($fault -eq 'MetaNullEvidence') {
                    $gate = Test-CommonProcessGate -CleanupResult $null -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory ""
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'CleanupResult is null')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL mandatory null"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                # R15-FU-04: New negative meta-tests
                } elseif ($fault -eq 'MetaEmptyManifest') {
                    # Launched-child with empty ExpectedManifest => Gate FAIL
                    $gate = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory "" -ExpectedManifest @() -IsLaunchedChild $true
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'ExpectedManifest empty')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL empty manifest for launched-child"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                } elseif ($fault -eq 'MetaDuplicateExpectedPID') {
                    # ExpectedManifest with duplicate PID => Gate FAIL
                    $dupManifest = @(
                        [PSCustomObject]@{ Pid=1001; Role="test-role"; Token="test-token"; CreationTime=12345678 },
                        [PSCustomObject]@{ Pid=1001; Role="dup-role"; Token="test-token"; CreationTime=99999999 }
                    )
                    $gate = Test-CommonProcessGate -CleanupResult $goodCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory "" -ExpectedManifest $dupManifest
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'Duplicate expected PID')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL duplicate expected PID"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                } elseif ($fault -eq 'MetaDuplicateActualPID') {
                    # EntrySnapshot with duplicate PID => Gate FAIL
                    $dupSnapshot = @(
                        [PSCustomObject]@{ Pid=1001; Role="test-role"; Token="test-token"; CreationTime=12345678; WaitOutcome='Exited'; Win32Error=0 },
                        [PSCustomObject]@{ Pid=1001; Role="dup-role"; Token="test-token"; CreationTime=12345678; WaitOutcome='Exited'; Win32Error=0 }
                    )
                    $dupCleanup = [PSCustomObject]@{
                        Success=$true; Errors=@(); Actions=@('test'); ActiveBeforeClose=0; ActiveAfter=0
                        RegistrationResult=[PSCustomObject]@{ Success=$true }
                        CloseResult=[PSCustomObject]@{ AllClosed=$true; Failed=0; Attempted=2 }
                        EntrySnapshot=$dupSnapshot; EntryCount=2
                    }
                    $dupManifest = @(
                        [PSCustomObject]@{ Pid=1001; Role="test-role"; Token="test-token"; CreationTime=12345678 }
                    )
                    $gate = Test-CommonProcessGate -CleanupResult $dupCleanup -CaptureHealthMapping $goodCapture -ParentRegOk $true -CreationTimeOk $true -MarkerDirectory "" -ExpectedManifest $dupManifest
                    $pass = (-not $gate.Pass) -and ($gate.Errors -join ' ' -match 'Duplicate actual PID')
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="Gate FAIL duplicate actual PID"; Actual="Pass=$($gate.Pass) err=$($gate.Errors.Count)"; Pass=$pass }
                } else {
                    $pass = $false
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known manifestMeta"; Actual="unknown"; Pass=$pass }
                }
            }
            'cleanupIdentity' {
                # R15-FU2-03: Deterministic cleanup identity tests — prove handle lifecycle
                if ($fault -eq 'CleanupIdentityMatch') {
                    # R15-FU2-03: Handle-based cleanup through shared helper with pre-acquired registry.
                    # Helper consumes the registry (CloseAll in finally). No PID fallback.
                    $matchProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
                    $matchProcId = $matchProc.Id
                    $matchCreationTime = $matchProc.StartTime.Ticks
                    # R15-FU2-03: Pre-acquire handle for the helper to consume
                    $matchTargetReg = New-Object ProcessHandleRegistry
                    $matchTargetRegOk = $matchTargetReg.RegisterProcess($matchProcId, $testRunToken, "match-target").Success
                    try {
                        # R15-FU2-03: Call helper with pre-acquired registry (not PID)
                        $matchResult = Stop-Wait-VerifyOwnedProcess -Registry $matchTargetReg -ExpectedCreationTime $matchCreationTime
                        # Prove: identity matched, terminated, exited, handles closed
                        $identityOk = $matchResult.IdentityMatched -and $matchResult.IdentityVerified
                        $termOk = $matchResult.TerminateAttempted -and $matchResult.TerminateSucceeded -and $matchResult.ExitedVerified
                        $closeOk = $matchResult.CloseAllSucceeded
                        $handlePreAcquired = $matchTargetRegOk
                        $pass = $identityOk -and $termOk -and $closeOk -and $handlePreAcquired
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="identity match + terminate + exited + close + handle pre-acquired"; Actual="identity=$identityOk verified=$($matchResult.IdentityVerified) matched=$($matchResult.IdentityMatched) term=$($matchResult.TerminateAttempted) succeeded=$($matchResult.TerminateSucceeded) exited=$($matchResult.ExitedVerified) close=$closeOk handle=$handlePreAcquired"; Pass=$pass }
                    } finally {
                        # R15-FU2-03: Helper already closed registry in its finally; just dispose
                        $matchProc.Dispose()
                    }
                } elseif ($fault -eq 'CleanupIdentityMismatch') {
                    # R13-FU3-01: Start TWO processes. Prove mismatch causes no termination.
                    # Three registries: target (consumed by helper), owned cleanup, other cleanup.
                    # Evidence collected in try; test record finalized in finally after outer cleanup.
                    $ownedProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 10`"" -PassThru -WindowStyle Hidden
                    $ownedProcId = $ownedProc.Id
                    # R13-FU3-01/FU3-03: Freeze creation identity before any hooks
                    $ownedCreationTime = $ownedProc.StartTime.Ticks
                    $otherProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 10`"" -PassThru -WindowStyle Hidden
                    $otherProcId = $otherProc.Id
                    # R13-FU3-01/FU3-03: Freeze creation identity before any hooks
                    $otherCreationTime = $otherProc.StartTime.Ticks
                    # R13-FU3-01: Pre-acquire TARGET handle for helper to consume
                    $ownedTargetReg = New-Object ProcessHandleRegistry
                    $ownedTargetRegOk = $ownedTargetReg.RegisterProcess($ownedProcId, $testRunToken, "mismatch-target").Success
                    # R13-FU3-01: Pre-acquire CLEANUP handle for outer finally
                    $ownedCleanupReg = New-Object ProcessHandleRegistry
                    $ownedCleanupRegOk = $ownedCleanupReg.RegisterProcess($ownedProcId, $testRunToken, "mismatch-cleanup").Success
                    # R13-FU3-01: Pre-acquire OTHER cleanup handle
                    $otherCleanupReg = New-Object ProcessHandleRegistry
                    $otherCleanupRegOk = $otherCleanupReg.RegisterProcess($otherProcId, $testRunToken, "mismatch-other").Success
                    # R13-FU3-01: Collect evidence in try; create test record in finally after cleanup
                    $mismatchResult = $null
                    $mismatchNoTerm = $false
                    $mismatchIdentityMismatch = $false
                    $mismatchOwnedStillAlive = $false
                    $mismatchException = $null
                    try {
                        # Call helper with target reg and wrong creation time -> mismatch
                        $mismatchResult = Stop-Wait-VerifyOwnedProcess -Registry $ownedTargetReg -ExpectedCreationTime $otherCreationTime
                        # Must NOT have terminated the owned process
                        $mismatchNoTerm = (-not $mismatchResult.TerminateAttempted)
                        $mismatchIdentityMismatch = $mismatchResult.IdentityVerified -and (-not $mismatchResult.IdentityMatched)
                        # R13-FU3-01: Owned still alive via cleanup handle (not PID lookup)
                        $mismatchOwnedStillAlive = (-not $ownedCleanupReg.CheckWaitStatus(0).Exited)
                    } catch {
                        $mismatchException = $_.Exception.Message
                    } finally {
                        # R13-FU3-01: Outer cleanup via shared helper for each cleanup registry
                        $ownedCleanupResult = Stop-Wait-VerifyOwnedProcess -Registry $ownedCleanupReg -ExpectedCreationTime $ownedCreationTime
                        $otherCleanupResult = Stop-Wait-VerifyOwnedProcess -Registry $otherCleanupReg -ExpectedCreationTime $otherCreationTime
                        $ownedProc.Dispose()
                        $otherProc.Dispose()

                        # R13-FU3-01: Build pass from ALL required evidence
                        $handlesPreAcquired = $ownedTargetRegOk -and $ownedCleanupRegOk -and $otherCleanupRegOk
                        $targetCloseAllOk = if ($mismatchResult) { $mismatchResult.CloseAllSucceeded } else { $false }
                        $ownedOuterOk = $ownedCleanupResult.Success -and $ownedCleanupResult.ExitedVerified -and $ownedCleanupResult.CloseAllSucceeded
                        $otherOuterOk = $otherCleanupResult.Success -and $otherCleanupResult.ExitedVerified -and $otherCleanupResult.CloseAllSucceeded
                        $noException = ($null -eq $mismatchException)
                        $noCleanupError = ($ownedCleanupResult.Errors.Count -eq 0) -and ($otherCleanupResult.Errors.Count -eq 0)
                        $pass = $handlesPreAcquired -and $mismatchNoTerm -and $mismatchIdentityMismatch -and
                            $mismatchOwnedStillAlive -and $targetCloseAllOk -and
                            $ownedOuterOk -and $otherOuterOk -and $noException -and $noCleanupError

                        $mr = $mismatchResult
                        $actual = "targetReg=$ownedTargetRegOk ownedCleanupReg=$ownedCleanupRegOk otherCleanupReg=$otherCleanupRegOk"
                        if ($mr) {
                            $actual += " idVerified=$($mr.IdentityVerified) idMatched=$($mr.IdentityMatched) noTerm=$mismatchNoTerm targetCloseAll=$($mr.CloseAllSucceeded)"
                        } else {
                            $actual += " mismatchResult=null"
                        }
                        $actual += " alive=$mismatchOwnedStillAlive"
                        $actual += " ownedExited=$($ownedCleanupResult.ExitedVerified) ownedClose=$($ownedCleanupResult.CloseAllSucceeded)"
                        $actual += " otherExited=$($otherCleanupResult.ExitedVerified) otherClose=$($otherCleanupResult.CloseAllSucceeded)"
                        $actual += " noException=$noException noCleanupError=$noCleanupError"

                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="identity mismatch + no term + still alive + outer cleanups success"; Actual=$actual; Pass=$pass }
                    }
                } else {
                    $pass = $false
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known cleanupIdentity"; Actual="unknown"; Pass=$pass }
                }
            }
            'cleanupRegFailure' {
                # R15-FU2-04: Deterministic cleanup registration failure fixture
                if ($fault -eq 'CleanupRegistrationFailure') {
                    # Start a real process, pre-acquire backup handle, inject registration
                    # failure in a separate cleanup registry, verify fail-closed behavior.
                    # No PID termination fallback.
                    $crgProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
                    $crgProcId = $crgProc.Id
                    # R13-FU3-03: Freeze creation identity before hook injection
                    $crgCreationTime = $crgProc.StartTime.Ticks
                    # R15-FU2-04: Pre-acquire backup handle BEFORE hook injection
                    $crgBackupReg = New-Object ProcessHandleRegistry
                    $crgBackupRegOk = $crgBackupReg.RegisterProcess($crgProcId, $testRunToken, "crg-backup").Success
                    # Separate cleanup authority registry (will fail)
                    $crgCleanupReg = New-Object ProcessHandleRegistry
                    $crgSemanticPass = $false; $crgSemanticExpected = ""; $crgSemanticActual = ""
                    try {
                        # R15-FU2-04: Inject registration failure via hook
                        [ProcessHandleRegistry]::TestHook_FailGetProcessTimes = $true
                        # Attempt cleanup registration → must fail
                        $crgRegResult = $crgCleanupReg.RegisterProcess($crgProcId, $testRunToken, "crg-cleanup")
                        $crgRegFailed = (-not $crgRegResult.Success)
                        $crgHasError = (-not [string]::IsNullOrEmpty($crgRegResult.Error))
                        # Verify no entries in failed cleanup registry
                        $crgNoEntries = ($crgCleanupReg.Count -eq 0)
                        # Verify backup was pre-acquired and valid
                        $crgBackupOk = $crgBackupRegOk -and ($crgBackupReg.Count -eq 1)
                        # R15-FU2-04: All assertions — failure is structural, backup is valid
                        $crgSemanticPass = $crgRegFailed -and $crgHasError -and $crgNoEntries -and $crgBackupOk
                        $crgSemanticExpected = "regFailed hasError noEntries backupOk backupCleanupOk"
                        $crgSemanticActual = "regFailed=$crgRegFailed hasError=$crgHasError noEntries=$crgNoEntries backupOk=$crgBackupOk error=$($crgRegResult.Error)"
                    } finally {
                        [ProcessHandleRegistry]::TestHook_FailGetProcessTimes = $false
                        # R15-FU2-04: Use backup handle for safe cleanup — NO PID fallback
                        $crgBackupResult = Stop-Wait-VerifyOwnedProcess -Registry $crgBackupReg -ExpectedCreationTime $crgCreationTime
                        # R15-FU2-04: Gate PASS on semantic AND backup cleanup
                        $pass = $crgSemanticPass -and $crgBackupResult.Success
                        $crgSemanticActual += " backupSuccess=$($crgBackupResult.Success) exited=$($crgBackupResult.ExitedVerified) close=$($crgBackupResult.CloseAllSucceeded)"
                        $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected=$crgSemanticExpected; Actual=$crgSemanticActual; Pass=$pass }
                        $crgProc.Dispose()
                    }
                } else {
                    $pass = $false
                    $tests += [PSCustomObject]@{ Name="Fault=$fault"; Expected="known cleanupRegFailure"; Actual="unknown"; Pass=$pass }
                }
            }
        }
        if (-not $tests[-1].Pass) { $allPassed = $false }
        Get-ChildItem -Path $markerDir -Filter "desc-*.txt" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # R7-REM-03: Final orphan check (outer registry — per-fixture registries already cleaned up)
    $orphanResult = Test-HandleOrphans -Registry $handleRegistry -JobHandle $jobHandle -JobAssigned $false
    $orphanFree = ($orphanResult.Status -eq 'VerifiedClean')
    if (-not $orphanFree) {
        Write-Host "  ORPHAN DETECTED: $($orphanResult.Detail) (token=$testRunToken)" -ForegroundColor Red
        $finalCleanupResult = Invoke-HandleCleanup -Registry $handleRegistry -Token $testRunToken -MarkerDirectory $markerDir -JobHandle $jobHandle -JobAssigned $false
        if (-not $finalCleanupResult.Success) {
            Write-Host "  FINAL CLEANUP FAILED: $($finalCleanupResult.Errors -join '; ')" -ForegroundColor Red
        }
        $allPassed = $false
    }

    # R7-REM-02: Close all registered handles — R8: check CloseAllResult
    $closeResult = $handleRegistry.CloseAll()
    if (-not $closeResult.AllClosed) {
        Write-Host "  WARNING: CloseAll failed: $($closeResult.Failed) of $($closeResult.Attempted)" -ForegroundColor Red
        $allPassed = $false
    }
    if ($jobHandle -ne [IntPtr]::Zero) { [JobObjectHelper]::CloseHandle($jobHandle) | Out-Null }

    # R7-REM-05: Delete markers after all handles confirmed closed
    if (Test-Path $markerDir) {
        Remove-Item $markerDir -Recurse -Force -ErrorAction Stop
        if (Test-Path $markerDir) {
            Write-Host "  FATAL: Marker directory still exists: $markerDir" -ForegroundColor Red
            $allPassed = $false; $script:CleanupErrors += "Marker dir deletion failed: $markerDir"
        }
    }

    $script:SelfTestSuiteResults['ProcessLevelFaults'] = @{ Declared=$faults.Count; Actual=$tests.Count; Passed=@($tests | Where-Object { $_.Pass }).Count; Failed=@($tests | Where-Object { -not $_.Pass }).Count }
    if ($tests.Count -ne $faults.Count) { Write-Host "  COUNT MISMATCH: display=$($tests.Count) actual=$($faults.Count)" -ForegroundColor Red; $allPassed = $false }

    Write-Host "`n=== Process-Level Fault Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) { $color = if ($t.Pass) { "Green" } else { "Red" }; Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected=$($t.Expected) actual=$($t.Actual))" -ForegroundColor $color }
    if (-not $orphanFree) { Write-Host "  FAIL: Orphaned test processes detected after cleanup" -ForegroundColor Red }

    # R14-FU4-03: Run focused negative tests using the same production predicates
    # that determine the real fixture result. Durable, committed, runtime-derived.
    $negPassed = Test-FocusedNegatives
    if (-not $negPassed) { $allPassed = $false }

    return $allPassed
}

# R14-FU4-03: Focused negative evidence using production predicates/helpers.
# Proves deterministic failure modes of Stop-Wait-VerifyOwnedProcess and
# CleanupIdentityMismatch's stored result, using the shared Test-HelperSuccess
# predicate (not a copied formula).
function Test-FocusedNegatives {
    $allNegPassed = $true
    $negTests = @()

    # --- Neg-1: Extra registry entry makes helper Success false ---
    $negProc1 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
    $negProc2 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
    try {
        $negReg1 = New-Object ProcessHandleRegistry
        $negReg1.RegisterProcess($negProc1.Id, "neg", "neg-1") | Out-Null
        $negReg1.RegisterProcess($negProc2.Id, "neg", "neg-2") | Out-Null
        $negR1 = Stop-Wait-VerifyOwnedProcess -Registry $negReg1 -ExpectedCreationTime $negProc1.StartTime.Ticks -ExpectedEntryCount 1
        $neg1Pass = (-not (Test-HelperSuccess -Result $negR1))
        $negTests += [PSCustomObject]@{ Name="Neg1-ExtraEntry"; Pass=$neg1Pass; Actual="Success=$($negR1.Success) EntryCount=$($negR1.EntryCount) ExpectedEntryCount=$($negR1.ExpectedEntryCount)" }
    } finally {
        $negProc1.Dispose(); $negProc2.Dispose()
    }

    # --- Neg-2: Nonempty Errors makes helper Success false ---
    $negProc3 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
    try {
        $negReg2 = New-Object ProcessHandleRegistry
        $negReg2.RegisterProcess($negProc3.Id, "neg", "neg-3") | Out-Null
        $negR2 = Stop-Wait-VerifyOwnedProcess -Registry $negReg2 -ExpectedCreationTime $negProc3.StartTime.Ticks
        # Clean result should be Success=true; inject error to prove fail-closed
        $negR2.Errors += "Injected test error"
        $neg2Pass = (-not (Test-HelperSuccess -Result $negR2))
        $negTests += [PSCustomObject]@{ Name="Neg2-NonemptyErrors"; Pass=$neg2Pass; Actual="Success(pre-inject)=$($negR2.Success) Errors.Count=$($negR2.Errors.Count)" }
    } finally {
        $negProc3.Dispose()
    }

    # --- Neg-3: CloseAll failure makes helper Success false ---
    # Uses pre-acquired backup handle for safe cleanup (no PID-only fallback)
    $negProc4 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
    $negBackup4 = New-Object ProcessHandleRegistry
    $negBackup4Ok = $negBackup4.RegisterProcess($negProc4.Id, "neg", "neg-4-backup").Success
    try {
        $negReg3 = New-Object ProcessHandleRegistry
        $negReg3.RegisterProcess($negProc4.Id, "neg", "neg-4") | Out-Null
        [ProcessHandleRegistry]::TestHook_FailClose = $true
        $negR3 = Stop-Wait-VerifyOwnedProcess -Registry $negReg3 -ExpectedCreationTime $negProc4.StartTime.Ticks
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        $neg3Pass = (-not (Test-HelperSuccess -Result $negR3)) -and (-not $negR3.CloseAllSucceeded)
        $negTests += [PSCustomObject]@{ Name="Neg3-CloseAllFailure"; Pass=$neg3Pass; Actual="Success=$($negR3.Success) CloseAllSucceeded=$($negR3.CloseAllSucceeded)" }
    } finally {
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        # Pre-acquired backup handle cleans up safely
        $negBackup4Result = Stop-Wait-VerifyOwnedProcess -Registry $negBackup4 -ExpectedCreationTime $negProc4.StartTime.Ticks
        $negProc4.Dispose()
    }

    # --- Neg-4: Owned outer-cleanup failure makes CleanupIdentityMismatch result false ---
    # Mismatch helper: identity mismatch -> no termination -> outer cleanup fails via hook
    $negProc5 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 10`"" -PassThru -WindowStyle Hidden
    $negCreation5 = $negProc5.StartTime.Ticks
    $negReg5 = New-Object ProcessHandleRegistry
    $negReg5.RegisterProcess($negProc5.Id, "neg", "neg-5-mismatch") | Out-Null
    $negBackup5 = New-Object ProcessHandleRegistry
    $negBackup5.RegisterProcess($negProc5.Id, "neg", "neg-5-backup") | Out-Null
    $wrongTime5 = (Get-Date).AddDays(-1).Ticks
    try {
        [ProcessHandleRegistry]::TestHook_FailClose = $true
        $negR5 = Stop-Wait-VerifyOwnedProcess -Registry $negReg5 -ExpectedCreationTime $wrongTime5
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        # Mismatch stored result: helper Success + outer CloseAll -> must be false
        $neg5StoredResult = (Test-HelperSuccess -Result $negR5) -and $negR5.CloseAllSucceeded
        $neg5Pass = (-not $neg5StoredResult)
        $negTests += [PSCustomObject]@{ Name="Neg4-OwnedOuterCleanupFail"; Pass=$neg5Pass; Actual="HelperSuccess=$($negR5.Success) CloseAllSucceeded=$($negR5.CloseAllSucceeded) StoredResult=$neg5StoredResult" }
    } finally {
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        $negBackup5Result = Stop-Wait-VerifyOwnedProcess -Registry $negBackup5 -ExpectedCreationTime $negCreation5
        $negProc5.Dispose()
    }

    # --- Neg-5: Other outer-cleanup failure makes CleanupIdentityMismatch result false ---
    # Match helper: identity match -> terminate -> exit -> outer cleanup fails via hook
    $negProc6 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 10`"" -PassThru -WindowStyle Hidden
    $negCreation6 = $negProc6.StartTime.Ticks
    $negReg6 = New-Object ProcessHandleRegistry
    $negReg6.RegisterProcess($negProc6.Id, "neg", "neg-6-match") | Out-Null
    $negBackup6 = New-Object ProcessHandleRegistry
    $negBackup6.RegisterProcess($negProc6.Id, "neg", "neg-6-backup") | Out-Null
    try {
        [ProcessHandleRegistry]::TestHook_FailClose = $true
        $negR6 = Stop-Wait-VerifyOwnedProcess -Registry $negReg6 -ExpectedCreationTime $negCreation6
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        # Match stored result: helper Success + outer CloseAll -> must be false
        $neg6StoredResult = (Test-HelperSuccess -Result $negR6) -and $negR6.CloseAllSucceeded
        $neg6Pass = (-not $neg6StoredResult)
        $negTests += [PSCustomObject]@{ Name="Neg5-OtherOuterCleanupFail"; Pass=$neg6Pass; Actual="HelperSuccess=$($negR6.Success) ExitedVerified=$($negR6.ExitedVerified) CloseAllSucceeded=$($negR6.CloseAllSucceeded) StoredResult=$neg6StoredResult" }
    } finally {
        [ProcessHandleRegistry]::TestHook_FailClose = $false
        $negBackup6Result = Stop-Wait-VerifyOwnedProcess -Registry $negBackup6 -ExpectedCreationTime $negCreation6
        $negProc6.Dispose()
    }

    # --- Neg-6: Diagnostic fields exposed on WaitFailure ---
    $negProc7 = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 5`"" -PassThru -WindowStyle Hidden
    try {
        $negReg7 = New-Object ProcessHandleRegistry
        $negReg7.RegisterProcess($negProc7.Id, "neg", "neg-7-diag") | Out-Null
        [ProcessHandleRegistry]::TestHook_FailWait = $true
        [ProcessHandleRegistry]::TestHook_WaitErrorCode = 0x57
        $negR7 = Stop-Wait-VerifyOwnedProcess -Registry $negReg7 -ExpectedCreationTime $negProc7.StartTime.Ticks
        [ProcessHandleRegistry]::TestHook_FailWait = $false
        [ProcessHandleRegistry]::TestHook_WaitErrorCode = 0
        $hasDiag = ($negR7.PSObject.Properties.Name -contains 'TerminateWin32Error') -and
            ($negR7.PSObject.Properties.Name -contains 'TerminateError') -and
            ($negR7.PSObject.Properties.Name -contains 'FinalWaitCode') -and
            ($negR7.PSObject.Properties.Name -contains 'FinalWaitWin32Error')
        $negTests += [PSCustomObject]@{ Name="Neg6-DiagFields"; Pass=$hasDiag; Actual="TerminateWin32Error=$($negR7.TerminateWin32Error) FinalWaitCode=$($negR7.FinalWaitCode) FinalWaitWin32Error=$($negR7.FinalWaitWin32Error)" }
    } finally {
        [ProcessHandleRegistry]::TestHook_FailWait = $false
        [ProcessHandleRegistry]::TestHook_WaitErrorCode = 0
        $negProc7.Dispose()
    }

    # Summary
    $script:SelfTestSuiteResults['FocusedNegatives'] = @{ Declared=$negTests.Count; Actual=$negTests.Count; Passed=@($negTests | Where-Object { $_.Pass }).Count; Failed=@($negTests | Where-Object { -not $_.Pass }).Count }
    Write-Host "\n=== Focused Negative Evidence ($($negTests.Count) checks) ===" -ForegroundColor Cyan
    foreach ($t in $negTests) {
        if (-not $t.Pass) { $allNegPassed = $false }
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) ($($t.Actual))" -ForegroundColor $color
    }
    return $allNegPassed
}



# R9-04 + R10-05: Self-test for ConvertFrom-LockfileSafe with real Node.js fixtures.
# Creates minimal package-lock.json fixtures in $env:TEMP, calls the reader,
# and verifies the Hashtable map. All fixtures are cleaned up after the test.
# R10-05: Expanded to 21 cases covering all required fail-closed branches.
function Test-LockfileReader {
    $allPassed = $true
    $tests = @()
    $fixtureDir = Join-Path $env:TEMP "lockfile-test-fixtures-$(Get-Random)"
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

    try {
        # F1: packages with root key "" and root optionalDependencies
        $f1 = Join-Path $fixtureDir "f1-root-optdep.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0", "optionalDependencies": { "opt-pkg": "*" } },
    "node_modules/opt-pkg": { "name": "opt-pkg", "version": "1.0.0", "os": ["linux"] },
    "node_modules/req-pkg": { "name": "req-pkg", "version": "2.0.0" }
  }
}
'@ | Out-File -FilePath $f1 -Encoding ASCII
        $r1 = ConvertFrom-LockfileSafe -LockfilePath $f1
        $p1 = $r1.Parsed -and $r1.Packages.ContainsKey("") -and $r1.Packages.ContainsKey("node_modules/opt-pkg") -and $r1.Packages.ContainsKey("node_modules/req-pkg")
        $tests += [PSCustomObject]@{ Name="F1: root key + optdep + required"; Pass=$p1 }
        if (-not $p1) { $allPassed = $false }

        # F2: nested dependency
        $f2 = Join-Path $fixtureDir "f2-nested.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/parent": { "name": "parent", "version": "1.0.0" },
    "node_modules/parent/node_modules/child": { "name": "child", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $f2 -Encoding ASCII
        $r2 = ConvertFrom-LockfileSafe -LockfilePath $f2
        $p2 = $r2.Parsed -and $r2.Packages.ContainsKey("node_modules/parent/node_modules/child")
        $tests += [PSCustomObject]@{ Name="F2: nested dependency"; Pass=$p2 }
        if (-not $p2) { $allPassed = $false }

        # F3: scoped parent
        $f3 = Join-Path $fixtureDir "f3-scoped.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/@scope/parent": { "name": "parent", "version": "1.0.0", "optionalDependencies": { "child": "*" } },
    "node_modules/@scope/parent/node_modules/child": { "name": "child", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $f3 -Encoding ASCII
        $r3 = ConvertFrom-LockfileSafe -LockfilePath $f3
        $p3 = $r3.Parsed -and $r3.Packages.ContainsKey("node_modules/@scope/parent/node_modules/child")
        $tests += [PSCustomObject]@{ Name="F3: scoped parent"; Pass=$p3 }
        if (-not $p3) { $allPassed = $false }

        # F4: same-name different paths
        $f4 = Join-Path $fixtureDir "f4-samename.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/a": { "name": "a", "version": "1.0.0" },
    "node_modules/a/node_modules/shared": { "name": "shared", "version": "1.0.0" },
    "node_modules/b": { "name": "b", "version": "1.0.0" },
    "node_modules/b/node_modules/shared": { "name": "shared", "version": "2.0.0" }
  }
}
'@ | Out-File -FilePath $f4 -Encoding ASCII
        $r4 = ConvertFrom-LockfileSafe -LockfilePath $f4
        $p4 = $r4.Parsed -and $r4.Packages.ContainsKey("node_modules/a/node_modules/shared") -and $r4.Packages.ContainsKey("node_modules/b/node_modules/shared") -and ($r4.Packages.Count -eq 5)
        $tests += [PSCustomObject]@{ Name="F4: same-name different paths"; Pass=$p4 }
        if (-not $p4) { $allPassed = $false }

        # F5: malformed JSON -> Parsed=false
        $f5 = Join-Path $fixtureDir "f5-malformed.json"
        '{ invalid json }' | Out-File -FilePath $f5 -Encoding ASCII
        $r5 = ConvertFrom-LockfileSafe -LockfilePath $f5
        $p5 = (-not $r5.Parsed) -and $r5.Error -ne ""
        $tests += [PSCustomObject]@{ Name="F5: malformed JSON => Parsed=false"; Pass=$p5 }
        if (-not $p5) { $allPassed = $false }

        # F6: missing packages -> Parsed=false
        $f6 = Join-Path $fixtureDir "f6-nopackages.json"
        '{ "name": "test", "lockfileVersion": 3 }' | Out-File -FilePath $f6 -Encoding ASCII
        $r6 = ConvertFrom-LockfileSafe -LockfilePath $f6
        $p6 = (-not $r6.Parsed) -and $r6.Error -match "packages"
        $tests += [PSCustomObject]@{ Name="F6: missing packages => Parsed=false"; Pass=$p6 }
        if (-not $p6) { $allPassed = $false }

        # F7: non-existent file -> Parsed=false
        $f7 = Join-Path $fixtureDir "nonexistent.json"
        $r7 = ConvertFrom-LockfileSafe -LockfilePath $f7
        $p7 = (-not $r7.Parsed) -and $r7.Error -match "not found"
        $tests += [PSCustomObject]@{ Name="F7: missing file => Parsed=false"; Pass=$p7 }
        if (-not $p7) { $allPassed = $false }

        # F8: Integration -- root optionalDependencies resolved correctly
        $f8 = Join-Path $fixtureDir "f8-root-optdep-native.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0", "optionalDependencies": { "native-opt": "*" } },
    "node_modules/native-opt": { "name": "native-opt", "version": "1.0.0", "gypfile": true, "os": ["linux"] }
  }
}
'@ | Out-File -FilePath $f8 -Encoding ASCII
        $r8lock = ConvertFrom-LockfileSafe -LockfilePath $f8
        $d8 = @( @{ Name="native-opt"; PkgData=$r8lock.Packages["node_modules/native-opt"]; InstancePath="node_modules/native-opt"; ParentPath=(Resolve-LockfileParentPath "node_modules/native-opt") } )
        $j8 = Get-NativeAddonJudgment -DependencyMap $d8 -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $r8lock.Packages
        $p8 = ($j8[0].ParentOptional -eq $true -and $j8[0].IsNative -eq $true)
        $tests += [PSCustomObject]@{ Name="F8: root optDep via reader => ParentOptional"; Pass=$p8 }
        if (-not $p8) { $allPassed = $false }

        # F9: Integration -- nested optionalDependency resolved correctly
        $f9 = Join-Path $fixtureDir "f9-nested-optdep.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/myparent": { "name": "myparent", "version": "1.0.0", "optionalDependencies": { "mychild": "*" } },
    "node_modules/myparent/node_modules/mychild": { "name": "mychild", "version": "1.0.0", "gypfile": true }
  }
}
'@ | Out-File -FilePath $f9 -Encoding ASCII
        $r9lock = ConvertFrom-LockfileSafe -LockfilePath $f9
        $d9 = @( @{ Name="mychild"; PkgData=$r9lock.Packages["node_modules/myparent/node_modules/mychild"]; InstancePath="node_modules/myparent/node_modules/mychild"; ParentPath=(Resolve-LockfileParentPath "node_modules/myparent/node_modules/mychild") } )
        $j9 = Get-NativeAddonJudgment -DependencyMap $d9 -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $r9lock.Packages
        $p9 = ($j9[0].ParentOptional -eq $true)
        $tests += [PSCustomObject]@{ Name="F9: nested optDep via reader => ParentOptional"; Pass=$p9 }
        if (-not $p9) { $allPassed = $false }

        # === R10-05: Expanded fail-closed test cases ===

        # F10: Canonical path collision (two raw keys map to same normalized path) -> reader rejects
        $f10 = Join-Path $fixtureDir "f10-collision.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg/": { "name": "pkg", "version": "1.0.0" },
    "node_modules/pkg": { "name": "pkg", "version": "2.0.0" }
  }
}
'@ | Out-File -FilePath $f10 -Encoding ASCII
        $r10 = ConvertFrom-LockfileSafe -LockfilePath $f10
        # R11-REV-05: trailing-slash path is now rejected as non-canonical before collision detection
        $p10 = (-not $r10.Parsed) -and ($r10.Error -match "non-canonical|collision|trailing|reject")
        $tests += [PSCustomObject]@{ Name="F10: canonical collision => Parsed=false"; Pass=$p10 }
        if (-not $p10) { $allPassed = $false }

        # F11: Node non-zero exit (invalid lockfile structure) -> reader rejects with exit evidence
        $f11 = Join-Path $fixtureDir "f11-badpackages.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": "not-an-object"
}
'@ | Out-File -FilePath $f11 -Encoding ASCII
        $r11 = ConvertFrom-LockfileSafe -LockfilePath $f11
        # R11: Node writes to stderr and exits 1; error may appear as exception or exit evidence
        $p11 = (-not $r11.Parsed) -and ($r11.Error -match "packages|exit|non-null")
        $tests += [PSCustomObject]@{ Name="F11: non-obj packages => Parsed=false with exit evidence"; Pass=$p11 }
        if (-not $p11) { $allPassed = $false }

        # F12: Node exit 0 with empty stdout -> reader rejects
        # (Achieved by creating a lockfile with empty packages object)
        $f12 = Join-Path $fixtureDir "f12-emptypackages.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {}
}
'@ | Out-File -FilePath $f12 -Encoding ASCII
        $r12 = ConvertFrom-LockfileSafe -LockfilePath $f12
        # Empty packages {} produces "[]" which is valid JSON but represents 0 entries
        # This should actually Parsed=true with 0 entries (empty packages is valid)
        $p12 = ($r12.Parsed -eq $true) -and ($r12.Packages.Count -eq 0)
        $tests += [PSCustomObject]@{ Name="F12: empty packages => Parsed=true, 0 entries"; Pass=$p12 }
        if (-not $p12) { $allPassed = $false }

        # F12b: Truly empty stdout is harder to test via a file -- we test via Node script that produces no output.
        # Instead, test that packages=null is rejected.
        $f12b = Join-Path $fixtureDir "f12b-nullpackages.json"
        '{ "name": "test", "lockfileVersion": 3, "packages": null }' | Out-File -FilePath $f12b -Encoding ASCII
        $r12b = ConvertFrom-LockfileSafe -LockfilePath $f12b
        $p12b = (-not $r12b.Parsed)
        $tests += [PSCustomObject]@{ Name="F12b: packages=null => Parsed=false"; Pass=$p12b }
        if (-not $p12b) { $allPassed = $false }

        # F13: unexpected stderr on exit 0
        # Achieved by triggering a console.error warning in Node while still exiting 0
        # Actually the Node script doesn't produce stderr on success. We test packages=array instead.
        $f13 = Join-Path $fixtureDir "f13-arraypackages.json"
        '{ "name": "test", "lockfileVersion": 3, "packages": ["a","b"] }' | Out-File -FilePath $f13 -Encoding ASCII
        $r13 = ConvertFrom-LockfileSafe -LockfilePath $f13
        $p13 = (-not $r13.Parsed) -and ($r13.Error -match "packages")
        $tests += [PSCustomObject]@{ Name="F13: packages=array => Parsed=false"; Pass=$p13 }
        if (-not $p13) { $allPassed = $false }

        # F14: packages=string -> reader rejects
        $f14 = Join-Path $fixtureDir "f14-stringpackages.json"
        '{ "name": "test", "lockfileVersion": 3, "packages": "hello" }' | Out-File -FilePath $f14 -Encoding ASCII
        $r14 = ConvertFrom-LockfileSafe -LockfilePath $f14
        $p14 = (-not $r14.Parsed) -and ($r14.Error -match "packages")
        $tests += [PSCustomObject]@{ Name="F14: packages=string => Parsed=false"; Pass=$p14 }
        if (-not $p14) { $allPassed = $false }

        # F15: packages=number -> reader rejects
        $f15 = Join-Path $fixtureDir "f15-numberpackages.json"
        '{ "name": "test", "lockfileVersion": 3, "packages": 42 }' | Out-File -FilePath $f15 -Encoding ASCII
        $r15 = ConvertFrom-LockfileSafe -LockfilePath $f15
        $p15 = (-not $r15.Parsed) -and ($r15.Error -match "packages")
        $tests += [PSCustomObject]@{ Name="F15: packages=number => Parsed=false"; Pass=$p15 }
        if (-not $p15) { $allPassed = $false }

        # F16: package Data=null -> reader rejects
        $f16 = Join-Path $fixtureDir "f16-nulldata.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": null
  }
}
'@ | Out-File -FilePath $f16 -Encoding ASCII
        $r16 = ConvertFrom-LockfileSafe -LockfilePath $f16
        $p16 = (-not $r16.Parsed) -and ($r16.Error -match "non-null|Data|null")
        $tests += [PSCustomObject]@{ Name="F16: package Data=null => Parsed=false"; Pass=$p16 }
        if (-not $p16) { $allPassed = $false }

        # F17: package Data=array -> reader rejects
        $f17 = Join-Path $fixtureDir "f17-arraydata.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": [1, 2, 3]
  }
}
'@ | Out-File -FilePath $f17 -Encoding ASCII
        $r17 = ConvertFrom-LockfileSafe -LockfilePath $f17
        $p17 = (-not $r17.Parsed) -and ($r17.Error -match "non-null|array|Array")
        $tests += [PSCustomObject]@{ Name="F17: package Data=array => Parsed=false"; Pass=$p17 }
        if (-not $p17) { $allPassed = $false }

        # F18: package Data=string -> reader rejects
        $f18 = Join-Path $fixtureDir "f18-stringdata.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": "not-an-object"
  }
}
'@ | Out-File -FilePath $f18 -Encoding ASCII
        $r18 = ConvertFrom-LockfileSafe -LockfilePath $f18
        $p18 = (-not $r18.Parsed) -and ($r18.Error -match "non-null|object|string")
        $tests += [PSCustomObject]@{ Name="F18: package Data=string => Parsed=false"; Pass=$p18 }
        if (-not $p18) { $allPassed = $false }

        # F19: package Data=number -> reader rejects
        $f19 = Join-Path $fixtureDir "f19-numberdata.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": 42
  }
}
'@ | Out-File -FilePath $f19 -Encoding ASCII
        $r19 = ConvertFrom-LockfileSafe -LockfilePath $f19
        $p19 = (-not $r19.Parsed) -and ($r19.Error -match "non-null|object|number")
        $tests += [PSCustomObject]@{ Name="F19: package Data=number => Parsed=false"; Pass=$p19 }
        if (-not $p19) { $allPassed = $false }

        # F20: root "", nested, scoped, Unicode/space path, same-name distinct all pass
        $f20 = Join-Path $fixtureDir "f20-diverse-paths.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": { "name": "pkg", "version": "1.0.0" },
    "node_modules/a/node_modules/b": { "name": "b", "version": "1.0.0" },
    "node_modules/@scope/parent/node_modules/child": { "name": "child", "version": "1.0.0" },
    "node_modules/\u00e9\u00e8\u00ea-pkg": { "name": "e-pkg", "version": "1.0.0" },
    "node_modules/my pkg": { "name": "my-pkg", "version": "1.0.0" },
    "node_modules/x/node_modules/shared": { "name": "shared", "version": "1.0.0" },
    "node_modules/y/node_modules/shared": { "name": "shared", "version": "2.0.0" }
  }
}
'@ | Out-File -FilePath $f20 -Encoding ASCII
        $r20 = ConvertFrom-LockfileSafe -LockfilePath $f20
        $p20 = $r20.Parsed -and ($r20.Packages.Count -eq 8) -and
            $r20.Packages.ContainsKey("") -and
            $r20.Packages.ContainsKey("node_modules/pkg") -and
            $r20.Packages.ContainsKey("node_modules/a/node_modules/b") -and
            $r20.Packages.ContainsKey("node_modules/@scope/parent/node_modules/child") -and
            $r20.Packages.ContainsKey("node_modules/x/node_modules/shared") -and
            $r20.Packages.ContainsKey("node_modules/y/node_modules/shared")
        $tests += [PSCustomObject]@{ Name="F20: diverse paths all pass (8 entries)"; Pass=$p20 }
        if (-not $p20) { $allPassed = $false }

        # F21: one-entry intermediate collection is scalar-safe on PS 5.1
        $f21 = Join-Path $fixtureDir "f21-single-entry.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/only": { "name": "only", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $f21 -Encoding ASCII
        $r21 = ConvertFrom-LockfileSafe -LockfilePath $f21
        $p21 = $r21.Parsed -and ($r21.Packages.Count -eq 2)
        $tests += [PSCustomObject]@{ Name="F21: one-entry collection scalar-safe"; Pass=$p21 }
        if (-not $p21) { $allPassed = $false }

        # F22: zero-entry intermediate (only root) is scalar-safe
        $f22 = Join-Path $fixtureDir "f22-root-only.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $f22 -Encoding ASCII
        $r22 = ConvertFrom-LockfileSafe -LockfilePath $f22
        $p22 = $r22.Parsed -and ($r22.Packages.Count -eq 1) -and $r22.Packages.ContainsKey("")
        $tests += [PSCustomObject]@{ Name="F22: root-only zero-dep scalar-safe"; Pass=$p22 }
        if (-not $p22) { $allPassed = $false }

        # F23: R14-REV-01: Integration — real shared path: reader → mapping → shared function → gate
        # Uses ConvertFrom-MappingToInstanceResult (same function as production Test 6)
        $f23 = Join-Path $fixtureDir "f23-native-linux.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/native-linux": { "name": "native-linux", "version": "1.0.0", "gypfile": true, "os": ["linux"] }
  }
}
'@ | Out-File -FilePath $f23 -Encoding ASCII
        $r23lock = ConvertFrom-LockfileSafe -LockfilePath $f23
        $p23 = $false
        $p23b = $false
        $r23mapKey = ""
        if ($r23lock.Parsed) {
            $r23mapping = ConvertFrom-TransitiveMapping -LockfilePackages $r23lock.Packages -NativeDepsToCheck @("native-linux") -TargetOs "win32" -TargetCpu "x64"
            $r23instances = @()
            foreach ($mapKey in @($r23mapping.Keys)) {
                $r23mapKey = $mapKey
                $r23instances += ConvertFrom-MappingToInstanceResult `
                    -MappingEntry $r23mapping[$mapKey] `
                    -InstancePath $mapKey `
                    -InstalledPath "C:\fake\node_modules\native-linux" `
                    -Version "1.0.0" `
                    -LoadExit 0 `
                    -LoadOutput ""
            }
            $r23gate = Get-NativeGateSummary -InstanceResults $r23instances -LockfileParsed $true
            $p23 = ($r23gate.Status -eq "PASS") -and ($r23gate.Category -eq "Informational") -and ($r23instances.Count -eq 1)
            # R14-REV-01: Verify exact InstancePath, Path, resolution fields, and load evidence
            $p23b = ($r23instances[0].Name -eq "native-linux") -and
                    ($r23instances[0].InstancePath -eq "node_modules/native-linux") -and
                    ($r23instances[0].Path -eq "C:\fake\node_modules\native-linux") -and
                    ($r23instances[0].ResolutionStatus -eq "Resolved") -and
                    ($r23instances[0].PlatformApplicable -eq $false) -and
                    ($r23instances[0].IsNative -eq $true) -and
                    ($r23instances[0].LoadExit -eq 0) -and
                    ($r23instances[0].Version -eq "1.0.0")
        }
        $tests += [PSCustomObject]@{ Name="F23: exact status PASS/Informational for platform-n/a"; Pass=$p23 }
        if (-not $p23) { $allPassed = $false }
        $tests += [PSCustomObject]@{ Name="F23b: exact InstancePath+Path+resolution+load evidence"; Pass=$p23b }
        if (-not $p23b) { $allPassed = $false }

        # F23c: R14-REV-01: No-match case — dep not in lockfile => shared function returns BLOCKED
        $f23cLock = ConvertFrom-LockfileSafe -LockfilePath $f23
        $p23c = $false
        $p23c_gate = $false
        if ($f23cLock.Parsed) {
            $r23cmap = ConvertFrom-TransitiveMapping -LockfilePackages $f23cLock.Packages -NativeDepsToCheck @("nonexistent-dep")
            # Mapping is empty for nonexistent dep — call shared function with $null MappingEntry
            $r23cResult = ConvertFrom-MappingToInstanceResult `
                -MappingEntry $null `
                -InstancePath "node_modules/nonexistent-dep" `
                -InstalledPath "" `
                -Version "unknown" `
                -LoadExit -1 `
                -LoadOutput ""
            $p23c = ($r23cResult.ResolutionStatus -eq "Blocked") -and
                    ($r23cResult.BlockReason -match "No lockfile mapping") -and
                    ($r23cResult.InstancePath -eq "node_modules/nonexistent-dep") -and
                    ($r23cResult.LoadExit -eq -1)
            # Assert gate outcome via Get-NativeGateSummary
            $r23cGate = Get-NativeGateSummary -InstanceResults @($r23cResult) -LockfileParsed $true
            $p23c_gate = ($r23cGate.Status -eq "BLOCKED") -and ($r23cGate.Category -eq "EvidenceDependent")
        }
        $tests += [PSCustomObject]@{ Name="F23c: no-match => structured BLOCKED via shared function"; Pass=$p23c }
        if (-not $p23c) { $allPassed = $false }
        $tests += [PSCustomObject]@{ Name="F23c-gate: BLOCKED gate outcome"; Pass=$p23c_gate }
        if (-not $p23c_gate) { $allPassed = $false }

        # F23d: R14-REV-01: Same-name/different-instance isolation via shared function
        $f23d = Join-Path $fixtureDir "f23d-samename.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/a/node_modules/shared": { "name": "shared", "version": "1.0.0", "gypfile": true, "os": ["linux"] },
    "node_modules/b/node_modules/shared": { "name": "shared", "version": "2.0.0", "gypfile": true }
  }
}
'@ | Out-File -FilePath $f23d -Encoding ASCII
        $r23dlock = ConvertFrom-LockfileSafe -LockfilePath $f23d
        $p23d = $false
        if ($r23dlock.Parsed) {
            $r23dmapping = ConvertFrom-TransitiveMapping -LockfilePackages $r23dlock.Packages -NativeDepsToCheck @("shared") -TargetOs "win32" -TargetCpu "x64"
            $r23d_a = ConvertFrom-MappingToInstanceResult `
                -MappingEntry $r23dmapping["node_modules/a/node_modules/shared"] `
                -InstancePath "node_modules/a/node_modules/shared" `
                -InstalledPath "C:\fake\a\node_modules\shared" `
                -Version "1.0.0" -LoadExit 0 -LoadOutput ""
            $r23d_b = ConvertFrom-MappingToInstanceResult `
                -MappingEntry $r23dmapping["node_modules/b/node_modules/shared"] `
                -InstancePath "node_modules/b/node_modules/shared" `
                -InstalledPath "C:\fake\b\node_modules\shared" `
                -Version "2.0.0" -LoadExit 0 -LoadOutput ""
            $p23d = ($r23d_a.Name -eq "shared") -and ($r23d_b.Name -eq "shared") -and
                    ($r23d_a.InstancePath -eq "node_modules/a/node_modules/shared") -and
                    ($r23d_b.InstancePath -eq "node_modules/b/node_modules/shared") -and
                    ($r23d_a.Path -eq "C:\fake\a\node_modules\shared") -and
                    ($r23d_b.Path -eq "C:\fake\b\node_modules\shared") -and
                    ($r23d_a.Version -eq "1.0.0") -and ($r23d_b.Version -eq "2.0.0") -and
                    ($r23d_a.PlatformApplicable -eq $false) -and
                    ($r23d_b.PlatformApplicable -eq $true) -and
                    ($r23d_a.ResolutionStatus -eq "Resolved") -and ($r23d_b.ResolutionStatus -eq "Resolved")
        }
        $tests += [PSCustomObject]@{ Name="F23d: same-name/different-instance exact-path isolation"; Pass=$p23d }
        if (-not $p23d) { $allPassed = $false }

        # F24: Test 4 parser failure + otherwise-passing => overall BLOCKED/exit 2
        # Simulate: parser failure (EvidenceDependent/BLOCKED), other gate-blocking PASS
        $parserFailResults = @(
            [PSCustomObject]@{ TestId="3"; Category="MandatoryFunctional"; Status="PASS"; Description="Install"; Expected="pass"; Actual="pass"; ErrorSummary="" },
            [PSCustomObject]@{ TestId="4"; Category="EvidenceDependent"; Status="BLOCKED"; Description="Lockfile version"; Expected="Lockfile parsed"; Actual="Parse failed"; ErrorSummary="BLOCKED" },
            [PSCustomObject]@{ TestId="5"; Category="MandatoryFunctional"; Status="PASS"; Description="npm ls"; Expected="pass"; Actual="pass"; ErrorSummary="" }
        )
        $overallForParserFail = Get-OverallResult -Results $parserFailResults -HasFatalInternalError $false -CleanupErrorList @()
        $p24 = ($overallForParserFail -eq "BLOCKED")
        $tests += [PSCustomObject]@{ Name="F24: parser fail + others PASS => overall BLOCKED"; Pass=$p24 }
        if (-not $p24) { $allPassed = $false }

        # === R11-REV-02 + R11-REV-03: Expanded fail-closed test cases ===

        # F25: Exit 0 + truly empty stdout (custom Node script)
        $f25script = Join-Path $fixtureDir "f25-emptystdout.js"
        'process.exit(0);' | Out-File -FilePath $f25script -Encoding ASCII -NoNewline
        $f25lock = Join-Path $fixtureDir "f25-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f25lock -Encoding ASCII
        $r25 = ConvertFrom-LockfileSafe -LockfilePath $f25lock -TestCustomNodeScriptPath $f25script
        $p25 = (-not $r25.Parsed) -and ($r25.Error -match "empty stdout")
        $tests += [PSCustomObject]@{ Name="F25: exit 0 + empty stdout => Parsed=false"; Pass=$p25 }
        if (-not $p25) { $allPassed = $false }

        # F26: Exit 0 + non-empty stderr (custom Node script)
        $f26script = Join-Path $fixtureDir "f26-stderronexit0.js"
        'process.stderr.write("warning");process.stdout.write("[]");process.exit(0);' | Out-File -FilePath $f26script -Encoding ASCII -NoNewline
        $f26lock = Join-Path $fixtureDir "f26-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f26lock -Encoding ASCII
        $r26 = ConvertFrom-LockfileSafe -LockfilePath $f26lock -TestCustomNodeScriptPath $f26script
        # R11: PS5.1 with ErrorActionPreference=Stop may surface stderr as exception
        # Either "unexpected stderr" (normal path) or "Lockfile reader exception: <stderr content>" (catch path)
        $p26 = (-not $r26.Parsed) -and ($r26.Error -match "unexpected stderr|stderr|warning")
        $tests += [PSCustomObject]@{ Name="F26: exit 0 + stderr => Parsed=false"; Pass=$p26 }
        if (-not $p26) { $allPassed = $false }

        # F27: Oversized stdout (custom Node script)
        $f27script = Join-Path $fixtureDir "f27-bigstdout.js"
        @'
var arr = [];
for(var i=0;i<100000;i++) arr.push({Path:"node_modules/pkg"+i,Data:{name:"pkg"+i}});
process.stdout.write(JSON.stringify(arr));
process.exit(0);
'@ | Out-File -FilePath $f27script -Encoding ASCII -NoNewline
        $f27lock = Join-Path $fixtureDir "f27-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f27lock -Encoding ASCII
        $r27 = ConvertFrom-LockfileSafe -LockfilePath $f27lock -TestCustomNodeScriptPath $f27script
        $p27 = (-not $r27.Parsed) -and ($r27.Error -match "exceeds")
        $tests += [PSCustomObject]@{ Name="F27: oversized stdout => Parsed=false"; Pass=$p27 }
        if (-not $p27) { $allPassed = $false }

        # F28: Oversized stderr on non-zero exit (custom Node script)
        $f28script = Join-Path $fixtureDir "f28-bigstderr.js"
        @'
var big = "";
for(var i=0;i<100000;i++) big += "error line "+i+"\n";
process.stderr.write(big);
process.exit(1);
'@ | Out-File -FilePath $f28script -Encoding ASCII -NoNewline
        $f28lock = Join-Path $fixtureDir "f28-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f28lock -Encoding ASCII
        $r28 = ConvertFrom-LockfileSafe -LockfilePath $f28lock -TestCustomNodeScriptPath $f28script
        # R14-REV-03: Assert the explicit Read-BoundedFile stderr size-limit branch
        # With ErrorActionPreference saved/restored around Node invocation,
        # Read-BoundedFile is deterministically reached for oversized stderr.
        $r28_error = $r28.Error
        $p28 = (-not $r28.Parsed) -and ($r28_error.Length -lt 2000) -and ($r28_error -ne "") -and
               ($r28_error -match "^Stderr diagnostic:.*exceeds maximum size") -and
               ($r28_error -notmatch "cleanup|Cleanup") -and
               ($r28_error -notmatch "^Lockfile reader exception:")
        $tests += [PSCustomObject]@{ Name="F28: oversized stderr => bounded size-limit diagnostic"; Pass=$p28 }
        if (-not $p28) { $allPassed = $false }

        # F29: Oversized input via TestMaxInputBytes
        $f29 = Join-Path $fixtureDir "f29-biginput.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": { "name": "pkg", "version": "1.0.0", "description": "padding for size" }
  }
}
'@ | Out-File -FilePath $f29 -Encoding ASCII
        $r29 = ConvertFrom-LockfileSafe -LockfilePath $f29 -TestMaxInputBytes 100
        $p29 = (-not $r29.Parsed) -and ($r29.Error -match "exceeds")
        $tests += [PSCustomObject]@{ Name="F29: oversized input (100B limit) => Parsed=false"; Pass=$p29 }
        if (-not $p29) { $allPassed = $false }

        # F29b: R14-REV-02: Exercise Node's independent 50 MiB input-size rejection
        # In self-test mode, raise PS-side limit above fixture size so Node's check fires first
        $f29b = Join-Path $fixtureDir "f29b-sparse-big.json"
        try {
            # Create sparse file with reported size >50 MiB
            $fs = [System.IO.File]::Create($f29b)
            $fs.SetLength(52428801)  # 50 MiB + 1 byte
            $fs.Close()
            # R14-REV-02: Use TestMaxInputBytes to raise PS limit above fixture; Node stays at 50 MiB
            $r29b = ConvertFrom-LockfileSafe -LockfilePath $f29b -TestMaxInputBytes 62914560
            # Must be the Node-side diagnostic, not the PS pre-check
            $p29b_node = (-not $r29b.Parsed) -and ($r29b.Error -match "input exceeds 50MB")
            $p29b_notPS = ($r29b.Error -notmatch "exceeds maximum input size")
            $p29b = $p29b_node -and $p29b_notPS
        } catch {
            $p29b = $false
            $p29b_node = $false
            $p29b_notPS = $false
        } finally {
            Remove-Item $f29b -Force -ErrorAction SilentlyContinue
        }
        $tests += [PSCustomObject]@{ Name="F29b: Node-side 50MiB sparse file => rejected"; Pass=$p29b }
        if (-not $p29b) { $allPassed = $false }

        # F29c: R12-REV-06: Malformed intermediate JSON (Node outputs garbage)
        $f29cscript = Join-Path $fixtureDir "f29c-badjson.js"
        'process.stdout.write("{not json at all");process.exit(0);' | Out-File -FilePath $f29cscript -Encoding ASCII -NoNewline
        $f29clock = Join-Path $fixtureDir "f29c-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f29clock -Encoding ASCII
        $r29c = ConvertFrom-LockfileSafe -LockfilePath $f29clock -TestCustomNodeScriptPath $f29cscript
        $p29c = (-not $r29c.Parsed) -and ($r29c.Error -match "JSON|ConvertFrom-Json|exception|parse")
        $tests += [PSCustomObject]@{ Name="F29c: malformed intermediate JSON => Parsed=false"; Pass=$p29c }
        if (-not $p29c) { $allPassed = $false }

        # F30: Non-string Path in intermediate entry (custom Node script)
        $f30script = Join-Path $fixtureDir "f30-nonstrpath.js"
        'process.stdout.write(JSON.stringify([{Path:123,Data:{name:"pkg"}}]));process.exit(0);' | Out-File -FilePath $f30script -Encoding ASCII -NoNewline
        $f30lock = Join-Path $fixtureDir "f30-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f30lock -Encoding ASCII
        $r30 = ConvertFrom-LockfileSafe -LockfilePath $f30lock -TestCustomNodeScriptPath $f30script
        $p30 = (-not $r30.Parsed) -and ($r30.Error -match "not a string|Path")
        $tests += [PSCustomObject]@{ Name="F30: non-string Path => Parsed=false"; Pass=$p30 }
        if (-not $p30) { $allPassed = $false }

        # F31: Non-object Data boolean in intermediate entry (custom Node script)
        $f31script = Join-Path $fixtureDir "f31-booleandata.js"
        'process.stdout.write(JSON.stringify([{Path:"node_modules/pkg",Data:true}]));process.exit(0);' | Out-File -FilePath $f31script -Encoding ASCII -NoNewline
        $f31lock = Join-Path $fixtureDir "f31-dummy.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"}}}' | Out-File -FilePath $f31lock -Encoding ASCII
        $r31 = ConvertFrom-LockfileSafe -LockfilePath $f31lock -TestCustomNodeScriptPath $f31script
        $p31 = (-not $r31.Parsed) -and ($r31.Error -match "scalar|boolean|Data")
        $tests += [PSCustomObject]@{ Name="F31: boolean Data => Parsed=false"; Pass=$p31 }
        if (-not $p31) { $allPassed = $false }

        # F32: Cleanup failure via TestCleanupFail (ownership-safe)
        # R12-REV-03: Create a sentinel directory to prove unrelated matches are preserved
        $sentinelDir = Join-Path $env:TEMP "lockfile-reader-sentinel-$(Get-Random)"
        New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null

        $f32 = Join-Path $fixtureDir "f32-valid.json"
        '{"name":"test","lockfileVersion":3,"packages":{"":{"name":"test","version":"1.0.0"},"node_modules/pkg":{"name":"pkg","version":"1.0.0"}}}' | Out-File -FilePath $f32 -Encoding ASCII
        $r32 = ConvertFrom-LockfileSafe -LockfilePath $f32 -TestCleanupFail
        $p32 = (-not $r32.Parsed) -and ($r32.Error -match "cleanup|Cleanup")
        $tests += [PSCustomObject]@{ Name="F32: cleanup failure => Parsed=false"; Pass=$p32 }
        if (-not $p32) { $allPassed = $false }

        # R12-REV-03: Ownership-safe cleanup — delete ONLY the exact test-owned helper dir
        $ownedHelperDir = $r32['_HelperDir']
        $p32b = $false
        $p32c = $false
        if ($ownedHelperDir -and (Test-Path $ownedHelperDir)) {
            # Validate it is inside the expected temp parent
            $expectedPrefix = Join-Path $env:TEMP "lockfile-reader-"
            if ($ownedHelperDir -like "$expectedPrefix*") {
                Remove-Item -Path $ownedHelperDir -Recurse -Force -ErrorAction Stop
                $p32b = (-not (Test-Path $ownedHelperDir))
            }
        } elseif (-not $ownedHelperDir) {
            # No helper dir exposed — self-test mode guard failed
            $p32b = $false
        } else {
            # Already cleaned up (shouldn't happen with TestCleanupFail)
            $p32b = $true
        }
        $tests += [PSCustomObject]@{ Name="F32b: owned helper dir recovered"; Pass=$p32b }
        if (-not $p32b) { $allPassed = $false }

        # R12-REV-03: Sentinel directory must survive (not deleted by wildcard)
        $p32c = (Test-Path $sentinelDir)
        $tests += [PSCustomObject]@{ Name="F32c: sentinel dir preserved (no wildcard delete)"; Pass=$p32c }
        if (-not $p32c) { $allPassed = $false }

        # Clean up sentinel
        Remove-Item -Path $sentinelDir -Recurse -Force -ErrorAction SilentlyContinue

        # R12-REV-03: Failed recovery must fail the test (gate-asserted)
        if (-not $p32 -or -not $p32b) {
            Write-Host "  FAIL: F32 cleanup failure recovery failed" -ForegroundColor Red
            $allPassed = $false
        }

        # F33: Resolve-NodeExecutable structure and validity
        $nodeRes = Resolve-NodeExecutable
        $p33 = ($null -ne $nodeRes) -and ($nodeRes.Path -ne $null -and $nodeRes.Path -ne "") -and (Test-Path $nodeRes.Path)
        $tests += [PSCustomObject]@{ Name="F33: Resolve-NodeExecutable returns valid path"; Pass=$p33 }
        if (-not $p33) { $allPassed = $false }

        # F33b: R12-REV-10: Verify Resolve-NodeExecutable returns valid structure (Error empty on success)
        $p33b = ($nodeRes.Error -eq "")
        $tests += [PSCustomObject]@{ Name="F33b: Resolve-NodeExecutable Error empty on success"; Pass=$p33b }
        if (-not $p33b) { $allPassed = $false }

        # === R12-REV-01: Deterministic Node candidate validation tests ===
        # Tests use pure Test-NodeCandidateValidation; no ambient PATH dependency.
        # F-NC1: No candidates => blocked
        $fNC1 = Test-NodeCandidateValidation -Candidates @()
        $pNC1 = ($null -eq $fNC1.Path) -and ($fNC1.Error -match "No.*candidates")
        $tests += [PSCustomObject]@{ Name="F-NC1: no candidates => blocked"; Pass=$pNC1 }
        if (-not $pNC1) { $allPassed = $false }

        # F-NC2: Application with nonexistent path => blocked
        $fNC2 = Test-NodeCandidateValidation -Candidates @([PSCustomObject]@{CommandType='Application'; Source='C:\nonexistent\node.exe'; Name='node'})
        $pNC2 = ($null -eq $fNC2.Path) -and ($fNC2.Error -match "does not exist")
        $tests += [PSCustomObject]@{ Name="F-NC2: nonexistent path => blocked"; Pass=$pNC2 }
        if (-not $pNC2) { $allPassed = $false }

        # F-NC3: Application with directory path => blocked
        $fNC3 = Test-NodeCandidateValidation -Candidates @([PSCustomObject]@{CommandType='Application'; Source=$env:TEMP; Name='node'})
        $pNC3 = ($null -eq $fNC3.Path) -and ($fNC3.Error -match "not a file")
        $tests += [PSCustomObject]@{ Name="F-NC3: directory path => blocked"; Pass=$pNC3 }
        if (-not $pNC3) { $allPassed = $false }

        # F-NC4: Multiple Applications => blocked (AMBIGUOUS)
        $fNC4 = Test-NodeCandidateValidation -Candidates @(
            [PSCustomObject]@{CommandType='Application'; Source='C:\node1\node.exe'; Name='node'},
            [PSCustomObject]@{CommandType='Application'; Source='C:\node2\node.exe'; Name='node'}
        )
        $pNC4 = ($null -eq $fNC4.Path) -and ($fNC4.Error -match "AMBIGUOUS")
        $tests += [PSCustomObject]@{ Name="F-NC4: multiple Applications => blocked"; Pass=$pNC4 }
        if (-not $pNC4) { $allPassed = $false }

        # F-NC5: Alias + Application => blocked (alias shadows)
        $fNC5 = Test-NodeCandidateValidation -Candidates @(
            [PSCustomObject]@{CommandType='Alias'; Source=''; Name='node'},
            [PSCustomObject]@{CommandType='Application'; Source='C:\node1\node.exe'; Name='node'}
        )
        $pNC5 = ($null -eq $fNC5.Path) -and ($fNC5.Error -match "Non-Application")
        $tests += [PSCustomObject]@{ Name="F-NC5: alias+app => blocked (alias shadows)"; Pass=$pNC5 }
        if (-not $pNC5) { $allPassed = $false }

        # F-NC6: Function only (no Application) => blocked
        $fNC6 = Test-NodeCandidateValidation -Candidates @(
            [PSCustomObject]@{CommandType='Function'; Source='function node {}'; Name='node'}
        )
        $pNC6 = ($null -eq $fNC6.Path) -and ($fNC6.Error -match "Non-Application")
        $tests += [PSCustomObject]@{ Name="F-NC6: function only => blocked"; Pass=$pNC6 }
        if (-not $pNC6) { $allPassed = $false }

        # F-NC7: Cmdlet only (no Application) => blocked
        $fNC7 = Test-NodeCandidateValidation -Candidates @(
            [PSCustomObject]@{CommandType='Cmdlet'; Source='Invoke-Node'; Name='node'}
        )
        $pNC7 = ($null -eq $fNC7.Path) -and ($fNC7.Error -match "Non-Application")
        $tests += [PSCustomObject]@{ Name="F-NC7: cmdlet only => blocked"; Pass=$pNC7 }
        if (-not $pNC7) { $allPassed = $false }

        # F-NC8: Script + Application => blocked (script shadows even with valid app)
        $fNC8 = Test-NodeCandidateValidation -Candidates @(
            [PSCustomObject]@{CommandType='Script'; Source='C:\scripts\node.ps1'; Name='node'},
            [PSCustomObject]@{CommandType='Application'; Source='C:\node1\node.exe'; Name='node'}
        )
        $pNC8 = ($null -eq $fNC8.Path) -and ($fNC8.Error -match "Non-Application")
        $tests += [PSCustomObject]@{ Name="F-NC8: script+app => blocked (script shadows)"; Pass=$pNC8 }
        if (-not $pNC8) { $allPassed = $false }

        # F-NC9: Single valid Application => accepted (uses real resolved path)
        if ($nodeRes.Path) {
            $fNC9 = Test-NodeCandidateValidation -Candidates @(
                [PSCustomObject]@{CommandType='Application'; Source=$nodeRes.Path; Name='node'}
            )
            $pNC9 = ($fNC9.Path -eq $nodeRes.Path) -and ($fNC9.Error -eq "")
        } else {
            $pNC9 = $false
        }
        $tests += [PSCustomObject]@{ Name="F-NC9: single valid Application => accepted"; Pass=$pNC9 }
        if (-not $pNC9) { $allPassed = $false }

        # F34-F39: Non-canonical path spellings via ConvertFrom-LockfilePathPolicy
        $pathTests = @(
            @{ Name="F34: trailing slash"; Path="node_modules/pkg/"; },
            @{ Name="F35: repeated slash"; Path="node_modules//pkg"; },
            @{ Name="F36: backslash"; Path="node_modules\pkg"; },
            @{ Name="F37: dot segment"; Path="node_modules/./pkg"; },
            @{ Name="F38: dot-dot segment"; Path="node_modules/pkg/../other"; },
            @{ Name="F39: absolute path"; Path="/node_modules/pkg"; }
        )
        foreach ($pt in $pathTests) {
            $canonResult = ConvertFrom-LockfilePathPolicy -RawPath $pt.Path
            $ptPass = ($null -eq $canonResult)
            $tests += [PSCustomObject]@{ Name=$pt.Name; Pass=$ptPass }
            if (-not $ptPass) { $allPassed = $false }
        }

        # === R12-REV-08: Additional path grammar test cases ===

        # F40: Terminal dot
        $canonF40 = ConvertFrom-LockfilePathPolicy -RawPath "node_modules/pkg/."
        $p40 = ($null -eq $canonF40)
        $tests += [PSCustomObject]@{ Name="F40: terminal dot (/.`)" ; Pass=$p40 }
        if (-not $p40) { $allPassed = $false }

        # F41: Terminal dot-dot
        $canonF41 = ConvertFrom-LockfilePathPolicy -RawPath "node_modules/pkg/.."
        $p41 = ($null -eq $canonF41)
        $tests += [PSCustomObject]@{ Name="F41: terminal dot-dot (/..)"; Pass=$p41 }
        if (-not $p41) { $allPassed = $false }

        # F42: Incomplete scope (no package after @scope)
        $canonF42 = ConvertFrom-LockfilePathPolicy -RawPath "node_modules/@scope"
        $p42 = ($null -eq $canonF42)
        $tests += [PSCustomObject]@{ Name="F42: incomplete scope (@scope no pkg)"; Pass=$p42 }
        if (-not $p42) { $allPassed = $false }

        # F43: Drive letter with path (already tested F39 for absolute, this is explicit C:)
        $canonF43 = ConvertFrom-LockfilePathPolicy -RawPath "C:/node_modules/pkg"
        $p43 = ($null -eq $canonF43)
        $tests += [PSCustomObject]@{ Name="F43: drive letter path (C:/...)"; Pass=$p43 }
        if (-not $p43) { $allPassed = $false }

        # F44: Control character in middle of path
        $f44ctrl = [char]0x01
        $canonF44 = ConvertFrom-LockfilePathPolicy -RawPath "node_modules/pkg$($f44ctrl)name"
        $p44 = ($null -eq $canonF44)
        $tests += [PSCustomObject]@{ Name="F44: control char in path (0x01)"; Pass=$p44 }
        if (-not $p44) { $allPassed = $false }

        # === R12-REV-02: Additional path grammar tests ===
        # Valid paths: root, unscoped, scoped, nested, scoped-nested, same-name
        $validPaths = @(
            @{ Name="F-GV1: root (empty string)"; Path=""; },
            @{ Name="F-GV2: unscoped pkg"; Path="node_modules/pkg"; },
            @{ Name="F-GV3: scoped pkg"; Path="node_modules/@scope/pkg"; },
            @{ Name="F-GV4: nested pkg"; Path="node_modules/a/node_modules/b"; },
            @{ Name="F-GV5: scoped-nested"; Path="node_modules/@scope/a/node_modules/@scope2/b"; },
            @{ Name="F-GV6: deeply nested"; Path="node_modules/a/node_modules/b/node_modules/c"; },
            @{ Name="F-GV7: same-name instances"; Path="node_modules/x/node_modules/shared"; },
            @{ Name="F-GV8: space in name"; Path="node_modules/my pkg"; }
        )
        foreach ($vp in $validPaths) {
            $canonResult = ConvertFrom-LockfilePathPolicy -RawPath $vp.Path
            $vpPass = ($canonResult -eq $vp.Path)
            $tests += [PSCustomObject]@{ Name=$vp.Name; Pass=$vpPass }
            if (-not $vpPass) { $allPassed = $false }
        }

        # Invalid paths: arbitrary suffix, incomplete scope at depth, malformed nested transitions
        $invalidPaths = @(
            @{ Name="F-GI1: arbitrary suffix"; Path="node_modules/pkg/arbitrary"; },
            @{ Name="F-GI2: arbitrary suffix after scoped"; Path="node_modules/@scope/pkg/extra"; },
            @{ Name="F-GI3: incomplete scope at depth"; Path="node_modules/a/node_modules/@scope"; },
            @{ Name="F-GI4: bare node_modules/"; Path="node_modules/"; },
            @{ Name="F-GI5: nested bare node_modules/"; Path="node_modules/a/node_modules/"; },
            @{ Name="F-GI6: trailing after deep nested"; Path="node_modules/a/node_modules/b/trailing"; },
            @{ Name="F-GI7: scoped without pkg at root"; Path="node_modules/@scope"; },
            @{ Name="F-GI8: double scope"; Path="node_modules/@scope/@scope2/pkg"; }
        )
        foreach ($ip in $invalidPaths) {
            $canonResult = ConvertFrom-LockfilePathPolicy -RawPath $ip.Path
            $ipPass = ($null -eq $canonResult)
            $tests += [PSCustomObject]@{ Name=$ip.Name; Pass=$ipPass }
            if (-not $ipPass) { $allPassed = $false }
        }

        # === R14-REV-04: Paired Node/PS grammar tests via ConvertFrom-LockfileSafe ===
        # These exercise the real Node helper (not TestCustomNodeScriptPath) for path grammar.

        # F-IG1: Valid grammar fixture — root, unscoped, scoped, nested, scoped-nested, deeply nested, same-name
        $fIG1 = Join-Path $fixtureDir "fIG1-valid-grammar.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/pkg": { "name": "pkg", "version": "1.0.0" },
    "node_modules/@scope/pkg": { "name": "pkg", "version": "2.0.0" },
    "node_modules/a/node_modules/b": { "name": "b", "version": "1.0.0" },
    "node_modules/@scope/a/node_modules/@scope2/b": { "name": "b", "version": "1.0.0" },
    "node_modules/a/node_modules/b/node_modules/c": { "name": "c", "version": "1.0.0" },
    "node_modules/x/node_modules/shared": { "name": "shared", "version": "1.0.0" },
    "node_modules/y/node_modules/shared": { "name": "shared", "version": "2.0.0" }
  }
}
'@ | Out-File -FilePath $fIG1 -Encoding ASCII
        $rIG1 = ConvertFrom-LockfileSafe -LockfilePath $fIG1
        $pIG1 = $rIG1.Parsed -and ($rIG1.Packages.Count -eq 8) -and
                $rIG1.Packages.ContainsKey("") -and
                $rIG1.Packages.ContainsKey("node_modules/pkg") -and
                $rIG1.Packages.ContainsKey("node_modules/@scope/pkg") -and
                $rIG1.Packages.ContainsKey("node_modules/a/node_modules/b") -and
                $rIG1.Packages.ContainsKey("node_modules/@scope/a/node_modules/@scope2/b") -and
                $rIG1.Packages.ContainsKey("node_modules/a/node_modules/b/node_modules/c") -and
                $rIG1.Packages.ContainsKey("node_modules/x/node_modules/shared") -and
                $rIG1.Packages.ContainsKey("node_modules/y/node_modules/shared")
        $tests += [PSCustomObject]@{ Name="F-IG1: valid grammar (root+unscoped+scoped+nested+deep+same-name)"; Pass=$pIG1 }
        if (-not $pIG1) { $allPassed = $false }

        # F-IG2: Arbitrary suffix at depth (node_modules/a/node_modules/b/trailing)
        $fIG2 = Join-Path $fixtureDir "fIG2-arbitrary-suffix-depth.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/a/node_modules/b/trailing": { "name": "b", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $fIG2 -Encoding ASCII
        $rIG2 = ConvertFrom-LockfileSafe -LockfilePath $fIG2
        $pIG2 = (-not $rIG2.Parsed) -and ($rIG2.Error -match "non-canonical|reject|policy")
        $tests += [PSCustomObject]@{ Name="F-IG2: arbitrary suffix at depth => rejected"; Pass=$pIG2 }
        if (-not $pIG2) { $allPassed = $false }

        # F-IG3: Incomplete scope at depth (node_modules/a/node_modules/@scope)
        $fIG3 = Join-Path $fixtureDir "fIG3-incomplete-scope-depth.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/a/node_modules/@scope": { "name": "scope", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $fIG3 -Encoding ASCII
        $rIG3 = ConvertFrom-LockfileSafe -LockfilePath $fIG3
        $pIG3 = (-not $rIG3.Parsed) -and ($rIG3.Error -match "non-canonical|reject|policy")
        $tests += [PSCustomObject]@{ Name="F-IG3: incomplete scope at depth => rejected"; Pass=$pIG3 }
        if (-not $pIG3) { $allPassed = $false }

        # F-IG4: Trailing after deeply nested (node_modules/a/node_modules/b/trailing)
        # Same as F-IG2 but verifies PS and Node agree
        $pIG4 = ($null -eq (ConvertFrom-LockfilePathPolicy -RawPath "node_modules/a/node_modules/b/trailing"))
        $tests += [PSCustomObject]@{ Name="F-IG4: PS grammar matches Node for trailing at depth"; Pass=$pIG4 }
        if (-not $pIG4) { $allPassed = $false }

        # F-IG5: Double scope (node_modules/@scope/@scope2/pkg)
        $fIG5 = Join-Path $fixtureDir "fIG5-double-scope.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/@scope/@scope2/pkg": { "name": "pkg", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $fIG5 -Encoding ASCII
        $rIG5 = ConvertFrom-LockfileSafe -LockfilePath $fIG5
        $pIG5 = (-not $rIG5.Parsed) -and ($rIG5.Error -match "non-canonical|reject|policy")
        $tests += [PSCustomObject]@{ Name="F-IG5: double scope => rejected by Node"; Pass=$pIG5 }
        if (-not $pIG5) { $allPassed = $false }

        # === R12-REV-10: ConvertFrom-TransitiveMapping judgment count tests ===

        # F45: 0 matching deps — mapping should be empty
        $f45 = Join-Path $fixtureDir "f45-zero-match.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/regular-pkg": { "name": "regular-pkg", "version": "1.0.0" }
  }
}
'@ | Out-File -FilePath $f45 -Encoding ASCII
        $r45lock = ConvertFrom-LockfileSafe -LockfilePath $f45
        $p45 = $false
        if ($r45lock.Parsed) {
            $r45map = ConvertFrom-TransitiveMapping -LockfilePackages $r45lock.Packages -NativeDepsToCheck @("nonexistent-pkg")
            $p45 = ($r45map.Count -eq 0)
        }
        $tests += [PSCustomObject]@{ Name="F45: 0 matching deps => empty mapping"; Pass=$p45 }
        if (-not $p45) { $allPassed = $false }

        # F46: 1 matching dep — mapping should have exactly 1 entry
        $f46 = Join-Path $fixtureDir "f46-one-match.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/native-pkg": { "name": "native-pkg", "version": "1.0.0", "gypfile": true }
  }
}
'@ | Out-File -FilePath $f46 -Encoding ASCII
        $r46lock = ConvertFrom-LockfileSafe -LockfilePath $f46
        $p46 = $false
        if ($r46lock.Parsed) {
            $r46map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            $p46 = ($r46map.Count -eq 1) -and ($r46map.ContainsKey("node_modules/native-pkg"))
        }
        $tests += [PSCustomObject]@{ Name="F46: 1 matching dep => 1-entry mapping"; Pass=$p46 }
        if (-not $p46) { $allPassed = $false }

        # F47: N matching deps — mapping should have multiple entries
        $f47 = Join-Path $fixtureDir "f47-n-match.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/native-a": { "name": "native-a", "version": "1.0.0", "gypfile": true },
    "node_modules/native-b": { "name": "native-b", "version": "2.0.0", "binary": true }
  }
}
'@ | Out-File -FilePath $f47 -Encoding ASCII
        $r47lock = ConvertFrom-LockfileSafe -LockfilePath $f47
        $p47 = $false
        if ($r47lock.Parsed) {
            $r47map = ConvertFrom-TransitiveMapping -LockfilePackages $r47lock.Packages -NativeDepsToCheck @("native-a", "native-b")
            $p47 = ($r47map.Count -eq 2)
        }
        $tests += [PSCustomObject]@{ Name="F47: N matching deps => multi-entry mapping"; Pass=$p47 }
        if (-not $p47) { $allPassed = $false }

        # F48: IsNative=false dep — should produce blocked entry (IsNative must be true)
        $f48 = Join-Path $fixtureDir "f48-notnative.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/js-only": { "name": "js-only", "version": "1.0.0", "main": "index.js" }
  }
}
'@ | Out-File -FilePath $f48 -Encoding ASCII
        $r48lock = ConvertFrom-LockfileSafe -LockfilePath $f48
        $p48 = $false
        if ($r48lock.Parsed) {
            $r48map = ConvertFrom-TransitiveMapping -LockfilePackages $r48lock.Packages -NativeDepsToCheck @("js-only")
            # REV-06: IsNative=false => blocked entry in mapping
            if ($r48map.ContainsKey("node_modules/js-only")) {
                $p48 = ($r48map["node_modules/js-only"].ResolutionStatus -eq "Blocked")
            } else {
                # Not in mapping at all is also acceptable
                $p48 = $true
            }
        }
        $tests += [PSCustomObject]@{ Name="F48: IsNative=false => blocked or absent"; Pass=$p48 }
        if (-not $p48) { $allPassed = $false }

        # === R12-REV-04: Judgment cardinality and field validation tests ===
        # These use the TestJudgmentProvider seam to force specific judgment counts.

        # F48b: R12-REV-04: F48 tightened — absence must fail, only blocked entry passes
        # The original F48 accepted absence as valid; fail-closed requires blocked entry
        $p48b = $false
        if ($r48lock.Parsed) {
            $r48map2 = ConvertFrom-TransitiveMapping -LockfilePackages $r48lock.Packages -NativeDepsToCheck @("js-only")
            if ($r48map2.ContainsKey("node_modules/js-only")) {
                $p48b = ($r48map2["node_modules/js-only"].ResolutionStatus -eq "Blocked") -and
                        ($r48map2["node_modules/js-only"].BlockReason -ne "")
            }
            # Absence is NOT acceptable (fail-closed)
        }
        $tests += [PSCustomObject]@{ Name="F48b: IsNative=false => blocked entry with reason (fail-closed)"; Pass=$p48b }
        if (-not $p48b) { $allPassed = $false }

        # F-JC1: Force 0 judgments for single candidate => blocked entry
        $fJC1map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp) return @() }
                $fJC1map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC1 = $false
        if ($fJC1map -and $fJC1map.ContainsKey("node_modules/native-pkg")) {
            $entry = $fJC1map["node_modules/native-pkg"]
            $pJC1 = ($entry.ResolutionStatus -eq "Blocked") -and ($entry.BlockReason -match "Expected exactly 1 judgment")
        }
        $tests += [PSCustomObject]@{ Name="F-JC1: 0 judgments => blocked entry"; Pass=$pJC1 }
        if (-not $pJC1) { $allPassed = $false }

                # F-JC2: Force N judgments (2) for single candidate => blocked entry
        $fJC2map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @(
                        [PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="Resolved"; InstancePath="node_modules/native-pkg"; BlockReason="" },
                        [PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="Resolved"; InstancePath="node_modules/native-pkg"; BlockReason="" }
                    )
                }
                $fJC2map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC2 = $false
        if ($fJC2map -and $fJC2map.ContainsKey("node_modules/native-pkg")) {
            $entry = $fJC2map["node_modules/native-pkg"]
            $pJC2 = ($entry.ResolutionStatus -eq "Blocked") -and ($entry.BlockReason -match "Expected exactly 1 judgment")
        }
        $tests += [PSCustomObject]@{ Name="F-JC2: N judgments (2) => blocked entry"; Pass=$pJC2 }
        if (-not $pJC2) { $allPassed = $false }

                # F-JC3: Name validation => blocked entry
        $fJC3map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name=$null; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="Resolved"; InstancePath="node_modules/native-pkg"; BlockReason="" })
                }
                $fJC3map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC3 = $false
        if ($fJC3map -and $fJC3map.ContainsKey("node_modules/native-pkg")) {
            $pJC3 = ($fJC3map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and ($fJC3map["node_modules/native-pkg"].BlockReason -match "Name")
        }
        $tests += [PSCustomObject]@{ Name="F-JC3: null Name => blocked entry"; Pass=$pJC3 }
        if (-not $pJC3) { $allPassed = $false }

                # F-JC4: ResolutionStatus validation => blocked entry
        $fJC4map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="InvalidStatus"; InstancePath="node_modules/native-pkg"; BlockReason="" })
                }
                $fJC4map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC4 = $false
        if ($fJC4map -and $fJC4map.ContainsKey("node_modules/native-pkg")) {
            $pJC4 = ($fJC4map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and ($fJC4map["node_modules/native-pkg"].BlockReason -match "ResolutionStatus")
        }
        $tests += [PSCustomObject]@{ Name="F-JC4: invalid ResolutionStatus => blocked entry"; Pass=$pJC4 }
        if (-not $pJC4) { $allPassed = $false }

                # F-JC5: IsNative validation => blocked entry
        $fJC5map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$null; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="Resolved"; InstancePath="node_modules/native-pkg"; BlockReason="" })
                }
                $fJC5map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC5 = $false
        if ($fJC5map -and $fJC5map.ContainsKey("node_modules/native-pkg")) {
            $pJC5 = ($fJC5map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and ($fJC5map["node_modules/native-pkg"].BlockReason -match "IsNative")
        }
        $tests += [PSCustomObject]@{ Name="F-JC5: null IsNative => blocked entry"; Pass=$pJC5 }
        if (-not $pJC5) { $allPassed = $false }

                # F-JC6: PlatformApplicable validation => blocked entry
        $fJC6map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$null; ParentOptional=$false; ResolutionStatus="Resolved"; InstancePath="node_modules/native-pkg"; BlockReason="" })
                }
                $fJC6map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC6 = $false
        if ($fJC6map -and $fJC6map.ContainsKey("node_modules/native-pkg")) {
            $pJC6 = ($fJC6map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and ($fJC6map["node_modules/native-pkg"].BlockReason -match "PlatformApplicable")
        }
        $tests += [PSCustomObject]@{ Name="F-JC6: null PlatformApplicable => blocked entry"; Pass=$pJC6 }
        if (-not $pJC6) { $allPassed = $false }

                # F-JC7: ParentOptional validation => blocked entry
        $fJC7map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=$null; ResolutionStatus="Resolved"; InstancePath="node_modules/native-pkg"; BlockReason="" })
                }
                $fJC7map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC7 = $false
        if ($fJC7map -and $fJC7map.ContainsKey("node_modules/native-pkg")) {
            $pJC7 = ($fJC7map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and ($fJC7map["node_modules/native-pkg"].BlockReason -match "ParentOptional")
        }
        $tests += [PSCustomObject]@{ Name="F-JC7: null ParentOptional => blocked entry"; Pass=$pJC7 }
        if (-not $pJC7) { $allPassed = $false }

        # === R14-REV-05: Expanded judgment validation and cross-candidate isolation ===

        # F-JC8: Provider exception => exact-path structured Blocked entry
        $fJC8map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp) throw "TEST: simulated provider crash" }
                $fJC8map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC8 = $false
        if ($fJC8map -and $fJC8map.ContainsKey("node_modules/native-pkg")) {
            $entry = $fJC8map["node_modules/native-pkg"]
            $pJC8 = ($entry.ResolutionStatus -eq "Blocked") -and
                    ($entry.BlockReason -match "Judgment provider exception") -and
                    ($entry.BlockReason -match "simulated provider crash")
        }
        $tests += [PSCustomObject]@{ Name="F-JC8: provider exception => exact-path Blocked entry"; Pass=$pJC8 }
        if (-not $pJC8) { $allPassed = $false }

        # F-JC9: Cross-candidate isolation — first throws, second succeeds
        $fJC9 = Join-Path $fixtureDir "fJC9-two-deps.json"
        @'
{
  "name": "test",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "test", "version": "1.0.0" },
    "node_modules/native-a": { "name": "native-a", "version": "1.0.0", "gypfile": true },
    "node_modules/native-b": { "name": "native-b", "version": "2.0.0", "gypfile": true }
  }
}
'@ | Out-File -FilePath $fJC9 -Encoding ASCII
        $rJC9lock = ConvertFrom-LockfileSafe -LockfilePath $fJC9
        $pJC9 = $false
        if ($rJC9lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = {
                    param($dm, $os, $cpu, $lp)
                    $name = $dm[0].Name
                    if ($name -eq "native-a") { throw "TEST: native-a crashes" }
                    # native-b succeeds
                    return @([PSCustomObject]@{ Name=$name; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="Resolved"; BlockReason="" })
                }
                $fJC9map = ConvertFrom-TransitiveMapping -LockfilePackages $rJC9lock.Packages -NativeDepsToCheck @("native-a", "native-b")
            } finally { $script:TestJudgmentProviderOverride = $null }
            if ($fJC9map) {
                $aEntry = $fJC9map["node_modules/native-a"]
                $bEntry = $fJC9map["node_modules/native-b"]
                $pJC9 = ($null -ne $aEntry) -and ($null -ne $bEntry) -and
                        ($aEntry.ResolutionStatus -eq "Blocked") -and
                        ($aEntry.BlockReason -match "native-a crashes") -and
                        ($bEntry.ResolutionStatus -eq "Resolved") -and
                        ($bEntry.IsNative -eq $true)
            }
        }
        $tests += [PSCustomObject]@{ Name="F-JC9: cross-candidate isolation (1st throws, 2nd succeeds)"; Pass=$pJC9 }
        if (-not $pJC9) { $allPassed = $false }

        # F-JC10: Blocked with missing/empty BlockReason
        $fJC10map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus="Blocked"; BlockReason="" })
                }
                $fJC10map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC10 = $false
        if ($fJC10map -and $fJC10map.ContainsKey("node_modules/native-pkg")) {
            $pJC10 = ($fJC10map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and
                     ($fJC10map["node_modules/native-pkg"].BlockReason -match "BlockReason")
        }
        $tests += [PSCustomObject]@{ Name="F-JC10: Blocked with empty BlockReason => caught"; Pass=$pJC10 }
        if (-not $pJC10) { $allPassed = $false }

        # F-JC11: null/missing ResolutionStatus
        $fJC11map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=$false; ResolutionStatus=$null; BlockReason="" })
                }
                $fJC11map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC11 = $false
        if ($fJC11map -and $fJC11map.ContainsKey("node_modules/native-pkg")) {
            $pJC11 = ($fJC11map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and
                     ($fJC11map["node_modules/native-pkg"].BlockReason -match "ResolutionStatus")
        }
        $tests += [PSCustomObject]@{ Name="F-JC11: null ResolutionStatus => blocked"; Pass=$pJC11 }
        if (-not $pJC11) { $allPassed = $false }

        # F-JC12: Non-Boolean PlatformApplicable
        $fJC12map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable="yes"; ParentOptional=$false; ResolutionStatus="Resolved"; BlockReason="" })
                }
                $fJC12map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC12 = $false
        if ($fJC12map -and $fJC12map.ContainsKey("node_modules/native-pkg")) {
            $pJC12 = ($fJC12map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and
                     ($fJC12map["node_modules/native-pkg"].BlockReason -match "PlatformApplicable.*not Boolean|Boolean")
        }
        $tests += [PSCustomObject]@{ Name="F-JC12: non-Boolean PlatformApplicable => blocked"; Pass=$pJC12 }
        if (-not $pJC12) { $allPassed = $false }

        # F-JC13: Non-Boolean ParentOptional
        $fJC13map = $null
        if ($r46lock.Parsed) {
            try {
                $script:TestJudgmentProviderOverride = { param($dm, $os, $cpu, $lp)
                    return @([PSCustomObject]@{ Name="native-pkg"; IsNative=$true; PlatformApplicable=$true; ParentOptional=1; ResolutionStatus="Resolved"; BlockReason="" })
                }
                $fJC13map = ConvertFrom-TransitiveMapping -LockfilePackages $r46lock.Packages -NativeDepsToCheck @("native-pkg")
            } finally { $script:TestJudgmentProviderOverride = $null }
        }
        $pJC13 = $false
        if ($fJC13map -and $fJC13map.ContainsKey("node_modules/native-pkg")) {
            $pJC13 = ($fJC13map["node_modules/native-pkg"].ResolutionStatus -eq "Blocked") -and
                     ($fJC13map["node_modules/native-pkg"].BlockReason -match "ParentOptional.*not Boolean|Boolean")
        }
        $tests += [PSCustomObject]@{ Name="F-JC13: non-Boolean ParentOptional => blocked"; Pass=$pJC13 }
        if (-not $pJC13) { $allPassed = $false }

    } finally {
        Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # R15-REV-02: Independent declared manifest — exact name-set comparison via Compare-TestManifest
    # This catches accidentally removed, duplicated, or replaced test cases
    $testNames = @($tests | ForEach-Object { $_.Name })

    # R14-REV-06 + R15-REV-02: Manifest of all expected test names for LockfileReader suite
    $manifest = @(
        "F1: root key + optdep + required", "F2: nested dependency", "F3: scoped parent",
        "F4: same-name different paths", "F5: malformed JSON => Parsed=false",
        "F6: missing packages => Parsed=false", "F7: missing file => Parsed=false",
        "F8: root optDep via reader => ParentOptional", "F9: nested optDep via reader => ParentOptional",
        "F10: canonical collision => Parsed=false", "F11: non-obj packages => Parsed=false with exit evidence",
        "F12: empty packages => Parsed=true, 0 entries", "F12b: packages=null => Parsed=false",
        "F13: packages=array => Parsed=false", "F14: packages=string => Parsed=false",
        "F15: packages=number => Parsed=false", "F16: package Data=null => Parsed=false",
        "F17: package Data=array => Parsed=false", "F18: package Data=string => Parsed=false",
        "F19: package Data=number => Parsed=false", "F20: diverse paths all pass (8 entries)",
        "F21: one-entry collection scalar-safe", "F22: root-only zero-dep scalar-safe",
        "F23: exact status PASS/Informational for platform-n/a",
        "F23b: exact InstancePath+Path+resolution+load evidence",
        "F23c: no-match => structured BLOCKED via shared function", "F23c-gate: BLOCKED gate outcome",
        "F23d: same-name/different-instance exact-path isolation",
        "F24: parser fail + others PASS => overall BLOCKED",
        "F25: exit 0 + empty stdout => Parsed=false", "F26: exit 0 + stderr => Parsed=false",
        "F27: oversized stdout => Parsed=false", "F28: oversized stderr => bounded size-limit diagnostic",
        "F29: oversized input (100B limit) => Parsed=false", "F29b: Node-side 50MiB sparse file => rejected",
        "F29c: malformed intermediate JSON => Parsed=false",
        "F30: non-string Path => Parsed=false", "F31: boolean Data => Parsed=false",
        "F32: cleanup failure => Parsed=false", "F32b: owned helper dir recovered",
        "F32c: sentinel dir preserved (no wildcard delete)",
        "F33: Resolve-NodeExecutable returns valid path", "F33b: Resolve-NodeExecutable Error empty on success",
        "F-NC1: no candidates => blocked", "F-NC2: nonexistent path => blocked",
        "F-NC3: directory path => blocked", "F-NC4: multiple Applications => blocked",
        "F-NC5: alias+app => blocked (alias shadows)", "F-NC6: function only => blocked",
        "F-NC7: cmdlet only => blocked", "F-NC8: script+app => blocked (script shadows)",
        "F-NC9: single valid Application => accepted",
        "F34: trailing slash", "F35: repeated slash", "F36: backslash",
        "F37: dot segment", "F38: dot-dot segment", "F39: absolute path",
        "F40: terminal dot (/.)", "F41: terminal dot-dot (/..)",
        "F42: incomplete scope (@scope no pkg)", "F43: drive letter path (C:/...)",
        "F44: control char in path (0x01)",
        "F-GV1: root (empty string)", "F-GV2: unscoped pkg", "F-GV3: scoped pkg",
        "F-GV4: nested pkg", "F-GV5: scoped-nested", "F-GV6: deeply nested",
        "F-GV7: same-name instances", "F-GV8: space in name",
        "F-GI1: arbitrary suffix", "F-GI2: arbitrary suffix after scoped",
        "F-GI3: incomplete scope at depth", "F-GI4: bare node_modules/",
        "F-GI5: nested bare node_modules/", "F-GI6: trailing after deep nested",
        "F-GI7: scoped without pkg at root", "F-GI8: double scope",
        "F-IG1: valid grammar (root+unscoped+scoped+nested+deep+same-name)",
        "F-IG2: arbitrary suffix at depth => rejected", "F-IG3: incomplete scope at depth => rejected",
        "F-IG4: PS grammar matches Node for trailing at depth", "F-IG5: double scope => rejected by Node",
        "F45: 0 matching deps => empty mapping", "F46: 1 matching dep => 1-entry mapping",
        "F47: N matching deps => multi-entry mapping", "F48: IsNative=false => blocked or absent",
        "F48b: IsNative=false => blocked entry with reason (fail-closed)",
        "F-JC1: 0 judgments => blocked entry", "F-JC2: N judgments (2) => blocked entry",
        "F-JC3: null Name => blocked entry", "F-JC4: invalid ResolutionStatus => blocked entry",
        "F-JC5: null IsNative => blocked entry", "F-JC6: null PlatformApplicable => blocked entry",
        "F-JC7: null ParentOptional => blocked entry",
        "F-JC8: provider exception => exact-path Blocked entry",
        "F-JC9: cross-candidate isolation (1st throws, 2nd succeeds)",
        "F-JC10: Blocked with empty BlockReason => caught",
        "F-JC11: null ResolutionStatus => blocked",
        "F-JC12: non-Boolean PlatformApplicable => blocked",
        "F-JC13: non-Boolean ParentOptional => blocked"
    )
    $manifestCount = $manifest.Count

    # R15-REM-02: Use exact name-set comparison with ordinal-comparing collections
    $manifestComparison = Compare-TestManifest -ExpectedNames $manifest -ActualNames $testNames
    $manifestMatch = $manifestComparison.Match
    if (-not $manifestMatch) {
        $allPassed = $false
        $detailParts = @()
        if ($manifestComparison.MissingTotal -gt 0) { $detailParts += "Missing=$($manifestComparison.MissingTotal)($($manifestComparison.Missing -join ','))" }
        if ($manifestComparison.ExtraTotal -gt 0) { $detailParts += "Extra=$($manifestComparison.ExtraTotal)($($manifestComparison.Extra -join ','))" }
        if ($manifestComparison.DuplicateExpectedTotal -gt 0) { $detailParts += "DupExpected=$($manifestComparison.DuplicateExpectedTotal)($($manifestComparison.DuplicateExpected -join ','))" }
        if ($manifestComparison.DuplicateActualTotal -gt 0) { $detailParts += "DupActual=$($manifestComparison.DuplicateActualTotal)($($manifestComparison.DuplicateActual -join ','))" }
        if ($manifestComparison.Truncated) { $detailParts += "(truncated)" }
        Write-Host "  FAIL: LockfileReader manifest mismatch: $($detailParts -join '; ')" -ForegroundColor Red
    }

    # R14-REV-06: Record suite counts with Declared from manifest, add Failed
    $expectedTestCount = $manifestCount
    $passedReaderCount = @($tests | Where-Object { $_.Pass }).Count
    $failedReaderCount = @($tests | Where-Object { -not $_.Pass }).Count
    $script:SelfTestSuiteResults['LockfileReader'] = @{ Declared=$manifestCount; Actual=$tests.Count; Passed=$passedReaderCount; Failed=$failedReaderCount }

    Write-Host "`n=== Lockfile Reader Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name)" -ForegroundColor $color
    }

    return $allPassed
}

# R6-03: Self-test for Resolve-LockfileParentPath
function Test-ResolveLockfileParentPath {
    $allPassed = $true
    $tests = @()

    # T1: node_modules/pkg → root parent ""
    $t1 = Resolve-LockfileParentPath -InstancePath "node_modules/pkg"
    $tests += [PSCustomObject]@{ Name="T1: root pkg"; Expected=""; Actual=$t1; Pass=($t1 -eq "") }
    if ($t1 -ne "") { $allPassed = $false }

    # T2: node_modules/parent/node_modules/pkg → node_modules/parent
    $t2 = Resolve-LockfileParentPath -InstancePath "node_modules/parent/node_modules/pkg"
    $tests += [PSCustomObject]@{ Name="T2: nested pkg"; Expected="node_modules/parent"; Actual=$t2; Pass=($t2 -eq "node_modules/parent") }
    if ($t2 -ne "node_modules/parent") { $allPassed = $false }

    # T3: node_modules/@scope/parent/node_modules/pkg → node_modules/@scope/parent
    $t3 = Resolve-LockfileParentPath -InstancePath "node_modules/@scope/parent/node_modules/pkg"
    $tests += [PSCustomObject]@{ Name="T3: scoped nested pkg"; Expected="node_modules/@scope/parent"; Actual=$t3; Pass=($t3 -eq "node_modules/@scope/parent") }
    if ($t3 -ne "node_modules/@scope/parent") { $allPassed = $false }

    # T4: node_modules/a/node_modules/b/node_modules/pkg → node_modules/a/node_modules/b (deeply nested)
    $t4 = Resolve-LockfileParentPath -InstancePath "node_modules/a/node_modules/b/node_modules/pkg"
    $tests += [PSCustomObject]@{ Name="T4: deeply nested"; Expected="node_modules/a/node_modules/b"; Actual=$t4; Pass=($t4 -eq "node_modules/a/node_modules/b") }
    if ($t4 -ne "node_modules/a/node_modules/b") { $allPassed = $false }

    # R12-REV-10: Runtime count assertion
    $expectedParentPathCount = 4
    if ($tests.Count -ne $expectedParentPathCount) {
        Write-Host "FAIL: Expected $expectedParentPathCount parent path tests, got $($tests.Count)" -ForegroundColor Red
        $allPassed = $false
    }
    # R12-REV-07: Record suite counts
    $passedParentCount = @($tests | Where-Object { $_.Pass }).Count
    $failedParentCount = @($tests | Where-Object { -not $_.Pass }).Count
    $script:SelfTestSuiteResults['ParentPath'] = @{ Declared=$expectedParentPathCount; Actual=$tests.Count; Passed=$passedParentCount; Failed=$failedParentCount }

    # R5-REM-05: Dynamic count from actual test results
    Write-Host "`n=== Resolve-LockfileParentPath Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected='$($t.Expected)' actual='$($t.Actual)')" -ForegroundColor $color
    }

    return $allPassed
}

# R6-04: Self-test for Get-NativeGateSummary (15 cases)
function Test-NativeGateSummary {
    $allPassed = $true
    $tests = @()

    # T1: All required resolved + loaded → PASS
    $i1 = @([PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" })
    $g1 = Get-NativeGateSummary -InstanceResults $i1 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T1: required resolved+loaded => PASS"; Expected="PASS"; Actual=$g1.Status; Pass=($g1.Status -eq "PASS") }
    if ($g1.Status -ne "PASS") { $allPassed = $false }

    # T2: Required load failure → FAIL
    $i2 = @([PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=1; LoadOutput="ERR" })
    $g2 = Get-NativeGateSummary -InstanceResults $i2 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T2: required load fail => FAIL"; Expected="FAIL"; Actual=$g2.Status; Pass=($g2.Status -eq "FAIL") }
    if ($g2.Status -ne "FAIL") { $allPassed = $false }

    # T3: Blocked instance (even if load succeeded) → BLOCKED
    $i3 = @([PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Blocked"; BlockReason="No mapping"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" })
    $g3 = Get-NativeGateSummary -InstanceResults $i3 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T3: blocked instance => BLOCKED"; Expected="BLOCKED"; Actual=$g3.Status; Pass=($g3.Status -eq "BLOCKED") }
    if ($g3.Status -ne "BLOCKED") { $allPassed = $false }

    # T4: Lockfile not parsed → BLOCKED
    $i4 = @([PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" })
    $g4 = Get-NativeGateSummary -InstanceResults $i4 -LockfileParsed $false -LockfileParseError "JSON invalid"
    $tests += [PSCustomObject]@{ Name="T4: lockfile not parsed => BLOCKED"; Expected="BLOCKED"; Actual=$g4.Status; Pass=($g4.Status -eq "BLOCKED") }
    if ($g4.Status -ne "BLOCKED") { $allPassed = $false }

    # T5: All optional/platform-n/a → Informational
    $i5 = @([PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$false; ParentOptional=$false; LoadExit=0; LoadOutput="" })
    $g5 = Get-NativeGateSummary -InstanceResults $i5 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T5: all optional/n-a => Info PASS"; Expected="PASS"; Actual=$g5.Status; Pass=($g5.Status -eq "PASS" -and $g5.Category -eq "Informational") }
    if ($g5.Status -ne "PASS" -or $g5.Category -ne "Informational") { $allPassed = $false }

    # T6: Same-name different paths — one blocked, one loaded → BLOCKED
    $i6 = @(
        [PSCustomObject]@{ Name="x"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" },
        [PSCustomObject]@{ Name="x"; Version="1.0"; ResolutionStatus="Blocked"; BlockReason="Ambiguous"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" }
    )
    $g6 = Get-NativeGateSummary -InstanceResults $i6 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T6: mixed blocked/resolved => BLOCKED"; Expected="BLOCKED"; Actual=$g6.Status; Pass=($g6.Status -eq "BLOCKED") }
    if ($g6.Status -ne "BLOCKED") { $allPassed = $false }

    # T7: Empty instance list + lockfile parsed → Informational PASS (no native deps)
    $i7 = @()
    $g7 = Get-NativeGateSummary -InstanceResults $i7 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T7: empty list => Info PASS"; Expected="PASS"; Actual=$g7.Status; Pass=($g7.Status -eq "PASS" -and $g7.Category -eq "Informational") }
    if ($g7.Status -ne "PASS" -or $g7.Category -ne "Informational") { $allPassed = $false }

    # === R7-04: PowerShell 5.1 regression cases ===

    # T8: 0 blocked instances (empty blocked list) → no BLOCKED gate
    $i8 = @([PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" })
    $g8 = Get-NativeGateSummary -InstanceResults $i8 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T8: 0 blocked => PASS"; Expected="PASS"; Actual=$g8.Status; Pass=($g8.Status -eq "PASS") }
    if ($g8.Status -ne "PASS") { $allPassed = $false }

    # T9: Bare PSCustomObject (single item, NOT wrapped in @()) → must still work
    # This tests the exact PS 5.1 unwrapping scenario: input is a bare object, not an array
    $i9bare = [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Blocked"; BlockReason="No mapping"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" }
    $g9 = Get-NativeGateSummary -InstanceResults $i9bare -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T9: bare PSCustomObject blocked => BLOCKED"; Expected="BLOCKED"; Actual=$g9.Status; Pass=($g9.Status -eq "BLOCKED") }
    if ($g9.Status -ne "BLOCKED") { $allPassed = $false }

    # T10: 2 blocked instances → BLOCKED
    $i10 = @(
        [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Blocked"; BlockReason="Missing data"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" },
        [PSCustomObject]@{ Name="b"; Version="2.0"; ResolutionStatus="Unresolved"; BlockReason="Ambiguous"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" }
    )
    $g10 = Get-NativeGateSummary -InstanceResults $i10 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T10: 2 blocked => BLOCKED"; Expected="BLOCKED"; Actual=$g10.Status; Pass=($g10.Status -eq "BLOCKED") }
    if ($g10.Status -ne "BLOCKED") { $allPassed = $false }

    # T11: 1 required load failure (bare PSCustomObject) → FAIL
    $i11bare = [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=1; LoadOutput="ERR" }
    $g11 = Get-NativeGateSummary -InstanceResults $i11bare -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T11: bare 1 load failure => FAIL"; Expected="FAIL"; Actual=$g11.Status; Pass=($g11.Status -eq "FAIL") }
    if ($g11.Status -ne "FAIL") { $allPassed = $false }

    # T12: 1 required loaded (bare PSCustomObject) → PASS
    $i12bare = [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" }
    $g12 = Get-NativeGateSummary -InstanceResults $i12bare -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T12: bare 1 loaded => PASS"; Expected="PASS"; Actual=$g12.Status; Pass=($g12.Status -eq "PASS") }
    if ($g12.Status -ne "PASS") { $allPassed = $false }

    # R8-01: T13: 1 FAIL + 1 BLOCKED → FAIL (required failure takes priority)
    $i13 = @(
        [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$true; ParentOptional=$false; LoadExit=1; LoadOutput="ERR" },
        [PSCustomObject]@{ Name="b"; Version="2.0"; ResolutionStatus="Blocked"; BlockReason="No mapping"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" }
    )
    $g13 = Get-NativeGateSummary -InstanceResults $i13 -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T13: 1 FAIL + 1 BLOCKED => FAIL (R8-01 priority)"; Expected="FAIL"; Actual=$g13.Status; Pass=($g13.Status -eq "FAIL") }
    if ($g13.Status -ne "FAIL") { $allPassed = $false }

    # T14: Bare PSCustomObject optional/platform-n/a → Informational PASS
    $i14bare = [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Resolved"; BlockReason=""; PlatformApplicable=$false; ParentOptional=$false; LoadExit=1; LoadOutput="ERR" }
    $g14 = Get-NativeGateSummary -InstanceResults $i14bare -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T14: bare optional n/a fail => Info PASS"; Expected="PASS"; Actual=$g14.Status; Pass=($g14.Status -eq "PASS" -and $g14.Category -eq "Informational") }
    if ($g14.Status -ne "PASS" -or $g14.Category -ne "Informational") { $allPassed = $false }

    # T15: Bare PSCustomObject with Unresolved → BLOCKED
    $i15bare = [PSCustomObject]@{ Name="a"; Version="1.0"; ResolutionStatus="Unresolved"; BlockReason="Parse error"; PlatformApplicable=$true; ParentOptional=$false; LoadExit=0; LoadOutput="" }
    $g15 = Get-NativeGateSummary -InstanceResults $i15bare -LockfileParsed $true
    $tests += [PSCustomObject]@{ Name="T15: bare Unresolved => BLOCKED"; Expected="BLOCKED"; Actual=$g15.Status; Pass=($g15.Status -eq "BLOCKED") }
    if ($g15.Status -ne "BLOCKED") { $allPassed = $false }

    # R12-REV-10: Runtime count assertion
    $expectedGateCount = 15
    if ($tests.Count -ne $expectedGateCount) {
        Write-Host "FAIL: Expected $expectedGateCount gate summary tests, got $($tests.Count)" -ForegroundColor Red
        $allPassed = $false
    }
    # R12-REV-07: Record suite counts
    $passedGateCount = @($tests | Where-Object { $_.Pass }).Count
    $failedGateCount = @($tests | Where-Object { -not $_.Pass }).Count
    $script:SelfTestSuiteResults['GateSummary'] = @{ Declared=$expectedGateCount; Actual=$tests.Count; Passed=$passedGateCount; Failed=$failedGateCount }

    # R5-REM-05: Dynamic count from actual test results
    Write-Host "`n=== Native Gate Summary Self-Test ($($tests.Count) cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected=$($t.Expected) actual=$($t.Actual))" -ForegroundColor $color
    }

    return $allPassed
}

# R3-R3-08 + R1-08: Self-test for aggregation logic
# R4-01: 11 test cases including kill+identityBlock combo
# Runtime execution verified via self-test harness.
function Test-GetOverallResult {
    $allPassed = $true
    $tests = @()

    $r1 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" },
        [PSCustomObject]@{ Category = "Informational"; Status = "FAIL" }
    )
    $g1 = Get-OverallResult -Results $r1 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "All PASS + Info FAIL -> PASS"; Expected = "PASS"; Actual = $g1; Pass = ($g1 -eq "PASS") }
    if ($g1 -ne "PASS") { $allPassed = $false }

    $r2 = @(
        [PSCustomObject]@{ Category = "EvidenceDependent"; Status = "BLOCKED" },
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" }
    )
    $g2 = Get-OverallResult -Results $r2 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "EvidenceDependent BLOCKED -> BLOCKED"; Expected = "BLOCKED"; Actual = $g2; Pass = ($g2 -eq "BLOCKED") }
    if ($g2 -ne "BLOCKED") { $allPassed = $false }

    $r3 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "FAIL" },
        [PSCustomObject]@{ Category = "EvidenceDependent"; Status = "PASS" }
    )
    $g3 = Get-OverallResult -Results $r3 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "MandatoryFunctional FAIL -> FAIL"; Expected = "FAIL"; Actual = $g3; Pass = ($g3 -eq "FAIL") }
    if ($g3 -ne "FAIL") { $allPassed = $false }

    $r4 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "FAIL" },
        [PSCustomObject]@{ Category = "EvidenceDependent"; Status = "BLOCKED" }
    )
    $g4 = Get-OverallResult -Results $r4 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "FAIL + BLOCKED -> FAIL"; Expected = "FAIL"; Actual = $g4; Pass = ($g4 -eq "FAIL") }
    if ($g4 -ne "FAIL") { $allPassed = $false }

    $r5 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" }
    )
    $g5 = Get-OverallResult -Results $r5 -HasFatalInternalError $true -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "Fatal internal error -> ERROR"; Expected = "ERROR"; Actual = $g5; Pass = ($g5 -eq "ERROR") }
    if ($g5 -ne "ERROR") { $allPassed = $false }

    $r6 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" }
    )
    $g6 = Get-OverallResult -Results $r6 -HasFatalInternalError $false -CleanupErrorList @("ERR-CLEANUP-PROCESS: kill failed")
    $tests += [PSCustomObject]@{ Name = "Cleanup fatal error -> ERROR"; Expected = "ERROR"; Actual = $g6; Pass = ($g6 -eq "ERROR") }
    if ($g6 -ne "ERROR") { $allPassed = $false }

    $r7 = @(
        [PSCustomObject]@{ Category = "Informational"; Status = "PASS" }
    )
    $g7 = Get-OverallResult -Results $r7 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "No Gate-blocking -> ERROR"; Expected = "ERROR"; Actual = $g7; Pass = ($g7 -eq "ERROR") }
    if ($g7 -ne "ERROR") { $allPassed = $false }

    # R3-01: IdentityBlocked in MandatoryFunctional -> BLOCKED/2
    $r8 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" },
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "BLOCKED" }
    )
    $g8 = Get-OverallResult -Results $r8 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "IdentityBlocked -> BLOCKED"; Expected = "BLOCKED"; Actual = $g8; Pass = ($g8 -eq "BLOCKED") }
    if ($g8 -ne "BLOCKED") { $allPassed = $false }

    # R5-06: CleanupError FAIL (script exception, NOT kill failure) -> ERROR/3
    $r9 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" },
        [PSCustomObject]@{ Category = "CleanupError"; Status = "FAIL" }
    )
    $g9 = Get-OverallResult -Results $r9 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "Script exception (CleanupError) -> ERROR"; Expected = "ERROR"; Actual = $g9; Pass = ($g9 -eq "ERROR") }
    if ($g9 -ne "ERROR") { $allPassed = $false }

    # R5-06: Script exception + IdentityBlocked -> ERROR (exception takes priority)
    $r10 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" },
        [PSCustomObject]@{ Category = "CleanupError"; Status = "FAIL" },
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "BLOCKED" }
    )
    $g10 = Get-OverallResult -Results $r10 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "Script exception + IdentityBlocked -> ERROR"; Expected = "ERROR"; Actual = $g10; Pass = ($g10 -eq "ERROR") }
    if ($g10 -ne "ERROR") { $allPassed = $false }

    # R4-01: Kill failure (MandatoryFunctional FAIL) + IdentityBlocked -> FAIL
    # Kill failure as gate-blocking FAIL overrides BLOCKED
    $r11 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "FAIL" },
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "BLOCKED" }
    )
    $g11 = Get-OverallResult -Results $r11 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "Kill fail (gate) + IdentityBlocked -> FAIL"; Expected = "FAIL"; Actual = $g11; Pass = ($g11 -eq "FAIL") }
    if ($g11 -ne "FAIL") { $allPassed = $false }

    # R12-REV-10: Runtime count assertion
    $expectedAggCount = 11
    if ($tests.Count -ne $expectedAggCount) {
        Write-Host "FAIL: Expected $expectedAggCount aggregation tests, got $($tests.Count)" -ForegroundColor Red
        $allPassed = $false
    }
    # R12-REV-07: Record suite counts
    $passedAggCount = @($tests | Where-Object { $_.Pass }).Count
    $failedAggCount = @($tests | Where-Object { -not $_.Pass }).Count
    $script:SelfTestSuiteResults['Aggregation'] = @{ Declared=$expectedAggCount; Actual=$tests.Count; Passed=$passedAggCount; Failed=$failedAggCount }

    Write-Host "`n=== Aggregation Self-Test ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected=$($t.Expected) actual=$($t.Actual))" -ForegroundColor $color
    }

    return $allPassed
}

# === Process tracking data structure ===
$script:PreSnapshot = @{}
$script:HarnessLauncherPid = $null
$script:HarnessNodePid = $null
$script:HarnessLauncherCreationDate = $null
$script:OwnedProcessRecords = @()
$script:HarnessReady = $false
$script:SavedProcessEvidence = @()
$script:SavedHarnessProven = $false
$script:SavedHarnessEvidence = ""

function Save-ProcessSnapshot {
    $snap = @{}
    Get-CimInstance Win32_Process | ForEach-Object {
        $snap[[int]$_.ProcessId] = [PSCustomObject]@{
            PID          = [int]$_.ProcessId
            Name         = $_.Name
            ParentPID    = [int]$_.ParentProcessId
            CommandLine  = $_.CommandLine
            CreationDate = $_.CreationDate
            ExecutablePath = $_.ExecutablePath
        }
    }
    return $snap
}

# R1-01: Process ownership ONLY via BFS from verified launcher.
# R1-01: No CommandLine wildcard ownership. No $isLauncherDescendant tautology.
# R1-05: Each record gets CaptureOrder for deterministic tie-breaking.
function Update-OwnedProcessRecords {
    param(
        [int]$LauncherPid,
        [string]$LauncherCreationDate
    )

    # R1-01: Verify launcher still exists and has matching CreationDate
    $launcherCim = Get-CimInstance Win32_Process -Filter "ProcessId = $LauncherPid" -ErrorAction SilentlyContinue
    $launcherVerified = $false
    if ($launcherCim -and $launcherCim.CreationDate -eq $LauncherCreationDate) {
        $launcherVerified = $true
    }

    if (-not $launcherVerified) {
        # R1-02: Launcher exited — do NOT re-BFS from dead launcher.
        # Return existing records for re-validation, do NOT overwrite with empty set.
        Write-Host "  WARNING: Launcher PID $LauncherPid no longer verified (exited or PID reused). Preserving existing records." -ForegroundColor Yellow
        return  # Do not modify $script:OwnedProcessRecords
    }

    $allProcs = Get-CimInstance Win32_Process
    $byParent = @{}
    foreach ($proc in $allProcs) {
        $ppid = [int]$proc.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $proc
    }

    # BFS from verified launcher — ONLY BFS-discovered descendants
    $visited = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([PSCustomObject]@{ PID = $LauncherPid; Depth = 0 })
    $visited[$LauncherPid] = $true
    $records = @()
    $captureSeq = 0

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $currentPid = $item.PID
        $currentDepth = $item.Depth

        # R1-01: Exclude current PowerShell $PID
        if ($currentPid -eq $PID) { continue }

        $cim = $allProcs | Where-Object { [int]$_.ProcessId -eq $currentPid } | Select-Object -First 1
        if ($cim) {
            # R1-01: Must NOT be in pre-snapshot (new process created by this test)
            $isNewProcess = -not $script:PreSnapshot.ContainsKey($currentPid)
            if ($isNewProcess) {
                $captureSeq++
                $records += [PSCustomObject]@{
                    PID            = $currentPid
                    ParentPID      = [int]$cim.ParentProcessId
                    CreationDate   = $cim.CreationDate
                    CommandLine    = $cim.CommandLine
                    Depth          = $currentDepth
                    ExecutablePath = $cim.ExecutablePath
                    CaptureOrder   = $captureSeq
                }
            }
        }

        if ($byParent.ContainsKey($currentPid)) {
            foreach ($child in $byParent[$currentPid]) {
                $childPid = [int]$child.ProcessId
                if (-not $visited.ContainsKey($childPid)) {
                    $visited[$childPid] = $true
                    $queue.Enqueue([PSCustomObject]@{ PID = $childPid; Depth = $currentDepth + 1 })
                }
            }
        }
    }

    # R1-01: Unverified processes (CommandLine contains test dir but not BFS-proven) — logged only
    $unverified = @()
    foreach ($proc in $allProcs) {
        $procPid = [int]$proc.ProcessId
        if (-not $visited.ContainsKey($procPid) -and $procPid -ne $PID) {
            if ($proc.CommandLine -and $proc.CommandLine -like "*$TEST_DIR*") {
                $unverified += $procPid
            }
        }
    }
    if ($unverified.Count -gt 0) {
        Write-Host "  INFO: $($unverified.Count) unverified processes (NOT owned, NOT killed)" -ForegroundColor DarkYellow
    }

    $script:OwnedProcessRecords = $records
}

# R2-02: Stop-OwnedProcesses with four result categories
function Stop-OwnedProcesses {
    $killResults = @{
        Terminated      = @()
        AlreadyExited   = @()
        IdentityBlocked = @()  # Still running but identity unconfirmed — NOT killed, Gate-blocking
        Failed          = @()  # Identity confirmed but Kill/WaitForExit failed — FAIL
    }

    # R1-05: Sort by Depth DESC, then CaptureOrder ASC for deterministic ordering
    $sorted = $script:OwnedProcessRecords | Sort-Object -Property @{Expression={$_.Depth}; Descending=$true}, @{Expression={$_.CaptureOrder}; Descending=$false}

    foreach ($record in $sorted) {
        $processId = $record.PID
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.HasExited) {
            $killResults.AlreadyExited += $processId
            continue
        }

        # R1-01: Full identity re-verification
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
        if (-not $cim) {
            $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "CIM lookup failed" }
            continue
        }

        if ($cim.CreationDate -ne $record.CreationDate) {
            $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "CreationDate mismatch (PID reuse)" }
            continue
        }
        if ($record.CommandLine -and $cim.CommandLine -ne $record.CommandLine) {
            $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "CommandLine mismatch" }
            continue
        }
        if ($record.ExecutablePath -and $cim.ExecutablePath -ne $record.ExecutablePath) {
            $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "ExecutablePath mismatch" }
            continue
        }
        # R5-05: ParentPID identity check — exact equality, fail-closed
        if ($null -ne $record.ParentPID -and $null -ne $cim.ParentProcessId) {
            if ([int]$cim.ParentProcessId -ne $record.ParentPID) {
                $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "ParentProcessId mismatch (expected=$($record.ParentPID), actual=$([int]$cim.ParentProcessId))" }
                continue
            }
        } elseif ($null -ne $record.ParentPID -or $null -ne $cim.ParentProcessId) {
            # One has ParentPID, the other doesn't — cannot confirm identity
            $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "ParentProcessId unavailable (expected=$($record.ParentPID), actual=$($cim.ParentProcessId))" }
            continue
        }
        if ($processId -eq $PID) {
            $killResults.IdentityBlocked += [PSCustomObject]@{ PID = $processId; Reason = "Current PowerShell" }
            continue
        }

        # Verified — terminate
        try {
            $proc.Kill()
            $exited = $proc.WaitForExit(3000)
            if ($exited) {
                $killResults.Terminated += $processId
            } else {
                $killResults.Failed += [PSCustomObject]@{ PID = $processId; Reason = "WaitForExit timeout" }
            }
        } catch {
            $killResults.Failed += [PSCustomObject]@{ PID = $processId; Reason = "Kill exception: $($_.Exception.Message)" }
        }
    }

    return $killResults
}

# R1-02: Cleanup uses saved records, not re-BFS from dead launcher
function Invoke-Cleanup {
    param([string]$TestDir, [int]$Port, [bool]$Keep)

    $cleanupResults = @()

    # Step 1: Stop owned processes using SAVED records
    # R2-02: IdentityBlocked -> Gate-blocking; Failed -> MandatoryFunctional FAIL
    try {
        $killResult = Stop-OwnedProcesses
        $hasFailure = $killResult.Failed.Count -gt 0
        $hasIdentityBlock = $killResult.IdentityBlocked.Count -gt 0

        if ($hasFailure) {
            $failSummary = ($killResult.Failed | ForEach-Object { "PID=$($_.PID): $($_.Reason)" }) -join "; "
            $errMsg = "KILL-WAIT-FAILURE: Could not terminate: $failSummary"
            $cleanupResults += "Process cleanup: KILL FAILED ($($killResult.Failed.Count) failures)"
            # R4-01: Kill/Wait failure -> gate-blocking FAIL (exit 1), NOT ERROR/exit 3
            # Only script internal / cleanup framework exceptions -> ERROR/3
            Add-TestResult -TestId "CLEANUP-PROCESS" -Category "MandatoryFunctional" `
              -Description "Process cleanup: Kill/WaitForExit failure" `
              -Expected "Identity-confirmed processes terminated" `
              -Actual "Terminated=$($killResult.Terminated.Count), Failed=$($killResult.Failed.Count), IdentityBlocked=$($killResult.IdentityBlocked.Count)" `
              -Status "FAIL" -ErrorSummary $errMsg
            # R4-01: Do NOT set FatalInternalError or CleanupErrors for kill failures
        }

        if ($hasIdentityBlock) {
            $blockSummary = ($killResult.IdentityBlocked | ForEach-Object { "PID=$($_.PID): $($_.Reason)" }) -join "; "
            # R3-01: IdentityBlocked -> gate-blocking BLOCKED (exit 2), NOT ERROR/exit 3
            $cleanupResults += "Process cleanup: IDENTITY BLOCKED ($($killResult.IdentityBlocked.Count) unverified)"
            Add-TestResult -TestId "CLEANUP-IDENTITY" -Category "MandatoryFunctional" `
              -Description "Process cleanup: identity unconfirmed" `
              -Expected "All still-running processes have confirmed identity" `
              -Actual "IdentityBlocked=$($killResult.IdentityBlocked.Count): $blockSummary" `
              -Status "BLOCKED" -ErrorSummary "Processes still running but identity not confirmed; not killed"
            # R3-01: Do NOT set FatalInternalError or CleanupErrors
        }

        if (-not $hasFailure -and -not $hasIdentityBlock) {
            $cleanupResults += "Process cleanup: OK (terminated=$($killResult.Terminated.Count), exited=$($killResult.AlreadyExited.Count))"
        }
    } catch {
        $errMsg = "ERR-CLEANUP-PROCESS: $($_.Exception.Message)"
        $cleanupResults += "Process cleanup: EXCEPTION - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        Add-TestResult -TestId "CLEANUP-PROCESS" -Category "CleanupError" `
          -Description "Process cleanup phase" `
          -Expected "All owned processes terminated" `
          -Actual "Exception: $($_.Exception.Message)" -Status "FAIL" `
          -ErrorSummary $errMsg
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    # Step 2: Orphan check — use SAVED records
    try {
        Start-Sleep -Seconds 2
        $orphans = @()
        foreach ($record in $script:SavedProcessEvidence) {
            $p = Get-Process -Id $record.PID -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.PID)" -ErrorAction SilentlyContinue
                if ($cim -and $cim.CreationDate -eq $record.CreationDate) {
                    # R5-05: Full identity including ParentProcessId — fail-closed
                    $cmdMatch = (-not $record.CommandLine) -or ($cim.CommandLine -eq $record.CommandLine)
                    $exeMatch = (-not $record.ExecutablePath) -or ($cim.ExecutablePath -eq $record.ExecutablePath)
                    if ($null -ne $record.ParentPID -and $null -ne $cim.ParentProcessId) {
                        $ppidMatch = ([int]$cim.ParentProcessId -eq $record.ParentPID)
                    } else {
                        $ppidMatch = $false  # fail-closed
                    }
                    if ($cmdMatch -and $exeMatch -and $ppidMatch) {
                        $orphans += $record.PID
                    }
                }
            }
        }
        if ($orphans.Count -gt 0) {
            Add-TestResult -TestId "21" -Category "MandatoryFunctional" `
              -Description "Orphan process check" `
              -Expected "No test-owned processes still running after cleanup" `
              -Actual "Orphans: $($orphans -join ', ')" -Status "FAIL" `
              -ErrorSummary "Verified test processes survived cleanup"
            $cleanupResults += "Orphan check: FAIL ($($orphans.Count) orphans)"
        } else {
            Add-TestResult -TestId "21" -Category "MandatoryFunctional" `
              -Description "Orphan process check" `
              -Expected "No test-owned processes still running after cleanup" `
              -Actual "No orphans" -Status "PASS"
            $cleanupResults += "Orphan check: OK"
        }
    } catch {
        $errMsg = "ERR-CLEANUP-ORPHAN: $($_.Exception.Message)"
        $cleanupResults += "Orphan check: ERROR - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        Add-TestResult -TestId "CLEANUP-ORPHAN" -Category "CleanupError" `
          -Description "Orphan check phase" -Expected "Orphan check completes" `
          -Actual "Exception: $($_.Exception.Message)" -Status "FAIL" -ErrorSummary $errMsg
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    # Step 3: Port release
    try {
        $portUsed = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        if ($portUsed) {
            Add-TestResult -TestId "24" -Category "MandatoryFunctional" `
              -Description "Port release after cleanup" -Expected "Port $Port free" `
              -Actual "Port still in use" -Status "FAIL" -ErrorSummary "Port not released"
            $cleanupResults += "Port check: FAIL"
        } else {
            Add-TestResult -TestId "24" -Category "MandatoryFunctional" `
              -Description "Port release after cleanup" -Expected "Port $Port free" `
              -Actual "Port released" -Status "PASS"
            $cleanupResults += "Port check: OK"
        }
    } catch {
        $errMsg = "ERR-CLEANUP-PORT: $($_.Exception.Message)"
        $cleanupResults += "Port check: ERROR - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        Add-TestResult -TestId "CLEANUP-PORT" -Category "CleanupError" `
          -Description "Port check phase" -Expected "Port check completes" `
          -Actual "Exception: $($_.Exception.Message)" -Status "FAIL" -ErrorSummary $errMsg
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    # Step 4: Temp directory
    try {
        if (-not $Keep) {
            if (Test-Path $TestDir) {
                Remove-Item -Recurse -Force $TestDir -ErrorAction Stop
                Add-TestResult -TestId "25" -Category "MandatoryFunctional" `
                  -Description "Temp directory cleanup" -Expected "$TestDir removed" `
                  -Actual "Removed" -Status "PASS"
                $cleanupResults += "Temp cleanup: OK"
            } else {
                Add-TestResult -TestId "25" -Category "MandatoryFunctional" `
                  -Description "Temp directory cleanup" -Expected "$TestDir removed" `
                  -Actual "Not found" -Status "PASS"
                $cleanupResults += "Temp cleanup: OK (not found)"
            }
        } else {
            Add-TestResult -TestId "25" -Category "Informational" `
              -Description "Temp directory cleanup (user kept artifacts)" `
              -Expected "Skipped by user" -Actual "Kept at $TestDir" -Status "SKIPPED_BY_USER"
            $cleanupResults += "Temp cleanup: SKIPPED_BY_USER"
        }
    } catch {
        $errMsg = "ERR-CLEANUP-TEMPDIR: $($_.Exception.Message)"
        $cleanupResults += "Temp cleanup: FAILED - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        if (-not $Keep) {
            Add-TestResult -TestId "25" -Category "MandatoryFunctional" `
              -Description "Temp directory cleanup" -Expected "$TestDir removed" `
              -Actual "Failed: $($_.Exception.Message)" -Status "FAIL" `
              -ErrorSummary "Could not remove temp directory"
        }
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    return $cleanupResults
}

# === Config ===
$DSH_VERSION = "0.1.0-rc.8"
$TEST_PORT = 3080
$TEST_ID = "g0s1r3r3r1-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$TEST_DIR = Join-Path $env:TEMP "hawkai-$TEST_ID"
$DSH_HOME = Join-Path $TEST_DIR "dsh-home"
$WORKSPACE = Join-Path $TEST_DIR "workspace"
$script:HarnessProcess = $null

# ================================================================
# R3-REM-04: Fast fault child mode — skip all test execution
# Constructs deterministic valid suite records, injects fault, exits.
# This makes fault children complete in seconds instead of minutes.
# ================================================================
if ($SelfTestFastFault) {
    $script:SelfTestMode = $true
    $script:TestResults = @()

    # R5-REM-01: Write parent PID marker (identity evidence for process tree verification)
    if ($PLFToken -and $PLFMarkerDir -and (Test-Path $PLFMarkerDir)) {
        "$PLFToken|$PID|parent" | Out-File -FilePath (Join-Path $PLFMarkerDir "parent-$PID.txt") -Encoding ASCII -Force
    }

    # Construct deterministic valid suite records matching real test counts
    $script:SelfTestSuiteResults = @{
        'Aggregation'      = @{ Declared=11;  Actual=11;  Passed=11;  Failed=0 }
        'NativeJudgment'   = @{ Declared=24;  Actual=24;  Passed=24;  Failed=0 }
        'ParentPath'       = @{ Declared=4;   Actual=4;   Passed=4;   Failed=0 }
        'GateSummary'      = @{ Declared=15;  Actual=15;  Passed=15;  Failed=0 }
        'LockfileReader'   = @{ Declared=102; Actual=102; Passed=102; Failed=0 }
        'ManifestCompare'  = @{ Declared=14;  Actual=14;  Passed=14;  Failed=0 }
        'SuiteEvidence'    = @{ Declared=11;  Actual=11;  Passed=11;  Failed=0 }
    }

    # Inject fault
    $manifestComparisonForAggregation = $null
    $maxStreamBytes = 51200  # Must match Test-ProcessLevelFaults
    switch ($SelfTestFault) {
        'MissingSuite'      { $script:SelfTestSuiteResults.Remove('Aggregation') }
        'DeclaredMismatch'  { $script:SelfTestSuiteResults['Aggregation'].Declared = 999 }
        'PassedMismatch'    { $script:SelfTestSuiteResults['Aggregation'].Passed = 999 }
        'FailedNonZero'     { $script:SelfTestSuiteResults['Aggregation'].Failed = 1 }
        'ManifestMismatch'  { $manifestComparisonForAggregation = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("A","B","Z") }
        'Timeout'           {
            # R6-REM-02: Timeout child creates real descendant with identity evidence
            Write-Host "PRE-TIMEOUT-MARKER: $(Get-Date -Format 'o')"; [Console]::Out.Flush()
            if ($PLFToken -and $PLFMarkerDir -and (Test-Path $PLFMarkerDir)) {
                $descProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 300`" # TIMEOUT-DESC $PLFToken" -PassThru -WindowStyle Hidden
                "$PLFToken|$($descProc.Id)|timeout-descendant" | Out-File -FilePath (Join-Path $PLFMarkerDir "desc-$($descProc.Id).txt") -Encoding ASCII -Force
                Write-Host "PRE-TIMEOUT-DESCENDANT: PID=$($descProc.Id) token=$PLFToken"
                [Console]::Out.Flush()
            }
            Start-Sleep -Seconds 300
        }
        'StdoutOversize'    { $chunk = "X" * 1024; for ($i = 0; $i -lt 60; $i++) { [Console]::Out.Write($chunk + "`n") }; exit 3 }
        'StderrOversize'    { $chunk = "E" * 1024; for ($i = 0; $i -lt 60; $i++) { [Console]::Error.Write($chunk + "`n") }; exit 3 }
        'DualStreamOversize'{ $chunk = "D" * 1024; for ($i = 0; $i -lt 60; $i++) { [Console]::Out.Write($chunk + "`n"); [Console]::Error.Write($chunk + "`n") }; exit 3 }
        'LongLine'          { [Console]::Out.Write("L" * 61440 + "`n"); exit 3 }
        'BoundaryExact'     { [Console]::Out.Write("B" * ($maxStreamBytes - 1) + "`n"); exit 3 }
        'BoundaryOver'      { [Console]::Out.Write("O" * $maxStreamBytes + "`n"); exit 3 }
        'CleanupFailure'    {
            # R6-REM-02/05: Spawn a real descendant with token+role in command line (CIM-verifiable)
            $descProc = Start-Process powershell -ArgumentList "-NoProfile -Command `"Start-Sleep 300`" # $PLFToken cleanup-descendant" -PassThru -WindowStyle Hidden
            if ($PLFToken -and $PLFMarkerDir -and (Test-Path $PLFMarkerDir)) {
                # R6-REM-04: 3-field marker format: token|pid|role
                "$PLFToken|$($descProc.Id)|cleanup-descendant" | Out-File -FilePath (Join-Path $PLFMarkerDir "desc-$($descProc.Id).txt") -Encoding ASCII -Force
            }
            # Simulate cleanup failure: exit WITHOUT killing the descendant
            exit 3
        }
        'JobAssignFailure'  {
            # R8-REM-03: Signal job assignment failure and produce exit 3
            Write-Host "JOB-ASSIGN-FAILURE-INJECTED: $PLFToken"
            $script:SelfTestSuiteResults.Remove('Aggregation')
        }
        # R8: New fault fixtures — children exit cleanly; parent-side tests handle fault injection
        'ParentHandleRegFailure' { exit 0 }
        'DescendantHandleRegFailure' { exit 0 }
        'CollectorReadFailure' { exit 0 }
        'CollectorDrainTimeout' { exit 0 }
        'MarkerDeletionWhileLive' { exit 0 }
        'MarkerDeletionFailure' { exit 0 }
        'GetProcessTimesFailure' { exit 0 }
        'WaitFailure' { exit 0 }
        'CloseHandleFailure' { exit 0 }
        'MetaRoleMismatch' { exit 0 }
        'MetaTokenMismatch' { exit 0 }
        'MetaExtraEntry' { exit 0 }
        'MetaExtraMarker' { exit 0 }
        'MetaNullEvidence' { exit 0 }
    }

    # Call shared aggregation — same path as normal -SelfTestOnly
    $allSuites = @('Aggregation','NativeJudgment','ParentPath','GateSummary','LockfileReader','ManifestCompare','SuiteEvidence')
    $aggResult = Invoke-SelfTestAggregation `
      -SuiteResults $script:SelfTestSuiteResults `
      -AllSuites $allSuites `
      -ManifestComparison $manifestComparisonForAggregation `
      -PureTotal 54 -PurePassed 54 `
      -NodeTotal 102 -NodePassed 102 `
      -R15Total 53 -R15Passed 53

    Write-Host "`nSELF-TEST OVERALL: $($aggResult.Overall) (exit $($aggResult.ExitCode))" -ForegroundColor $(
        switch ($aggResult.Overall) { "PASS" { "Green" } "FAIL" { "Red" } "BLOCKED" { "Yellow" } "ERROR" { "Magenta" } }
    )

    # Print results table (same as normal path)
    Write-Host "`n=== SELF-TEST RESULTS ===" -ForegroundColor Cyan
    $script:TestResults | Format-Table TestId, Category, Status, Description -AutoSize

    $script:SelfTestMode = $false
    exit $aggResult.ExitCode
}

# ================================================================
# R3-R3-08 + R1-08: Run aggregation self-tests BEFORE any external operations
# R4-01: 11 test cases implemented (R4-01 expanded: kill+identityBlock combo).
# Runtime execution verified via self-test harness.
# ================================================================
# R5-REM-05: Heading dynamically generated inside Test-GetOverallResult
$script:SelfTestMode = $true  # R12-REV-12: Enable self-test mode for test injection parameters
$selfTestPassed = Test-GetOverallResult
if (-not $selfTestPassed) {
    Write-Host "FATAL: Aggregation self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST" -Category "ScriptInternal" `
      -Description "Aggregation self-test" `
      -Expected "All self-tests pass" `
      -Actual "One or more self-tests failed" -Status "FAIL" `
      -ErrorSummary "Aggregation self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Aggregation self-test failed"
    try {
        Write-Host "`n=== TEST RESULTS (aborted) ===" -ForegroundColor Cyan
        $script:TestResults | Format-Table TestId, Category, Status, Description -AutoSize
    } catch {}
    exit 3
}

# R5-01: Run native addon judgment self-test BEFORE any external operations
$nativeTestPassed = Test-NativeAddonJudgment
if (-not $nativeTestPassed) {
    Write-Host "FATAL: Native addon judgment self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST-NATIVE" -Category "ScriptInternal" `
      -Description "Native addon judgment self-test" `
      -Expected "All native judgment self-tests pass" `
      -Actual "One or more native judgment self-tests failed" -Status "FAIL" `
      -ErrorSummary "Native judgment self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Native judgment self-test failed"
    exit 3
}

# R6-03: Run Resolve-LockfileParentPath self-test BEFORE any external operations
# R5-REM-05: Heading dynamically generated inside Test-ResolveLockfileParentPath
$parentPathTestPassed = Test-ResolveLockfileParentPath
if (-not $parentPathTestPassed) {
    Write-Host "FATAL: Resolve-LockfileParentPath self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST-PARENTPATH" -Category "ScriptInternal" `
      -Description "Resolve-LockfileParentPath self-test" `
      -Expected "All parent path self-tests pass" `
      -Actual "One or more parent path self-tests failed" -Status "FAIL" `
      -ErrorSummary "Resolve-LockfileParentPath self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Resolve-LockfileParentPath self-test failed"
    exit 3
}

# R6-04: Run Native Gate Summary self-test BEFORE any external operations
# R5-REM-05: Heading dynamically generated inside Test-NativeGateSummary
$gateSummaryTestPassed = Test-NativeGateSummary
if (-not $gateSummaryTestPassed) {
    Write-Host "FATAL: Native Gate Summary self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST-GATESUMMARY" -Category "ScriptInternal" `
      -Description "Native Gate Summary self-test" `
      -Expected "All gate summary self-tests pass" `
      -Actual "One or more gate summary self-tests failed" -Status "FAIL" `
      -ErrorSummary "Native Gate Summary self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Native Gate Summary self-test failed"
    exit 3
}

# R11-REV-12: Pure-function self-tests run first, then Node-backed tests.

# R11-REV-12: Resolve-NodeExecutable check BEFORE Node-backed tests
# If Node is not found, report as EvidenceDependent/BLOCKED/exit 2 (not ERROR/3)
Write-Host "`n=== Node executable resolution check ===" -ForegroundColor Cyan
$nodeResolution = Resolve-NodeExecutable
if (-not $nodeResolution.Path -or $nodeResolution.Error -ne "") {
    Write-Host "BLOCKED: Node executable resolution failed: $($nodeResolution.Error)" -ForegroundColor Yellow
    Add-TestResult -TestId "SELFTEST-NODECHECK" -Category "EvidenceDependent" `
      -Description "Node executable resolution" `
      -Expected "Exactly one Node Application found, path valid, no ambiguity" `
      -Actual "Error: $($nodeResolution.Error)" -Status "BLOCKED" `
      -ErrorSummary "EvidenceDependent: Node-backed tests cannot run"
    Write-Host "`n=== RESULT: EvidenceDependent/BLOCKED (exit 2) ===" -ForegroundColor Yellow
    exit 2
} else {
    Write-Host "  Node resolved: $($nodeResolution.Path)" -ForegroundColor Green
}

# R11-REV-12: Test-LockfileReader runs AFTER Node is confirmed available
# R9-REV-07: Test-LockfileReader is defined but was never called in the pre-external-operation sequence.
# This invocation ensures the 40 reader test cases are executed in every full-script run.
# R5-REM-05: Heading dynamically generated inside Test-LockfileReader
$lockfileReaderTestPassed = Test-LockfileReader
if (-not $lockfileReaderTestPassed) {
    Write-Host "FATAL: Lockfile Reader self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST-LOCKFILEREADER" -Category "ScriptInternal" `
      -Description "Lockfile Reader self-test" `
      -Expected "All lockfile reader self-tests pass" `
      -Actual "One or more lockfile reader self-tests failed" -Status "FAIL" `
      -ErrorSummary "Lockfile Reader self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Lockfile Reader self-test failed"
    exit 3
}

# R15-REV-02: Run Compare-TestManifest self-test BEFORE any external operations
# R5-REM-05: Heading dynamically generated inside Test-CompareTestManifest
$manifestCompareTestPassed = Test-CompareTestManifest
if (-not $manifestCompareTestPassed) {
    Write-Host "FATAL: Compare-TestManifest self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST-MANIFESTCOMPARE" -Category "ScriptInternal" `
      -Description "Compare-TestManifest self-test" `
      -Expected "All manifest comparison self-tests pass" `
      -Actual "One or more manifest comparison self-tests failed" -Status "FAIL" `
      -ErrorSummary "Compare-TestManifest self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Compare-TestManifest self-test failed"
    exit 3
}

# R15-REV-01: Run Suite Evidence fault-injection self-test BEFORE any external operations
# R5-REM-05: Heading dynamically generated inside Test-SuiteEvidence
$suiteEvidenceTestPassed = Test-SuiteEvidence
if (-not $suiteEvidenceTestPassed) {
    Write-Host "FATAL: Suite Evidence fault-injection self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST-SUITEEVIDENCE" -Category "ScriptInternal" `
      -Description "Suite Evidence fault-injection self-test" `
      -Expected "All suite evidence self-tests pass" `
      -Actual "One or more suite evidence self-tests failed" -Status "FAIL" `
      -ErrorSummary "Suite Evidence self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Suite Evidence self-test failed"
    exit 3
}

# R15-REM-01: Run process-level fault fixture self-test
# Skip when running inside a fault subprocess to prevent recursive launching
if ($SelfTestFault -eq 'None') {
    # R5-REM-05: Heading dynamically generated inside Test-ProcessLevelFaults
    $processLevelTestPassed = Test-ProcessLevelFaults
    if (-not $processLevelTestPassed) {
        Write-Host "FATAL: Process-Level Fault self-test failed. Aborting." -ForegroundColor Red
        Add-TestResult -TestId "SELFTEST-PROCESSFAULTS" -Category "ScriptInternal" `
          -Description "Process-Level fault self-test" `
          -Expected "All process-level fault tests return exit 3" `
          -Actual "One or more process-level fault tests did not return exit 3" -Status "FAIL" `
          -ErrorSummary "Process-Level fault self-test failed before harness launch"
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = "Process-Level fault self-test failed"
        exit 3
    }
} else {
    # R2-REM-01: Do NOT record skipped tests as PASS — exclude from aggregation entirely
    Write-Host "=== Process-Level Fault self-test SKIPPED (inside fault subprocess) ===" -ForegroundColor Yellow
}

$script:SelfTestMode = $false  # R12-REV-12: Disable self-test mode after all self-tests pass

# R15-REM-01: SelfTestFault injection — corrupt suite data before aggregation
# Only runs when -SelfTestOnly -SelfTestFault <fault> is specified
$manifestComparisonForAggregation = $null
if ($SelfTestFault -ne 'None') {
    switch ($SelfTestFault) {
        'MissingSuite' { $script:SelfTestSuiteResults.Remove('Aggregation') }
        'DeclaredMismatch' { $script:SelfTestSuiteResults['Aggregation'].Declared = 999 }
        'PassedMismatch' { $script:SelfTestSuiteResults['Aggregation'].Passed = 999 }
        'FailedNonZero' { $script:SelfTestSuiteResults['Aggregation'].Failed = 1 }
        'ManifestMismatch' {
            $manifestComparisonForAggregation = Compare-TestManifest -ExpectedNames @("A","B","C") -ActualNames @("A","B","Z")
        }
    }
}

# R12-REV-11: Self-test-only mode exit point
# All self-tests have passed. Report results and exit before main flow.
if ($SelfTestOnly) {
    # R15-REM-01: Compute displayed totals
    $pureTotal = 0; $purePassed = 0
    foreach ($suiteName in @('Aggregation','NativeJudgment','ParentPath','GateSummary')) {
        $sr = $script:SelfTestSuiteResults[$suiteName]
        if ($sr) { $pureTotal += $sr.Actual; $purePassed += $sr.Passed }
    }
    $nodeTotal = 0; $nodePassed = 0
    $srLR = $script:SelfTestSuiteResults['LockfileReader']
    if ($srLR) { $nodeTotal = $srLR.Actual; $nodePassed = $srLR.Passed }
    $r15Total = 0; $r15Passed = 0
    foreach ($suiteName in @('ManifestCompare','SuiteEvidence','ProcessLevelFaults','FocusedNegatives')) {
        $sr = $script:SelfTestSuiteResults[$suiteName]
        if ($sr) { $r15Total += $sr.Actual; $r15Passed += $sr.Passed }
    }

    # R2-REM-01: Build suite list dynamically — only include suites that are actually recorded
    # In fault mode, ProcessLevelFaults may be skipped and not recorded
    $allSuites = @('Aggregation','NativeJudgment','ParentPath','GateSummary','LockfileReader','ManifestCompare','SuiteEvidence')
    if ($script:SelfTestSuiteResults.ContainsKey('ProcessLevelFaults')) {
        $allSuites += 'ProcessLevelFaults'
    }
    if ($script:SelfTestSuiteResults.ContainsKey('FocusedNegatives')) {
        $allSuites += 'FocusedNegatives'
    }
    $aggResult = Invoke-SelfTestAggregation `
      -SuiteResults $script:SelfTestSuiteResults `
      -AllSuites $allSuites `
      -ManifestComparison $manifestComparisonForAggregation `
      -NodeResolution $nodeResolution `
      -PureTotal $pureTotal -PurePassed $purePassed `
      -NodeTotal $nodeTotal -NodePassed $nodePassed `
      -R15Total $r15Total -R15Passed $r15Passed

    Write-Host "`nSELF-TEST OVERALL: $($aggResult.Overall) (exit $($aggResult.ExitCode))" -ForegroundColor $(
        switch ($aggResult.Overall) { "PASS" { "Green" } "FAIL" { "Red" } "BLOCKED" { "Yellow" } "ERROR" { "Magenta" } }
    )

    # Output structured results for harness consumption
    Write-Host "`n=== SELF-TEST RESULTS ===" -ForegroundColor Cyan
    $script:TestResults | Format-Table TestId, Category, Status, Description -AutoSize

    $script:SelfTestMode = $false  # R12-REV-12: Disable self-test mode before exit
    exit $aggResult.ExitCode
}

# === Main execution ===
$cleanupLog = @()
$mainError = $null

try {
    Write-Host "`n=== HawkAIAgent G0-S1-R3-R3-R1 Windows PoC ===" -ForegroundColor Cyan
    Write-Host "Test ID: $TEST_ID"
    Write-Host "Test dir: $TEST_DIR"

    New-Item -ItemType Directory -Path $DSH_HOME -Force | Out-Null
    New-Item -ItemType Directory -Path $WORKSPACE -Force | Out-Null

    # ================================================================
    # Test 1: Environment
    # ================================================================
    Write-Host "`n=== Test 1: Environment ===" -ForegroundColor Cyan
    $winVer = [System.Environment]::OSVersion.VersionString
    $arch = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    $nodeVer = $null; $npmVer = $null; $psVer = $PSVersionTable.PSVersion
    try { $nodeVer = (node -v 2>&1) | Out-String } catch {}
    try { $npmVer = (npm -v 2>&1) | Out-String } catch {}
    if ($nodeVer) { $nodeVer = $nodeVer.Trim() }
    if ($npmVer) { $npmVer = $npmVer.Trim() }

    Write-Host "Windows: $winVer | Arch: $arch | PS: $psVer | Node: $nodeVer | npm: $npmVer"

    $isWin11 = $winVer -match "10\.0\.22" -or $winVer -match "10\.0\.26"
    $isX64 = $arch -eq "x64"
    $hasNode = $nodeVer -and $nodeVer -match "^v\d+\."
    $hasNpm = $npmVer -and $npmVer -match "^\d+\."

    if (-not $hasNode -or -not $hasNpm) {
        Add-TestResult -TestId "1" -Category "MandatoryFunctional" `
          -Description "Environment" -Expected "Windows 11 x64 with Node.js and npm" `
          -Actual "Node=$nodeVer, npm=$npmVer, $winVer, $arch" -Status "BLOCKED" `
          -ErrorSummary "Node.js or npm not available"
        throw [PrerequisiteBlocked]::new("1", "Node.js or npm not available")
    }

    $envStatus = "PASS"; $envError = ""
    if (-not $isWin11) { $envStatus = "BLOCKED"; $envError = "Not Windows 11" }
    elseif (-not $isX64) { $envStatus = "BLOCKED"; $envError = "Not x64" }

    Add-TestResult -TestId "1" -Category "MandatoryFunctional" `
      -Description "Environment" -Expected "Windows 11 x64, Node.js, npm" `
      -Actual "$winVer, $arch, PS $psVer, Node $nodeVer, npm $npmVer" `
      -Status $envStatus -ErrorSummary $envError

    if ($envStatus -eq "BLOCKED") { throw [PrerequisiteBlocked]::new("1", $envError) }

    # ================================================================
    # Test 2: Port availability
    # ================================================================
    Write-Host "`n=== Test 2: Port availability ===" -ForegroundColor Cyan
    $portUsed = Get-NetTCPConnection -LocalPort $TEST_PORT -ErrorAction SilentlyContinue
    if ($portUsed) {
        $portPid = ($portUsed | Select-Object -First 1).OwningProcess
        Add-TestResult -TestId "2" -Category "MandatoryFunctional" `
          -Description "Port $TEST_PORT available" -Expected "Port free" `
          -Actual "Port in use by PID $portPid" -Status "BLOCKED" -ErrorSummary "Port already in use"
        throw [PrerequisiteBlocked]::new("2", "Port $TEST_PORT in use")
    }
    Add-TestResult -TestId "2" -Category "MandatoryFunctional" `
      -Description "Port $TEST_PORT available" -Expected "Port free" -Actual "Port free" -Status "PASS"

    # ================================================================
    # Pre-test process snapshot
    # ================================================================
    Write-Host "`n=== Pre-test process snapshot ===" -ForegroundColor Cyan
    $script:PreSnapshot = Save-ProcessSnapshot
    Write-Host "Pre-existing processes: $($script:PreSnapshot.Count)"

    # ================================================================
    # Test 3: Install dsh
    # ================================================================
    Write-Host "`n=== Test 3: Install @deepseek-ai/dsh@$DSH_VERSION ===" -ForegroundColor Cyan
    $env:DSH_HOME = $DSH_HOME

    Push-Location $TEST_DIR
    try {
        npm init -y 2>&1 | Out-Null
        npm install "@deepseek-ai/dsh@$DSH_VERSION" 2>&1 | Tee-Object -Variable installOutput
        $installExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($installExit -ne 0) {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh" -Expected "npm install exit code 0" `
          -Actual "Exit code $installExit" -Status "FAIL" -ErrorSummary "npm install failed"
        throw [AssertionFailure]::new("3", "npm install failed with exit code $installExit")
    }

    $dshBin = Join-Path $TEST_DIR "node_modules" ".bin" "dsh.cmd"
    if (-not (Test-Path $dshBin)) {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh" -Expected "dsh.cmd exists" `
          -Actual "Not found at $dshBin" -Status "FAIL" -ErrorSummary "Binary not found after install"
        throw [AssertionFailure]::new("3", "dsh.cmd not found")
    }

    $dshVersionOut = $null
    try {
        $dshVersionOut = (& $dshBin --version 2>&1) | Out-String
        $dshVersionExit = $LASTEXITCODE
    } catch { $dshVersionExit = -1 }
    if ($dshVersionOut) { $dshVersionOut = $dshVersionOut.Trim() }

    if ($dshVersionExit -ne 0 -or -not $dshVersionOut) {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh" -Expected "Exit code 0, version non-empty" `
          -Actual "exit=$dshVersionExit, output='$dshVersionOut'" -Status "FAIL" `
          -ErrorSummary "dsh --version failed or returned empty"
    } else {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh" -Expected "Exit code 0, dsh.cmd exists" `
          -Actual "Exit 0, version: $dshVersionOut" -Status "PASS"
    }

    # ================================================================
    # Test 4: Lockfile version
    # ================================================================
    Write-Host "`n=== Test 4: Lockfile version ===" -ForegroundColor Cyan
    $lockfile = Join-Path $TEST_DIR "package-lock.json"
    $lockfileVer = $null; $installedVer = $null; $requestedVer = $DSH_VERSION; $versionErrors = @()

    if (-not (Test-Path $lockfile)) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version" -Expected "requested==lockfile==installed" `
          -Actual "No lockfile" -Status "FAIL" -ErrorSummary "Lockfile not generated"
        throw [AssertionFailure]::new("4", "No lockfile")
    }

    # R9-01: Use safe lockfile reader (PS5.1 can't handle empty-string keys)
    # R10-06: Parser failure must produce EvidenceDependent/BLOCKED, not MandatoryFunctional/FAIL
    $lockResult = ConvertFrom-LockfileSafe -LockfilePath $lockfile
    if (-not $lockResult.Parsed) {
        # R10-06: Lockfile evidence failure = gate-blocking BLOCKED (not FAIL)
        $versionErrors += "Lockfile parse error: $($lockResult.Error)"
        Add-TestResult -TestId "4" -Category "EvidenceDependent" `
          -Description "Lockfile version" -Expected "Lockfile parsed successfully" `
          -Actual "Lockfile parse failed: $($lockResult.Error)" `
          -Status "BLOCKED" -ErrorSummary "BLOCKED — lockfile evidence unavailable; cannot verify version"
    } else {
        $lockDsh = $lockResult.Packages["node_modules/@deepseek-ai/dsh"]
        if ($lockDsh -and $lockDsh.version) { $lockfileVer = $lockDsh.version }
        else { $versionErrors += "dsh not in lockfile or version field missing" }

        $installedPkg = Join-Path $TEST_DIR "node_modules" "@deepseek-ai" "dsh" "package.json"
        if (Test-Path $installedPkg) {
            try {
                $installedPkgContent = Get-Content $installedPkg -Raw | ConvertFrom-Json
                if ($installedPkgContent.version) { $installedVer = $installedPkgContent.version }
                else { $versionErrors += "Installed package.json has no version field" }
            } catch { $versionErrors += "Installed package.json parse error: $($_.Exception.Message)" }
        } else { $versionErrors += "Installed package.json not found" }

        if ($versionErrors.Count -gt 0) {
            Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
              -Description "Lockfile version" -Expected "requested==lockfile==installed" `
              -Actual "requested=$requestedVer, lockfile=$lockfileVer, installed=$installedVer" `
              -Status "FAIL" -ErrorSummary ($versionErrors -join "; ")
        } elseif ($requestedVer -ne $lockfileVer -or $requestedVer -ne $installedVer) {
            Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
              -Description "Lockfile version" -Expected "requested==lockfile==installed" `
              -Actual "requested=$requestedVer, lockfile=$lockfileVer, installed=$installedVer" `
              -Status "FAIL" -ErrorSummary "Version mismatch"
        } else {
            Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
              -Description "Lockfile version" -Expected "requested==lockfile==installed" `
              -Actual "requested=$requestedVer, lockfile=$lockfileVer, installed=$installedVer" -Status "PASS"
        }
    }

    # ================================================================
    # Test 5: npm ls --all --json
    # ================================================================
    Write-Host "`n=== Test 5: npm ls ===" -ForegroundColor Cyan
    $npmLsJson = $null; $npmLsExit = -1; $npmLsError = $null
    Push-Location $TEST_DIR
    try {
        $npmLsRaw = (npm ls --all --json 2>&1) | Out-String
        $npmLsExit = $LASTEXITCODE
        if ($npmLsRaw) { try { $npmLsJson = $npmLsRaw | ConvertFrom-Json } catch { $npmLsError = "JSON parse failed" } }
        else { $npmLsError = "Empty output" }
    } catch { $npmLsError = "Command failed" }
    finally { Pop-Location }

    if ($npmLsExit -eq 0 -and $npmLsJson) {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls integrity" -Expected "Exit 0, valid JSON" `
          -Actual "Exit $npmLsExit, JSON parsed" -Status "PASS"
    } else {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls integrity" -Expected "Exit 0, valid JSON" `
          -Actual "Exit $npmLsExit. $npmLsError" -Status "FAIL" -ErrorSummary "npm ls reported issues"
    }
    # ================================================================
    # Test 6: Native addon detection (R1-07: transitive deps from lockfile)
    # R6-01: Blocked resolution state enters gate via Get-NativeGateSummary
    # R6-02: Lockfile parsing fail-closed — no empty catch
    # R6-03: Parent path via Resolve-LockfileParentPath (single implementation)
    # R6-04: Gate determination via Get-NativeGateSummary (pure function)
    # ================================================================
    Write-Host "`n=== Test 6: Native addon detection ===" -ForegroundColor Cyan

    $nativeDepsToCheck = @("node-pty", "koffi", "better-sqlite3", "sqlite3", "node-pty-prebuilt-multiarch")
    $foundNative = @()

    # R6-02: Explicit lockfile parse status — fail-closed
    $lockfileParsed = $false
    $lockfileParseError = ""
    $lockfileJson = $null
    $transitiveNativeExpected = @{}

    # R9-01: Use safe lockfile reader (PS5.1 can't handle empty-string keys in ConvertFrom-Json)
    $lockResult = ConvertFrom-LockfileSafe -LockfilePath $lockfile
    if (-not $lockResult.Parsed) {
        $lockfileParseError = $lockResult.Error
    } else {
        $lockfileParsed = $true
        $lockfilePackages = $lockResult.Packages  # Hashtable: exact path -> package data
    }

    if ($lockfileParsed) {
        # R12-REV-03: Use shared ConvertFrom-TransitiveMapping instead of inline loop
        $transitiveNativeExpected = ConvertFrom-TransitiveMapping `
          -LockfilePackages $lockfilePackages `
          -NativeDepsToCheck $nativeDepsToCheck `
          -TargetOs "win32" -TargetCpu "x64"
    } else {
        Write-Host "  Lockfile parse failed: $lockfileParseError" -ForegroundColor Yellow
    }

    foreach ($depName in $nativeDepsToCheck) {
        $found = Get-ChildItem -Path (Join-Path $TEST_DIR "node_modules") -Filter $depName -Recurse -Directory -ErrorAction SilentlyContinue
        foreach ($foundDir in $found) {
            # R14-REV-01: Extract package.json info, then use shared function
            $pkgJsonPath = Join-Path $foundDir.FullName "package.json"
            $ver = "unknown"
            $pkgJsonError = ""

            if (Test-Path $pkgJsonPath) {
                try {
                    $pkgContent = Get-Content $pkgJsonPath -Raw | ConvertFrom-Json
                    if ($pkgContent.version) { $ver = $pkgContent.version }
                } catch {
                    $pkgJsonError = "package.json parse failure: $($_.Exception.Message)"
                }
            } else {
                $pkgJsonError = "package.json not found"
            }

            # R5-04: Normalize lockfile instance path (no depName fallback)
            $normalizedPath = $foundDir.FullName -replace [regex]::Escape((Join-Path $TEST_DIR "node_modules") + [System.IO.Path]::DirectorySeparatorChar), ""
            $normalizedPath = "node_modules/$($normalizedPath -replace [regex]::Escape([System.IO.Path]::DirectorySeparatorChar), '/')"

            # R14-REV-01: Look up mapping entry (null if lockfile unavailable or dep not in mapping)
            $mappingEntry = $null
            if ($lockfileParsed -and $transitiveNativeExpected.ContainsKey($normalizedPath)) {
                $mappingEntry = $transitiveNativeExpected[$normalizedPath]
            }

            # Real load evidence — never synthetic
            $loadExit = -1; $loadOutput = ""
            Push-Location $TEST_DIR
            try {
                $nodeRequire = "try { require('$($foundDir.FullName -replace '\\','/'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }"
                $loadOutput = (node -e $nodeRequire 2>&1) | Out-String
                $loadExit = $LASTEXITCODE
            } catch { $loadOutput = $_.Exception.Message }
            finally { Pop-Location }

            # R14-REV-01: Use shared conversion function (same as F23/F23c/F23d)
            $foundNative += ConvertFrom-MappingToInstanceResult `
                -MappingEntry $mappingEntry `
                -InstancePath $normalizedPath `
                -InstalledPath $foundDir.FullName `
                -Version $ver `
                -PackageJsonError $pkgJsonError `
                -LoadExit $loadExit `
                -LoadOutput $(if ($loadOutput) { $loadOutput.Trim() } else { "" })
        }
    }

    # R6-04: Gate determination via Get-NativeGateSummary pure function
    $gateResult = Get-NativeGateSummary -InstanceResults $foundNative -LockfileParsed $lockfileParsed -LockfileParseError $lockfileParseError

    # R6-01: No native dirs found and lockfile not parsed → BLOCKED (not Informational/PASS)
    if ($foundNative.Count -eq 0 -and -not $lockfileParsed) {
        Add-TestResult -TestId "6" -Category "EvidenceDependent" -Description "Native addon detection" -Expected "Lockfile parsed" -Actual "Lockfile not parsed: $lockfileParseError" -Status "BLOCKED" -ErrorSummary "BLOCKED — lockfile not parsed; cannot determine native dependency status"
    } else {
        Add-TestResult -TestId "6" -Category $gateResult.Category -Description $gateResult.Description -Expected $gateResult.Expected -Actual $gateResult.Actual -Status $gateResult.Status -ErrorSummary $gateResult.ErrorSummary
    }
    $testModules = @("@deepseek-ai/dsh-client-connection", "@deepseek-ai/dsh-api-remotes", "@deepseek-ai/dsh-api-gateway")
    $moduleResults = @(); $anyModuleFailed = $false

    foreach ($mod in $testModules) {
        $exists = Test-Path (Join-Path $TEST_DIR "node_modules" ($mod -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        $loadExit = -1; $loadOutput = ""
        Push-Location $TEST_DIR
        try {
            $loadOutput = (node -e "try { require('$mod'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }" 2>&1) | Out-String
            $loadExit = $LASTEXITCODE
        } catch { $loadOutput = $_.Exception.Message }
        finally { Pop-Location }

        $loadOutputTrimmed = if ($loadOutput) { $loadOutput.Trim() } else { "" }
        $moduleResults += "$mod : exists=$exists, exit=$loadExit"
        if ($loadExit -ne 0) { $anyModuleFailed = $true; $moduleResults[-1] += ", error=$loadOutputTrimmed" }
    }

    if ($anyModuleFailed) {
        Add-TestResult -TestId "7" -Category "MandatoryFunctional" `
          -Description "Client packages resolution" -Expected "All 3 packages require() exit 0" `
          -Actual ($moduleResults -join "; ") -Status "FAIL" -ErrorSummary "Client package load failure"
    } else {
        Add-TestResult -TestId "7" -Category "MandatoryFunctional" `
          -Description "Client packages resolution" -Expected "All 3 packages require() exit 0" `
          -Actual ($moduleResults -join "; ") -Status "PASS"
    }

    # ================================================================
    # Test 8: Harness startup
    # ================================================================
    Write-Host "`n=== Test 8: Harness startup ===" -ForegroundColor Cyan
    $env:DEEPSEEK_API_KEY = ""
    $stdoutLog = Join-Path $TEST_DIR "stdout.log"
    $stderrLog = Join-Path $TEST_DIR "stderr.log"
    $preHarnessSnapshot = Save-ProcessSnapshot

    $script:HarnessProcess = Start-Process -FilePath $dshBin `
      -ArgumentList "web", "--no-open", "--port", $TEST_PORT `
      -PassThru -RedirectStandardOutput $stdoutLog `
      -RedirectStandardError $stderrLog -NoNewWindow `
      -WorkingDirectory $WORKSPACE

    $script:HarnessLauncherPid = $script:HarnessProcess.Id

    # R1-01: Record launcher CreationDate from CIM for ownership verification
    $launcherCim = Get-CimInstance Win32_Process -Filter "ProcessId = $script:HarnessLauncherPid" -ErrorAction SilentlyContinue
    if ($launcherCim) {
        $script:HarnessLauncherCreationDate = $launcherCim.CreationDate
    }

    Write-Host "Harness launcher PID: $($script:HarnessLauncherPid) (CreationDate=$($script:HarnessLauncherCreationDate))"

    # R1-03: Identify Harness Node ONLY from owned tree
    Start-Sleep -Seconds 2
    $postLaunchSnapshot = Save-ProcessSnapshot
    $newProcessRecords = @()
    foreach ($kv in $postLaunchSnapshot.GetEnumerator()) {
        if (-not $preHarnessSnapshot.ContainsKey($kv.Key)) {
            $newProcessRecords += $kv.Value
        }
    }

    # R1-01: Update owned processes using verified launcher
    Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid -LauncherCreationDate $script:HarnessLauncherCreationDate

    # R1-03: Select Harness Node ONLY from owned records
    # R8-02: @() for PS 5.1 scalar-safe pipeline (.Count used below)
    $candidateNodes = @($script:OwnedProcessRecords | Where-Object {
        $_.Name -eq "node.exe" -and $_.CommandLine -and $_.CommandLine -like "*dsh*"
    })
    if ($candidateNodes.Count -gt 0) {
        # R1-03: Pick the deepest one (most likely the actual harness, not a launcher wrapper)
        $script:HarnessNodePid = ($candidateNodes | Sort-Object -Property Depth -Descending | Select-Object -First 1).PID
    }
    if (-not $script:HarnessNodePid) {
        # Fallback: any node.exe in owned tree
        $anyNode = $script:OwnedProcessRecords | Where-Object { $_.Name -eq "node.exe" } | Sort-Object -Property Depth -Descending | Select-Object -First 1
        if ($anyNode) { $script:HarnessNodePid = $anyNode.PID }
    }

    if ($script:HarnessNodePid) {
        Write-Host "Harness Node PID: $($script:HarnessNodePid)"
    } else {
        Write-Host "WARNING: Could not identify Harness Node PID from owned tree" -ForegroundColor Yellow
    }

    # Readiness probe
    $maxWait = 30
    for ($i = 0; $i -lt $maxWait; $i++) {
        Start-Sleep -Seconds 1
        if ($script:HarnessProcess.HasExited) {
            Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
              -Description "Harness startup" -Expected "host.describe returns 200 within ${maxWait}s" `
              -Actual "Process exited prematurely (code $($script:HarnessProcess.ExitCode))" `
              -Status "FAIL" -ErrorSummary "Harness exited before readiness"
            break
        }
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $script:HarnessReady = $true
                Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid -LauncherCreationDate $script:HarnessLauncherCreationDate
                Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
                  -Description "Harness startup" -Expected "host.describe returns 200" `
                  -Actual "Ready after $($i + 1) seconds" -Status "PASS"
                break
            }
        } catch {}
    }

    if (-not $script:HarnessReady -and -not $script:HarnessProcess.HasExited) {
        Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
          -Description "Harness startup" -Expected "host.describe returns 200" `
          -Actual "Readiness timeout after ${maxWait}s" -Status "FAIL" -ErrorSummary "Harness did not become ready"
    }

    # ================================================================
    # Tests 9-14: HTTP and WS upgrade tests (unchanged logic)
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 9: host.describe ===" -ForegroundColor Cyan
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" -Method POST -ContentType "application/json" -Body '{"method":"host.describe"}' -TimeoutSec 5
            $statusOk = $response.StatusCode -eq 200
            $bodyNonEmpty = $null -ne $response.Content -and $response.Content.Length -gt 0
            $parsed = $null; $parseError = $null
            if ($bodyNonEmpty) { try { $parsed = $response.Content | ConvertFrom-Json } catch { $parseError = $_.Exception.Message } }

            if (-not $statusOk) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "HTTP 200 + JSON + result/error" -Actual "HTTP $($response.StatusCode)" -Status "FAIL" -ErrorSummary "Non-200"
            } elseif (-not $bodyNonEmpty) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "HTTP 200 + JSON + result/error" -Actual "Empty body" -Status "FAIL" -ErrorSummary "Empty"
            } elseif (-not $parsed) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "HTTP 200 + JSON + result/error" -Actual "JSON parse failed: $parseError" -Status "FAIL" -ErrorSummary "Invalid JSON"
            } else {
                $hasResult = $null -ne $parsed.result; $hasError = $null -ne $parsed.error
                if (-not $hasResult -and -not $hasError) {
                    Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "JSON with result or error" -Actual "Keys: $($parsed.PSObject.Properties.Name -join ', ')" -Status "FAIL" -ErrorSummary "No result/error"
                } else {
                    Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "HTTP 200 + JSON + result/error" -Actual "HTTP 200, result=$hasResult, error=$hasError" -Status "PASS"
                }
            }
        } catch {
            Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "HTTP 200 + JSON" -Actual "Failed: $($_.Exception.Message)" -Status "FAIL"
        }
    } else {
        Add-TestResult -TestId "9" -Category "MandatoryFunctional" -Description "host.describe" -Expected "HTTP 200 + JSON" -Actual "BLOCKED" -Status "BLOCKED"
    }

    # Tests 10-12: Security fences (same logic, abbreviated)
    foreach ($secTest in @(
        @{ Id="10"; Desc="Content-Type fence"; Body='{"method":"host.describe"}'; CT="text/plain"; Headers=@{} },
        @{ Id="11"; Desc="Invalid Origin"; Body='{"method":"host.describe"}'; CT="application/json"; Headers=@{"Origin"="http://evil.com"} },
        @{ Id="12"; Desc="Invalid Host"; Body='{"method":"host.describe"}'; CT="application/json"; Headers=@{"Host"="example.com:3080"} }
    )) {
        if ($script:HarnessReady) {
            Write-Host "`n=== Test $($secTest.Id): $($secTest.Desc) ===" -ForegroundColor Cyan
            try {
                $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" -Method POST -ContentType $secTest.CT -Body $secTest.Body -Headers $secTest.Headers -TimeoutSec 5 -ErrorAction Stop
                Add-TestResult -TestId $secTest.Id -Category "MandatorySecurity" -Description $secTest.Desc -Expected "4xx rejection" -Actual "Accepted HTTP $($response.StatusCode)" -Status "FAIL" -ErrorSummary "Security fence not enforced"
            } catch {
                $statusCode = 0; try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
                if ($statusCode -ge 400 -and $statusCode -lt 500) {
                    Add-TestResult -TestId $secTest.Id -Category "MandatorySecurity" -Description $secTest.Desc -Expected "4xx" -Actual "Rejected HTTP $statusCode" -Status "PASS"
                } elseif ($statusCode -gt 0) {
                    Add-TestResult -TestId $secTest.Id -Category "MandatorySecurity" -Description $secTest.Desc -Expected "4xx" -Actual "HTTP $statusCode" -Status "FAIL"
                } else {
                    Add-TestResult -TestId $secTest.Id -Category "MandatorySecurity" -Description $secTest.Desc -Expected "4xx" -Actual "Connection error" -Status "BLOCKED"
                }
            }
        } else {
            Add-TestResult -TestId $secTest.Id -Category "MandatorySecurity" -Description $secTest.Desc -Expected "4xx" -Actual "BLOCKED" -Status "BLOCKED"
        }
    }

    # Tests 13-14: WebSocket upgrade (same logic)
    foreach ($wsTest in @(
        @{ Id="13"; Path="/api/events.mux" },
        @{ Id="14"; Path="/api/events.host" }
    )) {
        if ($script:HarnessReady) {
            Write-Host "`n=== Test $($wsTest.Id): WS $($wsTest.Path) ===" -ForegroundColor Cyan
            try {
                $ws = [System.Net.WebSockets.ClientWebSocket]::new()
                $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT$($wsTest.Path)")
                $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
                if ($connectTask.Wait(5000)) {
                    if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                        Add-TestResult -TestId $wsTest.Id -Category "MandatoryFunctional" -Description "WS $($wsTest.Path)" -Expected "Open" -Actual "Connected" -Status "PASS"
                        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
                    } else {
                        Add-TestResult -TestId $wsTest.Id -Category "MandatoryFunctional" -Description "WS $($wsTest.Path)" -Expected "Open" -Actual "State=$($ws.State)" -Status "FAIL"
                    }
                } else {
                    Add-TestResult -TestId $wsTest.Id -Category "MandatoryFunctional" -Description "WS $($wsTest.Path)" -Expected "Connected" -Actual "Timeout" -Status "FAIL"
                }
            } catch {
                Add-TestResult -TestId $wsTest.Id -Category "MandatoryFunctional" -Description "WS $($wsTest.Path)" -Expected "Connected" -Actual "Error: $($_.Exception.Message)" -Status "FAIL"
            }
        } else {
            Add-TestResult -TestId $wsTest.Id -Category "MandatoryFunctional" -Description "WS $($wsTest.Path)" -Expected "Connected" -Actual "BLOCKED" -Status "BLOCKED"
        }
    }

    # ================================================================
    # Test 15: WS frame/envelope (R1-06: single terminal state, always BLOCKED for envelope)
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 15: WS frame/envelope ===" -ForegroundColor Cyan
        # R1-06: Single terminal state flag — once set, no more results for Test 15
        $test15Finalized = $false
        $ws = $null; $memStream = $null; $cts = $null; $reader = $null

        try {
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.mux")
            $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait(5000) | Out-Null

            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                  -Description "WS frame/envelope" -Expected "Valid frame or BLOCKED" `
                  -Actual "WS not open (state=$($ws.State))" -Status "BLOCKED" `
                  -ErrorSummary "BLOCKED — WS connection failed"
                $test15Finalized = $true
            }

            if (-not $test15Finalized) {
                $memStream = New-Object System.IO.MemoryStream
                $endOfMessage = $false; $messageType = $null
                $cts = New-Object System.Threading.CancellationTokenSource(8000)
                $maxSize = 1048576; $oversize = $false

                try {
                    do {
                        $chunkBuffer = [byte[]]::new(32768)
                        $receiveTask = $ws.ReceiveAsync([ArraySegment[byte]]::new($chunkBuffer), $cts.Token)
                        if (-not $receiveTask.Wait(9000)) { break }
                        $result = $receiveTask.Result
                        if ($null -eq $messageType) { $messageType = $result.MessageType }

                        if ($memStream.Length + $result.Count -gt $maxSize) {
                            $oversize = $true
                            Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                              -Description "WS frame/envelope" -Expected "Message within 1MB" `
                              -Actual "Exceeded 1MB ($($memStream.Length + $result.Count) bytes)" `
                              -Status "FAIL" -ErrorSummary "Frame too large"
                            $test15Finalized = $true
                            break
                        }

                        $memStream.Write($chunkBuffer, 0, $result.Count)
                        $endOfMessage = $result.EndOfMessage
                    } while (-not $endOfMessage)
                } catch {}

                if (-not $test15Finalized) {
                    $totalBytes = $memStream.Length

                    if ($totalBytes -eq 0) {
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope" -Expected "Count > 0" `
                          -Actual "No frame received (no stimulus)" -Status "BLOCKED" `
                          -ErrorSummary "BLOCKED — envelope requires event stimulus"
                    } elseif ($messageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope" -Expected "Text frame" `
                          -Actual "Close frame" -Status "FAIL" -ErrorSummary "Server closed"
                    } elseif ($messageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) {
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope" -Expected "Text frame" `
                          -Actual "Non-text: $messageType" -Status "FAIL" -ErrorSummary "Non-text frame"
                    } elseif (-not $endOfMessage) {
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope" -Expected "EndOfMessage=true" `
                          -Actual "Incomplete ($totalBytes bytes)" -Status "FAIL" -ErrorSummary "No EndOfMessage"
                    } else {
                        # Strict UTF-8
                        $decodedText = $null
                        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
                        try {
                            $memStream.Position = 0
                            $reader = New-Object System.IO.StreamReader($memStream, $utf8Strict, $true)
                            $decodedText = $reader.ReadToEnd()
                        } catch {}

                        if (-not $decodedText) {
                            Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                              -Description "WS frame/envelope" -Expected "Valid UTF-8" `
                              -Actual "UTF-8 decode failed" -Status "FAIL" -ErrorSummary "Invalid UTF-8"
                        } else {
                            $parsed = $null; $jsonError = $null
                            try { $parsed = $decodedText | ConvertFrom-Json } catch { $jsonError = $_.Exception.Message }

                            if (-not $parsed) {
                                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                                  -Description "WS frame/envelope" -Expected "Valid JSON" `
                                  -Actual "JSON parse failed: $jsonError" -Status "FAIL" -ErrorSummary "Invalid JSON"
                            } else {
                                # R1-06: Envelope contract NOT verified from upstream → always BLOCKED
                                # Having id/result/params/type/method/event in JSON is NOT proof of official envelope
                                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                                  -Description "WS frame/envelope" `
                                  -Expected "Verified envelope contract from upstream types/source" `
                                  -Actual "$totalBytes bytes, valid UTF-8, valid JSON (preview=$($decodedText.Substring(0, [Math]::Min(100, $decodedText.Length))))" `
                                  -Status "BLOCKED" `
                                  -ErrorSummary "BLOCKED — official envelope contract not verified from @deepseek-ai/dsh types/source; JSON structure alone insufficient"
                            }
                        }
                    }
                    $test15Finalized = $true
                }
            }
        } catch {
            if (-not $test15Finalized) {
                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                  -Description "WS frame/envelope" -Expected "Valid frame" `
                  -Actual "Exception: $($_.Exception.Message)" -Status "BLOCKED" `
                  -ErrorSummary "BLOCKED — WS exception"
            }
        } finally {
            # R1-06: Always dispose resources in finally
            # R2-05: Dispose StreamReader, MemoryStream, CTS, WebSocket independently
            if ($reader) { try { $reader.Dispose() } catch {} }
            if ($memStream) { try { $memStream.Dispose() } catch {} }
            if ($cts) { try { $cts.Dispose() } catch {} }
            if ($ws) {
                try { if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null } } catch {}
                try { $ws.Dispose() } catch {}
            }
        }
    } else {
        Add-TestResult -TestId "15" -Category "EvidenceDependent" -Description "WS frame/envelope" -Expected "Valid frame" -Actual "BLOCKED" -Status "BLOCKED"
    }

    # ================================================================
    # Test 16: No-key error path (unchanged logic)
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 16: No-key error path ===" -ForegroundColor Cyan
        $sessionId = $null; $sessionCreateUsed = $false
        try {
            $createResp = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" -Method POST -ContentType "application/json" -Body '{"method":"session.create","params":{}}' -TimeoutSec 10 -ErrorAction Stop
            if ($createResp.Content) {
                $createParsed = $createResp.Content | ConvertFrom-Json
                if ($createParsed.result -and $createParsed.result.sessionId) { $sessionId = $createParsed.result.sessionId; $sessionCreateUsed = $true }
                elseif ($createParsed.result -and $createParsed.result.id) { $sessionId = $createParsed.result.id; $sessionCreateUsed = $true }
            }
        } catch {}

        if (-not $sessionCreateUsed) {
            Add-TestResult -TestId "16" -Category "EvidenceDependent" -Description "No-key error path" -Expected "Verified RPC contract" -Actual "session.create failed; cannot test followup" -Status "BLOCKED" -ErrorSummary "BLOCKED — RPC contract not verified"
        } else {
            $followupBody = "{`"method`":`"agent.followup`",`"params`":{`"prompt`":`"hello`",`"sessionId`":`"$sessionId`"}}"
            $noKeyStatus = $null; $noKeyContent = $null
            try {
                $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" -Method POST -ContentType "application/json" -Body $followupBody -TimeoutSec 15 -ErrorAction Stop
                $noKeyStatus = $response.StatusCode; $noKeyContent = $response.Content
            } catch {
                try { $noKeyStatus = [int]$_.Exception.Response.StatusCode } catch {}
                try { $stream = $_.Exception.Response.GetResponseStream(); if ($stream) { $reader = New-Object System.IO.StreamReader($stream); $noKeyContent = $reader.ReadToEnd() } } catch {}
            }

            if ($null -eq $noKeyStatus) {
                Add-TestResult -TestId "16" -Category "EvidenceDependent" -Description "No-key error path" -Expected "Credential error" -Actual "No response" -Status "BLOCKED" -ErrorSummary "BLOCKED"
            } else {
                $parsed = $null; $errorCode = ""
                if ($noKeyContent) { try { $parsed = $noKeyContent | ConvertFrom-Json } catch {} }
                if ($parsed -and $parsed.error) { if ($parsed.error.code) { $errorCode = [string]$parsed.error.code } elseif ($parsed.error -is [string]) { $errorCode = $parsed.error } }
                if ($parsed -and $parsed.result -and $parsed.result.error) { if ($parsed.result.error.code) { $errorCode = [string]$parsed.result.error.code } elseif ($parsed.result.error -is [string]) { $errorCode = $parsed.result.error } }

                $isCredentialError = $errorCode -match "^(missing_api_key|unauthorized|authentication_required|provider_not_configured|MISSING_CREDENTIALS)$"
                $isAmbiguous = $errorCode -match "(session.not.found|method.not.found|invalid.params|invalid.schema)"

                if ($isCredentialError -and -not $isAmbiguous) {
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" -Description "No-key error path" -Expected "Structured credential error" -Actual "HTTP $noKeyStatus code=$errorCode" -Status "PASS"
                } else {
                    $bodyPreview = if ($noKeyContent) { $noKeyContent.Substring(0, [Math]::Min(200, $noKeyContent.Length)) } else { "(empty)" }
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" -Description "No-key error path" -Expected "Structured credential error" -Actual "HTTP $noKeyStatus code=$errorCode body=$bodyPreview" -Status "BLOCKED" -ErrorSummary "BLOCKED — contract not verified"
                }
            }
        }
    } else {
        Add-TestResult -TestId "16" -Category "EvidenceDependent" -Description "No-key error path" -Expected "Credential error" -Actual "BLOCKED" -Status "BLOCKED"
    }

    # ================================================================
    # R3-R3-05 + R1-01/R1-03: Save process identity BEFORE shutdown
    # ================================================================
    Write-Host "`n=== Saving process identity evidence ===" -ForegroundColor Cyan
    if ($script:HarnessReady -and $script:HarnessLauncherPid) {
        Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid -LauncherCreationDate $script:HarnessLauncherCreationDate
        $script:SavedProcessEvidence = $script:OwnedProcessRecords | ForEach-Object { $_ }
        $script:SavedHarnessProven = $false; $script:SavedHarnessEvidence = ""

        if ($script:HarnessNodePid) {
            # R1-03: Verify Harness Node is in owned tree
            $inOwnedTree = $script:OwnedProcessRecords | Where-Object { $_.PID -eq $script:HarnessNodePid }
            if ($inOwnedTree) {
                $harnessCim = Get-CimInstance Win32_Process -Filter "ProcessId = $script:HarnessNodePid" -ErrorAction SilentlyContinue
                if ($harnessCim) {
                    $cmdLine = $harnessCim.CommandLine
                    $nameOk = $harnessCim.Name -eq "node.exe"
                    # R2-03: Match exact dsh binary path, not broad wildcard
                    $cmdOk = $cmdLine -and $cmdLine -like "*$dshBin*"
                    # R2-03: Full identity comparison against owned record
                    $identityOk = $true
                    if ($harnessCim.CreationDate -ne $inOwnedTree.CreationDate) { $identityOk = $false }
                    if ($harnessCim.CommandLine -ne $inOwnedTree.CommandLine) { $identityOk = $false }
                    if ($harnessCim.ExecutablePath -ne $inOwnedTree.ExecutablePath) { $identityOk = $false }
                    if ($harnessCim.ParentProcessId -ne $inOwnedTree.ParentPID) { $identityOk = $false }

                    # R1-03: Verify parent chain leads to launcher
                    $parentChainOk = $false
                    $tracePid = $inOwnedTree.ParentPID
                    $traceDepth = 0
                    while ($traceDepth -lt 20) {
                        if ($tracePid -eq $script:HarnessLauncherPid) { $parentChainOk = $true; break }
                        $parentRecord = $script:OwnedProcessRecords | Where-Object { $_.PID -eq $tracePid } | Select-Object -First 1
                        if (-not $parentRecord) { break }
                        $tracePid = $parentRecord.ParentPID
                        $traceDepth++
                    }

                    if ($nameOk -and $cmdOk -and $parentChainOk -and $identityOk) {
                        $script:SavedHarnessProven = $true
                        $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid in owned tree, full identity match (CreationDate+CommandLine+ExecutablePath+ParentPID), CommandLine matches dshBin, parent chain reaches launcher"
                    } else {
                        $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid: nameOk=$nameOk cmdOk=$cmdOk parentChainOk=$parentChainOk identityOk=$identityOk"
                    }
                } else {
                    $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid not found in CIM"
                }
            } else {
                $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid NOT in owned tree"
            }
        } else {
            $script:SavedHarnessEvidence = "No Node PID identified from owned tree"
        }
        Write-Host "  Saved: $($script:SavedProcessEvidence.Count) processes, harness proven=$($script:SavedHarnessProven)"
    }

    # ================================================================
    # Test 17: Graceful shutdown
    # ================================================================
    Write-Host "`n=== Test 17: Graceful shutdown ===" -ForegroundColor Cyan
    if ($script:HarnessProcess -and -not $script:HarnessProcess.HasExited) {
        $hadWindow = $script:HarnessProcess.CloseMainWindow()
        if ($hadWindow) {
            $exited = $script:HarnessProcess.WaitForExit(5000)
            if ($exited) {
                Add-TestResult -TestId "17" -Category "EvidenceDependent" -Description "Graceful shutdown" -Expected "Process exits" -Actual "Exit code: $($script:HarnessProcess.ExitCode)" -Status "PASS"
            } else {
                Add-TestResult -TestId "17" -Category "EvidenceDependent" -Description "Graceful shutdown" -Expected "Exit within 5s" -Actual "Still running" -Status "FAIL"
            }
        } else {
            Add-TestResult -TestId "17" -Category "EvidenceDependent" -Description "Graceful shutdown" -Expected "Graceful exit" -Actual "No window (console app)" -Status "BLOCKED" -ErrorSummary "No verified graceful shutdown for console harness"
        }
    } elseif ($script:HarnessProcess -and $script:HarnessProcess.HasExited) {
        Add-TestResult -TestId "17" -Category "EvidenceDependent" -Description "Graceful shutdown" -Expected "Test graceful" -Actual "Already exited" -Status "BLOCKED"
    } else {
        Add-TestResult -TestId "17" -Category "EvidenceDependent" -Description "Graceful shutdown" -Expected "Test graceful" -Actual "No harness" -Status "BLOCKED"
    }

    # ================================================================
    # Test 18: Force cleanup (R1-02: uses SAVED records, not re-BFS)
    # ================================================================
    Write-Host "`n=== Test 18: Force cleanup ===" -ForegroundColor Cyan
    # R1-02: Use SAVED evidence, do NOT re-BFS from possibly-dead launcher
    $stillRunning = @()
    foreach ($record in $script:SavedProcessEvidence) {
        $p = Get-Process -Id $record.PID -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.PID)" -ErrorAction SilentlyContinue
            if ($cim -and $cim.CreationDate -eq $record.CreationDate) {
                $stillRunning += $record
            }
        }
    }

    if ($stillRunning.Count -gt 0) {
        $killResult = Stop-OwnedProcesses
        Start-Sleep -Seconds 1
        # R3-02: Full-identity survivor check
        $afterKill = @()
        foreach ($record in $stillRunning) {
            $p = Get-Process -Id $record.PID -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.PID)" -ErrorAction SilentlyContinue
                if ($cim -and $cim.CreationDate -eq $record.CreationDate) {
                    # R5-05: Full identity including ParentProcessId — exact equality, fail-closed
                    $cmdOk = (-not $record.CommandLine) -or ($cim.CommandLine -eq $record.CommandLine)
                    $exeOk = (-not $record.ExecutablePath) -or ($cim.ExecutablePath -eq $record.ExecutablePath)
                    # ParentPID: both must be present and equal; either missing → BLOCKED (fail-closed)
                    if ($null -ne $record.ParentPID -and $null -ne $cim.ParentProcessId) {
                        $ppidOk = ([int]$cim.ParentProcessId -eq $record.ParentPID)
                    } else {
                        $ppidOk = $false  # fail-closed: cannot confirm identity
                    }
                    if ($cmdOk -and $exeOk -and $ppidOk) { $afterKill += $record.PID }
                }
            }
        }
        # R3-02: Consume structured results directly
        if ($killResult.Failed.Count -gt 0) {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" -Description "Force cleanup" -Expected "All identity-confirmed terminated" -Actual "Failed=$($killResult.Failed.Count)" -Status "FAIL" -ErrorSummary "Kill/WaitForExit failure"
        } elseif ($killResult.IdentityBlocked.Count -gt 0) {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" -Description "Force cleanup" -Expected "All processes terminated or identity confirmed" -Actual "IdentityBlocked=$($killResult.IdentityBlocked.Count)" -Status "BLOCKED" -ErrorSummary "Identity unconfirmed"
        } elseif ($afterKill.Count -gt 0) {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" -Description "Force cleanup" -Expected "All terminated" -Actual "Survived: $($afterKill -join ', ')" -Status "FAIL" -ErrorSummary "Survived despite confirmed identity"
        } else {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" -Description "Force cleanup" -Expected "All terminated" -Actual "Terminated=$($killResult.Terminated.Count), Exited=$($killResult.AlreadyExited.Count)" -Status "PASS"
        }
    } else {
        Add-TestResult -TestId "18" -Category "MandatoryFunctional" -Description "Force cleanup" -Expected "All terminated" -Actual "No owned processes running" -Status "PASS"
    }

    # ================================================================
    # Test 19-20: Snapshot + Owned PID (unchanged)
    # ================================================================
    Write-Host "`n=== Test 19-20 ===" -ForegroundColor Cyan
    Add-TestResult -TestId "19" -Category "Informational" -Description "Pre-snapshot" -Expected "Recorded" -Actual "$($script:PreSnapshot.Count) processes" -Status "PASS"

    $ownedCount = $script:SavedProcessEvidence.Count
    $ownedPids = ($script:SavedProcessEvidence | ForEach-Object { $_.PID }) -join ', '
    $maxDepth = 0
    if ($script:SavedProcessEvidence.Count -gt 0) { $maxDepth = ($script:SavedProcessEvidence | Measure-Object -Property Depth -Maximum).Maximum }

    if (-not $script:SavedHarnessProven) {
        Add-TestResult -TestId "20" -Category "MandatoryFunctional" -Description "Owned PID identification" -Expected "Harness proven in owned tree" -Actual "Owned=$ownedCount. $($script:SavedHarnessEvidence)" -Status "BLOCKED" -ErrorSummary "Harness not proven"
    } else {
        Add-TestResult -TestId "20" -Category "MandatoryFunctional" -Description "Owned PID identification" -Expected "Harness proven in owned tree" -Actual "Owned=$ownedCount, MaxDepth=$maxDepth. $($script:SavedHarnessEvidence). PIDs: $ownedPids" -Status "PASS"
    }

    # ================================================================
    # Test 22: Windows ACL sandbox (unchanged)
    # ================================================================
    Write-Host "`n=== Test 22: ACL sandbox ===" -ForegroundColor Cyan
    Add-TestResult -TestId "22" -Category "EvidenceDependent" -Description "ACL sandbox" -Expected "Verify confinement" -Actual "NOT TESTED — no stimulus" -Status "BLOCKED" -ErrorSummary "BLOCKED"

    # ================================================================
    # Test 23: Harness depth chain (R1-04: real ancestor chain traversal)
    # ================================================================
    Write-Host "`n=== Test 23: Harness depth chain ===" -ForegroundColor Cyan
    if ($script:SavedHarnessProven -and $script:HarnessNodePid) {
        # R1-04: Trace real ancestor chain from HarnessNodePid back to launcher
        $chainPids = @()
        $currentPid = $script:HarnessNodePid
        $chainValid = $true
        $visited = @{}
        $maxChainDepth = 50

        for ($i = 0; $i -lt $maxChainDepth; $i++) {
            if ($currentPid -eq $script:HarnessLauncherPid) {
                $chainPids += $currentPid
                break
            }
            if ($visited.ContainsKey($currentPid)) {
                $chainValid = $false  # Cycle detected
                break
            }
            $visited[$currentPid] = $true
            $chainPids += $currentPid

            $record = $script:SavedProcessEvidence | Where-Object { $_.PID -eq $currentPid } | Select-Object -First 1
            if (-not $record) {
                $chainValid = $false  # Chain broken
                break
            }
            $currentPid = $record.ParentPID
        }

        if ($chainValid -and $chainPids.Count -gt 0 -and $chainPids[-1] -eq $script:HarnessLauncherPid) {
            # R1-04: Verify Depth is monotonically decreasing along chain
            $depthsOk = $true
            $prevDepth = -1
            foreach ($chainProcessId in $chainPids) {
                $rec = $script:SavedProcessEvidence | Where-Object { $_.PID -eq $chainProcessId } | Select-Object -First 1
                if ($rec) {
                    if ($prevDepth -ge 0 -and $rec.Depth -ge $prevDepth) { $depthsOk = $false; break }
                    $prevDepth = $rec.Depth
                }
            }

            if ($depthsOk) {
                # R2-05: Reverse for launcher -> node display order
                $reversedChain = @($chainPids)
                [Array]::Reverse($reversedChain)
                $chainDesc = ($reversedChain | ForEach-Object {
                    $chainPid = $_
                    $rec = $script:SavedProcessEvidence | Where-Object { $_.PID -eq $chainPid } | Select-Object -First 1
                    $d = if ($rec) { $rec.Depth } else { "?" }
                    "depth=$d PID=$chainPid"
                }) -join " -> "
                Add-TestResult -TestId "23" -Category "MandatoryFunctional" `
                  -Description "Harness depth chain (launcher -> node)" `
                  -Expected "Complete chain with decreasing Depth" `
                  -Actual "Chain ($($chainPids.Count) hops): $chainDesc" -Status "PASS"
            } else {
                Add-TestResult -TestId "23" -Category "MandatoryFunctional" `
                  -Description "Harness depth chain" -Expected "Decreasing Depth" `
                  -Actual "Depth not monotonically decreasing" -Status "FAIL" -ErrorSummary "Depth ordering violated"
            }
        } else {
            Add-TestResult -TestId "23" -Category "MandatoryFunctional" `
              -Description "Harness depth chain" -Expected "Chain reaches launcher" `
              -Actual "Chain broken or cycle (hops=$($chainPids.Count), valid=$chainValid)" `
              -Status "FAIL" -ErrorSummary "Ancestor chain invalid"
        }
    } else {
        Add-TestResult -TestId "23" -Category "MandatoryFunctional" `
          -Description "Harness depth chain" -Expected "Chain from launcher to node" `
          -Actual "BLOCKED — harness not proven" -Status "BLOCKED"
    }

} catch [PrerequisiteBlocked] {
    Write-Host "`nPrerequisite blocked: $($_.Exception.Message)" -ForegroundColor Yellow
    $mainError = $_
} catch [AssertionFailure] {
    Write-Host "`nAssertion failure: $($_.Exception.Message)" -ForegroundColor Red
    $mainError = $_
} catch {
    Write-Host "`nScript internal error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = $_.Exception.Message
    Add-TestResult -TestId "ERR" -Category "ScriptInternal" `
      -Description "Script internal error" -Expected "No errors" `
      -Actual "$($_.Exception.Message)" -Status "FAIL" -ErrorSummary $_.ScriptStackTrace
    $mainError = $_
} finally {
    try {
        $cleanupLog = Invoke-Cleanup -TestDir $TEST_DIR -Port $TEST_PORT -Keep $KeepArtifacts
    } catch {
        $errMsg = "ERR-CLEANUP-FRAMEWORK: $($_.Exception.Message)"
        Write-Host "Cleanup framework error: $($_.Exception.Message)" -ForegroundColor Magenta
        $cleanupLog += $errMsg
        $script:CleanupErrors += $errMsg
        $script:FatalInternalError = $true
        if (-not $script:FatalInternalErrorMessage) { $script:FatalInternalErrorMessage = $errMsg }
    }
}

# === Results generation ===
try {
    Write-Host "`n=== TEST RESULTS ===" -ForegroundColor Cyan
    Write-Host ("=" * 90)
    $script:TestResults | Format-Table TestId, Category, Status, Description -AutoSize
    Write-Host ("=" * 90)

    Write-Host "`n=== DETAILED RESULTS ===" -ForegroundColor Cyan
    foreach ($r in $script:TestResults) {
        $color = switch ($r.Status) { "PASS" { "Green" } "FAIL" { "Red" } "BLOCKED" { "Yellow" } default { "Gray" } }
        Write-Host "--- $($r.TestId) [$($r.Category)] $($r.Status) ---" -ForegroundColor $color
        Write-Host "  Description: $($r.Description)"
        Write-Host "  Expected:    $($r.Expected)"
        Write-Host "  Actual:      $($r.Actual)"
        if ($r.ErrorSummary) { Write-Host "  Error:       $($r.ErrorSummary)" }
    }

    Write-Host "`n=== JSON OUTPUT ===" -ForegroundColor Cyan
    $script:TestResults | ConvertTo-Json -Depth 6

    $overallResult = Get-OverallResult -Results $script:TestResults `
      -HasFatalInternalError $script:FatalInternalError `
      -CleanupErrorList $script:CleanupErrors

    if ($script:FatalInternalError) {
        Write-Host "`nFATAL INTERNAL ERROR: $script:FatalInternalErrorMessage" -ForegroundColor Magenta
    }
    if ($script:CleanupErrors.Count -gt 0) {
        Write-Host "`nCLEANUP ERRORS ($($script:CleanupErrors.Count)):" -ForegroundColor Magenta
        foreach ($ce in $script:CleanupErrors) { Write-Host "  $ce" -ForegroundColor Magenta }
    }

    Write-Host "`nOVERALL RESULT: $overallResult" -ForegroundColor $(
        switch ($overallResult) { "PASS" { "Green" } "FAIL" { "Red" } "BLOCKED" { "Yellow" } "ERROR" { "Magenta" } }
    )

    $exitCode = switch ($overallResult) {
        "PASS"    { 0 }
        "FAIL"    { 1 }
        "BLOCKED" { 2 }
        "ERROR"   { 3 }
        default   { 3 }
    }

    $script:ResultsGenerated = $true
    Write-Host "Exit code: $exitCode"
    exit $exitCode

} catch {
    Write-Host "FATAL: Results generation failed: $($_.Exception.Message)" -ForegroundColor Magenta
    Write-Host "OVERALL RESULT: ERROR (results generation failure)" -ForegroundColor Magenta
    Write-Host "Fatal internal error: $script:FatalInternalError" -ForegroundColor Magenta
    Write-Host "Cleanup errors: $($script:CleanupErrors.Count)" -ForegroundColor Magenta
    exit 3
}
