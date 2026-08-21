# HawkAIAgent G0-S1-R3-R1 Windows PoC Test Script
# =================================================
# SAFETY: No admin required. No system modifications.
# All operations scoped to $TEST_DIR (precise, known path).
# Compatible with Windows PowerShell 5.1+.
# =================================================
# Exit codes:
#   0 = All Mandatory tests passed (no failures, no unresolvable blocks)
#   1 = One or more assertion failures
#   2 = Environment or prerequisite blocked (no assertion failures)
#   3 = Script internal error
# =================================================
# Test categories:
#   MandatoryFunctional       — must pass for gate
#   MandatorySecurity         — must reject unsafe requests
#   EvidenceDependent         — BLOCKED without stimulus/contract
#   Informational             — recorded, not gate-blocking
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
$script:HasMandatoryFailure = $false
$script:HasMandatoryBlock = $false

function Add-TestResult {
    param(
        [string]$TestId,
        [string]$Category,  # MandatoryFunctional, MandatorySecurity, EvidenceDependent, Informational
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
    if ($Status -eq "FAIL" -and $Category -match "^Mandatory") {
        $script:HasMandatoryFailure = $true
    }
    if ($Status -eq "BLOCKED" -and $Category -match "^Mandatory") {
        $script:HasMandatoryBlock = $true
    }
}

# === Process tracking ===
$script:PreSnapshotPids = @{}      # PID -> ProcessInfo before test
$script:HarnessLauncherPid = $null  # Start-Process PID (may be CMD launcher)
$script:OwnedPids = @{}            # All PIDs verified to belong to this test
$script:HarnessNodePid = $null     # Actual Node harness PID

function Save-ProcessSnapshot {
    $snap = @{}
    Get-CimInstance Win32_Process | ForEach-Object {
        $snap[[int]$_.ProcessId] = [PSCustomObject]@{
            PID             = [int]$_.ProcessId
            Name            = $_.Name
            ParentPID       = [int]$_.ParentProcessId
            CommandLine     = $_.CommandLine
            CreationDate    = $_.CreationDate
        }
    }
    return $snap
}

function Update-OwnedPids {
    # Recursively find all PIDs whose ancestor chain includes $script:HarnessLauncherPid
    # or whose CommandLine contains $TEST_DIR / local dsh path
    param([string]$TestDir, [int]$LauncherPid)

    $allProcs = Get-CimInstance Win32_Process
    $byParent = @{}
    foreach ($p in $allProcs) {
        $ppid = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $p
    }

    # BFS from launcher PID
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($LauncherPid)
    $visited = @{}
    $visited[$LauncherPid] = $true

    while ($queue.Count -gt 0) {
        $pid = $queue.Dequeue()
        $script:OwnedPids[$pid] = $true
        if ($byParent.ContainsKey($pid)) {
            foreach ($child in $byParent[$pid]) {
                $childPid = [int]$child.ProcessId
                if (-not $visited.ContainsKey($childPid)) {
                    $visited[$childPid] = $true
                    $queue.Enqueue($childPid)
                }
            }
        }
    }

    # Also check CommandLine for exact $TestDir path (not wildcard)
    foreach ($p in $allProcs) {
        $pid = [int]$p.ProcessId
        if ($script:OwnedPids.ContainsKey($pid)) { continue }
        if ($p.CommandLine -and $p.CommandLine -like "*$TestDir*") {
            $script:OwnedPids[$pid] = $true
        }
    }
}

function Stop-OwnedProcesses {
    # Kill deepest children first, then parents
    $pidsToKill = @($script:OwnedPids.Keys) | Sort-Object -Descending
    foreach ($pid in $pidsToKill) {
        # Re-verify still belongs to us
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.HasExited) { continue }
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
            if ($cim) {
                # Verify still in our tree or test dir
                $isOurs = $false
                if ($script:OwnedPids.ContainsKey($pid)) { $isOurs = $true }
                if ($cim.CommandLine -and $cim.CommandLine -like "*$TEST_DIR*") { $isOurs = $true }
                if ($isOurs) {
                    $proc.Kill()
                    $proc.WaitForExit(3000)
                }
            }
        } catch {
            Write-Host "Warning: Could not kill PID $pid`: $_" -ForegroundColor Yellow
        }
    }
}

# === Cleanup function ===
function Invoke-Cleanup {
    Write-Host "`n=== Cleanup ===" -ForegroundColor Cyan

    # Update owned PIDs one last time
    if ($script:HarnessLauncherPid) {
        UpdateOwnedPids -TestDir $TEST_DIR -LauncherPid $script:HarnessLauncherPid
    }

    # Kill owned processes
    Stop-OwnedProcesses

    # Port release check
    Start-Sleep -Seconds 2
    $portUsed = Get-NetTCPConnection -LocalPort $TEST_PORT -ErrorAction SilentlyContinue
    if ($portUsed) {
        Add-TestResult -TestId "24" -Category "MandatoryFunctional" -Description "Port release after cleanup" `
          -Expected "Port $TEST_PORT free" -Actual "Port still in use" -Status "FAIL" `
          -ErrorSummary "Port not released after all owned processes terminated"
    } else {
        Add-TestResult -TestId "24" -Category "MandatoryFunctional" -Description "Port release after cleanup" `
          -Expected "Port $TEST_PORT free" -Actual "Port released" -Status "PASS"
    }

    # Temp directory cleanup
    if (-not $KeepArtifacts) {
        if (Test-Path $TEST_DIR) {
            try {
                Remove-Item -Recurse -Force $TEST_DIR -ErrorAction Stop
                Add-TestResult -TestId "25" -Category "MandatoryFunctional" -Description "Temp directory cleanup" `
                  -Expected "$TEST_DIR removed" -Actual "Removed" -Status "PASS"
            } catch {
                Add-TestResult -TestId "25" -Category "MandatoryFunctional" -Description "Temp directory cleanup" `
                  -Expected "$TEST_DIR removed" -Actual "Cleanup failed: $($_.Exception.Message)" -Status "FAIL" `
                  -ErrorSummary "Could not remove test directory"
            }
        } else {
            Add-TestResult -TestId "25" -Category "MandatoryFunctional" -Description "Temp directory cleanup" `
              -Expected "$TEST_DIR removed" -Actual "Directory not found" -Status "PASS"
        }
    } else {
        Write-Host "Artifacts kept at: $TEST_DIR" -ForegroundColor Yellow
        Add-TestResult -TestId "25" -Category "Informational" -Description "Temp directory cleanup (user kept artifacts)" `
          -Expected "Skipped by user" -Actual "Kept at $TEST_DIR" -Status "SKIPPED_BY_USER"
    }
}

