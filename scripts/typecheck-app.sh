#!/usr/bin/env bash
# Type-checks the App files that do not import SwiftUI, on Linux.
#
# The app target only compiles on macOS, so a concurrency mistake in a model
# class is normally found by CI several minutes after it is pushed — twice now
# it has been found *by* CI rather than before it. The model files import only
# Foundation, Observation and the local packages, so with small stand-ins for
# the Apple-only transport they can be checked here in about a second.
#
# `-warnings-as-errors` matches the app's CI build, where warnings are errors
# and only there: the app builds in Swift 5 language mode, so concurrency
# mistakes that are hard errors in the package downgrade to warnings here.
#
# Not a substitute for the macOS build — nothing containing a SwiftUI `View`
# can be checked at all.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT="${SWIFT:-swift}"
SWIFTC="${SWIFTC:-swiftc}"
SHIM="Scripts/linux-app-shim.swift"
MODULES=".build/debug/Modules"

# The shim stands in for KoboldBLE, so anything that names a real BLE type is
# fine, but a file importing SwiftUI is not checkable and is skipped by name.
# Base files every check includes; the rest are added one at a time. The app
# target is one module, so a file that references SessionModel needs it present.
BASE=(App/SessionModel.swift App/DemoVehicle.swift)
EXTRA=(App/ScanModel.swift App/DiagnosticsModel.swift)

if [[ ! -d "$MODULES" ]]; then
  echo "Building the package first so the modules exist…"
  "$SWIFT" build
fi

check() {
  local label="$1"; shift
  if "$SWIFTC" -typecheck -swift-version 5 -warnings-as-errors \
       -I "$MODULES" "$SHIM" "$@" 2>&1 | grep -E "error:|warning:"; then
    echo "FAIL $label"
    return 1
  fi
  echo "ok   $label"
}

status=0
check "base" "${BASE[@]}" || status=1
for file in "${EXTRA[@]}"; do
  [[ -f "$file" ]] || continue
  check "$file" "${BASE[@]}" "$file" || status=1
done
exit $status
