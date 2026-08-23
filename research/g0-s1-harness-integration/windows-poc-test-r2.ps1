# HawkAIAgent G0-S1-R3-R3 Windows PoC Test Script
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
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"

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
$script:FatalInternalError = $false
$script:FatalInternalErrorMessage = ""
$script:CleanupErrors = @()

function Add-TestResult {
    param(
        [string]$TestId,
        [string]$Category,  # MandatoryFunctional, MandatorySecurity, EvidenceDependent, Informational, ScriptInternal, CleanupError
        [string]$Description,
        [string]$Expected,
        [string]$Actual,
        [string]$Status,    # PASS, FAIL, BLOCKED, SKIPPED_BY_USER
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

# R3-R3-08: Refactored Get-OverallResult as pure function accepting results array
function Get-OverallResult {
    param(
        [Parameter(Mandatory=$true)]$Results,
        [bool]$HasFatalInternalError = $false,
        [string[]]$CleanupErrorList = @()
    )

    # Priority 1: ScriptInternal / cleanup fatal → ERROR/3
    if ($HasFatalInternalError) { return "ERROR" }
    if ($CleanupErrorList.Count -gt 0) { return "ERROR" }

    # Check for ScriptInternal or CleanupError category results
    $scriptInternalResults = $Results | Where-Object {
        $_.Category -in @("ScriptInternal", "CleanupError")
    }
    if ($scriptInternalResults | Where-Object { $_.Status -eq "FAIL" }) { return "ERROR" }

    # Priority 2: Gate-blocking categories
    $gateBlocking = $Results | Where-Object {
        $_.Category -in @("MandatoryFunctional", "MandatorySecurity", "EvidenceDependent")
    }

    # Priority 7: No gate-blocking tests → ERROR/3
    if ($gateBlocking.Count -eq 0) { return "ERROR" }

    # Priority 3: Any Gate-blocking FAIL → FAIL/1
    $hasFail = $gateBlocking | Where-Object { $_.Status -eq "FAIL" }
    if ($hasFail) { return "FAIL" }

    # Priority 4: Any Gate-blocking BLOCKED → BLOCKED/2
    $hasBlocked = $gateBlocking | Where-Object { $_.Status -eq "BLOCKED" }
    if ($hasBlocked) { return "BLOCKED" }

    # All Gate-blocking PASS → PASS/0
    return "PASS"
}

# R3-R3-08: Self-test for aggregation logic
function Test-GetOverallResult {
    $allPassed = $true
    $tests = @()

    # Test 1: All Gate-blocking PASS + Informational FAIL → PASS/0
    $r1 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" },
        [PSCustomObject]@{ Category = "Informational"; Status = "FAIL" }
    )
    $g1 = Get-OverallResult -Results $r1 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "All PASS + Info FAIL → PASS"; Expected = "PASS"; Actual = $g1; Pass = ($g1 -eq "PASS") }
    if ($g1 -ne "PASS") { $allPassed = $false }

    # Test 2: EvidenceDependent BLOCKED → BLOCKED/2
    $r2 = @(
        [PSCustomObject]@{ Category = "EvidenceDependent"; Status = "BLOCKED" },
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" }
    )
    $g2 = Get-OverallResult -Results $r2 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "EvidenceDependent BLOCKED → BLOCKED"; Expected = "BLOCKED"; Actual = $g2; Pass = ($g2 -eq "BLOCKED") }
    if ($g2 -ne "BLOCKED") { $allPassed = $false }

    # Test 3: MandatoryFunctional FAIL → FAIL/1
    $r3 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "FAIL" },
        [PSCustomObject]@{ Category = "EvidenceDependent"; Status = "PASS" }
    )
    $g3 = Get-OverallResult -Results $r3 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "MandatoryFunctional FAIL → FAIL"; Expected = "FAIL"; Actual = $g3; Pass = ($g3 -eq "FAIL") }
    if ($g3 -ne "FAIL") { $allPassed = $false }

    # Test 4: FAIL + BLOCKED → FAIL/1
    $r4 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "FAIL" },
        [PSCustomObject]@{ Category = "EvidenceDependent"; Status = "BLOCKED" }
    )
    $g4 = Get-OverallResult -Results $r4 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "FAIL + BLOCKED → FAIL"; Expected = "FAIL"; Actual = $g4; Pass = ($g4 -eq "FAIL") }
    if ($g4 -ne "FAIL") { $allPassed = $false }

    # Test 5: Fatal internal error → ERROR/3
    $r5 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" }
    )
    $g5 = Get-OverallResult -Results $r5 -HasFatalInternalError $true -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "Fatal internal error → ERROR"; Expected = "ERROR"; Actual = $g5; Pass = ($g5 -eq "ERROR") }
    if ($g5 -ne "ERROR") { $allPassed = $false }

    # Test 6: Cleanup fatal error → ERROR/3
    $r6 = @(
        [PSCustomObject]@{ Category = "MandatoryFunctional"; Status = "PASS" }
    )
    $g6 = Get-OverallResult -Results $r6 -HasFatalInternalError $false -CleanupErrorList @("ERR-CLEANUP-PROCESS: kill failed")
    $tests += [PSCustomObject]@{ Name = "Cleanup fatal error → ERROR"; Expected = "ERROR"; Actual = $g6; Pass = ($g6 -eq "ERROR") }
    if ($g6 -ne "ERROR") { $allPassed = $false }

    # Test 7: No Gate-blocking tests → ERROR/3
    $r7 = @(
        [PSCustomObject]@{ Category = "Informational"; Status = "PASS" }
    )
    $g7 = Get-OverallResult -Results $r7 -HasFatalInternalError $false -CleanupErrorList @()
    $tests += [PSCustomObject]@{ Name = "No Gate-blocking → ERROR"; Expected = "ERROR"; Actual = $g7; Pass = ($g7 -eq "ERROR") }
    if ($g7 -ne "ERROR") { $allPassed = $false }

    # Print results
    Write-Host "`n=== Aggregation Self-Test ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected=$($t.Expected) actual=$($t.Actual))" -ForegroundColor $color
    }

    return $allPassed
}

# === Process tracking data structure ===
$script:PreSnapshot = @{}          # PID -> snapshot record before test
$script:HarnessLauncherPid = $null # Start-Process PID (may be CMD launcher)
$script:HarnessNodePid = $null     # Actual Node harness PID (identified after launch)
$script:OwnedProcessRecords = @()  # Array of process records with Depth (only proven descendants)
$script:HarnessReady = $false
# R3-R3-05: Saved identity evidence before shutdown
$script:SavedProcessEvidence = @() # Saved before shutdown for Test 20/23
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

