# HawkAIAgent G0-S1-R2 Windows PoC Test Script
# =================================================
# SAFETY: No admin required. No system modifications.
# All operations scoped to $env:TEMP\hawkai-poc-*
# =================================================

$ErrorActionPreference = "Continue"

# === Config ===
$DSH_VERSION = "0.1.0-rc.8"
$TEST_PORT = 3080
$TEST_DIR = Join-Path $env:TEMP "hawkai-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$DSH_HOME = Join-Path $TEST_DIR "dsh-home"
$WORKSPACE = Join-Path $TEST_DIR "workspace"
$NPM_DIR = Join-Path $TEST_DIR "npm-global"

# === Setup ===
Write-Host "=== HawkAIAgent G0-S1-R2 Windows PoC ===" -ForegroundColor Cyan
Write-Host "Test dir: $TEST_DIR"
Write-Host "DSH_HOME: $DSH_HOME"

New-Item -ItemType Directory -Path $DSH_HOME -Force | Out-Null
New-Item -ItemType Directory -Path $WORKSPACE -Force | Out-Null
New-Item -ItemType Directory -Path $NPM_DIR -Force | Out-Null

# === Environment Info ===
Write-Host "`n=== Environment ===" -ForegroundColor Cyan
Write-Host "Windows: $([System.Environment]::OSVersion.VersionString)"
Write-Host "Architecture: $(if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })"
Write-Host "Node: $(node -v 2>&1)"
Write-Host "npm: $(npm -v 2>&1)"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

# === Install dsh (local, not global) ===
Write-Host "`n=== Installing dsh@$DSH_VERSION (local) ===" -ForegroundColor Cyan
$env:DSH_HOME = $DSH_HOME
$env:NPM_CONFIG_PREFIX = $NPM_DIR

# Install to temp dir, not global
Push-Location $TEST_DIR
npm init -y 2>&1 | Out-Null
npm install "@deepseek-ai/dsh@$DSH_VERSION" 2>&1 | Tee-Object -Variable installOutput
$installExit = $LASTEXITCODE
Write-Host "Install exit code: $installExit"
Pop-Location

# Verify installation
$dshBin = Join-Path $TEST_DIR "node_modules" ".bin" "dsh.cmd"
if (Test-Path $dshBin) {
  $dshVersion = & $dshBin --version 2>&1
  Write-Host "dsh version: $dshVersion"
} else {
  Write-Host "dsh binary not found at: $dshBin" -ForegroundColor Red
  Write-Host "Trying npx..."
  $dshBin = "npx"
  $dshArgs = @("-y", "@deepseek-ai/dsh@$DSH_VERSION")
}

# === Test 1: Startup (no Key) ===
Write-Host "`n=== Test 1: Startup without API Key ===" -ForegroundColor Cyan
$env:DEEPSEEK_API_KEY = ""

# Build command
if ($dshBin -eq "npx") {
  $startArgs = @("-y", "@deepseek-ai/dsh@$DSH_VERSION", "web", "--no-open", "--port", $TEST_PORT)
} else {
  $startArgs = @("web", "--no-open", "--port", $TEST_PORT)
}

$stdoutLog = Join-Path $TEST_DIR "stdout.log"
$stderrLog = Join-Path $TEST_DIR "stderr.log"

$process = Start-Process -FilePath $dshBin -ArgumentList $startArgs `
  -PassThru -RedirectStandardOutput $stdoutLog `
  -RedirectStandardError $stderrLog -NoNewWindow `
  -WorkingDirectory $WORKSPACE

Write-Host "PID: $($process.Id)"
Write-Host "Waiting for readiness (max 30s)..."

# Readiness probe
$maxWait = 30
$ready = $false
for ($i = 0; $i -lt $maxWait; $i++) {
  Start-Sleep -Seconds 1
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
      -Method POST -ContentType "application/json" `
      -Body '{"method":"host.describe"}' -TimeoutSec 3 -ErrorAction Stop
    if ($response.StatusCode -eq 200) {
      $ready = $true
      Write-Host "Ready after $($i + 1) seconds" -ForegroundColor Green
      break
    }
  } catch {
    # Not ready yet
  }
}

if (-not $ready) {
  Write-Host "Readiness timeout after $maxWait seconds" -ForegroundColor Red
  Write-Host "stdout (last 20 lines):"
  Get-Content $stdoutLog -Tail 20 -ErrorAction SilentlyContinue
  Write-Host "stderr (last 20 lines):"
  Get-Content $stderrLog -Tail 20 -ErrorAction SilentlyContinue
}

