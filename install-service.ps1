#Requires -Version 5.1

# =========================
# НАСТРОЙКИ (МЕНЯЙ ТУТ)
# =========================
$ServiceId    = "MinIO"
$BaseDir      = "C:\MinIO"
$DataDir      = "C:\MinIOBase"
$LogsDir      = "C:\MinIO\logs"

$ApiPort      = 9000
$ConsolePort  = 9001
$BindAddress  = "0.0.0.0"     # 0.0.0.0 = все интерфейсы, 127.0.0.1 = только локально

# Root credentials (будут показаны в консоли и попадут в transcript-лог)
$RootUser     = "minioadmin"
$RootPass     = "minioadmin123"   # >= 8 chars

# URLs
$MinioUrl     = "https://dl.min.io/server/minio/release/windows-amd64/minio.exe"
$WinSwUrl     = "https://github.com/winsw/winsw/releases/download/v2.8.0/WinSW.NET4.exe"

# =========================
# ВНУТРЕННИЕ ПУТИ
# =========================
$MinioExe     = Join-Path $BaseDir "minio.exe"
$WinSwExe     = Join-Path $BaseDir "minio-service.exe"
$XmlPath      = Join-Path $BaseDir "minio-service.xml"
$ConsoleUrl   = "http://127.0.0.1:$ConsolePort"

# =========================
# УТИЛИТЫ ВЫВОДА
# =========================
$TOTAL = 10
function Step([int]$n, [string]$msg) {
  $pct = [math]::Round((($n-1) / $TOTAL) * 100, 0)
  Write-Progress -Activity "MinIO install" -Status ("Step {0}/{1}: {2}" -f $n, $TOTAL, $msg) -PercentComplete $pct
  Write-Host ("[{0}/{1}] {2}" -f $n, $TOTAL, $msg) -ForegroundColor Cyan
}
function Pause-End([string]$prompt = "Нажмите Enter для выхода...") {
  Write-Host ""
  Read-Host -Prompt $prompt | Out-Null
}

# =========================
# 0) ELEVATE (ADMIN)
# =========================
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Write-Host "Перезапуск с правами Администратора (UAC)..." -ForegroundColor Yellow
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

