#!/usr/bin/env bash
# scripts/client_singbox_verify.sh
# Verifies sing-box installation, executes real sing-box core regression tests
# without mocks, and validates isolated candidate verification.
set -euo pipefail

echo "==> Verifying sing-box binary availability..."
if ! command -v sing-box &>/dev/null; then
    if [ -x "/usr/local/bin/sing-box" ]; then
        export PATH="/usr/local/bin:$PATH"
    elif [ -x "dist/linux/MosaicVPN/sing-box" ]; then
        export PATH="$(pwd)/dist/linux/MosaicVPN:$PATH"
    else
        echo "ERROR: sing-box binary not found on PATH or expected locations." >&2
        exit 1
    fi
fi

sing-box version

echo "==> Running internal/state real sing-box regressions..."
go test -v -run 'TestGeneratedTunConfigPassesBundledSingBoxCheck|TestVerifyCatchesRealSingBoxMuxBlackHole' ./internal/state

echo "==> Running internal/api candidate isolated tunnel probe tests..."
go test -v -run 'TestValidateCandidateProbeURL_PolicyValidation|TestProbeCandidateIsolated_RealFixtureCredentialsAnd200Rejection' ./internal/api

echo "==> All sing-box verification tests completed successfully."