# R3-R3-01: Process ownership ONLY via BFS/DFS from launcher; NO CommandLine wildcard matching
# R3-R3-02: Only proven descendants get real Depth; unknown processes NEVER get fake Depth
function Update-OwnedProcessRecords {
    param([int]$LauncherPid)

    $allProcs = Get-CimInstance Win32_Process
    $byParent = @{}
    foreach ($proc in $allProcs) {
        $ppid = [int]$proc.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $proc
    }

    # BFS from launcher with depth tracking — ONLY proven descendants
    $visited = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([PSCustomObject]@{ PID = $LauncherPid; Depth = 0 })
    $visited[$LauncherPid] = $true
    $records = @()

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $currentPid = $item.PID
        $currentDepth = $item.Depth

        # R3-R3-01: Exclude current PowerShell $PID from owned set
        if ($currentPid -eq $PID) { continue }

        $cim = $allProcs | Where-Object { [int]$_.ProcessId -eq $currentPid } | Select-Object -First 1
        if ($cim) {
            # R3-R3-01: Must not exist in pre-snapshot (new process) OR must be proven via launcher ancestry
            $isNewProcess = -not $script:PreSnapshot.ContainsKey($currentPid)
            $isLauncherDescendant = $true  # BFS from launcher guarantees this

            if ($isNewProcess -or $isLauncherDescendant) {
                $records += [PSCustomObject]@{
                    PID          = $currentPid
                    ParentPID    = [int]$cim.ParentProcessId
                    CreationDate = $cim.CreationDate
                    CommandLine  = $cim.CommandLine
                    Depth        = $currentDepth
                    ExecutablePath = $cim.ExecutablePath
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

    # R3-R3-01: REMOVED — no more CommandLine wildcard matching
    # Only BFS-proven launcher descendants are owned

    # R3-R3-01: Any process NOT provably owned → unverified (logged, NEVER killed)
    $unverified = @()
    foreach ($proc in $allProcs) {
        $procPid = [int]$proc.ProcessId
        if (-not $visited.ContainsKey($procPid) -and $procPid -ne $PID) {
            # Check if it might be test-related but unprovable
            if ($proc.CommandLine -and $proc.CommandLine -like "*$TEST_DIR*") {
                $unverified += $procPid
            }
        }
    }
    if ($unverified.Count -gt 0) {
        Write-Host "  INFO: $($unverified.Count) unverified processes with test dir in CommandLine (NOT owned, NOT killed)" -ForegroundColor DarkYellow
    }

    $script:OwnedProcessRecords = $records
}

function Stop-OwnedProcesses {
    # R3-R3-02: Sort by Depth descending (deepest first → launcher last)
    $sorted = $script:OwnedProcessRecords | Sort-Object -Property Depth -Descending
    foreach ($record in $sorted) {
        $processId = $record.PID
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.HasExited) { continue }

        # R3-R3-01: Re-validate identity via CIM before termination
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
        if (-not $cim) { continue }

        # Identity check: PID + CreationDate must match
        if ($cim.CreationDate -ne $record.CreationDate) {
            Write-Host "  SKIP PID $processId`: CreationDate mismatch (possible PID reuse)" -ForegroundColor Yellow
            continue
        }
        # CommandLine check (if we have one)
        if ($record.CommandLine -and $cim.CommandLine -ne $record.CommandLine) {
            Write-Host "  SKIP PID $processId`: CommandLine mismatch" -ForegroundColor Yellow
            continue
        }

        # R3-R3-01: Final safety check — never kill current PowerShell
        if ($processId -eq $PID) {
            Write-Host "  SKIP PID $processId`: current PowerShell process" -ForegroundColor Yellow
            continue
        }

        # Verified — terminate
        try {
            $proc.Kill()
            $proc.WaitForExit(3000)
            Write-Host "  Terminated PID $processId (depth=$($record.Depth))" -ForegroundColor Gray
        } catch {
            Write-Host "  Warning: Could not kill PID $processId`: $_" -ForegroundColor Yellow
        }
    }
}

# === Cleanup function (independent, resilient) ===
# R3-R3-04: Each cleanup phase has independent try/catch; exceptions generate ERR-CLEANUP-* and set fatal error
function Invoke-Cleanup {
    param([string]$TestDir, [int]$Port, [bool]$Keep)

    $cleanupResults = @()

    # Step 1: Stop owned processes
    try {
        Stop-OwnedProcesses
        $cleanupResults += "Process cleanup: OK"
    } catch {
        $errMsg = "ERR-CLEANUP-PROCESS: $($_.Exception.Message)"
        $cleanupResults += "Process cleanup: FAILED - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        Add-TestResult -TestId "CLEANUP-PROCESS" -Category "CleanupError" `
          -Description "Process cleanup phase" `
          -Expected "All owned processes terminated" `
          -Actual "Exception: $($_.Exception.Message)" -Status "FAIL" `
          -ErrorSummary $errMsg
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    # Step 2: Orphan check
    try {
        Start-Sleep -Seconds 2
        $orphans = @()
        foreach ($record in $script:OwnedProcessRecords) {
            $p = Get-Process -Id $record.PID -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) {
                # Re-verify identity
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.PID)" -ErrorAction SilentlyContinue
                if ($cim -and $cim.CreationDate -eq $record.CreationDate) {
                    $orphans += $record.PID
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
          -Description "Orphan check phase" `
          -Expected "Orphan check completes" `
          -Actual "Exception: $($_.Exception.Message)" -Status "FAIL" `
          -ErrorSummary $errMsg
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    # Step 3: Port release
    try {
        $portUsed = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        if ($portUsed) {
            Add-TestResult -TestId "24" -Category "MandatoryFunctional" `
              -Description "Port release after cleanup" `
              -Expected "Port $Port free" `
              -Actual "Port still in use" -Status "FAIL" `
              -ErrorSummary "Port not released"
            $cleanupResults += "Port check: FAIL"
        } else {
            Add-TestResult -TestId "24" -Category "MandatoryFunctional" `
              -Description "Port release after cleanup" `
              -Expected "Port $Port free" -Actual "Port released" -Status "PASS"
            $cleanupResults += "Port check: OK"
        }
    } catch {
        $errMsg = "ERR-CLEANUP-PORT: $($_.Exception.Message)"
        $cleanupResults += "Port check: ERROR - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        Add-TestResult -TestId "CLEANUP-PORT" -Category "CleanupError" `
          -Description "Port check phase" `
          -Expected "Port check completes" `
          -Actual "Exception: $($_.Exception.Message)" -Status "FAIL" `
          -ErrorSummary $errMsg
        $script:FatalInternalError = $true
        $script:FatalInternalErrorMessage = $errMsg
    }

    # Step 4: Temp directory
    try {
        if (-not $Keep) {
            if (Test-Path $TestDir) {
                Remove-Item -Recurse -Force $TestDir -ErrorAction Stop
                Add-TestResult -TestId "25" -Category "MandatoryFunctional" `
                  -Description "Temp directory cleanup" `
                  -Expected "$TestDir removed" -Actual "Removed" -Status "PASS"
                $cleanupResults += "Temp cleanup: OK"
            } else {
                Add-TestResult -TestId "25" -Category "MandatoryFunctional" `
                  -Description "Temp directory cleanup" `
                  -Expected "$TestDir removed" -Actual "Not found" -Status "PASS"
                $cleanupResults += "Temp cleanup: OK (not found)"
            }
        } else {
            # R3-R3-04: KeepArtifacts is user choice → Informational only
            Add-TestResult -TestId "25" -Category "Informational" `
              -Description "Temp directory cleanup (user kept artifacts)" `
              -Expected "Skipped by user" -Actual "Kept at $TestDir" -Status "SKIPPED_BY_USER"
            $cleanupResults += "Temp cleanup: SKIPPED_BY_USER"
        }
    } catch {
        $errMsg = "ERR-CLEANUP-TEMPDIR: $($_.Exception.Message)"
        $cleanupResults += "Temp cleanup: FAILED - $($_.Exception.Message)"
        $script:CleanupErrors += $errMsg
        # R3-R3-04: Non-KeepArtifacts directory removal failure → FAIL
        if (-not $Keep) {
            Add-TestResult -TestId "25" -Category "MandatoryFunctional" `
              -Description "Temp directory cleanup" `
              -Expected "$TestDir removed" `
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
$TEST_ID = "g0s1r3r3-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$TEST_DIR = Join-Path $env:TEMP "hawkai-$TEST_ID"
$DSH_HOME = Join-Path $TEST_DIR "dsh-home"
$WORKSPACE = Join-Path $TEST_DIR "workspace"
$script:HarnessProcess = $null

# ================================================================
# R3-R3-08: Run aggregation self-tests BEFORE any external operations
# ================================================================
Write-Host "=== R3-R3-08: Aggregation self-test ===" -ForegroundColor Cyan
$selfTestPassed = Test-GetOverallResult
if (-not $selfTestPassed) {
    Write-Host "FATAL: Aggregation self-test failed. Aborting." -ForegroundColor Red
    Add-TestResult -TestId "SELFTEST" -Category "ScriptInternal" `
      -Description "Aggregation self-test" `
      -Expected "All 7 self-tests pass" `
      -Actual "One or more self-tests failed" -Status "FAIL" `
      -ErrorSummary "Aggregation self-test failed before harness launch"
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = "Aggregation self-test failed"
    # Exit immediately — do not proceed to harness launch
    try {
        Write-Host "`n=== TEST RESULTS (aborted) ===" -ForegroundColor Cyan
        $script:TestResults | Format-Table TestId, Category, Status, Description -AutoSize
    } catch {}
    exit 3
}

# === Main execution ===
$cleanupLog = @()
$mainError = $null

try {
    Write-Host "`n=== HawkAIAgent G0-S1-R3-R3 Windows PoC ===" -ForegroundColor Cyan
    Write-Host "Test ID: $TEST_ID"
    Write-Host "Test dir: $TEST_DIR"

    New-Item -ItemType Directory -Path $DSH_HOME -Force | Out-Null
    New-Item -ItemType Directory -Path $WORKSPACE -Force | Out-Null

    # ================================================================
    # Test 1: Environment
    # Category: MandatoryFunctional
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
          -Description "Environment: Windows version, architecture, PowerShell, Node, npm" `
          -Expected "Windows 11 x64 with Node.js and npm" `
          -Actual "Node=$nodeVer, npm=$npmVer, $winVer, $arch" -Status "BLOCKED" `
          -ErrorSummary "Node.js or npm not available"
        throw [PrerequisiteBlocked]::new("1", "Node.js or npm not available")
    }

    $envStatus = "PASS"; $envError = ""
    if (-not $isWin11) { $envStatus = "BLOCKED"; $envError = "Not Windows 11" }
    elseif (-not $isX64) { $envStatus = "BLOCKED"; $envError = "Not x64" }

    Add-TestResult -TestId "1" -Category "MandatoryFunctional" `
      -Description "Environment: Windows version, architecture, PowerShell, Node, npm" `
      -Expected "Windows 11 x64, Node.js, npm" `
      -Actual "$winVer, $arch, PS $psVer, Node $nodeVer, npm $npmVer" `
      -Status $envStatus -ErrorSummary $envError

    if ($envStatus -eq "BLOCKED") {
        throw [PrerequisiteBlocked]::new("1", $envError)
    }

    # ================================================================
    # Test 2: Port availability
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 2: Port availability ===" -ForegroundColor Cyan
    $portUsed = Get-NetTCPConnection -LocalPort $TEST_PORT -ErrorAction SilentlyContinue
    if ($portUsed) {
        $portPid = ($portUsed | Select-Object -First 1).OwningProcess
        Add-TestResult -TestId "2" -Category "MandatoryFunctional" `
          -Description "Port $TEST_PORT available before test" `
          -Expected "Port free" -Actual "Port in use by PID $portPid" -Status "BLOCKED" `
          -ErrorSummary "Port already in use"
        throw [PrerequisiteBlocked]::new("2", "Port $TEST_PORT in use")
    }
    Add-TestResult -TestId "2" -Category "MandatoryFunctional" `
      -Description "Port $TEST_PORT available before test" `
      -Expected "Port free" -Actual "Port free" -Status "PASS"

    # ================================================================
    # Pre-test process snapshot
    # ================================================================
    Write-Host "`n=== Pre-test process snapshot ===" -ForegroundColor Cyan
    $script:PreSnapshot = Save-ProcessSnapshot
    Write-Host "Pre-existing processes: $($script:PreSnapshot.Count)"

    # ================================================================
    # Test 3: Install dsh
    # Category: MandatoryFunctional
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
          -Description "Install dsh@$DSH_VERSION locally" `
          -Expected "npm install exit code 0" -Actual "Exit code $installExit" -Status "FAIL" `
          -ErrorSummary "npm install failed"
        throw [AssertionFailure]::new("3", "npm install failed with exit code $installExit")
    }

    $dshBin = Join-Path $TEST_DIR "node_modules" ".bin" "dsh.cmd"
    if (-not (Test-Path $dshBin)) {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh@$DSH_VERSION locally" `
          -Expected "dsh.cmd exists" -Actual "Not found at $dshBin" -Status "FAIL" `
          -ErrorSummary "Binary not found after install"
        throw [AssertionFailure]::new("3", "dsh.cmd not found")
    }

    # dsh --version with exit code check
    $dshVersionOut = $null
    try {
        $dshVersionOut = (& $dshBin --version 2>&1) | Out-String
        $dshVersionExit = $LASTEXITCODE
    } catch {
        $dshVersionExit = -1
    }
    if ($dshVersionOut) { $dshVersionOut = $dshVersionOut.Trim() }

    if ($dshVersionExit -ne 0 -or -not $dshVersionOut) {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh@$DSH_VERSION locally" `
          -Expected "Exit code 0, dsh.cmd exists, version non-empty" `
          -Actual "dsh --version exit=$dshVersionExit, output='$dshVersionOut'" -Status "FAIL" `
          -ErrorSummary "dsh --version failed or returned empty"
    } else {
        Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
          -Description "Install dsh@$DSH_VERSION locally" `
          -Expected "Exit code 0, dsh.cmd exists" `
          -Actual "Exit 0, version: $dshVersionOut" -Status "PASS"
    }

    # ================================================================
    # Test 4: Lockfile version assertion (strict null-safety)
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 4: Lockfile version ===" -ForegroundColor Cyan
    $lockfile = Join-Path $TEST_DIR "package-lock.json"
    $lockfileVer = $null
    $installedVer = $null
    $requestedVer = $DSH_VERSION
    $versionErrors = @()

    if (-not (Test-Path $lockfile)) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "requested=$requestedVer == lockfile=$requestedVer == installed=$requestedVer" `
          -Actual "No lockfile" -Status "FAIL" -ErrorSummary "Lockfile not generated"
        throw [AssertionFailure]::new("4", "No lockfile")
    }

    try {
        $lockContent = Get-Content $lockfile -Raw | ConvertFrom-Json
        $lockDsh = $lockContent.packages."node_modules/@deepseek-ai/dsh"
        if ($lockDsh -and $lockDsh.version) {
            $lockfileVer = $lockDsh.version
        } else {
            $versionErrors += "dsh not in lockfile or version field missing"
        }
    } catch {
        $versionErrors += "Lockfile parse error: $($_.Exception.Message)"
    }

    $installedPkg = Join-Path $TEST_DIR "node_modules" "@deepseek-ai" "dsh" "package.json"
    if (Test-Path $installedPkg) {
        try {
            $installedPkgContent = Get-Content $installedPkg -Raw | ConvertFrom-Json
            if ($installedPkgContent.version) {
                $installedVer = $installedPkgContent.version
            } else {
                $versionErrors += "Installed package.json has no version field"
            }
        } catch {
            $versionErrors += "Installed package.json parse error: $($_.Exception.Message)"
        }
    } else {
        $versionErrors += "Installed package.json not found"
    }

    if ($versionErrors.Count -gt 0) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "requested=$requestedVer == lockfile=$requestedVer == installed=$requestedVer" `
          -Actual "requested=$requestedVer, lockfile=$lockfileVer, installed=$installedVer" `
          -Status "FAIL" -ErrorSummary ($versionErrors -join "; ")
    } elseif ($requestedVer -ne $lockfileVer -or $requestedVer -ne $installedVer) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "requested=$requestedVer == lockfile=$requestedVer == installed=$requestedVer" `
          -Actual "requested=$requestedVer, lockfile=$lockfileVer, installed=$installedVer" `
          -Status "FAIL" -ErrorSummary "Version mismatch"
    } else {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "requested=$requestedVer == lockfile=$requestedVer == installed=$requestedVer" `
          -Actual "requested=$requestedVer, lockfile=$lockfileVer, installed=$installedVer" `
          -Status "PASS"
    }

    # ================================================================
    # Test 5: npm ls --all --json
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 5: npm ls --all --json ===" -ForegroundColor Cyan
    $npmLsJson = $null
    $npmLsExit = -1
    $npmLsError = $null
    Push-Location $TEST_DIR
    try {
        $npmLsRaw = (npm ls --all --json 2>&1) | Out-String
        $npmLsExit = $LASTEXITCODE
        if ($npmLsRaw) {
            try { $npmLsJson = $npmLsRaw | ConvertFrom-Json } catch {
                $npmLsError = "JSON parse failed: $($_.Exception.Message)"
            }
        } else {
            $npmLsError = "Empty output"
        }
    } catch {
        $npmLsError = "Command failed: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }

    if ($npmLsExit -eq 0 -and $npmLsJson) {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls --all --json integrity" `
          -Expected "Exit code 0, valid JSON" `
          -Actual "Exit $npmLsExit, JSON parsed" -Status "PASS"
    } else {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls --all --json integrity" `
          -Expected "Exit code 0, valid JSON" `
          -Actual "Exit $npmLsExit. $($npmLsError -join '; ')" `
          -Status "FAIL" -ErrorSummary "npm ls reported issues or unparseable output"
    }

    # ================================================================
    # Test 6: Native addon detection (R3-R3-06: Gate-blocking)
    # Category: EvidenceDependent (was Informational)
    # ================================================================
    Write-Host "`n=== Test 6: Native addon detection ===" -ForegroundColor Cyan

    # R3-R3-06: Determine expected native addons from lockfile/dependency tree
    $nativeDepsToCheck = @("node-pty", "koffi", "better-sqlite3", "sqlite3", "node-pty-prebuilt-multiarch")
    $foundNative = @()

    foreach ($depName in $nativeDepsToCheck) {
        $found = Get-ChildItem -Path (Join-Path $TEST_DIR "node_modules") -Filter $depName -Recurse -Directory -ErrorAction SilentlyContinue
        foreach ($foundDir in $found) {
            $pkgJsonPath = Join-Path $foundDir.FullName "package.json"
            $ver = "unknown"
            $isOptional = $false
            if (Test-Path $pkgJsonPath) {
                try {
                    $pkgContent = Get-Content $pkgJsonPath -Raw | ConvertFrom-Json
                    $ver = $pkgContent.version
                    if ($pkgContent.optional -eq $true) { $isOptional = $true }
                    if ($pkgContent.os -and $pkgContent.os -notcontains "win32") { $isOptional = $true }
                    if ($pkgContent.cpu -and $pkgContent.cpu -notcontains "x64") { $isOptional = $true }
                } catch {}
            }

            # Real load test
            $loadExit = -1
            $loadOutput = ""
            Push-Location $TEST_DIR
            try {
                $nodeRequire = "try { require('$($foundDir.FullName -replace '\\','/')'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }"
                $loadOutput = (node -e $nodeRequire 2>&1) | Out-String
                $loadExit = $LASTEXITCODE
            } catch {
                $loadOutput = $_.Exception.Message
            } finally {
                Pop-Location
            }

            $foundNative += [PSCustomObject]@{
                Name       = $depName
                Path       = $foundDir.FullName
                Version    = $ver
                LoadExit   = $loadExit
                LoadOutput = if ($loadOutput) { $loadOutput.Trim() } else { "" }
                IsOptional = $isOptional
            }
        }
    }

    # R3-R3-06: Gate-blocking determination
    if ($foundNative.Count -gt 0) {
        $summary = ($foundNative | ForEach-Object {
            "$($_.Name)@$($_.Version) exit=$($_.LoadExit) optional=$($_.IsOptional)"
        }) -join "; "
        $loadFailures = $foundNative | Where-Object { $_.LoadExit -ne 0 }

        if ($loadFailures.Count -gt 0) {
            # R3-R3-06: Found but failed to load → EvidenceDependent FAIL
            $failureDetails = ($loadFailures | ForEach-Object {
                "$($_.Name)@$($_.Version): exit=$($_.LoadExit) $($_.LoadOutput)"
            }) -join "; "
            Add-TestResult -TestId "6" -Category "EvidenceDependent" `
              -Description "Native addon detection and load test" `
              -Expected "All expected native addons load successfully" `
              -Actual "LOAD FAILURES: $failureDetails" `
              -Status "FAIL" -ErrorSummary "Native addon(s) found but failed to load"
        } else {
            $windowsExpected = $foundNative | Where-Object { -not $_.IsOptional }
            if ($windowsExpected.Count -gt 0) {
                Add-TestResult -TestId "6" -Category "EvidenceDependent" `
                  -Description "Native addon detection and load test" `
                  -Expected "Expected Windows native addons load" `
                  -Actual "All loaded: $summary" -Status "PASS"
            } else {
                Add-TestResult -TestId "6" -Category "Informational" `
                  -Description "Native addon detection (all optional)" `
                  -Expected "Optional addons documented" `
                  -Actual "Found: $summary" -Status "PASS"
            }
        }
    } else {
        # R3-R3-06: None found — check if any were expected
        $dshPkgPath = Join-Path $TEST_DIR "node_modules" "@deepseek-ai" "dsh" "package.json"
        $expectedNative = @()
        if (Test-Path $dshPkgPath) {
            try {
                $dshPkg = Get-Content $dshPkgPath -Raw | ConvertFrom-Json
                $allDeps = @()
                if ($dshPkg.dependencies) { $allDeps += $dshPkg.dependencies.PSObject.Properties.Name }
                if ($dshPkg.optionalDependencies) { $allDeps += $dshPkg.optionalDependencies.PSObject.Properties.Name }
                $expectedNative = $allDeps | Where-Object { $_ -in $nativeDepsToCheck }
            } catch {}
        }

        if ($expectedNative.Count -gt 0) {
            Add-TestResult -TestId "6" -Category "EvidenceDependent" `
              -Description "Native addon detection" `
              -Expected "Expected native addons: $($expectedNative -join ', ')" `
              -Actual "None of [$($nativeDepsToCheck -join ', ')] found in install tree" `
              -Status "BLOCKED" `
              -ErrorSummary "Expected native addons not found — may need Windows Phase A install"
        } else {
            Add-TestResult -TestId "6" -Category "Informational" `
              -Description "Native addon detection" `
              -Expected "Document presence" `
              -Actual "None of [$($nativeDepsToCheck -join ', ')] found; not expected for current platform" `
              -Status "PASS"
        }
    }

    # ================================================================
    # Test 7: Client module host-side resolution
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 7: Client module host-side resolution ===" -ForegroundColor Cyan
    $testModules = @(
        "@deepseek-ai/dsh-client-connection",
        "@deepseek-ai/dsh-api-remotes",
        "@deepseek-ai/dsh-api-gateway"
    )
    $moduleResults = @()
    $anyModuleFailed = $false

    foreach ($mod in $testModules) {
        $modDirPath = Join-Path $TEST_DIR "node_modules" ($mod -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $exists = Test-Path $modDirPath
        $loadExit = -1
        $loadOutput = ""

        Push-Location $TEST_DIR
        try {
            $nodeRequire = "try { require('$mod'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }"
            $loadOutput = (node -e $nodeRequire 2>&1) | Out-String
            $loadExit = $LASTEXITCODE
        } catch {
            $loadOutput = $_.Exception.Message
        } finally {
            Pop-Location
        }

        $loadOutputTrimmed = if ($loadOutput) { $loadOutput.Trim() } else { "" }
        $moduleResults += "$mod : exists=$exists, exit=$loadExit"
        if ($loadExit -ne 0) {
            $anyModuleFailed = $true
            $moduleResults[-1] += ", error=$loadOutputTrimmed"
        }
    }

    if ($anyModuleFailed) {
        Add-TestResult -TestId "7" -Category "MandatoryFunctional" `
          -Description "Client packages host-side resolution" `
          -Expected "All 3 packages require() exit 0 from correct project directory" `
          -Actual ($moduleResults -join "; ") -Status "FAIL" `
          -ErrorSummary "One or more client packages failed host-side load"
    } else {
        Add-TestResult -TestId "7" -Category "MandatoryFunctional" `
          -Description "Client packages host-side resolution" `
          -Expected "All 3 packages require() exit 0" `
          -Actual ($moduleResults -join "; ") -Status "PASS"
    }

    # ================================================================
    # Test 8: Harness startup
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 8: Harness startup ===" -ForegroundColor Cyan
    $env:DEEPSEEK_API_KEY = ""

    $stdoutLog = Join-Path $TEST_DIR "stdout.log"
    $stderrLog = Join-Path $TEST_DIR "stderr.log"

    # Post-install snapshot (after npm, before harness)
    $preHarnessSnapshot = Save-ProcessSnapshot

    $script:HarnessProcess = Start-Process -FilePath $dshBin `
      -ArgumentList "web", "--no-open", "--port", $TEST_PORT `
      -PassThru -RedirectStandardOutput $stdoutLog `
      -RedirectStandardError $stderrLog -NoNewWindow `
      -WorkingDirectory $WORKSPACE

    $script:HarnessLauncherPid = $script:HarnessProcess.Id
    Write-Host "Harness launcher PID: $($script:HarnessLauncherPid)"

    # Identify real Node harness process
    Start-Sleep -Seconds 2
    $postLaunchSnapshot = Save-ProcessSnapshot
    $newProcessRecords = @()
    foreach ($kv in $postLaunchSnapshot.GetEnumerator()) {
        if (-not $preHarnessSnapshot.ContainsKey($kv.Key)) {
            $newProcessRecords += $kv.Value
        }
    }
    # Find Node process running dsh by CommandLine
    foreach ($newRec in $newProcessRecords) {
        if ($newRec.CommandLine -and $newRec.CommandLine -like "*dsh*" -and $newRec.Name -eq "node.exe") {
            $script:HarnessNodePid = $newRec.PID
            break
        }
    }
    # Fallback: child of launcher that is node.exe
    if (-not $script:HarnessNodePid) {
        foreach ($newRec in $newProcessRecords) {
            if ($newRec.ParentPID -eq $script:HarnessLauncherPid -and $newRec.Name -eq "node.exe") {
                $script:HarnessNodePid = $newRec.PID
                break
            }
        }
    }
    # Fallback: launcher IS node
    if (-not $script:HarnessNodePid) {
        $launcherRec = $postLaunchSnapshot[[int]$script:HarnessLauncherPid]
        if ($launcherRec -and $launcherRec.Name -eq "node.exe") {
            $script:HarnessNodePid = $script:HarnessLauncherPid
        }
    }

    if ($script:HarnessNodePid) {
        Write-Host "Harness Node PID: $($script:HarnessNodePid)"
    } else {
        Write-Host "WARNING: Could not identify real Harness Node PID" -ForegroundColor Yellow
    }

    # R3-R3-01: Update owned processes — ONLY BFS-proven descendants
    Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid

    # Readiness probe
    $maxWait = 30
    for ($i = 0; $i -lt $maxWait; $i++) {
        Start-Sleep -Seconds 1
        if ($script:HarnessProcess.HasExited) {
            Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
              -Description "Harness startup and readiness" `
              -Expected "host.describe returns 200 within ${maxWait}s" `
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
                # R3-R3-05: Refresh owned process tree while harness is running
                Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid
                Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
                  -Description "Harness startup and readiness" `
                  -Expected "host.describe returns 200 within ${maxWait}s" `
                  -Actual "Ready after $($i + 1) seconds" -Status "PASS"
                break
            }
        } catch {}
    }

    if (-not $script:HarnessReady -and -not $script:HarnessProcess.HasExited) {
        Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
          -Description "Harness startup and readiness" `
          -Expected "host.describe returns 200 within ${maxWait}s" `
          -Actual "Readiness timeout after ${maxWait}s" -Status "FAIL" `
          -ErrorSummary "Harness did not become ready"
    }

    # ================================================================
    # Test 9: host.describe with full envelope validation
    # Category: MandatoryFunctional
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 9: host.describe ===" -ForegroundColor Cyan
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -TimeoutSec 5

            $statusOk = $response.StatusCode -eq 200
            $bodyNonEmpty = $null -ne $response.Content -and $response.Content.Length -gt 0
            $parsed = $null
            $parseError = $null
            if ($bodyNonEmpty) {
                try { $parsed = $response.Content | ConvertFrom-Json } catch { $parseError = $_.Exception.Message }
            }

            if (-not $statusOk) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                  -Description "host.describe response validation" `
                  -Expected "HTTP 200 + non-empty body + valid JSON + result/error field" `
                  -Actual "HTTP $($response.StatusCode)" -Status "FAIL" `
                  -ErrorSummary "Non-200 status"
            } elseif (-not $bodyNonEmpty) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                  -Description "host.describe response validation" `
                  -Expected "HTTP 200 + non-empty body + valid JSON + result/error field" `
                  -Actual "HTTP 200 but empty body" -Status "FAIL" `
                  -ErrorSummary "Empty response body"
            } elseif (-not $parsed) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                  -Description "host.describe response validation" `
                  -Expected "HTTP 200 + non-empty body + valid JSON + result/error field" `
                  -Actual "JSON parse failed: $parseError" -Status "FAIL" `
                  -ErrorSummary "Invalid JSON"
            } else {
                $hasResult = $null -ne $parsed.result
                $hasError = $null -ne $parsed.error
                if (-not $hasResult -and -not $hasError) {
                    Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                      -Description "host.describe response validation" `
                      -Expected "JSON with 'result' or 'error' field" `
                      -Actual "JSON parsed, keys: $($parsed.PSObject.Properties.Name -join ', ')" `
                      -Status "FAIL" -ErrorSummary "No result/error field in response"
                } else {
                    Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                      -Description "host.describe response validation" `
                      -Expected "HTTP 200 + non-empty body + valid JSON + result/error" `
                      -Actual "HTTP 200, JSON valid, result=$hasResult, error=$hasError" `
                      -Status "PASS"
                }
            }
        } catch {
            Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
              -Description "host.describe response validation" `
              -Expected "HTTP 200 + non-empty body + valid JSON" `
              -Actual "Request failed: $($_.Exception.Message)" -Status "FAIL" `
              -ErrorSummary $_.Exception.Message
        }
    } else {
        Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
          -Description "host.describe response validation" `
          -Expected "HTTP 200 + non-empty body + valid JSON" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 10: HTTP Content-Type fence
    # Category: MandatorySecurity
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 10: HTTP Content-Type fence ===" -ForegroundColor Cyan
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "text/plain" `
              -Body '{"method":"host.describe"}' -TimeoutSec 5 -ErrorAction Stop
            Add-TestResult -TestId "10" -Category "MandatorySecurity" `
              -Description "Content-Type fence: text/plain must be rejected" `
              -Expected "4xx rejection" `
              -Actual "Accepted with HTTP $($response.StatusCode)" -Status "FAIL" `
              -ErrorSummary "Harness accepted text/plain — security fence not enforced"
        } catch {
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            if ($statusCode -ge 400 -and $statusCode -lt 500) {
                Add-TestResult -TestId "10" -Category "MandatorySecurity" `
                  -Description "Content-Type fence: text/plain must be rejected" `
                  -Expected "4xx rejection" -Actual "Rejected with HTTP $statusCode" -Status "PASS"
            } elseif ($statusCode -gt 0) {
                Add-TestResult -TestId "10" -Category "MandatorySecurity" `
                  -Description "Content-Type fence: text/plain must be rejected" `
                  -Expected "4xx rejection" -Actual "HTTP $statusCode (non-4xx)" -Status "FAIL" `
                  -ErrorSummary "Unexpected non-4xx status"
            } else {
                Add-TestResult -TestId "10" -Category "MandatorySecurity" `
                  -Description "Content-Type fence: text/plain must be rejected" `
                  -Expected "4xx rejection" `
                  -Actual "Connection error: $($_.Exception.Message)" -Status "BLOCKED" `
                  -ErrorSummary "Could not complete test request"
            }
        }
    } else {
        Add-TestResult -TestId "10" -Category "MandatorySecurity" `
          -Description "Content-Type fence" -Expected "4xx rejection" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 11: Invalid Origin rejection
    # Category: MandatorySecurity
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 11: Invalid Origin ===" -ForegroundColor Cyan
        try {
            $headers = @{ "Origin" = "http://evil.com" }
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            Add-TestResult -TestId "11" -Category "MandatorySecurity" `
              -Description "Invalid Origin (http://evil.com) must be rejected" `
              -Expected "4xx rejection" `
              -Actual "Accepted with HTTP $($response.StatusCode)" -Status "FAIL" `
              -ErrorSummary "Harness accepted evil Origin"
        } catch {
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            if ($statusCode -ge 400 -and $statusCode -lt 500) {
                Add-TestResult -TestId "11" -Category "MandatorySecurity" `
                  -Description "Invalid Origin (http://evil.com) must be rejected" `
                  -Expected "4xx rejection" -Actual "Rejected with HTTP $statusCode" -Status "PASS"
            } elseif ($statusCode -gt 0) {
                Add-TestResult -TestId "11" -Category "MandatorySecurity" `
                  -Description "Invalid Origin (http://evil.com) must be rejected" `
                  -Expected "4xx rejection" -Actual "HTTP $statusCode (non-4xx)" -Status "FAIL" `
                  -ErrorSummary "Unexpected non-4xx status"
            } else {
                Add-TestResult -TestId "11" -Category "MandatorySecurity" `
                  -Description "Invalid Origin (http://evil.com) must be rejected" `
                  -Expected "4xx rejection" `
                  -Actual "Connection error: $($_.Exception.Message)" -Status "BLOCKED" `
                  -ErrorSummary "Could not complete test"
            }
        }
    } else {
        Add-TestResult -TestId "11" -Category "MandatorySecurity" `
          -Description "Invalid Origin rejection" -Expected "4xx rejection" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 12: Invalid Host / loopback fence
    # Category: MandatorySecurity
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 12: Invalid Host ===" -ForegroundColor Cyan
        try {
            $headers = @{ "Host" = "example.com:3080" }
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            Add-TestResult -TestId "12" -Category "MandatorySecurity" `
              -Description "Invalid Host (example.com:3080) must be rejected" `
              -Expected "4xx rejection" `
              -Actual "Accepted with HTTP $($response.StatusCode)" -Status "FAIL" `
              -ErrorSummary "Harness accepted non-loopback Host"
        } catch {
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            if ($statusCode -ge 400 -and $statusCode -lt 500) {
                Add-TestResult -TestId "12" -Category "MandatorySecurity" `
                  -Description "Invalid Host (example.com:3080) must be rejected" `
                  -Expected "4xx rejection" -Actual "Rejected with HTTP $statusCode" -Status "PASS"
            } elseif ($statusCode -gt 0) {
                Add-TestResult -TestId "12" -Category "MandatorySecurity" `
                  -Description "Invalid Host (example.com:3080) must be rejected" `
                  -Expected "4xx rejection" -Actual "HTTP $statusCode (non-4xx)" -Status "FAIL" `
                  -ErrorSummary "Unexpected non-4xx status"
            } else {
                Add-TestResult -TestId "12" -Category "MandatorySecurity" `
                  -Description "Invalid Host (example.com:3080) must be rejected" `
                  -Expected "4xx rejection" `
                  -Actual "Connection error: $($_.Exception.Message)" -Status "BLOCKED" `
                  -ErrorSummary "Could not complete test"
            }
        }
    } else {
        Add-TestResult -TestId "12" -Category "MandatorySecurity" `
          -Description "Invalid Host rejection" -Expected "4xx rejection" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 13: WebSocket /api/events.mux upgrade
    # Category: MandatoryFunctional
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 13: WS /api/events.mux ===" -ForegroundColor Cyan
        try {
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.mux")
            $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
            if ($connectTask.Wait(5000)) {
                if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
                      -Description "WS /api/events.mux upgrade" `
                      -Expected "WebSocket state=Open" `
                      -Actual "Connected, state=$($ws.State)" -Status "PASS"
                    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
                } else {
                    Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
                      -Description "WS /api/events.mux upgrade" `
                      -Expected "WebSocket state=Open" `
                      -Actual "State=$($ws.State)" -Status "FAIL" `
                      -ErrorSummary "WebSocket not in Open state"
                }
            } else {
                Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
                  -Description "WS /api/events.mux upgrade" `
                  -Expected "WebSocket connected within 5s" `
                  -Actual "Connect timeout" -Status "FAIL"
            }
        } catch {
            Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
              -Description "WS /api/events.mux upgrade" `
              -Expected "WebSocket connected" `
              -Actual "Error: $($_.Exception.Message)" -Status "FAIL" `
              -ErrorSummary $_.Exception.Message
        }
    } else {
        Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
          -Description "WS /api/events.mux upgrade" -Expected "WebSocket connected" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 14: WebSocket /api/events.host upgrade
    # Category: MandatoryFunctional
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 14: WS /api/events.host ===" -ForegroundColor Cyan
        try {
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.host")
            $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
            if ($connectTask.Wait(5000)) {
                if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
                      -Description "WS /api/events.host upgrade" `
                      -Expected "WebSocket state=Open" `
                      -Actual "Connected, state=$($ws.State)" -Status "PASS"
                    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
                } else {
                    Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
                      -Description "WS /api/events.host upgrade" `
                      -Expected "WebSocket state=Open" `
                      -Actual "State=$($ws.State)" -Status "FAIL"
                }
            } else {
                Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
                  -Description "WS /api/events.host upgrade" `
                  -Expected "WebSocket connected within 5s" `
                  -Actual "Connect timeout" -Status "FAIL"
            }
        } catch {
            Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
              -Description "WS /api/events.host upgrade" `
              -Expected "WebSocket connected" `
              -Actual "Error: $($_.Exception.Message)" -Status "FAIL"
        }
    } else {
        Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
          -Description "WS /api/events.host upgrade" -Expected "WebSocket connected" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 15: WS frame/envelope reception (R3-R3-07: strict validation)
    # Category: EvidenceDependent
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 15: WS frame/envelope ===" -ForegroundColor Cyan
        try {
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.mux")
            $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait(5000) | Out-Null

            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                  -Description "WS frame/envelope reception" `
                  -Expected "Valid frame or BLOCKED without stimulus" `
                  -Actual "WS not open (state=$($ws.State))" -Status "BLOCKED" `
                  -ErrorSummary "BLOCKED — WS connection failed"
            } else {
                # R3-R3-07: Use growable MemoryStream instead of fixed 64KB buffer
                $memStream = New-Object System.IO.MemoryStream
                $endOfMessage = $false
                $messageType = $null
                $cts = New-Object System.Threading.CancellationTokenSource(8000)
                $maxSize = 1048576  # 1MB max

                try {
                    do {
                        $chunkBuffer = [byte[]]::new(32768)  # 32KB read chunks
                        $receiveTask = $ws.ReceiveAsync([ArraySegment[byte]]::new($chunkBuffer), $cts.Token)
                        if (-not $receiveTask.Wait(9000)) { break }
                        $result = $receiveTask.Result
                        if ($null -eq $messageType) { $messageType = $result.MessageType }

                        # R3-R3-07: Check accumulated size BEFORE adding chunk
                        if ($memStream.Length + $result.Count -gt $maxSize) {
                            Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                              -Description "WS frame/envelope reception" `
                              -Expected "Message within 1MB limit" `
                              -Actual "Message exceeded 1MB ($($memStream.Length + $result.Count) bytes)" `
                              -Status "FAIL" -ErrorSummary "Frame too large"
                            $memStream.Dispose()
                            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::MessageTooBig, "Too large", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch {}
                            break
                        }

                        $memStream.Write($chunkBuffer, 0, $result.Count)
                        $endOfMessage = $result.EndOfMessage
                    } while (-not $endOfMessage)
                } catch {
                    # ReceiveAsync threw
                }

                $totalBytes = $memStream.Length

                if ($totalBytes -eq 0) {
                    Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                      -Description "WS frame/envelope reception" `
                      -Expected "Count > 0, valid MessageType, text decodable, JSON parseable" `
                      -Actual "No frame received within timeout (no active session/event stimulus)" `
                      -Status "BLOCKED" `
                      -ErrorSummary "BLOCKED — envelope format requires a supported event stimulus"
                } elseif ($messageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                      -Description "WS frame/envelope reception" `
                      -Expected "Text or binary frame" `
                      -Actual "Received Close frame" -Status "FAIL" `
                      -ErrorSummary "WebSocket closed by server"
                } elseif ($messageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) {
                    # R3-R3-07: Non-Text frame → FAIL
                    Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                      -Description "WS frame/envelope reception" `
                      -Expected "Text frame" `
                      -Actual "Non-text MessageType: $messageType" -Status "FAIL" `
                      -ErrorSummary "Non-text WebSocket frame"
                } elseif (-not $endOfMessage) {
                    # R3-R3-07: Did not reach EndOfMessage → FAIL
                    Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                      -Description "WS frame/envelope reception" `
                      -Expected "Complete message (EndOfMessage=true)" `
                      -Actual "Incomplete message ($totalBytes bytes, no EndOfMessage)" `
                      -Status "FAIL" -ErrorSummary "Message not complete"
                } else {
                    # R3-R3-07: Strict UTF-8 decode (throws on invalid bytes)
                    $decodedText = $null
                    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
                    try {
                        $memStream.Position = 0
                        $reader = New-Object System.IO.StreamReader($memStream, $utf8Strict)
                        $decodedText = $reader.ReadToEnd()
                    } catch {
                        # Invalid UTF-8 bytes
                    }

                    if (-not $decodedText) {
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope reception" `
                          -Expected "Valid UTF-8 text" `
                          -Actual "UTF-8 decode failed (invalid bytes)" -Status "FAIL" `
                          -ErrorSummary "Strict UTF-8 decode failed"
                    } else {
                        # R3-R3-07: JSON parse
                        $parsed = $null
                        $jsonError = $null
                        try { $parsed = $decodedText | ConvertFrom-Json } catch { $jsonError = $_.Exception.Message }

                        if (-not $parsed) {
                            Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                              -Description "WS frame/envelope reception" `
                              -Expected "Valid JSON" `
                              -Actual "JSON parse failed: $jsonError" -Status "FAIL" `
                              -ErrorSummary "Invalid JSON"
                        } else {
                            # R3-R3-07: Envelope validation — must have verifiable structure
                            $hasType = $null -ne $parsed.type -or $null -ne $parsed.method -or $null -ne $parsed.event
                            $hasIdOrResult = $null -ne $parsed.id -or $null -ne $parsed.result -or $null -ne $parsed.params

                            if ($hasType -or $hasIdOrResult) {
                                $preview = $decodedText.Substring(0, [Math]::Min(200, $decodedText.Length))
                                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                                  -Description "WS frame/envelope reception" `
                                  -Expected "Valid frame + valid UTF-8 + valid JSON + envelope structure" `
                                  -Actual "$totalBytes bytes, type=$messageType, EndOfMessage=true, envelope=valid, preview=$preview" `
                                  -Status "PASS"
                            } else {
                                # R3-R3-07: JSON parse OK but envelope structure unverified → BLOCKED
                                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                                  -Description "WS frame/envelope reception" `
                                  -Expected "Verifiable envelope structure" `
                                  -Actual "$totalBytes bytes, JSON valid but envelope contract unverified (no type/method/event/id/result/params)" `
                                  -Status "BLOCKED" `
                                  -ErrorSummary "BLOCKED — envelope contract not yet verified from upstream types"
                            }
                        }
                    }
                }

                $memStream.Dispose()
                try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch {}
            }
        } catch {
            Add-TestResult -TestId "15" -Category "EvidenceDependent" `
              -Description "WS frame/envelope reception" `
              -Expected "Valid frame" `
              -Actual "Exception: $($_.Exception.Message)" -Status "BLOCKED" `
              -ErrorSummary "BLOCKED — WS receive threw exception"
        }
    } else {
        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
          -Description "WS frame/envelope reception" -Expected "Valid frame" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 16: No-key error path (R3-R3-09: strict RPC contract)
    # Category: EvidenceDependent
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 16: No-key error path ===" -ForegroundColor Cyan

        # R3-R3-09: RPC names must be verified from upstream @deepseek-ai/dsh@0.1.0-rc.8
        # Current evidence: guessing session.create / agent.followup
        # Pre-flight doc must record evidence; without verified contract → BLOCKED

        $sessionId = $null
        $sessionCreateUsed = $false
        try {
            # R3-R3-09: Only use RPC method if contract is verified
            $createBody = '{"method":"session.create","params":{}}'
            $createResp = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body $createBody -TimeoutSec 10 -ErrorAction Stop
            if ($createResp.Content) {
                $createParsed = $createResp.Content | ConvertFrom-Json
                if ($createParsed.result -and $createParsed.result.sessionId) {
                    $sessionId = $createParsed.result.sessionId
                    $sessionCreateUsed = $true
                } elseif ($createParsed.result -and $createParsed.result.id) {
                    $sessionId = $createParsed.result.id
                    $sessionCreateUsed = $true
                }
            }
        } catch {
            # R3-R3-09: session.create failed — do NOT proceed with followup
        }

        if (-not $sessionCreateUsed) {
            # R3-R3-09: Cannot create session → cannot safely test no-key path
            Add-TestResult -TestId "16" -Category "EvidenceDependent" `
              -Description "No-key error path" `
              -Expected "Verified RPC contract for session.create → agent.followup" `
              -Actual "session.create did not return usable session; cannot test followup safely" `
              -Status "BLOCKED" `
              -ErrorSummary "BLOCKED — RPC contract not verified; session.create failed; cannot safely test agent.followup without valid context"
        } else {
            # R3-R3-09: Session created — now test followup
            $followupBody = "{`"method`":`"agent.followup`",`"params`":{`"prompt`":`"hello`",`"sessionId`":`"$sessionId`"}}"

            $noKeyStatus = $null
            $noKeyContent = $null
            try {
                $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
                  -Method POST -ContentType "application/json" `
                  -Body $followupBody -TimeoutSec 15 -ErrorAction Stop
                $noKeyStatus = $response.StatusCode
                $noKeyContent = $response.Content
            } catch {
                try { $noKeyStatus = [int]$_.Exception.Response.StatusCode } catch {}
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $noKeyContent = $reader.ReadToEnd()
                    }
                } catch {}
            }

            if ($null -eq $noKeyStatus) {
                Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                  -Description "No-key error path (agent.followup without API key)" `
                  -Expected "Response indicating missing credentials" `
                  -Actual "No HTTP response received" -Status "BLOCKED" `
                  -ErrorSummary "BLOCKED — no-key model-call contract not yet verified"
            } elseif ($noKeyStatus -ge 200 -and $noKeyStatus -lt 300) {
                # R3-R3-09: 2xx — envelope must have structured error code
                $parsed = $null
                if ($noKeyContent) {
                    try { $parsed = $noKeyContent | ConvertFrom-Json } catch {}
                }
                $hasCredentialError = $false
                if ($parsed) {
                    # R3-R3-09: Must match structured error code/field, not broad regex
                    $errorCode = ""
                    if ($parsed.error) {
                        if ($parsed.error.code) { $errorCode = [string]$parsed.error.code }
                        elseif ($parsed.error -is [string]) { $errorCode = $parsed.error }
                    }
                    if ($parsed.result -and $parsed.result.error) {
                        if ($parsed.result.error.code) { $errorCode = [string]$parsed.result.error.code }
                        elseif ($parsed.result.error -is [string]) { $errorCode = $parsed.result.error }
                    }
                    # R3-R3-09: Only match specific credential-related error codes
                    if ($errorCode -match "^(missing_api_key|unauthorized|authentication_required|provider_not_configured|MISSING_CREDENTIALS)$") {
                        $hasCredentialError = $true
                    }
                }
                if ($hasCredentialError) {
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                      -Description "No-key error path (agent.followup without API key)" `
                      -Expected "Structured credential error code" `
                      -Actual "HTTP $noKeyStatus with verified credential error code" -Status "PASS"
                } else {
                    $bodyPreview = if ($noKeyContent) { $noKeyContent.Substring(0, [Math]::Min(300, $noKeyContent.Length)) } else { "(empty)" }
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                      -Description "No-key error path (agent.followup without API key)" `
                      -Expected "Structured credential error code" `
                      -Actual "HTTP $noKeyStatus but no verified credential error code. Body: $bodyPreview" `
                      -Status "BLOCKED" `
                      -ErrorSummary "BLOCKED — no-key model-call contract not yet verified (2xx without structured credential error)"
                }
            } else {
                # R3-R3-09: Non-2xx — check for specific error code, not broad regex
                $bodyPreview = ""
                if ($noKeyContent) { $bodyPreview = $noKeyContent.Substring(0, [Math]::Min(300, $noKeyContent.Length)) }

                $parsed = $null
                try { $parsed = $noKeyContent | ConvertFrom-Json } catch {}

                $errorCode = ""
                if ($parsed -and $parsed.error) {
                    if ($parsed.error.code) { $errorCode = [string]$parsed.error.code }
                    elseif ($parsed.error -is [string]) { $errorCode = $parsed.error }
                }

                # R3-R3-09: Only pass with verified credential error codes
                $isCredentialError = $errorCode -match "^(missing_api_key|unauthorized|authentication_required|provider_not_configured|MISSING_CREDENTIALS)$"
                # R3-R3-09: Ambiguous errors → BLOCKED/FAIL
                $isAmbiguous = $errorCode -match "(session.not.found|method.not.found|invalid.params|invalid.schema)" -or
                               $bodyPreview -match "(?i)(not.?found|method|session|param|schema)"

                if ($isCredentialError -and -not $isAmbiguous) {
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                      -Description "No-key error path (agent.followup without API key)" `
                      -Expected "Structured credential error code" `
                      -Actual "HTTP $noKeyStatus with code=$errorCode. Body: $bodyPreview" `
                      -Status "PASS"
                } elseif ($isAmbiguous) {
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                      -Description "No-key error path (agent.followup without API key)" `
                      -Expected "Credential error (not session/method error)" `
                      -Actual "HTTP $noKeyStatus but ambiguous code=$errorCode. Body: $bodyPreview" `
                      -Status "BLOCKED" `
                      -ErrorSummary "BLOCKED — could not distinguish credential error from session/method error"
                } else {
                    Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                      -Description "No-key error path (agent.followup without API key)" `
                      -Expected "Structured credential error code" `
                      -Actual "HTTP $noKeyStatus, code=$errorCode. Body: $bodyPreview" `
                      -Status "BLOCKED" `
                      -ErrorSummary "BLOCKED — no-key model-call contract not yet verified"
                }
            }
        }
    } else {
        Add-TestResult -TestId "16" -Category "EvidenceDependent" `
          -Description "No-key error path" -Expected "Credential error" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # R3-R3-05: Save process identity evidence BEFORE shutdown
    # ================================================================
    Write-Host "`n=== R3-R3-05: Saving process identity evidence ===" -ForegroundColor Cyan
    if ($script:HarnessReady -and $script:HarnessLauncherPid) {
        # Refresh owned process tree while harness is still running
        Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid
        # Save evidence for Test 20/23
        $script:SavedProcessEvidence = $script:OwnedProcessRecords | ForEach-Object { $_ }
        $script:SavedHarnessProven = $false
        $script:SavedHarnessEvidence = ""

        if ($script:HarnessNodePid) {
            $harnessCim = Get-CimInstance Win32_Process -Filter "ProcessId = $script:HarnessNodePid" -ErrorAction SilentlyContinue
            if ($harnessCim) {
                $cmdLine = $harnessCim.CommandLine
                if ($cmdLine -and ($cmdLine -like "*dsh*" -or $cmdLine -like "*harness*" -or $cmdLine -like "*deepseek*")) {
                    $script:SavedHarnessProven = $true
                    $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid, CommandLine contains dsh/harness reference"
                } else {
                    $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid found but CommandLine=$cmdLine (no dsh reference)"
                }
            } else {
                $script:SavedHarnessEvidence = "Node PID=$script:HarnessNodePid not found in CIM"
            }
        } else {
            $script:SavedHarnessEvidence = "No Node PID identified from launcher descendants"
        }
        Write-Host "  Saved evidence: $($script:SavedProcessEvidence.Count) processes, harness proven=$($script:SavedHarnessProven)"
    }

    # ================================================================
    # Test 17: Graceful shutdown
    # Category: EvidenceDependent
    # ================================================================
    Write-Host "`n=== Test 17: Graceful shutdown ===" -ForegroundColor Cyan
    if ($script:HarnessProcess -and -not $script:HarnessProcess.HasExited) {
        $hadWindow = $script:HarnessProcess.CloseMainWindow()
        if ($hadWindow) {
            $exited = $script:HarnessProcess.WaitForExit(5000)
            if ($exited) {
                Add-TestResult -TestId "17" -Category "EvidenceDependent" `
                  -Description "Graceful shutdown" `
                  -Expected "Verified graceful exit mechanism, process exits" `
                  -Actual "CloseMainWindow succeeded, exit code: $($script:HarnessProcess.ExitCode)" `
                  -Status "PASS"
            } else {
                Add-TestResult -TestId "17" -Category "EvidenceDependent" `
                  -Description "Graceful shutdown" `
                  -Expected "Process exits within 5s" `
                  -Actual "CloseMainWindow sent but process still running" `
                  -Status "FAIL" -ErrorSummary "Shutdown request sent but no exit"
            }
        } else {
            Add-TestResult -TestId "17" -Category "EvidenceDependent" `
              -Description "Graceful shutdown" `
              -Expected "Verified graceful exit mechanism" `
              -Actual "CloseMainWindow returned false (no window — console app)" `
              -Status "BLOCKED" `
              -ErrorSummary "BLOCKED — no verified graceful shutdown mechanism for console harness"
        }
    } elseif ($script:HarnessProcess -and $script:HarnessProcess.HasExited) {
        Add-TestResult -TestId "17" -Category "EvidenceDependent" `
          -Description "Graceful shutdown" `
          -Expected "Test graceful shutdown" `
          -Actual "Process already exited (code $($script:HarnessProcess.ExitCode))" `
          -Status "BLOCKED" -ErrorSummary "Cannot test — process already exited"
    } else {
        Add-TestResult -TestId "17" -Category "EvidenceDependent" `
          -Description "Graceful shutdown" -Expected "Test graceful shutdown" `
          -Actual "No harness process" -Status "BLOCKED"
    }

    # ================================================================
    # Test 18: Force cleanup verification
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 18: Force cleanup ===" -ForegroundColor Cyan
    Update-OwnedProcessRecords -LauncherPid $script:HarnessLauncherPid

    $stillRunning = @()
    foreach ($record in $script:OwnedProcessRecords) {
        $p = Get-Process -Id $record.PID -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.PID)" -ErrorAction SilentlyContinue
            if ($cim -and $cim.CreationDate -eq $record.CreationDate) {
                $stillRunning += $record
            }
        }
    }

    if ($stillRunning.Count -gt 0) {
        Stop-OwnedProcesses
        Start-Sleep -Seconds 1
        $afterKill = @()
        foreach ($record in $stillRunning) {
            $p = Get-Process -Id $record.PID -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.PID)" -ErrorAction SilentlyContinue
                if ($cim -and $cim.CreationDate -eq $record.CreationDate) {
                    $afterKill += $record.PID
                }
            }
        }
        if ($afterKill.Count -gt 0) {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" `
              -Description "Force cleanup of owned processes" `
              -Expected "All owned processes terminated" `
              -Actual "Survived: $($afterKill -join ', ')" -Status "FAIL" `
              -ErrorSummary "Could not terminate verified processes"
        } else {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" `
              -Description "Force cleanup of owned processes" `
              -Expected "All owned processes terminated" `
              -Actual "Killed $($stillRunning.Count) processes" -Status "PASS"
        }
    } else {
        Add-TestResult -TestId "18" -Category "MandatoryFunctional" `
          -Description "Force cleanup of owned processes" `
          -Expected "All owned processes terminated" `
          -Actual "No owned processes still running" -Status "PASS"
    }

    # ================================================================
    # Test 19: Process snapshot recorded
    # Category: Informational
    # ================================================================
    Write-Host "`n=== Test 19: Process snapshot ===" -ForegroundColor Cyan
    Add-TestResult -TestId "19" -Category "Informational" `
      -Description "Pre-startup process snapshot" `
      -Expected "Snapshot recorded" `
      -Actual "$($script:PreSnapshot.Count) processes captured" -Status "PASS"

    # ================================================================
    # Test 20: Owned PID identification (R3-R3-05: uses saved evidence)
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 20: Owned PID identification ===" -ForegroundColor Cyan

    # R3-R3-05: Use SAVED evidence from before shutdown, not post-hoc CIM queries
    $ownedCount = $script:SavedProcessEvidence.Count
    $ownedPids = ($script:SavedProcessEvidence | ForEach-Object { $_.PID }) -join ', '
    $maxDepth = 0
    if ($script:SavedProcessEvidence.Count -gt 0) {
        $maxDepth = ($script:SavedProcessEvidence | Measure-Object -Property Depth -Maximum).Maximum
    }

    $harnessProven = $script:SavedHarnessProven
    $harnessEvidence = $script:SavedHarnessEvidence

    if (-not $harnessProven) {
        Add-TestResult -TestId "20" -Category "MandatoryFunctional" `
          -Description "Owned PID identification with Harness process proof" `
          -Expected "Launcher descendants contain verified Harness/DSH Node process" `
          -Actual "Owned=$ownedCount, MaxDepth=$maxDepth. $harnessEvidence" `
          -Status "BLOCKED" `
          -ErrorSummary "BLOCKED — could not identify actual Harness process (evidence saved before shutdown)"
    } else {
        Add-TestResult -TestId "20" -Category "MandatoryFunctional" `
          -Description "Owned PID identification with Harness process proof" `
          -Expected "Launcher descendants contain verified Harness/DSH Node process" `
          -Actual "Owned=$ownedCount, MaxDepth=$maxDepth. $harnessEvidence. PIDs: $ownedPids" `
          -Status "PASS"
    }

    # ================================================================
    # Test 22: Windows ACL sandbox enforcement
    # Category: EvidenceDependent
    # ================================================================
    Write-Host "`n=== Test 22: Windows ACL sandbox ===" -ForegroundColor Cyan
    Add-TestResult -TestId "22" -Category "EvidenceDependent" `
      -Description "Windows ACL sandbox enforcement" `
      -Expected "Verify agent tool file-effect confinement" `
      -Actual "NOT TESTED — no safe no-key tool execution stimulus" `
      -Status "BLOCKED" `
      -ErrorSummary "BLOCKED — no safe no-key tool execution stimulus / upstream test command verified"

    # ================================================================
    # Test 23: Harness depth chain (R3-R3-05: uses saved evidence)
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 23: Harness depth chain ===" -ForegroundColor Cyan
    if ($script:SavedHarnessProven) {
        $chain = $script:SavedProcessEvidence | Sort-Object Depth | Select-Object -First 5 | ForEach-Object {
            "depth=$($_.Depth) PID=$($_.PID)"
        }
        Add-TestResult -TestId "23" -Category "MandatoryFunctional" `
          -Description "Harness process depth chain (launcher → node)" `
          -Expected "Depth chain from launcher to actual harness node" `
          -Actual ($chain -join " → ") -Status "PASS"
    } else {
        Add-TestResult -TestId "23" -Category "MandatoryFunctional" `
          -Description "Harness process depth chain" `
          -Expected "Depth chain from launcher to actual harness node" `
          -Actual "BLOCKED — harness not identified (evidence saved before shutdown)" -Status "BLOCKED"
    }

} catch [PrerequisiteBlocked] {
    Write-Host "`nPrerequisite blocked: $($_.Exception.Message)" -ForegroundColor Yellow
    $mainError = $_
} catch [AssertionFailure] {
    Write-Host "`nAssertion failure: $($_.Exception.Message)" -ForegroundColor Red
    $mainError = $_
} catch {
    # R3-R3-03: ScriptInternal error → set fatal flag
    Write-Host "`nScript internal error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $script:FatalInternalError = $true
    $script:FatalInternalErrorMessage = $_.Exception.Message
    Add-TestResult -TestId "ERR" -Category "ScriptInternal" `
      -Description "Script internal error" -Expected "No errors" `
      -Actual "$($_.Exception.Message)" -Status "FAIL" `
      -ErrorSummary $_.ScriptStackTrace
    $mainError = $_
} finally {
    # Cleanup must be independent and resilient
    try {
        $cleanupLog = Invoke-Cleanup -TestDir $TEST_DIR -Port $TEST_PORT -Keep $KeepArtifacts
    } catch {
        # R3-R3-04: Cleanup exception → fatal error
        $errMsg = "ERR-CLEANUP-FRAMEWORK: $($_.Exception.Message)"
        Write-Host "Cleanup framework error: $($_.Exception.Message)" -ForegroundColor Magenta
        $cleanupLog += $errMsg
        $script:CleanupErrors += $errMsg
        $script:FatalInternalError = $true
        if (-not $script:FatalInternalErrorMessage) {
            $script:FatalInternalErrorMessage = $errMsg
        }
    }
}

# === Results generation (must always execute) ===
# R3-R3-03: Results generation error → exit 3
# R3-R3-04: $script:ResultsGenerated only set AFTER successful generation
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

    # JSON output
    Write-Host "`n=== JSON OUTPUT ===" -ForegroundColor Cyan
    $script:TestResults | ConvertTo-Json -Depth 6

    # R3-R3-03: Gate aggregation with proper priority
    $overallResult = Get-OverallResult -Results $script:TestResults `
      -HasFatalInternalError $script:FatalInternalError `
      -CleanupErrorList $script:CleanupErrors

    # R3-R3-03: ScriptInternal/cleanup errors must be visible in final report
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

    # R3-R3-04: ResultsGenerated only set AFTER successful output
    $script:ResultsGenerated = $true

    Write-Host "Exit code: $exitCode"
    exit $exitCode

} catch {
    # R3-R3-03 + R3-R3-04: Results generation failed → fatal summary + exit 3
    Write-Host "FATAL: Results generation failed: $($_.Exception.Message)" -ForegroundColor Magenta
    Write-Host "OVERALL RESULT: ERROR (results generation failure)" -ForegroundColor Magenta
    Write-Host "Fatal internal error: $script:FatalInternalError" -ForegroundColor Magenta
    Write-Host "Cleanup errors: $($script:CleanupErrors.Count)" -ForegroundColor Magenta
    exit 3
}
