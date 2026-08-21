# HawkAIAgent-G0-S1-R1 Windows PoC Test Script
# =================================================
# STATUS: DEPRECATED — this script is superseded by windows-poc-test-r2.ps1
# DO NOT RUN this script. Use windows-poc-test-r2.ps1 instead.
# =================================================
# This script was the original R1 PoC script. It has been replaced because:
# 1. It used global npm install (not scoped to test directory)
# 2. It lacked deterministic PASS/FAIL and exit codes
# 3. It lacked proper process identification and cleanup
# 4. It had broad orphan process detection (by name, not PID)
# =================================================

$ErrorActionPreference = "Continue"

Write-Host "=== DEPRECATED SCRIPT ===" -ForegroundColor Red
Write-Host "This script (windows-poc-test.ps1) is deprecated." -ForegroundColor Red
Write-Host "Please use windows-poc-test-r2.ps1 instead." -ForegroundColor Red
Write-Host ""
Write-Host "Usage:" -ForegroundColor Yellow
Write-Host "  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass" -ForegroundColor Yellow
Write-Host "  .\windows-poc-test-r2.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "Exit code 2 = deprecated script invoked." -ForegroundColor Yellow

exit 2
