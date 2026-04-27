# Mosaic - Windows dev runner.
#
# Builds mosaicd + mosaic, points the daemon and the Tauri shell at a
# shared data directory via the MOSAIC_DATA_DIR environment variable,
# launches the daemon in a background job, and then runs `npm run tauri
# dev`. The %ProgramData%\Mosaic default location requires admin and
# breaks symmetry with the GUI when running under a normal user; the
# sandbox dir avoids both problems.
#
# Usage:
#   pwsh scripts/dev.ps1
#   pwsh scripts/dev.ps1 -NoUi
#   pwsh scripts/dev.ps1 -Reset

param(
	[switch]$NoUi,
	[switch]$Reset
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RepoRoot

if (-not $env:MOSAIC_DATA_DIR -or $env:MOSAIC_DATA_DIR -eq '') {
	$env:MOSAIC_DATA_DIR = Join-Path $RepoRoot '.mosaic-dev'
}

if ($Reset -and (Test-Path $env:MOSAIC_DATA_DIR)) {
	Remove-Item -Recurse -Force $env:MOSAIC_DATA_DIR
}
New-Item -ItemType Directory -Force -Path $env:MOSAIC_DATA_DIR | Out-Null

Write-Host "==> data dir:    $env:MOSAIC_DATA_DIR"
Write-Host "==> building Go binaries"
go build -o (Join-Path $RepoRoot 'bin\mosaicd.exe') ./cmd/mosaicd
go build -o (Join-Path $RepoRoot 'bin\mosaic.exe')  ./cmd/mosaic

$DaemonLog = Join-Path $env:MOSAIC_DATA_DIR 'daemon.log'
Write-Host "==> starting mosaicd (logs: $DaemonLog)"
$Daemon = Start-Process -FilePath (Join-Path $RepoRoot 'bin\mosaicd.exe') `
	-ArgumentList '-v' `
	-RedirectStandardOutput $DaemonLog `
	-RedirectStandardError  $DaemonLog `
	-PassThru -NoNewWindow

try {
	$Lock = Join-Path $env:MOSAIC_DATA_DIR 'daemon.lock'
	for ($i = 0; $i -lt 50; $i++) {
		if ((Test-Path $Lock) -and (Get-Item $Lock).Length -gt 0) { break }
		Start-Sleep -Milliseconds 100
	}
	if (-not (Test-Path $Lock)) {
		throw "mosaicd did not produce a lockfile within 5s - see $DaemonLog"
	}
	Write-Host "==> mosaicd ready: $(Get-Content $Lock -Raw)"

	if ($NoUi) {
		Write-Host "==> daemon-only mode; press Ctrl-C to stop"
		Wait-Process -Id $Daemon.Id
		return
	}

	Write-Host "==> launching Tauri dev shell"
	Set-Location (Join-Path $RepoRoot 'ui')
	if (-not (Test-Path 'node_modules')) {
		npm ci
	}
	npm run tauri -- dev
}
finally {
	if (-not $Daemon.HasExited) {
		Write-Host "==> stopping mosaicd (pid $($Daemon.Id))"
		Stop-Process -Id $Daemon.Id -Force -ErrorAction SilentlyContinue
	}
}
