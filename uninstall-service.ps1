#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Elevate (Admin) + keep windows open
# -----------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $IsAdmin) {
  Write-Host "Перезапуск с правами Администратора (UAC)..." -ForegroundColor Yellow

  # -NoExit чтобы админское окно не закрылось сразу после выполнения
  $argLine = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
  Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argLine

  Read-Host "Это окно (не-админ) можно закрыть. Нажмите Enter..." | Out-Null
  exit
}

function Ask-YesNo([string]$q, [bool]$defaultNo = $true) {
  $suffix = $(if ($defaultNo) { " [y/N]" } else { " [Y/n]" })
  $a = Read-Host ($q + $suffix)
  if ([string]::IsNullOrWhiteSpace($a)) { return -not $defaultNo }
  return ($a -match '^(y|yes|д|да)$')
}
function Pause-End([string]$prompt = "Нажмите Enter для выхода...") { Read-Host -Prompt $prompt | Out-Null }
function TryRun([scriptblock]$sb) { try { & $sb } catch {} }

# -----------------------------
# Settings (adapt if needed)
# -----------------------------
$ServiceName = "MinIO"
$MinioDir    = "C:\MinIO"
$DataDir     = "C:\MinIOBase"
$LogsDir     = "C:\MinIO\logs"
$WinSwExe    = Join-Path $MinioDir "minio-service.exe"

