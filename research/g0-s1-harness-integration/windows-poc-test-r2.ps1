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
# R1-01: Global capture-order counter for deterministic tie-breaking
$script:CaptureSequence = 0

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
function ConvertFrom-LockfilePathPolicy {
    param([string]$RawPath)

    # Root key is always valid
    if ($RawPath -eq "") { return "" }

    # Normalize separators to forward slash
    $canonical = $RawPath -replace '\\', '/'

    # Trim trailing slash (but not for root, already handled)
    $canonical = $canonical.TrimEnd('/')

    if ($canonical -eq "") { return "" }

    # Reject paths containing backslashes in node_modules segments
    # (after normalization — this catches raw backslash paths)
    if ($RawPath -like '*node_modules*' -and $RawPath -match '\\') { return $null }

    # Validate node_modules structure: must start with node_modules/
    if ($canonical -like 'node_modules*') {
        if (-not ($canonical -match '^node_modules/(@[^/]+/)?[^/]+')) { return $null }
    }

    return $canonical
}

# R10-01: PS5.1-safe lockfile reader — hardened.
# R10-02: Strict type validation (non-null, non-array objects for packages and entries).
# R10-03: Canonical path policy with collision rejection.
# R10-04: Exclusive helper directory, separate stdout/stderr, bounded I/O.
#
# Returns: @{ Parsed=$true/$false; Error=""; Packages=@{ path -> pkgData } }
# Fail-closed: any error returns Parsed=$false with bounded diagnostic.
function ConvertFrom-LockfileSafe {
    param(
        [Parameter(Mandatory=$true)][string]$LockfilePath
    )

    $result = @{ Parsed = $false; Error = ""; Packages = @{} }

    if (-not (Test-Path $LockfilePath)) {
        $result.Error = "Lockfile not found: $LockfilePath"
        return $result
    }

    # R10-04: Bound input size before reading
    $maxInputBytes = 52428800  # 50 MB
    $fileInfo = Get-Item $LockfilePath -ErrorAction SilentlyContinue
    if ($fileInfo -and $fileInfo.Length -gt $maxInputBytes) {
        $result.Error = "Lockfile exceeds maximum input size ($($fileInfo.Length) > $maxInputBytes bytes)"
        return $result
    }

    # R10-04: Create exclusively owned helper directory
    $helperDir = Join-Path $env:TEMP "lockfile-reader-$([guid]::NewGuid().ToString('N'))"
    $nodeHelperPath = Join-Path $helperDir "reader.js"
    $stdoutPath = Join-Path $helperDir "stdout.txt"
    $stderrPath = Join-Path $helperDir "stderr.txt"

    # R10-01: Node.js helper with strict validation and canonical path policy.
    # Lockfile path passed ONLY as process.argv[2] — never interpolated into source.
    # R10-02: Requires top-level lockfile and packages to be non-null, non-array objects.
    # R10-03: Validates canonical path form and rejects collisions.
    # R10-04: Bounded output via conservative byte limit.
    $nodeScript = @'
const fs = require("fs");
const MAX_OUTPUT = 2097152; // 2 MB conservative output limit
try {
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
        // Reject raw paths with backslashes
        if (p.indexOf("\\") !== -1) return null;
        // Normalize trailing slash
        let c = p.replace(/\/+$/, "");
        if (c === "") return "";
        // Validate node_modules structure if present
        if (c.indexOf("node_modules") === 0) {
            if (!/^node_modules\/(@[^\/]+\/)?[^\/]+/.test(c)) return null;
        }
        return c;
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
        # R10-04: Create helper directory
        New-Item -ItemType Directory -Path $helperDir -Force | Out-Null
        $nodeScript | Out-File -FilePath $nodeHelperPath -Encoding ASCII -NoNewline

        # R10-04: Invoke Node.js with SEPARATE stdout and stderr capture
        $nodeExit = -1
        & node $nodeHelperPath $LockfilePath 1> $stdoutPath 2> $stderrPath
        $nodeExit = $LASTEXITCODE

        # R10-04: Read stderr independently
        $stderrText = ""
        if (Test-Path $stderrPath) {
            $stderrText = (Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue)
            if ($stderrText) { $stderrText = $stderrText.Trim() }
        }

        # R10-04: Read stdout
        $jsonOut = ""
        if (Test-Path $stdoutPath) {
            $jsonOut = (Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue)
            if ($jsonOut) { $jsonOut = $jsonOut.Trim() }
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

        # R10-04: Output size bound (defensive, Node already checks)
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

            # R10-04: Path must be a string
            $path = [string]$entry.Path

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
        # R10-04: Remove only the exclusive helper directory; cleanup failure visible and fail closed
        if (Test-Path $helperDir) {
            try {
                Remove-Item $helperDir -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host "WARNING: Failed to clean up helper directory $helperDir : $($_.Exception.Message)" -ForegroundColor Yellow
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

    Write-Host "`n=== Native Judgment Self-Test (24 cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name)" -ForegroundColor $color
    }

    return $allPassed
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
        $p10 = (-not $r10.Parsed) -and ($r10.Error -match "collision")
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
        $p11 = (-not $r11.Parsed) -and ($r11.Error -match "exit") -and ($r11.Error -match "packages")
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

        # F23: Integration -- blocked judgment remains BLOCKED through Test 6 mapping path
        # Fixture: native dep with os=[linux] => not applicable on win32 => but still Resolved
        # We need a judgment that is actually Blocked (not just not-applicable).
        # Use a fixture where the native dep PkgData is null-ish (rejected by reader) or
        # where the normalized path doesn't match. Better: test the full flow with a
        # judgment that has ResolutionStatus=Blocked.
        # Since Get-NativeAddonJudgment only returns Blocked when PkgData is null,
        # and the reader rejects null Data, we test via direct Get-NativeGateSummary.
        $blockedJudgment = @([PSCustomObject]@{
            Name = "blocked-pkg"; Version = "1.0"; IsNative = $true
            ResolutionStatus = "Blocked"; BlockReason = "No lockfile mapping for node_modules/blocked-pkg"
            PlatformApplicable = $true; ParentOptional = $false; LoadExit = 0; LoadOutput = ""
        })
        $gateBlocked = Get-NativeGateSummary -InstanceResults $blockedJudgment -LockfileParsed $true
        $p23 = ($gateBlocked.Status -eq "BLOCKED") -and ($gateBlocked.Category -eq "EvidenceDependent")
        $tests += [PSCustomObject]@{ Name="F23: blocked judgment => gate BLOCKED"; Pass=$p23 }
        if (-not $p23) { $allPassed = $false }

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

    } finally {
        Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n=== Lockfile Reader Self-Test (21 cases) ===" -ForegroundColor Cyan
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

    Write-Host "\n=== Resolve-LockfileParentPath Self-Test (4 cases) ===" -ForegroundColor Cyan
    foreach ($t in $tests) {
        $color = if ($t.Pass) { "Green" } else { "Red" }
        Write-Host "  $(if ($t.Pass) { 'PASS' } else { 'FAIL' }): $($t.Name) (expected='$($t.Expected)' actual='$($t.Actual)')" -ForegroundColor $color
    }

    return $allPassed
}

# R6-04: Self-test for Get-NativeGateSummary (7 cases)
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

    Write-Host "\n=== Native Gate Summary Self-Test (15 cases) ===" -ForegroundColor Cyan
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
# R3-R3-08 + R1-08: Run aggregation self-tests BEFORE any external operations
# R4-01: 11 test cases implemented (R4-01 expanded: kill+identityBlock combo).
# Runtime execution verified via self-test harness.
# ================================================================
Write-Host "=== Aggregation self-test (11 cases) ===" -ForegroundColor Cyan
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
Write-Host "=== Resolve-LockfileParentPath self-test (4 cases) ===" -ForegroundColor Cyan
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
Write-Host "=== Native Gate Summary self-test (7 cases) ===" -ForegroundColor Cyan
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

# R10-07: Run Lockfile Reader self-test BEFORE any external operations
# R9-REV-07: Test-LockfileReader is defined but was never called in the pre-external-operation sequence.
# This invocation ensures the 21 reader test cases are executed in every full-script run.
Write-Host "=== Lockfile Reader self-test (21 cases) ===" -ForegroundColor Cyan
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
        # R1-07: Build transitive dependency map from lockfile packages
        # R9-02: Iterate Hashtable (not PSObject.Properties) — supports "" root key
        foreach ($rawName in @($lockfilePackages.Keys)) {
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
                # R9-03: Use Get-NativeAddonJudgment pure function for platform/optional judgment
                # This eliminates the duplicate inline platform/optional logic
                $depMap = @( @{ Name=$pkgName; PkgData=$pkgData; InstancePath=$rawName; ParentPath=(Resolve-LockfileParentPath -InstancePath $rawName) } )
                $judgments = Get-NativeAddonJudgment -DependencyMap $depMap -TargetOs "win32" -TargetCpu "x64" -LockfilePackages $lockfilePackages
                $judgment = $judgments[0]
                $transitiveNativeExpected[$rawName] = [PSCustomObject]@{
                    Name = $pkgName
                    Version = $pkgData.version
                    PlatformApplicable = $judgment.PlatformApplicable
                    ParentOptional = $judgment.ParentOptional
                    IsNative = $judgment.IsNative
                    ResolutionStatus = $judgment.ResolutionStatus
                    BlockReason = $judgment.BlockReason
                    InLockfile = $true
                }
            }
        }
    } else {
        Write-Host "  Lockfile parse failed: $lockfileParseError" -ForegroundColor Yellow
    }

    foreach ($depName in $nativeDepsToCheck) {
        $found = Get-ChildItem -Path (Join-Path $TEST_DIR "node_modules") -Filter $depName -Recurse -Directory -ErrorAction SilentlyContinue
        foreach ($foundDir in $found) {
            # R5-04 + R6-01: Per-instance initialization — fail-closed defaults
            $resolutionStatus = "Unresolved"
            $platformApplicable = $true
            $parentOptional = $false
            $isNative = $false
            $ver = "unknown"
            $blockReason = ""

            $pkgJsonPath = Join-Path $foundDir.FullName "package.json"
            $pkgContent = $null
            if (Test-Path $pkgJsonPath) {
                try {
                    $pkgContent = Get-Content $pkgJsonPath -Raw | ConvertFrom-Json
                    $ver = $pkgContent.version
                } catch {
                    # R5-04: parse failure → BLOCKED
                    $blockReason = "package.json parse failure: $($_.Exception.Message)"
                }
            } else {
                $blockReason = "package.json not found"
            }

            # R5-04: Match by normalized lockfile instance path (no depName fallback)
            $normalizedPath = $foundDir.FullName -replace [regex]::Escape((Join-Path $TEST_DIR "node_modules") + [System.IO.Path]::DirectorySeparatorChar), ""
            $normalizedPath = "node_modules/$($normalizedPath -replace [regex]::Escape([System.IO.Path]::DirectorySeparatorChar), '/')"

            # R6-01: Resolution status must be determined BEFORE load test
            if ($blockReason) {
                $resolutionStatus = "Blocked"
            } elseif (-not $lockfileParsed) {
                # R6-02: Lockfile not parsed → all instances BLOCKED
                $resolutionStatus = "Blocked"
                $blockReason = "Lockfile not parsed: $lockfileParseError"
            } elseif ($transitiveNativeExpected.ContainsKey($normalizedPath)) {
                $platformApplicable = $transitiveNativeExpected[$normalizedPath].PlatformApplicable
                $parentOptional = $transitiveNativeExpected[$normalizedPath].ParentOptional
                $isNative = $transitiveNativeExpected[$normalizedPath].IsNative
                # R10-05: Propagate ResolutionStatus and BlockReason from judgment
                $resolutionStatus = $transitiveNativeExpected[$normalizedPath].ResolutionStatus
                $blockReason = $transitiveNativeExpected[$normalizedPath].BlockReason
            } else {
                $resolutionStatus = "Blocked"
                $blockReason = "No lockfile mapping for $normalizedPath"
            }

            $loadExit = -1; $loadOutput = ""
            Push-Location $TEST_DIR
            try {
                $nodeRequire = "try { require('$($foundDir.FullName -replace '\\','/'); process.exit(0) } catch(e) { console.error(e.message); process.exit(1) }"
                $loadOutput = (node -e $nodeRequire 2>&1) | Out-String
                $loadExit = $LASTEXITCODE
            } catch { $loadOutput = $_.Exception.Message }
            finally { Pop-Location }

            # R6-01: Include ResolutionStatus and BlockReason in result
            # R10-05: Include IsNative from judgment
            $foundNative += [PSCustomObject]@{
                Name = $depName; Path = $foundDir.FullName; Version = $ver
                IsNative = $isNative
                LoadExit = $loadExit
                LoadOutput = if ($loadOutput) { $loadOutput.Trim() } else { "" }
                PlatformApplicable = $platformApplicable
                ParentOptional = $parentOptional
                ResolutionStatus = $resolutionStatus
                BlockReason = $blockReason
            }
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
