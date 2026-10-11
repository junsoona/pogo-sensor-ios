#!/bin/sh
# Checks what a built PogoHome.app contains of Power Base enrollment.
#
#   Scripts/check_release_enrollment_surface.sh <path/to/the built .app> [release|debug]
#
# In every configuration the product code must be there: registration, removal, re-enrollment and
# the setup QR code entry (the camera scan on iOS only; the Mac reads an image file and has neither
# the camera code nor the camera in its sandbox).
#
# release (default): the product registration and removal code must be there, and everything that
# only exists for testing must not: the DEBUG "BLE 등록 시험" screen, the USB-console test (its
# controller, its section and its PSKd display/copy clipboard) and the DEBUG string table.
#
# debug: the opposite check for the test-only parts, so this script is known to be able to find
# them (a check that can only ever say "absent" proves nothing).
#
# It replaces the earlier rule "a Release binary has no `PowerBaseEnrollment` string at all": the
# shared enrollment controller, transport and Bluetooth code are product code now.
#
# Only reads the given bundle. Exit status 0: as expected; 1: not; 2: usage.
set -eu

APP="${1:-}"
MODE="${2:-release}"
# An iOS bundle keeps Info.plist at its top, a Mac Catalyst bundle ("Jogakbo Home.app") in Contents.
PLIST=""
[ -n "$APP" ] && [ -f "$APP/Info.plist" ] && PLIST="$APP/Info.plist"
[ -n "$APP" ] && [ -f "$APP/Contents/Info.plist" ] && PLIST="$APP/Contents/Info.plist"
if [ -z "$PLIST" ]; then
    echo "usage: $0 <path/to/the built .app> [release|debug]" >&2
    exit 2
fi
case "$MODE" in release|debug) ;; *) echo "mode must be release or debug" >&2; exit 2 ;; esac

EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")
# iOS and Mac Catalyst bundles keep the executable in different places; a Debug build keeps the
# app's code in <name>.debug.dylib next to it.
BINARIES=""
for candidate in "$APP/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE" "$APP/$EXECUTABLE.debug.dylib" "$APP/Contents/MacOS/$EXECUTABLE.debug.dylib"; do
    [ -f "$candidate" ] && BINARIES="$BINARIES
$candidate"
done
if [ -z "$BINARIES" ]; then
    echo "no executable found in $APP" >&2
    exit 2
fi

TEXT=$(mktemp)
trap 'rm -f "$TEXT"' EXIT
echo "$BINARIES" | while IFS= read -r binary; do
    [ -n "$binary" ] && strings -a "$binary"
done > "$TEXT"

count() { grep -c -- "$1" "$TEXT" || true; }

STATUS=0
expect_present() {
    if [ "$(count "$1")" -eq 0 ]; then echo "MISSING  $1 ($2)"; STATUS=1; else echo "ok       $1 present"; fi
}
expect_absent() {
    n=$(count "$1")
    if [ "$n" -ne 0 ]; then echo "PRESENT  $1 x$n ($2)"; STATUS=1; else echo "ok       $1 absent"; fi
}

# Product code: in every configuration.
expect_present PowerBaseSetupView "the product registration screen"
expect_present PowerBaseEnrollmentBLEController "the shared enrollment controller"
expect_present PowerBaseManagementSheet "the product management sheet"
expect_present PowerBaseRemovalController "Power Base removal"
expect_present PowerBaseReenrollView "the product re-enrollment screen (move a Power Base to another hub)"
expect_present PowerBaseLocalResetController "the local reset of a registered Power Base"
# The setup QR code entry is product code too: the same in Debug and Release.
expect_present PowerBaseSetupQRIntake "the setup QR code entry"
expect_present PowerBaseSetupQRImageReader "reading a setup QR code from a picture"
expect_present PowerBaseSetupQRPayload "the setup QR code parser"
if [ -f "$APP/Contents/Info.plist" ]; then
    # Mac Catalyst: an image file only -- no camera code, and no camera in the sandbox.
    expect_absent PowerBaseSetupQRCaptureEngine "camera scanning in a Mac build"
    # Only a signed bundle carries its entitlements; an unsigned one says nothing either way.
    if ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null) && [ -n "$ENTITLEMENTS" ]; then
        case "$ENTITLEMENTS" in
            *com.apple.security.device.camera*) echo "PRESENT  com.apple.security.device.camera (the Mac build has no camera scan)"; STATUS=1 ;;
            *) echo "ok       com.apple.security.device.camera absent (Mac)" ;;
        esac
    else
        echo "note     entitlements not checked: this bundle is not signed"
    fi
