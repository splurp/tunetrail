# Builds the admin version of Tunetrail for Windows (debug tools included) on
# your own PC. It is never built on GitHub. The debug menu only unlocks for
# player ids listed in ADMINS on your server.
#
#   powershell -ExecutionPolicy Bypass -File tool\build_admin.ps1
#
# Settings come from admin-build.env in the repository folder (never
# committed; it's in .gitignore). The first run creates it for you to fill in.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$envFile = Join-Path $root 'admin-build.env'

if (-not (Test-Path $envFile)) {
@"
# Same values as the GitHub variables/secrets (Settings > Secrets and variables > Actions).
TUNETRAIL_SERVER=https://YOUR-SUBDOMAIN.duckdns.org
GOOGLE_SERVER_CLIENT_ID=
GOOGLE_DESKTOP_CLIENT_ID=
GOOGLE_DESKTOP_CLIENT_SECRET=
"@ | Set-Content -Encoding ascii $envFile
  Write-Host "Created $envFile - fill it in, then run this script again." -ForegroundColor Yellow
  exit 1
}

$defines = @('--dart-define=TUNETRAIL_ADMIN=true')
foreach ($line in Get-Content $envFile) {
  $l = $line.Trim()
  if ($l -eq '' -or $l.StartsWith('#')) { continue }
  $k, $v = $l -split '=', 2
  if ($v -eq '' -or $v -like '*YOUR-*') { Write-Host "Fill in $k in admin-build.env" -ForegroundColor Red; exit 1 }
  $defines += "--dart-define=$($k.Trim())=$($v.Trim())"
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Host 'Flutter is not installed or not on PATH - see docs/admin-build.md.' -ForegroundColor Red
  exit 1
}

# Flutter needs Windows Developer Mode (symlinks) to build plugins.
$dev = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
if (-not $dev -or $dev.AllowDevelopmentWithoutDevLicense -ne 1) {
  Write-Host 'Turn on Windows Developer Mode first (Flutter needs it to build plugins):' -ForegroundColor Red
  Write-Host '  Settings > System > For developers > Developer Mode  (opening it now)' -ForegroundColor Red
  Start-Process 'ms-settings:developers'
  exit 1
}

flutter pub get
if ($LASTEXITCODE -ne 0) { Write-Host 'flutter pub get failed - see the messages above.' -ForegroundColor Red; exit 1 }
flutter build windows --release --no-tree-shake-icons @defines
if ($LASTEXITCODE -ne 0) { Write-Host 'The build failed - see the messages above.' -ForegroundColor Red; exit 1 }
$out = Join-Path $root 'build\windows\x64\runner\Release'
$dest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Tunetrail-ADMIN'
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Copy-Item -Recurse $out $dest
Write-Host "Admin build ready: $dest\Tunetrail.exe  (keep it to yourself)" -ForegroundColor Green
