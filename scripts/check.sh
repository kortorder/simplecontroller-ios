#!/bin/bash
set -euo pipefail

APP_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_PROJECT_ROOT"
APP_CHECK_WORK_ROOT="${SC_BUILD_WORK_ROOT:-$APP_PROJECT_ROOT/work}"
APP_VALIDATION_PATH="$APP_CHECK_WORK_ROOT/validation"
mkdir -p "$APP_VALIDATION_PATH/module-cache"

bash Packages/ControllerCore/run-checks.sh

# Compile the actual app model and Network adapter against the available macOS
# SDK, then exercise the model with a fake transport/clock. No Xbox output.
swiftc -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -emit-library -emit-module -module-name ControllerCore \
  Packages/ControllerCore/Sources/ControllerCore/*.swift \
  -emit-module-path "$APP_VALIDATION_PATH/ControllerCore.swiftmodule" \
  -o "$APP_VALIDATION_PATH/libControllerCore.dylib"
swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  scripts/client_checks.swift -o "$APP_VALIDATION_PATH/client-checks"
"$APP_VALIDATION_PATH/client-checks"

swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/profile_client_checks.swift \
  scripts/android_preset_client_checks.swift scripts/camera_client_checks.swift \
  scripts/floating_action_client_checks.swift scripts/recovery_client_checks.swift scripts/orientation_client_checks.swift \
  scripts/starter_client_checks.swift scripts/floating_restoration_client_checks.swift scripts/macro_client_checks.swift \
  -o "$APP_VALIDATION_PATH/profile-client-checks"
"$APP_VALIDATION_PATH/profile-client-checks"

swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/trigger_client_checks.swift \
  -o "$APP_VALIDATION_PATH/trigger-client-checks"
"$APP_VALIDATION_PATH/trigger-client-checks"

swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/connection_intent_client_checks.swift \
  -o "$APP_VALIDATION_PATH/connection-intent-client-checks"
"$APP_VALIDATION_PATH/connection-intent-client-checks"

swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/usb_trigger_client_checks.swift \
  -o "$APP_VALIDATION_PATH/usb-trigger-client-checks"
"$APP_VALIDATION_PATH/usb-trigger-client-checks"

swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/zen_trigger_client_checks.swift \
  -o "$APP_VALIDATION_PATH/zen-trigger-client-checks"
"$APP_VALIDATION_PATH/zen-trigger-client-checks"

# Explicit DEBUG-only maintenance route; ordinary imports remain additive.
swiftc -DDEBUG -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/profile_update_client_checks.swift \
  -o "$APP_VALIDATION_PATH/profile-update-client-checks"
"$APP_VALIDATION_PATH/profile-update-client-checks"

# PC snapshots carry desktop ownership and pressure without altering saved profiles.
swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  -I "$APP_VALIDATION_PATH" -L "$APP_VALIDATION_PATH" -lControllerCore \
  -Xlinker -rpath -Xlinker @executable_path \
  iOSApp/UDPBridgeTransport.swift iOSApp/ControllerViewModel.swift \
  iOSApp/ProfileControllerViewModel.swift scripts/windows_pc_client_checks.swift \
  -o "$APP_VALIDATION_PATH/windows-pc-client-checks"
"$APP_VALIDATION_PATH/windows-pc-client-checks"

# First-run tutorial progress never mutates existing profiles or connection choices.
swiftc -swift-version 5 -module-cache-path "$APP_VALIDATION_PATH/module-cache" \
  iOSApp/QuickStartProgress.swift scripts/quick_start_checks.swift \
  -o "$APP_VALIDATION_PATH/quick-start-checks"
"$APP_VALIDATION_PATH/quick-start-checks"

swiftc -frontend -parse iOSApp/*.swift
plutil -lint iOSApp/Info.plist SimpleController.xcodeproj/project.pbxproj
python3 - <<'PY'
import pathlib
import subprocess
import json
import xml.etree.ElementTree as ET

ET.parse('SimpleController.xcodeproj/xcshareddata/xcschemes/SimpleController.xcscheme')
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', 'SimpleController.xcodeproj/project.pbxproj'
]))
objects = project['objects']
sources = [obj['path'] for obj in objects.values()
           if obj.get('isa') == 'PBXFileReference' and obj.get('lastKnownFileType') == 'sourcecode.swift']
assert set(sources) == {path.name for path in pathlib.Path('iOSApp').glob('*.swift')}, 'Xcode source list mismatch'
for source in sources:
    assert (pathlib.Path('iOSApp') / source).is_file(), source
assert pathlib.Path('Packages/ControllerCore/Package.swift').is_file()
print('PASS: project plist, shared scheme XML, source references, and Swift syntax.')
PY
printf '%s\n' 'No iOS SDK is used by these checks. Full Xcode build, UIKit rendering, phone, USB, and Xbox tests are still required.'