else
    expect_present PowerBaseSetupQRCaptureEngine "the camera scan of the setup QR code"
fi
# The camera's purpose is one setting of the app target: declared, and not empty, wherever the app is.
CAMERA=$(/usr/libexec/PlistBuddy -c 'Print NSCameraUsageDescription' "$PLIST" 2>/dev/null || true)
if [ -n "$CAMERA" ]; then echo "ok       NSCameraUsageDescription present"; else echo "MISSING  NSCameraUsageDescription"; STATUS=1; fi
# The picker hands over the picked picture only: the app declares no access to the photo library.
for key in NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription; do
    if /usr/libexec/PlistBuddy -c "Print $key" "$PLIST" >/dev/null 2>&1; then echo "PRESENT  $key"; STATUS=1; else echo "ok       $key absent"; fi
done
# Widgets and the Watch app never use the camera.
find "$APP" \( -name '*.appex' -o -path '*/Watch/*.app' \) -prune -print | while IFS= read -r nested; do
    for plist in "$nested/Info.plist" "$nested/Contents/Info.plist"; do
        [ -f "$plist" ] || continue
        if /usr/libexec/PlistBuddy -c 'Print NSCameraUsageDescription' "$plist" >/dev/null 2>&1; then
            echo "PRESENT  NSCameraUsageDescription in $(basename "$nested")"
            # A subshell cannot set STATUS: leave a mark.
            : > "$TEXT.nested-camera"
        else
            echo "ok       NSCameraUsageDescription absent in $(basename "$nested")"
        fi
    done
done
if [ -f "$TEXT.nested-camera" ]; then rm -f "$TEXT.nested-camera"; STATUS=1; fi

# Test-only code.
TEST_ONLY="PowerBaseEnrollmentBLETestView PowerBaseEnrollmentBLECleanupRows PowerBaseEnrollmentTestSection PowerBaseEnrollmentController SystemEnrollmentClipboard PowerBaseEnrollmentClipboard PowerBaseEnrollmentDebug"
for name in $TEST_ONLY; do
    if [ "$MODE" = release ]; then
        expect_absent "$name" "test-only code in a Release build"
    else
        expect_present "$name" "a Debug build has the tests"
    fi
done

# The DEBUG string table (the test screens' wording, PSKd display and copy included).
TABLES=$(find "$APP" -name 'PowerBaseEnrollmentDebug*' | wc -l | tr -d ' ')
if [ "$MODE" = release ]; then
    if [ "$TABLES" -ne 0 ]; then echo "PRESENT  PowerBaseEnrollmentDebug string table x$TABLES"; STATUS=1; else echo "ok       DEBUG string table absent"; fi
    # The product screen never touches the pasteboard itself (PasteButton is the system's).
    expect_absent UIPasteboard "pasteboard access in a Release build"
else
    if [ "$TABLES" -eq 0 ]; then echo "MISSING  PowerBaseEnrollmentDebug string table"; STATUS=1; else echo "ok       DEBUG string table present"; fi
fi

# Bluetooth is declared wherever the product screen exists.
if /usr/libexec/PlistBuddy -c 'Print NSBluetoothAlwaysUsageDescription' "$PLIST" >/dev/null 2>&1; then
    echo "ok       NSBluetoothAlwaysUsageDescription present"
else
    echo "MISSING  NSBluetoothAlwaysUsageDescription"; STATUS=1
fi

[ "$STATUS" -eq 0 ] && echo "RESULT: as expected ($MODE)" || echo "RESULT: NOT as expected ($MODE)"
exit "$STATUS"