# =========================
# 0.1) TRANSCRIPT LOG
# =========================
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
$TranscriptPath = Join-Path $LogsDir ("install-minio-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

try {
  Start-Transcript -Path $TranscriptPath -Append | Out-Null

  Step 1 "Показываю текущие учётные данные (берутся из начала файла)"
  Write-Host "MinIO Console URL: $ConsoleUrl" -ForegroundColor Yellow
  Write-Host "LOGIN: $RootUser" -ForegroundColor Yellow
  Write-Host "PASS : $RootPass" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Чтобы изменить логин/пароль: открой этот .ps1, поменяй `$RootUser/`$RootPass, сохрани и запусти снова." -ForegroundColor Yellow
  Write-Host "После изменения creds MinIO применит их после рестарта службы (см. команды ниже)." -ForegroundColor Yellow
  Write-Host ""

  Step 2 "Создаю каталоги"
  New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
  Write-Host "BaseDir: $BaseDir"
  Write-Host "DataDir: $DataDir"
  Write-Host "LogsDir: $LogsDir"

  Step 3 "Настраиваю TLS 1.2 для скачивания"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  Step 4 "Скачиваю minio.exe (если отсутствует)"
  if (-not (Test-Path $MinioExe)) {
    Write-Host "Download: $MinioUrl"
    Invoke-WebRequest -Uri $MinioUrl -OutFile $MinioExe
  } else {
    Write-Host "OK exists: $MinioExe"
  }

  Step 5 "Скачиваю WinSW wrapper (если отсутствует)"
  if (-not (Test-Path $WinSwExe)) {
    $tmp = Join-Path $BaseDir "WinSW.NET4.exe"
    Write-Host "Download: $WinSwUrl"
    Invoke-WebRequest -Uri $WinSwUrl -OutFile $tmp
    Move-Item -Force $tmp $WinSwExe
  } else {
    Write-Host "OK exists: $WinSwExe"
  }

  Step 6 "Останавливаю/удаляю старую службу (если была)"
  try { & $WinSwExe stop      | Out-Host } catch { Write-Host "stop: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  try { & $WinSwExe uninstall | Out-Host } catch { Write-Host "uninstall: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  try { Stop-Service -Name $ServiceId -Force -ErrorAction Stop } catch {}
  try { sc.exe delete $ServiceId | Out-Null } catch {}
  Start-Sleep -Seconds 1

  Step 7 "Генерирую minio-service.xml"
  $config = @"
<service>
  <id>$ServiceId</id>
  <name>$ServiceId</name>
  <description>MinIO object storage server</description>

  <executable>$MinioExe</executable>

  <env name="MINIO_ROOT_USER" value="$RootUser"/>
  <env name="MINIO_ROOT_PASSWORD" value="$RootPass"/>

  <arguments>server "$DataDir" --address $BindAddress`:$ApiPort --console-address $BindAddress`:$ConsolePort</arguments>

  <workingdirectory>$BaseDir</workingdirectory>

  <logpath>$LogsDir</logpath>
  <log mode="append"/>
</service>
"@
  Set-Content -Encoding UTF8 -Path $XmlPath -Value $config
  Write-Host "XML path: $XmlPath"

  Step 8 "Устанавливаю службу и ставлю автозапуск"
  & $WinSwExe install | Out-Host
  sc.exe config $ServiceId start= auto | Out-Null

  Step 9 "Запускаю службу и показываю статус"
  & $WinSwExe start | Out-Host
  Start-Sleep -Seconds 1

  $svc = Get-Service -Name $ServiceId -ErrorAction SilentlyContinue
  if (-not $svc) { throw "Service '$ServiceId' not found after install." }

  Write-Host "Service status (SCM): $($svc.Status)" -ForegroundColor Green
  if ($svc.Status -ne "Running") {
    Write-Host "Служба не запущена." -ForegroundColor Red
    Write-Host "Смотри: $LogsDir\minio-service.err.log и $LogsDir\minio-service.out.log" -ForegroundColor Yellow
    throw "MinIO service is not running."
  }

  Step 10 "Проверяю доступность консоли (до 10 секунд)"
  $ok = $false
  for ($i=1; $i -le 10; $i++) {
    Write-Progress -Activity "MinIO install" -Status "Console check $i/10 ($ConsoleUrl)" -PercentComplete 100
    try {
      Invoke-WebRequest -Uri $ConsoleUrl -UseBasicParsing -TimeoutSec 2 | Out-Null
      $ok = $true
      break
    } catch { Start-Sleep -Seconds 1 }
  }

  if ($ok) {
    Write-Host "Console OK: $ConsoleUrl" -ForegroundColor Green
  } else {
    Write-Host "Console пока не отвечает: $ConsoleUrl" -ForegroundColor Yellow
  }

  Write-Progress -Activity "MinIO install" -Completed
  Write-Host ""
  Write-Host "ГОТОВО." -ForegroundColor Green
  Write-Host "LOGIN: $RootUser"
  Write-Host "PASS : $RootPass"
  Write-Host "Console: $ConsoleUrl"
  Write-Host "Transcript log: $TranscriptPath"
  Write-Host "MinIO/WinSW logs: $LogsDir\minio-service.out.log, $LogsDir\minio-service.err.log"
  Write-Host ""
  Write-Host "Если поменял creds в начале файла: перезапусти службу командами:" -ForegroundColor Yellow
  Write-Host "  net stop $ServiceId"
  Write-Host "  net start $ServiceId"
}
catch {
  Write-Host ""
  Write-Host "ОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Transcript log: $TranscriptPath" -ForegroundColor Yellow
  Write-Host "Проверь логи: $LogsDir\minio-service.err.log и Windows Event Viewer" -ForegroundColor Yellow
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
  Pause-End "Нажмите Enter для выхода..."
}
