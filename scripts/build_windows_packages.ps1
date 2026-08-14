[CmdletBinding()]
param(
  [string]$Version = "",
  [string]$SingBoxPath = "",
  [string]$DaemonPath = "",
  [string]$CliPath = "",
  [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$FlutterDir = Join-Path $Root 'flutter'
$DistRoot = Join-Path $Root 'dist\windows'
$PortableDir = Join-Path $DistRoot 'MosaicVPN'

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = ((Select-String -Path (Join-Path $FlutterDir 'pubspec.yaml') -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value -split '\+')[0]
}

function Require-File([string]$Path, [string]$Hint) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required file is missing: $Path`n$Hint"
  }
}

Push-Location $FlutterDir
try {
  flutter pub get
  flutter build windows --release
} finally {
  Pop-Location
}

$Bundle = Join-Path $FlutterDir 'build\windows\x64\runner\Release'
Require-File (Join-Path $Bundle 'MosaicVPN.exe') 'Verify flutter/windows/CMakeLists.txt sets BINARY_NAME to MosaicVPN.'
Require-File $DaemonPath 'Pass -DaemonPath to the signed/verified mosaicd.exe artifact.'
Require-File $SingBoxPath 'Pass -SingBoxPath to the signed/verified sing-box.exe artifact.'
if (-not [string]::IsNullOrWhiteSpace($CliPath)) { Require-File $CliPath 'Pass a valid mosaic.exe path or omit -CliPath.' }

Remove-Item -Force -Recurse $PortableDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $PortableDir -Force | Out-Null
Copy-Item -Recurse -Force (Join-Path $Bundle '*') $PortableDir
Copy-Item -Force $DaemonPath (Join-Path $PortableDir 'mosaicd.exe')
Copy-Item -Force $SingBoxPath (Join-Path $PortableDir 'sing-box.exe')
if (-not [string]::IsNullOrWhiteSpace($CliPath)) { Copy-Item -Force $CliPath (Join-Path $PortableDir 'mosaic.exe') }

$Readme = @"
MosaicVPN $Version — Windows portable

1. Run MosaicVPN.exe.
2. Sign in or connect the application with your MosaicVPN account.
3. Keep mosaicd.exe and sing-box.exe next to MosaicVPN.exe; the client requires both files.

For assisted installation, use the matching MosaicVPN-Setup-x64-v$Version.exe installer.
"@
Set-Content -Path (Join-Path $PortableDir 'README.txt') -Value $Readme -Encoding utf8

$ZipPath = Join-Path $DistRoot "MosaicVPN-Portable-x64-v$Version.zip"
Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
Compress-Archive -Path $PortableDir -DestinationPath $ZipPath -CompressionLevel Optimal
Write-Host "Created portable archive: $ZipPath"

if (-not $SkipInstaller) {
  $Iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
  if (-not $Iscc) { $Iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source }
  if (-not $Iscc) {
    throw 'Inno Setup 6 is not available. Install it, add ISCC to PATH, then rerun without -SkipInstaller.'
  }
  & $Iscc "/DSourceDir=$PortableDir" "/DVersion=$Version" (Join-Path $Root 'scripts\setup.iss')
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup exited with code $LASTEXITCODE" }
  Write-Host "Created installer in: $(Split-Path -Parent $PortableDir)"
}