# === Test 2: host.describe ===
if ($ready) {
  Write-Host "`n=== Test 2: host.describe ===" -ForegroundColor Cyan
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
      -Method POST -ContentType "application/json" `
      -Body '{"method":"host.describe"}' -TimeoutSec 5
    Write-Host "Status: $($response.StatusCode)" -ForegroundColor Green
    Write-Host "Response (first 500 chars): $($response.Content.Substring(0, [Math]::Min(500, $response.Content.Length)))"
  } catch {
    Write-Host "host.describe failed: $($_.Exception.Message)" -ForegroundColor Red
  }
}

# === Test 3: WebSocket endpoints ===
if ($ready) {
  Write-Host "`n=== Test 3: WebSocket endpoints ===" -ForegroundColor Cyan

  foreach ($path in @("events.mux", "events.host")) {
    try {
      $ws = [System.Net.WebSockets.ClientWebSocket]::new()
      $ws.Options.SetRequestHeader("Host", "127.0.0.1:$TEST_PORT")
      $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/$path")
      $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
      if ($connectTask.Wait(5000)) {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
          Write-Host "/api/$path : Connected" -ForegroundColor Green
          $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
        } else {
          Write-Host "/api/$path : State=$($ws.State)" -ForegroundColor Yellow
        }
      } else {
        Write-Host "/api/$path : Connect timeout" -ForegroundColor Yellow
      }
    } catch {
      Write-Host "/api/$path : $($_.Exception.Message)" -ForegroundColor Red
    }
  }
}

# === Test 4: No-Key error path ===
if ($ready) {
  Write-Host "`n=== Test 4: No-Key error path ===" -ForegroundColor Cyan
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
      -Method POST -ContentType "application/json" `
      -Body '{"method":"session.create","params":{}}' -TimeoutSec 10 -ErrorAction Stop
    Write-Host "Status: $($response.StatusCode)"
    Write-Host "Response: $($response.Content.Substring(0, [Math]::Min(500, $response.Content.Length)))"
  } catch {
    Write-Host "Expected error (no key): $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# === Test 5: Graceful shutdown ===
Write-Host "`n=== Test 5: Graceful shutdown ===" -ForegroundColor Cyan
if (!$process.HasExited) {
  # Try graceful close first (CloseMainWindow sends WM_CLOSE)
  $closed = $process.CloseMainWindow()
  if ($closed) {
    $exited = $process.WaitForExit(5000)
    if ($exited) {
      Write-Host "Graceful shutdown, exit code: $($process.ExitCode)" -ForegroundColor Green
    } else {
      Write-Host "Graceful shutdown timeout, force killing..." -ForegroundColor Yellow
      $process.Kill()
      $process.WaitForExit(3000)
      Write-Host "Force killed, exit code: $($process.ExitCode)"
    }
  } else {
    Write-Host "CloseMainWindow failed (no window?), killing..."
    $process.Kill()
    $process.WaitForExit(3000)
    Write-Host "Killed, exit code: $($process.ExitCode)"
  }
} else {
  Write-Host "Process already exited, code: $($process.ExitCode)"
}

# === Test 6: Orphan process check ===
Write-Host "`n=== Test 6: Orphan process check ===" -ForegroundColor Cyan
$testStartTime = (Get-Date).AddMinutes(-2)
$nodeProcs = Get-Process -Name "node" -ErrorAction SilentlyContinue |
  Where-Object { $_.StartTime -gt $testStartTime -and $_.Id -ne $PID }
if ($nodeProcs) {
  Write-Host "Potential orphan node processes:" -ForegroundColor Yellow
  $nodeProcs | Format-Table Id, ProcessName, StartTime, Path -AutoSize
} else {
  Write-Host "No orphan node processes" -ForegroundColor Green
}

# === Test 7: Port release ===
Write-Host "`n=== Test 7: Port release ===" -ForegroundColor Cyan
Start-Sleep -Seconds 2
$portInUse = Get-NetTCPConnection -LocalPort $TEST_PORT -ErrorAction SilentlyContinue
if ($portInUse) {
  Write-Host "Port $TEST_PORT still in use" -ForegroundColor Yellow
} else {
  Write-Host "Port $TEST_PORT released" -ForegroundColor Green
}

# === Summary ===
Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan
Write-Host "Please copy ALL output above (from '=== HawkAIAgent' to here)"
Write-Host "and send it back to the agent."
Write-Host ""
Write-Host "Test dir: $TEST_DIR"
Write-Host "To cleanup: Remove-Item -Recurse -Force '$TEST_DIR'"
Write-Host ""
Write-Host "Do NOT cleanup if you want to inspect logs."