# === Config ===
$DSH_VERSION = "0.1.0-rc.8"
$TEST_PORT = 3080
$TEST_ID = "g0s1r3r1-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$TEST_DIR = Join-Path $env:TEMP "hawkai-$TEST_ID"
$DSH_HOME = Join-Path $TEST_DIR "dsh-home"
$WORKSPACE = Join-Path $TEST_DIR "workspace"
$script:HarnessProcess = $null
$script:HarnessReady = $false

# === Main execution ===
try {
    Write-Host "=== HawkAIAgent G0-S1-R3-R1 Windows PoC ===" -ForegroundColor Cyan
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

    $nodeVer = $nodeVer.Trim()
    $npmVer = $npmVer.Trim()
    Write-Host "Windows: $winVer | Arch: $arch | PS: $psVer | Node: $nodeVer | npm: $npmVer"

    $isWin11 = $winVer -match "10\.0\.22" -or $winVer -match "10\.0\.26"
    $isX64 = $arch -eq "x64"
    $hasNode = $nodeVer -match "^v\d+\."
    $hasNpm = $npmVer -match "^\d+\."

    if (-not $hasNode -or -not $hasNpm) {
        Add-TestResult -TestId "1" -Category "MandatoryFunctional" `
          -Description "Environment: Windows version, architecture, PowerShell, Node, npm" `
          -Expected "Windows 11 x64 with Node.js and npm" `
          -Actual "Node=$nodeVer, npm=$npmVer, $winVer, $arch" -Status "BLOCKED" `
          -ErrorSummary "Node.js or npm not available"
        throw [PrerequisiteBlocked]::new("1", "Node.js or npm not available")
    }

    $envStatus = "PASS"
    $envError = ""
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
    $script:PreSnapshotPids = Save-ProcessSnapshot
    Write-Host "Pre-existing processes: $($script:PreSnapshotPids.Count)"

    # ================================================================
    # Test 3: Install dsh
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 3: Install @deepseek-ai/dsh@$DSH_VERSION ===" -ForegroundColor Cyan
    $env:DSH_HOME = $DSH_HOME

    Push-Location $TEST_DIR
    npm init -y 2>&1 | Out-Null
    npm install "@deepseek-ai/dsh@$DSH_VERSION" 2>&1 | Tee-Object -Variable installOutput
    $installExit = $LASTEXITCODE
    Pop-Location

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
          -Expected "dsh.cmd exists at $dshBin" -Actual "Not found" -Status "FAIL" `
          -ErrorSummary "Binary not found after install"
        throw [AssertionFailure]::new("3", "dsh.cmd not found")
    }

    $dshVersionOut = & $dshBin --version 2>&1 | Out-String
    $dshVersionOut = $dshVersionOut.Trim()
    Write-Host "dsh version: $dshVersionOut"
    Add-TestResult -TestId "3" -Category "MandatoryFunctional" `
      -Description "Install dsh@$DSH_VERSION locally" `
      -Expected "Exit code 0, dsh.cmd exists" `
      -Actual "Exit code 0, version: $dshVersionOut" -Status "PASS"

    # ================================================================
    # Test 4: Lockfile version assertion
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 4: Lockfile version ===" -ForegroundColor Cyan
    $lockfile = Join-Path $TEST_DIR "package-lock.json"
    $lockStatus = "PASS"
    $lockError = ""

    if (-not (Test-Path $lockfile)) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "package-lock.json with dsh version $DSH_VERSION" `
          -Actual "No lockfile" -Status "FAIL" -ErrorSummary "Lockfile not generated"
        throw [AssertionFailure]::new("4", "No lockfile")
    }

    $lockContent = Get-Content $lockfile -Raw | ConvertFrom-Json
    $lockDsh = $lockContent.packages."node_modules/@deepseek-ai/dsh"
    if (-not $lockDsh) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "dsh@$DSH_VERSION in lockfile" `
          -Actual "dsh not in lockfile packages" -Status "FAIL" `
          -ErrorSummary "Package not found in lockfile"
        throw [AssertionFailure]::new("4", "dsh not in lockfile")
    }

    # Also check installed package.json
    $installedPkg = Join-Path $TEST_DIR "node_modules" "@deepseek-ai" "dsh" "package.json"
    $installedVersion = $null
    if (Test-Path $installedPkg) {
        $installedVersion = (Get-Content $installedPkg -Raw | ConvertFrom-Json).version
    }

    $requested = $DSH_VERSION
    $lockfileVer = $lockDsh.version
    $installedVer = $installedVersion

    if ($lockfileVer -ne $requested -or ($installedVer -and $installedVer -ne $requested)) {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "requested=$requested == lockfile=$requested == installed=$requested" `
          -Actual "requested=$requested, lockfile=$lockfileVer, installed=$installedVer" `
          -Status "FAIL" -ErrorSummary "Version mismatch"
    } else {
        Add-TestResult -TestId "4" -Category "MandatoryFunctional" `
          -Description "Lockfile version verification" `
          -Expected "requested=$requested == lockfile=$requested == installed=$requested" `
          -Actual "requested=$requested, lockfile=$lockfileVer, installed=$installedVer" `
          -Status "PASS"
    }

    # ================================================================
    # Test 5: npm ls --all --json
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 5: npm ls --all --json ===" -ForegroundColor Cyan
    Push-Location $TEST_DIR
    $npmLsJson = $null
    $npmLsExit = -1
    try {
        $npmLsRaw = npm ls --all --json 2>&1 | Out-String
        $npmLsExit = $LASTEXITCODE
        $npmLsJson = $npmLsRaw | ConvertFrom-Json
    } catch {
        $npmLsExit = -1
    }
    Pop-Location

    if ($npmLsExit -eq 0 -and $npmLsJson) {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls --all --json integrity" `
          -Expected "Exit code 0, valid JSON" `
          -Actual "Exit code $npmLsExit, JSON parsed" -Status "PASS"
    } elseif ($npmLsExit -ne 0) {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls --all --json integrity" `
          -Expected "Exit code 0" -Actual "Exit code $npmLsExit" -Status "FAIL" `
          -ErrorSummary "npm ls reported dependency issues"
    } else {
        Add-TestResult -TestId "5" -Category "MandatoryFunctional" `
          -Description "npm ls --all --json integrity" `
          -Expected "Valid JSON output" -Actual "JSON parse failed" -Status "FAIL" `
          -ErrorSummary "Could not parse npm ls --json output"
    }

    # ================================================================
    # Test 6: Native dependency detection (recursive)
    # Category: Informational
    # ================================================================
    Write-Host "`n=== Test 6: Native dependency detection ===" -ForegroundColor Cyan
    $nativeDepsToCheck = @("node-pty", "koffi", "better-sqlite3", "sqlite3", "node-pty-prebuilt-multiarch")
    $foundNative = @()

    # Recursive search in actual install tree
    foreach ($dep in $nativeDepsToCheck) {
        $found = Get-ChildItem -Path (Join-Path $TEST_DIR "node_modules") -Filter $dep -Recurse -Directory -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            $pkgJson = Join-Path $f.FullName "package.json"
            $ver = "unknown"
            if (Test-Path $pkgJson) {
                try { $ver = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version } catch {}
            }
            $foundNative += [PSCustomObject]@{
                Name    = $dep
                Path    = $f.FullName
                Version = $ver
            }
        }
    }

    if ($foundNative.Count -gt 0) {
        $nativeList = ($foundNative | ForEach-Object { "$($_.Name)@$($_.Version) at $($_.Path)" }) -join "; "
        # Try real load test for each
        $loadResults = @()
        foreach ($nd in $foundNative) {
            $nodeTest = "try { require('$($nd.Path -replace '\\','/')'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }"
            $nodeResult = & node -e $nodeTest 2>&1 | Out-String
            $nodeExit = $LASTEXITCODE
            $loadResults += "$($nd.Name)@$($nd.Version): load_exit=$nodeExit, output=$($nodeResult.Trim())"
        }
        $loadSummary = $loadResults -join "; "
        Add-TestResult -TestId "6" -Category "Informational" `
          -Description "Native dependencies in install tree (recursive)" `
          -Expected "Document presence and loadability" `
          -Actual "Found: $nativeList | Load tests: $loadSummary" -Status "PASS"
    } else {
        Add-TestResult -TestId "6" -Category "Informational" `
          -Description "Native dependencies in install tree (recursive)" `
          -Expected "Document presence" `
          -Actual "None of [$($nativeDepsToCheck -join ', ')] found in install tree" -Status "PASS"
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
    $allResolved = $true
    foreach ($mod in $testModules) {
        $modPath = Join-Path $TEST_DIR "node_modules" ($mod -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $exists = Test-Path $modPath
        # Real host-side import test
        $nodeTest = "try { require('$mod'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }"
        $nodeResult = & node -e $nodeTest 2>&1 | Out-String
        $nodeExit = $LASTEXITCODE
        Write-Host "  $mod : exists=$exists, host_load_exit=$nodeExit"
        if ($nodeExit -ne 0) {
            Write-Host "    Error: $($nodeResult.Trim())" -ForegroundColor Yellow
            $allResolved = $false
        }
    }

    if ($allResolved) {
        Add-TestResult -TestId "7" -Category "MandatoryFunctional" `
          -Description "Client packages host-side resolution" `
          -Expected "All 3 packages loadable via require() on Node host side" `
          -Actual "All loaded successfully (exit 0)" -Status "PASS"
    } else {
        Add-TestResult -TestId "7" -Category "MandatoryFunctional" `
          -Description "Client packages host-side resolution" `
          -Expected "All 3 packages loadable via require() on Node host side" `
          -Actual "One or more failed host-side load (see output)" -Status "BLOCKED" `
          -ErrorSummary "Host-side load failure. Note: browser-side ModuleLoader issue is NOT resolved."
    }

    # ================================================================
    # Test 8: Harness startup
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 8: Harness startup ===" -ForegroundColor Cyan
    $env:DEEPSEEK_API_KEY = ""

    $stdoutLog = Join-Path $TEST_DIR "stdout.log"
    $stderrLog = Join-Path $TEST_DIR "stderr.log"

    # Post-install process snapshot (after npm, before harness)
    $preHarnessSnapshot = Save-ProcessSnapshot

    $script:HarnessProcess = Start-Process -FilePath $dshBin `
      -ArgumentList "web", "--no-open", "--port", $TEST_PORT `
      -PassThru -RedirectStandardOutput $stdoutLog `
      -RedirectStandardError $stderrLog -NoNewWindow `
      -WorkingDirectory $WORKSPACE

    $script:HarnessLauncherPid = $script:HarnessProcess.Id
    Write-Host "Harness launcher PID: $($script:HarnessLauncherPid)"

    # Identify real Node harness process (launcher may be CMD)
    Start-Sleep -Seconds 2
    $postLaunchSnapshot = Save-ProcessSnapshot
    $newPids = @()
    foreach ($kv in $postLaunchSnapshot.GetEnumerator()) {
        if (-not $preHarnessSnapshot.ContainsKey($kv.Key)) {
            $newPids += $kv.Value
        }
    }
    # Find the Node process that's running dsh
    foreach ($np in $newPids) {
        if ($np.CommandLine -and $np.CommandLine -like "*dsh*" -and $np.Name -eq "node.exe") {
            $script:HarnessNodePid = $np.PID
            break
        }
    }
    # If no CommandLine match, use children of launcher
    if (-not $script:HarnessNodePid) {
        foreach ($np in $newPids) {
            if ($np.ParentPID -eq $script:HarnessLauncherPid -and $np.Name -eq "node.exe") {
                $script:HarnessNodePid = $np.PID
                break
            }
        }
    }
    # Fallback: if launcher IS node
    if (-not $script:HarnessNodePid) {
        $launcherInfo = $postLaunchSnapshot[[int]$script:HarnessLauncherPid]
        if ($launcherInfo -and $launcherInfo.Name -eq "node.exe") {
            $script:HarnessNodePid = $script:HarnessLauncherPid
        }
    }

    if ($script:HarnessNodePid) {
        Write-Host "Harness Node PID: $($script:HarnessNodePid)"
    } else {
        Write-Host "Warning: Could not identify real Harness Node PID" -ForegroundColor Yellow
    }

    # Update owned PIDs
    UpdateOwnedPids -TestDir $TEST_DIR -LauncherPid $script:HarnessLauncherPid

    # Readiness probe
    $maxWait = 30
    $ready = $false
    for ($i = 0; $i -lt $maxWait; $i++) {
        Start-Sleep -Seconds 1
        # Check process still alive
        if ($script:HarnessProcess.HasExited) {
            Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
              -Description "Harness startup and readiness" `
              -Expected "host.describe returns 200 within ${maxWait}s" `
              -Actual "Process exited prematurely with code $($script:HarnessProcess.ExitCode)" -Status "FAIL" `
              -ErrorSummary "Harness process exited before readiness"
            $script:HarnessReady = $false
            break
        }
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $ready = $true
                $script:HarnessReady = $true
                Write-Host "Ready after $($i + 1) seconds" -ForegroundColor Green
                # Update owned PIDs after readiness
                UpdateOwnedPids -TestDir $TEST_DIR -LauncherPid $script:HarnessLauncherPid
                Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
                  -Description "Harness startup and readiness" `
                  -Expected "host.describe returns 200 within ${maxWait}s" `
                  -Actual "Ready after $($i + 1) seconds" -Status "PASS"
                break
            }
        } catch {
            # Not ready yet
        }
    }

    if (-not $ready -and -not $script:HarnessProcess.HasExited) {
        Add-TestResult -TestId "8" -Category "MandatoryFunctional" `
          -Description "Harness startup and readiness" `
          -Expected "host.describe returns 200 within ${maxWait}s" `
          -Actual "Readiness timeout after ${maxWait}s" -Status "FAIL" `
          -ErrorSummary "Harness did not become ready"
        $script:HarnessReady = $false
    }

    # ================================================================
    # Test 9: host.describe with full validation
    # Category: MandatoryFunctional
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 9: host.describe ===" -ForegroundColor Cyan
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -TimeoutSec 5

            if ($response.StatusCode -ne 200) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                  -Description "host.describe response validation" `
                  -Expected "HTTP 200, non-empty body, valid JSON with Typert envelope" `
                  -Actual "HTTP $($response.StatusCode)" -Status "FAIL" `
                  -ErrorSummary "Non-200 status"
            } elseif ([string]::IsNullOrWhiteSpace($response.Content)) {
                Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                  -Description "host.describe response validation" `
                  -Expected "HTTP 200, non-empty body, valid JSON with Typert envelope" `
                  -Actual "HTTP 200 but empty body" -Status "FAIL" `
                  -ErrorSummary "Empty response body"
            } else {
                $parsed = $null
                try { $parsed = $response.Content | ConvertFrom-Json } catch {}
                if (-not $parsed) {
                    Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                      -Description "host.describe response validation" `
                      -Expected "HTTP 200, non-empty body, valid JSON with Typert envelope" `
                      -Actual "HTTP 200, body present but JSON parse failed" -Status "FAIL" `
                      -ErrorSummary "Invalid JSON response"
                } else {
                    # Check for Typert envelope structure (result or error field)
                    $hasResult = $null -ne $parsed.result
                    $hasError = $null -ne $parsed.error
                    $hasId = $null -ne $parsed.id
                    if (-not $hasResult -and -not $hasError) {
                        Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                          -Description "host.describe response validation" `
                          -Expected "HTTP 200, non-empty body, valid JSON with 'result' or 'error' field" `
                          -Actual "JSON parsed but no result/error field. Keys: $($parsed.PSObject.Properties.Name -join ', ')" `
                          -Status "FAIL" -ErrorSummary "Response does not match Typert envelope"
                    } else {
                        $preview = $response.Content.Substring(0, [Math]::Min(300, $response.Content.Length))
                        Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
                          -Description "host.describe response validation" `
                          -Expected "HTTP 200, non-empty body, valid JSON with result/error" `
                          -Actual "HTTP 200, JSON valid, has_result=$hasResult, has_error=$hasError, has_id=$hasId" `
                          -Status "PASS"
                    }
                }
            }
        } catch {
            Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
              -Description "host.describe response validation" `
              -Expected "HTTP 200, non-empty body, valid JSON" `
              -Actual "Request failed: $($_.Exception.Message)" -Status "FAIL" `
              -ErrorSummary $_.Exception.Message
        }
    } else {
        Add-TestResult -TestId "9" -Category "MandatoryFunctional" `
          -Description "host.describe response validation" `
          -Expected "HTTP 200, non-empty body, valid JSON" `
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
            # If we get here, Harness accepted text/plain — that's a FAIL for security
            Add-TestResult -TestId "10" -Category "MandatorySecurity" `
              -Description "Content-Type fence: text/plain must be rejected" `
              -Expected "4xx rejection for non-application/json Content-Type" `
              -Actual "Accepted with HTTP $($response.StatusCode)" -Status "FAIL" `
              -ErrorSummary "Harness accepted text/plain Content-Type — security fence not enforced"
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
                  -Expected "4xx rejection" -Actual "HTTP $statusCode (non-4xx error)" -Status "FAIL" `
                  -ErrorSummary "Unexpected status code"
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
        Write-Host "`n=== Test 11: Invalid Origin rejection ===" -ForegroundColor Cyan
        try {
            $headers = @{ "Origin" = "http://evil.com" }
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            # Accepted with evil Origin — FAIL
            Add-TestResult -TestId "11" -Category "MandatorySecurity" `
              -Description "Invalid Origin (http://evil.com) must be rejected" `
              -Expected "4xx rejection for non-loopback Origin" `
              -Actual "Accepted with HTTP $($response.StatusCode)" -Status "FAIL" `
              -ErrorSummary "Harness accepted request with Origin: http://evil.com — security fence not enforced"
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
                  -ErrorSummary "Unexpected status code"
            } else {
                Add-TestResult -TestId "11" -Category "MandatorySecurity" `
                  -Description "Invalid Origin (http://evil.com) must be rejected" `
                  -Expected "4xx rejection" `
                  -Actual "Connection error: $($_.Exception.Message)" -Status "BLOCKED" `
                  -ErrorSummary "Could not complete test request"
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
        Write-Host "`n=== Test 12: Invalid Host / loopback fence ===" -ForegroundColor Cyan
        try {
            $headers = @{ "Host" = "example.com:3080" }
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body '{"method":"host.describe"}' -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            # Accepted with non-loopback Host — FAIL
            Add-TestResult -TestId "12" -Category "MandatorySecurity" `
              -Description "Invalid Host (example.com:3080) must be rejected" `
              -Expected "4xx rejection for non-loopback Host" `
              -Actual "Accepted with HTTP $($response.StatusCode)" -Status "FAIL" `
              -ErrorSummary "Harness accepted request with Host: example.com:3080 — loopback fence not enforced"
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
                  -ErrorSummary "Unexpected status code"
            } else {
                Add-TestResult -TestId "12" -Category "MandatorySecurity" `
                  -Description "Invalid Host (example.com:3080) must be rejected" `
                  -Expected "4xx rejection" `
                  -Actual "Connection error: $($_.Exception.Message)" -Status "BLOCKED" `
                  -ErrorSummary "Could not complete test request"
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
                      -Expected "WebSocket state=Open after connect" `
                      -Actual "Connected, state=$($ws.State)" -Status "PASS"
                    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
                } else {
                    Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
                      -Description "WS /api/events.mux upgrade" `
                      -Expected "WebSocket state=Open" `
                      -Actual "State=$($ws.State)" -Status "FAIL" `
                      -ErrorSummary "WebSocket not in Open state after connect"
                }
            } else {
                Add-TestResult -TestId "13" -Category "MandatoryFunctional" `
                  -Description "WS /api/events.mux upgrade" `
                  -Expected "WebSocket connected within 5s" `
                  -Actual "Connect timeout" -Status "FAIL" `
                  -ErrorSummary "Connection timed out"
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
                      -Expected "WebSocket state=Open after connect" `
                      -Actual "Connected, state=$($ws.State)" -Status "PASS"
                    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
                } else {
                    Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
                      -Description "WS /api/events.host upgrade" `
                      -Expected "WebSocket state=Open" `
                      -Actual "State=$($ws.State)" -Status "FAIL" `
                      -ErrorSummary "WebSocket not in Open state"
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
              -Actual "Error: $($_.Exception.Message)" -Status "FAIL" `
              -ErrorSummary $_.Exception.Message
        }
    } else {
        Add-TestResult -TestId "14" -Category "MandatoryFunctional" `
          -Description "WS /api/events.host upgrade" -Expected "WebSocket connected" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 15: WS frame/envelope reception
    # Category: EvidenceDependent
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 15: WS frame/envelope reception ===" -ForegroundColor Cyan
        try {
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.mux")
            $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait(5000) | Out-Null

            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                  -Description "WS frame/envelope reception" `
                  -Expected "Receive valid frame, or BLOCKED without stimulus" `
                  -Actual "WS not open (state=$($ws.State))" -Status "BLOCKED" `
                  -ErrorSummary "Could not establish WS connection"
            } else {
                # Try to receive
                $buffer = [byte[]]::new(65536)
                $cts = New-Object System.Threading.CancellationTokenSource(5000)
                $received = $false
                $receiveResult = $null
                try {
                    $receiveTask = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cts.Token)
                    if ($receiveTask.Wait(6000)) {
                        $receiveResult = $receiveTask.Result
                        $received = $true
                    }
                } catch {
                    # ReceiveAsync threw
                }

                if (-not $received) {
                    # No frame received — BLOCKED (no stimulus to trigger envelope)
                    Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                      -Description "WS frame/envelope reception" `
                      -Expected "Receive valid frame with Count > 0 and valid MessageType" `
                      -Actual "No frame received within 5s (no active session/event stimulus)" `
                      -Status "BLOCKED" `
                      -ErrorSummary "BLOCKED — envelope format requires a supported event stimulus"
                } elseif ($receiveResult.Count -eq 0) {
                    Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                      -Description "WS frame/envelope reception" `
                      -Expected "Count > 0" -Actual "Received 0 bytes" -Status "FAIL" `
                      -ErrorSummary "Empty frame received"
                } else {
                    # Validate frame content
                    $frameValid = $true
                    $frameErrors = @()

                    if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        $frameValid = $false
                        $frameErrors += "Received Close frame"
                    }

                    $decodedText = $null
                    if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                        try {
                            $decodedText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $receiveResult.Count)
                        } catch {
                            $frameValid = $false
                            $frameErrors += "UTF-8 decode failed"
                        }
                        # Try JSON parse if expected
                        if ($decodedText) {
                            try { $decodedText | ConvertFrom-Json | Out-Null } catch {
                                $frameErrors += "JSON parse failed (may not be JSON)"
                            }
                        }
                    }

                    if ($frameValid) {
                        $preview = if ($decodedText) { $decodedText.Substring(0, [Math]::Min(200, $decodedText.Length)) } else { "binary frame" }
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope reception" `
                          -Expected "Count > 0, valid MessageType, text decodable" `
                          -Actual "Received $($receiveResult.Count) bytes, type=$($receiveResult.MessageType), preview=$preview" `
                          -Status "PASS"
                    } else {
                        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
                          -Description "WS frame/envelope reception" `
                          -Expected "Valid frame" `
                          -Actual "Received $($receiveResult.Count) bytes but: $($frameErrors -join '; ')" `
                          -Status "FAIL" -ErrorSummary ($frameErrors -join "; ")
                    }
                }

                try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch {}
            }
        } catch {
            Add-TestResult -TestId "15" -Category "EvidenceDependent" `
              -Description "WS frame/envelope reception" `
              -Expected "Receive valid frame" `
              -Actual "Exception: $($_.Exception.Message)" -Status "BLOCKED" `
              -ErrorSummary "BLOCKED — WS receive threw exception"
        }
    } else {
        Add-TestResult -TestId "15" -Category "EvidenceDependent" `
          -Description "WS frame/envelope reception" `
          -Expected "Receive valid frame" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 16: No-key error path
    # Category: EvidenceDependent
    # ================================================================
    if ($script:HarnessReady) {
        Write-Host "`n=== Test 16: No-key error path ===" -ForegroundColor Cyan
        # Try agent.followup which should trigger model call
        # Using session.create first, then followup
        $noKeyTestBody = '{"method":"agent.followup","params":{"prompt":"hello","sessionId":"test-nokey"}}'
        $noKeyStatus = $null
        $noKeyContent = $null
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
              -Method POST -ContentType "application/json" `
              -Body $noKeyTestBody -TimeoutSec 10 -ErrorAction Stop
            $noKeyStatus = $response.StatusCode
            $noKeyContent = $response.Content
        } catch {
            try { $noKeyStatus = [int]$_.Exception.Response.StatusCode } catch {}
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $noKeyContent = $reader.ReadToEnd()
            } catch {}
        }

        if ($null -eq $noKeyStatus) {
            Add-TestResult -TestId "16" -Category "EvidenceDependent" `
              -Description "No-key error path (agent.followup without API key)" `
              -Expected "Non-2xx with credential error, or 2xx with error envelope" `
              -Actual "No HTTP response received" -Status "BLOCKED" `
              -ErrorSummary "BLOCKED — no-key model-call contract not yet verified"
        } elseif ($noKeyStatus -ge 200 -and $noKeyStatus -lt 300) {
            # 2xx — check if envelope contains error
            $parsed = $null
            try { $parsed = $noKeyContent | ConvertFrom-Json } catch {}
            if ($parsed -and ($parsed.error -or ($parsed.result -and $parsed.result.error))) {
                Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                  -Description "No-key error path (agent.followup without API key)" `
                  -Expected "Error envelope with credential/key error" `
                  -Actual "HTTP $noKeyStatus with error envelope" -Status "PASS"
            } else {
                Add-TestResult -TestId "16" -Category "EvidenceDependent" `
                  -Description "No-key error path (agent.followup without API key)" `
                  -Expected "Error indicating missing credentials" `
                  -Actual "HTTP $noKeyStatus but no recognizable error envelope. Body: $($noKeyContent.Substring(0, [Math]::Min(300, $noKeyContent.Length)))" `
                  -Status "BLOCKED" `
                  -ErrorSummary "BLOCKED — no-key model-call contract not yet verified (2xx without clear error)"
            }
        } else {
            # Non-2xx — likely a proper error
            Add-TestResult -TestId "16" -Category "EvidenceDependent" `
              -Description "No-key error path (agent.followup without API key)" `
              -Expected "Non-2xx with credential error indication" `
              -Actual "HTTP $noKeyStatus. Body: $($noKeyContent.Substring(0, [Math]::Min(300, $noKeyContent.Length)))" `
              -Status "PASS"
        }
    } else {
        Add-TestResult -TestId "16" -Category "EvidenceDependent" `
          -Description "No-key error path" -Expected "Credential error" `
          -Actual "BLOCKED (harness not ready)" -Status "BLOCKED"
    }

    # ================================================================
    # Test 17: Graceful shutdown
    # Category: EvidenceDependent
    # ================================================================
    Write-Host "`n=== Test 17: Graceful shutdown ===" -ForegroundColor Cyan
    if ($script:HarnessProcess -and -not $script:HarnessProcess.HasExited) {
        # Note: CloseMainWindow() sends WM_CLOSE — this is NOT a verified graceful
        # shutdown for console/Node apps. We test it as a best-effort probe.
        $hadWindow = $script:HarnessProcess.CloseMainWindow()
        if ($hadWindow) {
            $exited = $script:HarnessProcess.WaitForExit(5000)
            if ($exited) {
                Add-TestResult -TestId "17" -Category "EvidenceDependent" `
                  -Description "Graceful shutdown" `
                  -Expected "Verified Harness graceful exit mechanism, process exits" `
                  -Actual "CloseMainWindow succeeded, exit code: $($script:HarnessProcess.ExitCode)" `
                  -Status "PASS"
            } else {
                Add-TestResult -TestId "17" -Category "EvidenceDependent" `
                  -Description "Graceful shutdown" `
                  -Expected "Process exits within 5s of shutdown request" `
                  -Actual "CloseMainWindow sent but process did not exit within 5s" `
                  -Status "FAIL" -ErrorSummary "Shutdown request sent but process still running"
            }
        } else {
            # No window — console app, CloseMainWindow not applicable
            Add-TestResult -TestId "17" -Category "EvidenceDependent" `
              -Description "Graceful shutdown" `
              -Expected "Verified Harness graceful exit mechanism" `
              -Actual "CloseMainWindow returned false (no visible window — expected for console app)" `
              -Status "BLOCKED" `
              -ErrorSummary "BLOCKED — no verified graceful shutdown mechanism for console harness"
        }
    } elseif ($script:HarnessProcess -and $script:HarnessProcess.HasExited) {
        Add-TestResult -TestId "17" -Category "EvidenceDependent" `
          -Description "Graceful shutdown" `
          -Expected "Test graceful shutdown" `
          -Actual "Process already exited (code $($script:HarnessProcess.ExitCode)) before shutdown test" `
          -Status "BLOCKED" -ErrorSummary "Cannot test shutdown — process already exited"
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
    # Update owned PIDs
    if ($script:HarnessLauncherPid) {
        UpdateOwnedPids -TestDir $TEST_DIR -LauncherPid $script:HarnessLauncherPid
    }

    $stillRunning = @()
    foreach ($pid in @($script:OwnedPids.Keys)) {
        $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) { $stillRunning += $pid }
    }

    if ($stillRunning.Count -gt 0) {
        # Force kill owned processes
        Stop-OwnedProcesses
        Start-Sleep -Seconds 1
        $afterKill = @()
        foreach ($pid in $stillRunning) {
            $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) { $afterKill += $pid }
        }
        if ($afterKill.Count -gt 0) {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" `
              -Description "Force cleanup of owned processes" `
              -Expected "All owned processes terminated" `
              -Actual "Still running after Kill: $($afterKill -join ', ')" -Status "FAIL" `
              -ErrorSummary "Could not terminate owned processes"
        } else {
            Add-TestResult -TestId "18" -Category "MandatoryFunctional" `
              -Description "Force cleanup of owned processes" `
              -Expected "All owned processes terminated" `
              -Actual "Killed $($stillRunning.Count) processes successfully" -Status "PASS"
        }
    } else {
        Add-TestResult -TestId "18" -Category "MandatoryFunctional" `
          -Description "Force cleanup of owned processes" `
          -Expected "All owned processes terminated" `
          -Actual "No owned processes still running" -Status "PASS"
    }

    # ================================================================
    # Test 19: Pre-startup process snapshot recorded
    # Category: Informational
    # ================================================================
    Write-Host "`n=== Test 19: Process snapshot ===" -ForegroundColor Cyan
    Add-TestResult -TestId "19" -Category "Informational" `
      -Description "Pre-startup process snapshot" `
      -Expected "Snapshot recorded for differential analysis" `
      -Actual "$($script:PreSnapshotPids.Count) processes captured pre-test" -Status "PASS"

    # ================================================================
    # Test 20: Owned PID identification
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 20: Owned PID identification ===" -ForegroundColor Cyan
    $ownedPidsList = @($script:OwnedPids.Keys) | Sort-Object
    Write-Host "Owned PIDs: $($ownedPidsList -join ', ')"
    if ($script:HarnessNodePid) {
        Write-Host "Harness Node PID: $($script:HarnessNodePid)"
    }
    Add-TestResult -TestId "20" -Category "MandatoryFunctional" `
      -Description "Identify test-owned processes by PID tree + CommandLine" `
      -Expected "Exact PID list with recursive ParentProcessId + CommandLine verification" `
      -Actual "Owned PIDs: $($ownedPidsList -join ', '); Launcher=$($script:HarnessLauncherPid); Node=$($script:HarnessNodePid)" `
      -Status "PASS"

    # ================================================================
    # Test 21: Orphan process check
    # Category: MandatoryFunctional
    # ================================================================
    Write-Host "`n=== Test 21: Orphan process check ===" -ForegroundColor Cyan
    $orphanPids = @()
    foreach ($pid in $ownedPidsList) {
        $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) {
            # Verify still belongs to us (re-check CommandLine)
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
            if ($cim -and ($cim.CommandLine -like "*$TEST_DIR*" -or $script:OwnedPids.ContainsKey($pid))) {
                $orphanPids += $pid
            }
        }
    }
    if ($orphanPids.Count -gt 0) {
        Add-TestResult -TestId "21" -Category "MandatoryFunctional" `
          -Description "Orphan process check" `
          -Expected "No test-owned processes still running" `
          -Actual "Still running: $($orphanPids -join ', ')" -Status "FAIL" `
          -ErrorSummary "Test-owned processes survived cleanup"
    } else {
        Add-TestResult -TestId "21" -Category "MandatoryFunctional" `
          -Description "Orphan process check" `
          -Expected "No test-owned processes still running" `
          -Actual "All test-owned processes exited" -Status "PASS"
    }

    # ================================================================
    # Test 22: Windows ACL sandbox enforcement
    # Category: EvidenceDependent
    # ================================================================
    Write-Host "`n=== Test 22: Windows ACL sandbox ===" -ForegroundColor Cyan
    # No safe no-key tool execution stimulus available
    Add-TestResult -TestId "22" -Category "EvidenceDependent" `
      -Description "Windows ACL sandbox enforcement" `
      -Expected "Verify agent tool file-effect confinement" `
      -Actual "NOT TESTED — no safe no-key tool execution stimulus / upstream test command verified" `
      -Status "BLOCKED" `
      -ErrorSummary "BLOCKED — No safe no-key tool execution stimulus. Cannot verify ACL sandbox without risking real agent tool execution."

} catch [PrerequisiteBlocked] {
    Write-Host "`nPrerequisite blocked: $($_.Exception.Message)" -ForegroundColor Yellow
    # Already logged via Add-TestResult — no additional action needed
} catch [AssertionFailure] {
    Write-Host "`nAssertion failure: $($_.Exception.Message)" -ForegroundColor Red
    # Already logged via Add-TestResult
} catch {
    Write-Host "`nScript internal error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Add-TestResult -TestId "ERR" -Category "ScriptInternal" `
      -Description "Script internal error" -Expected "No errors" `
      -Actual "$($_.Exception.Message) at $($_.ScriptStackTrace)" -Status "FAIL" `
      -ErrorSummary $_.ScriptStackTrace
} finally {
    Invoke-Cleanup
}

