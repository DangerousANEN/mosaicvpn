#!/usr/bin/env bash
# Mosaic — local dev runner.
#
# Builds the daemon + CLI, points everything at a sandboxed data
# directory via MOSAIC_DATA_DIR (so the daemon and the Tauri shell
# both look at the same lockfile), starts mosaicd in the background,
# then launches the Tauri dev shell.
#
# Usage:
#   scripts/dev.sh              # daemon + Tauri GUI
#   scripts/dev.sh --no-ui      # daemon only, useful for CLI smoke tests
#   scripts/dev.sh --reset      # wipe the dev data dir before starting
#
# The daemon's stdout/stderr are tee'd to ${MOSAIC_DATA_DIR}/daemon.log.
# On Ctrl-C the daemon is shut down cleanly via SIGTERM.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

: "${MOSAIC_DATA_DIR:=${REPO_ROOT}/.mosaic-dev}"
export MOSAIC_DATA_DIR

UI=1
RESET=0
for arg in "$@"; do
	case "${arg}" in
	--no-ui) UI=0 ;;
	--reset) RESET=1 ;;
	-h | --help)
		sed -n '2,15p' "$0"
		exit 0
		;;
	*)
		echo "unknown flag: ${arg}" >&2
		exit 2
		;;
	esac
done

if [[ "${RESET}" == "1" ]]; then
	rm -rf "${MOSAIC_DATA_DIR}"
fi
mkdir -p "${MOSAIC_DATA_DIR}"

echo "==> data dir:    ${MOSAIC_DATA_DIR}"
echo "==> building Go binaries"
go build -o "${REPO_ROOT}/bin/mosaicd" ./cmd/mosaicd
go build -o "${REPO_ROOT}/bin/mosaic" ./cmd/mosaic

DAEMON_LOG="${MOSAIC_DATA_DIR}/daemon.log"
echo "==> starting mosaicd (logs: ${DAEMON_LOG})"
"${REPO_ROOT}/bin/mosaicd" -v >"${DAEMON_LOG}" 2>&1 &
DAEMON_PID=$!

cleanup() {
	if kill -0 "${DAEMON_PID}" 2>/dev/null; then
		echo "==> stopping mosaicd (pid ${DAEMON_PID})"
		kill -TERM "${DAEMON_PID}" 2>/dev/null || true
		wait "${DAEMON_PID}" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

# Wait until the daemon has written its lockfile so the GUI's first
# resolveEndpoint() doesn't race against startup.
for _ in $(seq 1 50); do
	if [[ -s "${MOSAIC_DATA_DIR}/daemon.lock" ]]; then break; fi
	sleep 0.1
done
if [[ ! -s "${MOSAIC_DATA_DIR}/daemon.lock" ]]; then
	echo "mosaicd did not produce a lockfile within 5s — see ${DAEMON_LOG}" >&2
	exit 1
fi
echo "==> mosaicd ready: $(cat "${MOSAIC_DATA_DIR}/daemon.lock")"

if [[ "${UI}" == "0" ]]; then
	echo "==> daemon-only mode; press Ctrl-C to stop"
	wait "${DAEMON_PID}"
	exit 0
fi

echo "==> launching Tauri dev shell"
cd "${REPO_ROOT}/ui"
if [[ ! -d node_modules ]]; then
	npm ci
fi
# `npm run tauri dev` re-exports MOSAIC_DATA_DIR into the Rust shell so
# data_dir() resolves to the same sandbox the daemon is writing to.
MOSAIC_DATA_DIR="${MOSAIC_DATA_DIR}" npm run tauri -- dev
