#!/usr/bin/env bash
# dev-run.sh: local iteration loop for MyDikte.
#
# Builds MyDikte, assembles it into a real .app bundle at ~/Applications/MyDikte.app
# (a stable path, since SMAppService and TCC both key off of it), signs it with the
# Apple Development identity under Hardened Runtime plus the microphone entitlements,
# kills any prior instance, and relaunches from the installed path.
#
# Usage: ./dev-run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/MyDikte.app"
SIGN_IDENTITY="Apple Development: Anilcan Cakir (936TDTZJN9)"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "Building (debug)..."
( cd "$HERE" && swift build --product MyDikte 2>&1 | tail -3 )

say "Assembling $APP..."
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/.build/debug/MyDikte" "$APP/Contents/MacOS/MyDikte"
# The canonical Info.plist, not SwiftPM's generated one: a hand-assembled bundle
# resolves Bundle.main against this file at runtime (verified in
# .ac/plans/my-dikte-swift-macos/evidence/step-01-signing-probe.txt).
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

say "Signing with $SIGN_IDENTITY (Hardened Runtime)..."
if ! SIGN_OUTPUT="$(codesign --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$HERE/entitlements.plist" \
    "$APP" 2>&1)"; then
    printf '%s\n' "$SIGN_OUTPUT" >&2
    echo "codesign failed" >&2
    exit 1
fi

say "Checking signed entitlements..."
EMBEDDED_ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
for key in \
    "com.apple.security.device.audio-input" \
    "com.apple.security.device.microphone"
do
    if ! grep -q "$key" <<<"$EMBEDDED_ENTITLEMENTS"; then
        printf '%s\n' "$EMBEDDED_ENTITLEMENTS" >&2
        echo "missing required entitlement: $key" >&2
        exit 1
    fi
done

say "Stopping any prior instance..."
pkill -f "$APP/Contents/MacOS/MyDikte" 2>/dev/null || true
sleep 0.5

say "Launching..."
open "$APP"
# `open` returns before the process exists; poll instead of racing a fixed sleep.
LAUNCHED_PID=""
for _ in $(seq 1 25); do
    LAUNCHED_PID="$(pgrep -f "$APP/Contents/MacOS/MyDikte" | head -n 1 || true)"
    [[ -n "$LAUNCHED_PID" ]] && break
    sleep 0.2
done
if [[ -z "$LAUNCHED_PID" ]]; then
    echo "MyDikte did not appear within ~5s of 'open'." >&2
    exit 1
fi
echo "  pid=$LAUNCHED_PID $APP"