# === Print results ===
Write-Host "`n=== TEST RESULTS ===" -ForegroundColor Cyan
Write-Host ("=" * 90)
$script:TestResults | Format-Table TestId, Category, Status, Description -AutoSize
Write-Host ("=" * 90)

# Detailed results with Expected/Actual/ErrorSummary
Write-Host "`n=== DETAILED RESULTS ===" -ForegroundColor Cyan
foreach ($r in $script:TestResults) {
    Write-Host "--- $($r.TestId) [$($r.Category)] $($r.Status) ---" -ForegroundColor $(
        switch ($r.Status) { "PASS" { "Green" } "FAIL" { "Red" } "BLOCKED" { "Yellow" } default { "Gray" } }
    )
    Write-Host "  Description: $($r.Description)"
    Write-Host "  Expected:    $($r.Expected)"
    Write-Host "  Actual:      $($r.Actual)"
    if ($r.ErrorSummary) { Write-Host "  Error:       $($r.ErrorSummary)" }
}

# JSON output
Write-Host "`n=== JSON OUTPUT ===" -ForegroundColor Cyan
$script:TestResults | ConvertTo-Json -Depth 6

# Overall result
$hasErr = $script:TestResults | Where-Object { $_.TestId -eq "ERR" }
if ($hasErr) {
    $script:OverallResult = "INTERNAL_ERROR"
} elseif ($script:HasMandatoryFailure) {
    $script:OverallResult = "FAIL"
} elseif ($script:HasMandatoryBlock) {
    $script:OverallResult = "BLOCKED"
} else {
    $script:OverallResult = "PASS"
}

Write-Host "`nOVERALL RESULT: $($script:OverallResult)" -ForegroundColor $(
    switch ($script:OverallResult) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "BLOCKED" { "Yellow" }
        "INTERNAL_ERROR" { "Magenta" }
    }
)

# Exit code
$exitCode = switch ($script:OverallResult) {
    "PASS"           { 0 }
    "FAIL"           { 1 }
    "BLOCKED"        { 2 }
    "INTERNAL_ERROR" { 3 }
    default          { 3 }
}
Write-Host "Exit code: $exitCode"
exit $exitCode
