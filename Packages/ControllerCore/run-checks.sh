#!/bin/bash
set -euo pipefail

CORE_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_WORK_PATH="${SC_BUILD_WORK_ROOT:-$CORE_PROJECT_ROOT/work}"
case "$CORE_WORK_PATH" in
    /*) ;;
    *) printf '%s\n' 'SC_BUILD_WORK_ROOT must be an absolute path.' >&2; exit 2 ;;
esac
mkdir -p "$CORE_WORK_PATH/swift-core-cache" "$CORE_WORK_PATH/swift-core-module-cache" \
    "$CORE_WORK_PATH/swift-core-config" "$CORE_WORK_PATH/swift-core-security"

# Keep all build/cache writes within the project. The manifest has no external
# dependencies. Disabling SwiftPM's nested manifest sandbox does not change
# the enclosing tool/process sandbox or any macOS security setting.
export CLANG_MODULE_CACHE_PATH="$CORE_WORK_PATH/swift-core-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CORE_WORK_PATH/swift-core-module-cache"
exec swift run --disable-sandbox \
    --package-path "$CORE_PROJECT_ROOT/Packages/ControllerCore" \
    --cache-path "$CORE_WORK_PATH/swift-core-cache" \
    --config-path "$CORE_WORK_PATH/swift-core-config" \
    --security-path "$CORE_WORK_PATH/swift-core-security" \
    --scratch-path "$CORE_WORK_PATH/swift-core-build" \
    ControllerCoreChecks
