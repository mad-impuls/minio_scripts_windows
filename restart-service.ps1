#Requires -Version 5.1

# Elevate
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole] "Administrator"
)) {
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

$WinSwExe     = "C:\MinIO\minio-service.exe"
$ServiceName  = "MinIO"
$TimeoutSec   = 60

if (-not (Test-Path $WinSwExe)) { throw "Not found: $WinSwExe" }

Write-Host "Restarting '$ServiceName'..." -ForegroundColor Cyan

try {
  & $WinSwExe restart | Out-Host
} catch {
  Write-Host "WinSW restart failed, trying stop + start..." -ForegroundColor Yellow
  & $WinSwExe stop  | Out-Host
  & $WinSwExe start | Out-Host
}

# Wait for Running (or timeout)
$svc = Get-Service -Name $ServiceName -ErrorAction Stop
$ts  = New-TimeSpan -Seconds $TimeoutSec

Write-Host "Waiting up to $TimeoutSec sec for service to become Running..." -ForegroundColor Cyan

try {
  $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, $ts)  # waits with polling [web:123]
} catch {
  # timeout or other failure
}

# Refresh and show final status
$svc.Refresh()
Write-Host "Service status (SCM): $($svc.Status)" -ForegroundColor Cyan

if ($svc.Status -ne "Running") {
  Write-Host "Service did not reach Running within $TimeoutSec sec (or failed)." -ForegroundColor Red
  Write-Host "Check: C:\MinIO\logs\minio-service.err.log and Windows Event Viewer." -ForegroundColor Yellow
}

Read-Host -Prompt "Нажмите Enter для выхода..." | Out-Null
