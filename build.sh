#!/usr/bin/env bash
# Configure, build, and (optionally) install the MT7668 WiFi driver via CMake.
#
# Usage:
#   ./build.sh                    configure + build
#   ./build.sh --install          configure + build + install (sudo)
#   ./build.sh --clean            remove the build directory first
#   ./build.sh -DKERNEL_CC=gcc-13 any extra args are passed through to `cmake` (configure step)
#
# Env overrides: BUILD_DIR (default "build"), JOBS (default nproc)

set -euo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-$(nproc)}"
DO_INSTALL=0
CMAKE_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --install)
            DO_INSTALL=1
            ;;
        --clean)
            echo "==> Removing ${BUILD_DIR}"
            rm -rf "${BUILD_DIR}"
            ;;
        *)
            CMAKE_ARGS+=("$arg")
            ;;
    esac
done

echo "==> Configuring (${BUILD_DIR})"
cmake -S . -B "${BUILD_DIR}" "${CMAKE_ARGS[@]}"

echo "==> Building"
cmake --build "${BUILD_DIR}" -j"${JOBS}"

if [[ "${DO_INSTALL}" -eq 1 ]]; then
    echo "==> Installing (requires sudo)"
    sudo cmake --install "${BUILD_DIR}"
else
    echo "==> Skipping install (pass --install to install the module + firmware and enable autoload)"
fi

echo "==> Done."
