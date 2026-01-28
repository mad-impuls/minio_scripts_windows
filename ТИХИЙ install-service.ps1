#Requires -Version 5.1

# =========================
# НАСТРОЙКИ (меняй тут)
# =========================
$ServiceId    = "MinIO"               # <id> сервиса (то, что увидишь в services.msc)
$BaseDir      = "C:\MinIO"            # где лежат minio.exe и winsw wrapper
$DataDir      = "C:\MinIOBase"        # каталог данных
$LogsDir      = "C:\MinIO\logs"       # каталог логов winsw/minio

$ApiPort      = 9000
$ConsolePort  = 9001
$BindAddress  = "0.0.0.0"             # 0.0.0.0 = слушать на всех интерфейсах (можно 127.0.0.1)

$RootUser     = "minioadmin"
$RootPass     = "minioadmin123"       # >= 8 chars

# URLs
$MinioUrl     = "https://dl.min.io/server/minio/release/windows-amd64/minio.exe"
$WinSwUrl     = "https://github.com/winsw/winsw/releases/download/v2.8.0/WinSW.NET4.exe"

# Files
$MinioExe     = Join-Path $BaseDir "minio.exe"
$WinSwExe     = Join-Path $BaseDir "minio-service.exe"
$XmlPath      = Join-Path $BaseDir "minio-service.xml"

$ConsoleUrl   = "http://127.0.0.1:$ConsolePort"

# =========================
# 0) Elevate (Admin)
# =========================
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

# =========================
# 1) Ensure folders
# =========================
New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

# =========================
# 2) Download binaries (if missing)
# =========================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $MinioExe)) {
  Invoke-WebRequest -Uri $MinioUrl -OutFile $MinioExe
}

if (-not (Test-Path $WinSwExe)) {
  $tmp = Join-Path $BaseDir "WinSW.NET4.exe"
  Invoke-WebRequest -Uri $WinSwUrl -OutFile $tmp
  Move-Item -Force $tmp $WinSwExe
}

# =========================
# 3) Stop + uninstall old service (clean, via WinSW)
# =========================
try { & $WinSwExe stop | Out-Null } catch {}
try { & $WinSwExe uninstall | Out-Null } catch {}

# Подстраховка: если в SCM всё ещё висит сервис с таким именем
try { Stop-Service -Name $ServiceId -Force -ErrorAction Stop } catch {}
try { sc.exe delete $ServiceId | Out-Null } catch {}

Start-Sleep -Seconds 1

# =========================
# 4) Write WinSW XML
# =========================
# В arguments:
# - DataDir в кавычках (на случай пробелов)
# - порты без кавычек, чтобы исключить странности парсинга
$config = @"
<service>
  <id>$ServiceId</id>
  <name>$ServiceId</name>
  <description>MinIO is a high performance object storage server</description>

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

# =========================
# 5) Install + start
# =========================
& $WinSwExe install | Out-Null
sc.exe config $ServiceId start= auto | Out-Null
& $WinSwExe start | Out-Null

# =========================
# 6) Verify
# =========================
Start-Sleep -Seconds 1
$svc = Get-Service -Name $ServiceId -ErrorAction SilentlyContinue
if (-not $svc) {
  throw "Service '$ServiceId' not found after install."
}

Write-Host "Service status (SCM): $($svc.Status)"
if ($svc.Status -ne "Running") {
  Write-Host "Check logs: $LogsDir\minio-service.err.log and $LogsDir\minio-service.out.log"
  Write-Host "Also check Windows Event Viewer (Application/System)."
  throw "MinIO service is not running."
}

# wait up to ~10s for console port
$ok = $false
for ($i=0; $i -lt 10; $i++) {
  try {
    Invoke-WebRequest -Uri $ConsoleUrl -UseBasicParsing -TimeoutSec 2 | Out-Null
    $ok = $true
    break
  } catch {
    Start-Sleep -Seconds 1
  }
}

if ($ok) {
  Write-Host "Console OK: $ConsoleUrl"
} else {
  Write-Host "Console not reachable yet: $ConsoleUrl"
  Write-Host "If service is Running, check firewall/bind address/ports and logs."
}

Write-Host "Done."