# Transcript (в TEMP, чтобы не удалить вместе с LogsDir)
$TranscriptPath = Join-Path $env:TEMP ("minio-uninstall-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $TranscriptPath -Append | Out-Null

try {
  Write-Host ""
  Write-Host "=== MinIO FULL UNINSTALL (interactive) ===" -ForegroundColor Cyan
  Write-Host "Service     : $ServiceName"
  Write-Host "MinioDir    : $MinioDir"
  Write-Host "DataDir     : $DataDir  (ВАЖНО: удаление = потеря всех объектов)"
  Write-Host "LogsDir     : $LogsDir"
  Write-Host "WinSW path  : $WinSwExe"
  Write-Host "Transcript  : $TranscriptPath"
  Write-Host ""

  # -----------------------------
  # Detect mc config candidates (best-effort)
  # -----------------------------
  $mcCandidates = New-Object System.Collections.Generic.List[string]
  $mcEnvMachine = [Environment]::GetEnvironmentVariable("MC_CONFIG_DIR", "Machine")
  $mcEnvUser    = [Environment]::GetEnvironmentVariable("MC_CONFIG_DIR", "User")
  if ($mcEnvMachine) { $mcCandidates.Add($mcEnvMachine) }
  if ($mcEnvUser)    { $mcCandidates.Add($mcEnvUser) }

  if ($env:USERPROFILE) {
    $mcCandidates.Add((Join-Path $env:USERPROFILE "mc"))
    $mcCandidates.Add((Join-Path $env:USERPROFILE ".mc"))
  }
  if ($env:APPDATA) {
    $mcCandidates.Add((Join-Path $env:APPDATA "mc"))
    $mcCandidates.Add((Join-Path $env:APPDATA ".mc"))
  }

  $mcCandidates = $mcCandidates | Where-Object { $_ -and $_.Trim() -ne "" } | Select-Object -Unique

  # -----------------------------
  # User choices
  # -----------------------------
  Write-Host "Выбери, что удалять:" -ForegroundColor Yellow
  $RemoveService   = Ask-YesNo "1) Удалить службу Windows ($ServiceName)?" $false
  $RemoveBinaries  = Ask-YesNo "2) Удалить MinioDir (binaries/wrapper/xml) = $MinioDir ?" $true
  $RemoveLogs      = Ask-YesNo "3) Удалить LogsDir = $LogsDir ?" $true
  $RemoveData      = Ask-YesNo "4) Удалить DataDir (ДАННЫЕ! все бакеты/объекты) = $DataDir ?" $true
  $RemoveFirewall  = Ask-YesNo "5) Удалить firewall rules (DisplayName содержит 'MinIO')?" $true
  $RemoveMcConfig  = Ask-YesNo "6) Удалить конфиги mc (если найдутся в кандидатов)?" $true
  $RemoveEnvVars   = Ask-YesNo "7) Удалить системные ENV MINIO_* и MC_CONFIG_DIR (Machine+User) если заданы?" $true

  Write-Host ""
  Write-Host "План:" -ForegroundColor Yellow
  Write-Host "- RemoveService  : $RemoveService"
  Write-Host "- RemoveBinaries : $RemoveBinaries"
  Write-Host "- RemoveLogs     : $RemoveLogs"
  Write-Host "- RemoveData     : $RemoveData"
  Write-Host "- RemoveFirewall : $RemoveFirewall"
  Write-Host "- RemoveMcConfig : $RemoveMcConfig"
  Write-Host "- RemoveEnvVars  : $RemoveEnvVars"
  Write-Host ""

  if (-not (Ask-YesNo "Продолжить?" $false)) { throw "Отменено пользователем." }

  # -----------------------------
  # A) Remove service
  # -----------------------------
  if ($RemoveService) {
    Write-Host ""
    Write-Host "[A] Stop service (если есть)..." -ForegroundColor Cyan
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
      TryRun { Stop-Service -Name $ServiceName -Force }
      TryRun { sc.exe stop $ServiceName | Out-Null }

      TryRun { $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, (New-TimeSpan -Seconds 30)) }
      $svc.Refresh()
      Write-Host "Status after stop: $($svc.Status)"
    } else {
      Write-Host "Service not found in SCM (возможно уже удалена)." -ForegroundColor DarkYellow
    }

    Write-Host "[B] WinSW uninstall (если wrapper существует)..." -ForegroundColor Cyan
    if (Test-Path $WinSwExe) {
      TryRun { & $WinSwExe uninstall | Out-Host }
    } else {
      Write-Host "WinSW wrapper не найден, пропускаю." -ForegroundColor DarkYellow
    }

    Write-Host "[C] sc delete..." -ForegroundColor Cyan
    TryRun { sc.exe delete $ServiceName | Out-Host }

    Write-Host "[D] Ожидание исчезновения службы из SCM..." -ForegroundColor Cyan
    for ($i=0; $i -lt 80; $i++) {
      if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
      Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
      throw "Служба '$ServiceName' ещё существует (возможно marked for deletion). Закрой services.msc/MMC (mmc.exe) и повтори."
    }

    Write-Host "Service removed: $ServiceName" -ForegroundColor Green
  }

  # -----------------------------
  # B) Remove firewall rules (by name pattern)
  # -----------------------------
  if ($RemoveFirewall) {
    Write-Host ""
    Write-Host "[E] Firewall cleanup (по DisplayName содержит 'MinIO')..." -ForegroundColor Cyan

    $rules = @()
    TryRun { $rules = Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -like "*MinIO*" } }

    if (-not $rules -or $rules.Count -eq 0) {
      Write-Host "Firewall rules с 'MinIO' не найдены." -ForegroundColor DarkYellow
    } else {
      $rules | Select-Object DisplayName, Enabled, Direction, Action | Format-Table -AutoSize | Out-Host
      if (Ask-YesNo "Удалить ВСЕ найденные правила?" $false) {
        $rules | Remove-NetFirewallRule
        Write-Host "Firewall rules removed." -ForegroundColor Green
      } else {
        Write-Host "Firewall rules оставлены." -ForegroundColor DarkYellow
      }
    }
  }

  # -----------------------------
  # C) Remove mc config
  # -----------------------------
  if ($RemoveMcConfig) {
    Write-Host ""
    Write-Host "[F] mc config cleanup..." -ForegroundColor Cyan

    $existing = @()
    foreach ($p in $mcCandidates) {
      if (Test-Path $p) { $existing += $p }
    }
    $existing = $existing | Select-Object -Unique

    if (-not $existing -or $existing.Count -eq 0) {
      Write-Host "mc config dirs не найдены (из известных путей)." -ForegroundColor DarkYellow
    } else {
      Write-Host "Найдены кандидаты:" -ForegroundColor Yellow
      $existing | ForEach-Object { Write-Host " - $_" }

      if (Ask-YesNo "Удалить эти каталоги?" $false) {
        foreach ($p in $existing) {
          Remove-Item -Recurse -Force $p
          Write-Host "Removed: $p" -ForegroundColor Green
        }
      } else {
        Write-Host "mc config оставлен." -ForegroundColor DarkYellow
      }
    }
  }

  # -----------------------------
  # D) Remove env vars
  # -----------------------------
  if ($RemoveEnvVars) {
    Write-Host ""
    Write-Host "[G] ENV cleanup (Machine+User)..." -ForegroundColor Cyan

    $names = @(
      "MINIO_ROOT_USER","MINIO_ROOT_PASSWORD",
      "MINIO_ACCESS_KEY","MINIO_SECRET_KEY",
      "MC_CONFIG_DIR"
    )

    foreach ($scope in @("Machine","User")) {
      foreach ($n in $names) {
        $v = [Environment]::GetEnvironmentVariable($n, $scope)
        if ($v) {
          Write-Host "$scope ENV найдено: $n=$v" -ForegroundColor Yellow
          if (Ask-YesNo "Удалить $n в scope=$scope ?" $true) {
            [Environment]::SetEnvironmentVariable($n, $null, $scope)
            Write-Host "Deleted: $scope $n" -ForegroundColor Green
          }
        }
      }
    }
  }

  # -----------------------------
  # E) Remove directories
  # -----------------------------
  if ($RemoveLogs -and (Test-Path $LogsDir)) {
    Write-Host ""
    Write-Host "[H] Removing LogsDir..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $LogsDir
    Write-Host "Removed: $LogsDir" -ForegroundColor Green
  }

  if ($RemoveData -and (Test-Path $DataDir)) {
    Write-Host ""
    Write-Host "[I] Removing DataDir (ДАННЫЕ!)..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $DataDir
    Write-Host "Removed: $DataDir" -ForegroundColor Green
  }

  if ($RemoveBinaries -and (Test-Path $MinioDir)) {
    Write-Host ""
    Write-Host "[J] Removing MinioDir..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $MinioDir
    Write-Host "Removed: $MinioDir" -ForegroundColor Green
  }

  Write-Host ""
  Write-Host "ГОТОВО. Transcript: $TranscriptPath" -ForegroundColor Green
}
catch {
  Write-Host ""
  Write-Host ("ОШИБКА: {0}" -f $_.Exception.Message) -ForegroundColor Red
  Write-Host ("Transcript: {0}" -f $TranscriptPath) -ForegroundColor Yellow
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
  Pause-End
}
