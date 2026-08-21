# HawkAIAgent-G0-S1-R1 Windows PoC Test Script
# Run on Windows 11 x64 with Node.js 22+ installed
# Requires: npm, PowerShell 5.1+

$ErrorActionPreference = "Continue"

# === Config ===
$DSH_VERSION = "0.1.0-rc.8"
$TEST_PORT = 3080
$TEST_DIR = Join-Path $env:TEMP "hawkai-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$DSH_HOME = Join-Path $TEST_DIR "dsh-home"
$WORKSPACE = Join-Path $TEST_DIR "workspace"

# === Setup ===
Write-Host "=== HawkAIAgent G0-S1-R1 Windows PoC ===" -ForegroundColor Cyan
Write-Host "Test dir: $TEST_DIR"
Write-Host "DSH_HOME: $DSH_HOME"

New-Item -ItemType Directory -Path $DSH_HOME -Force | Out-Null
New-Item -ItemType Directory -Path $WORKSPACE -Force | Out-Null

# === Environment Info ===
Write-Host "`n=== Environment ===" -ForegroundColor Cyan
Write-Host "Windows: $([System.Environment]::OSVersion.VersionString)"
Write-Host "Architecture: $([System.Environment]::Is64BitOperatingSystem ? 'x64' : 'x86')"
Write-Host "Node: $(node -v)"
Write-Host "npm: $(npm -v)"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

# === Install dsh ===
Write-Host "`n=== Installing dsh@$DSH_VERSION ===" -ForegroundColor Cyan
$env:DSH_HOME = $DSH_HOME
npm install -g "@deepseek-ai/dsh@$DSH_VERSION" 2>&1 | Tee-Object -Variable installOutput
Write-Host "Install exit code: $LASTEXITCODE"

# Verify installation
$dshVersion = dsh --version 2>&1
Write-Host "dsh version: $dshVersion"

# === Test 1: Startup (no Key) ===
Write-Host "`n=== Test 1: Startup without API Key ===" -ForegroundColor Cyan
$env:DEEPSEEK_API_KEY = ""

$process = Start-Process -FilePath "dsh" -ArgumentList "web", "--no-open", "--port", $TEST_PORT `
  -PassThru -RedirectStandardOutput "$TEST_DIR\stdout.log" `
  -RedirectStandardError "$TEST_DIR\stderr.log" -NoNewWindow

Write-Host "PID: $($process.Id)"
Write-Host "Waiting for readiness..."

# Readiness probe (not fixed sleep)
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
      Write-Host "✅ Ready after $($i + 1) seconds" -ForegroundColor Green
      Write-Host "Response: $($response.Content | Select-String -Pattern '.*' | Select-Object -First 5)"
      break
    }
  } catch {
    # Not ready yet
  }
}

if (-not $ready) {
  Write-Host "❌ Readiness timeout after $maxWait seconds" -ForegroundColor Red
  Write-Host "stdout: $(Get-Content "$TEST_DIR\stdout.log" -Tail 20)"
  Write-Host "stderr: $(Get-Content "$TEST_DIR\stderr.log" -Tail 20)"
}

# === Test 2: WebSocket endpoints ===
if ($ready) {
  Write-Host "`n=== Test 2: WebSocket endpoints ===" -ForegroundColor Cyan
  
  # Test events.mux upgrade
  try {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader("Host", "127.0.0.1:$TEST_PORT")
    $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.mux")
    $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait(5000)
    if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      Write-Host "✅ /api/events.mux: Connected" -ForegroundColor Green
      $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000)
    } else {
      Write-Host "❌ /api/events.mux: State=$($ws.State)" -ForegroundColor Red
    }
  } catch {
    Write-Host "❌ /api/events.mux: $($_.Exception.Message)" -ForegroundColor Red
  }

  # Test events.host upgrade
  try {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.SetRequestHeader("Host", "127.0.0.1:$TEST_PORT")
    $uri = [Uri]::new("ws://127.0.0.1:$TEST_PORT/api/events.host")
    $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait(5000)
    if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      Write-Host "✅ /api/events.host: Connected" -ForegroundColor Green
      $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait(2000)
    } else {
      Write-Host "❌ /api/events.host: State=$($ws.State)" -ForegroundColor Red
    }
  } catch {
    Write-Host "❌ /api/events.host: $($_.Exception.Message)" -ForegroundColor Red
  }
}

# === Test 3: host.describe ===
if ($ready) {
  Write-Host "`n=== Test 3: host.describe ===" -ForegroundColor Cyan
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
      -Method POST -ContentType "application/json" `
      -Body '{"method":"host.describe"}' -TimeoutSec 5
    Write-Host "✅ host.describe: $($response.StatusCode)" -ForegroundColor Green
    Write-Host "Response: $($response.Content.Substring(0, [Math]::Min(500, $response.Content.Length)))"
  } catch {
    Write-Host "❌ host.describe: $($_.Exception.Message)" -ForegroundColor Red
  }
}

# === Test 4: No-Key error path ===
if ($ready) {
  Write-Host "`n=== Test 4: No-Key error path ===" -ForegroundColor Cyan
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$TEST_PORT/api" `
      -Method POST -ContentType "application/json" `
      -Body '{"method":"session.create","params":{"prompt":"hello"}}' -TimeoutSec 10
    Write-Host "Response: $($response.Content.Substring(0, [Math]::Min(500, $response.Content.Length)))"
  } catch {
    Write-Host "Expected error (no key): $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# === Test 5: Shutdown ===
Write-Host "`n=== Test 5: Shutdown ===" -ForegroundColor Cyan
if (!$process.HasExited) {
  $process.Kill()
  $process.WaitForExit(5000)
  Write-Host "Process killed, exit code: $($process.ExitCode)"
} else {
  Write-Host "Process already exited, code: $($process.ExitCode)"
}

# === Test 6: Orphan check ===
Write-Host "`n=== Test 6: Orphan process check ===" -ForegroundColor Cyan
$orphans = Get-Process -Name "node","dsh","powershell" -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -ne $PID -and $_.StartTime -gt (Get-Date).AddMinutes(-5) }
if ($orphans) {
  Write-Host "⚠️ Potential orphans:" -ForegroundColor Yellow
  $orphans | Format-Table Id, ProcessName, StartTime
} else {
  Write-Host "✅ No orphan processes" -ForegroundColor Green
}

# === Test 7: Port check ===
Write-Host "`n=== Test 7: Port release check ===" -ForegroundColor Cyan
$portInUse = Get-NetTCPConnection -LocalPort $TEST_PORT -ErrorAction SilentlyContinue
if ($portInUse) {
  Write-Host "⚠️ Port $TEST_PORT still in use" -ForegroundColor Yellow
} else {
  Write-Host "✅ Port $TEST_PORT released" -ForegroundColor Green
}

# === Cleanup ===
Write-Host "`n=== Cleanup ===" -ForegroundColor Cyan
Write-Host "Test artifacts at: $TEST_DIR"
Write-Host "To cleanup: Remove-Item -Recurse -Force '$TEST_DIR'"

# === Summary ===
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Please copy ALL output above and send back to the agent."
Write-Host "Include any error messages verbatim."
