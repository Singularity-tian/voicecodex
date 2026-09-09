#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VoiceCodex"
BUNDLE_ID="com.singularity.voicecodex"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_BUNDLE="$HOME/Applications/$APP_NAME.app"
MODE="run"
INSTALL_APP=false

for argument in "$@"; do
  case "$argument" in
    run|--run) MODE="run" ;;
    --build-only|--verify|--debug|--logs|--telemetry) MODE="$argument" ;;
    --install) INSTALL_APP=true ;;
    --help|-h)
      echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry] [--install]"
      exit 0
      ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

target_pids() {
  local expected_binary="$1/Contents/MacOS/$APP_NAME"
  local candidate actual_binary
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    actual_binary="$(/bin/ps -ww -p "$candidate" -o comm= 2>/dev/null || true)"
    if [[ "$actual_binary" == "$expected_binary" ]]; then
      echo "$candidate"
    fi
  done < <(/usr/bin/pgrep -x "$APP_NAME" || true)
}

stop_bundle() {
  local bundle="$1" candidate attempt identifier
  identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$identifier" == "$BUNDLE_ID" ]] || return 0
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    kill -TERM "$candidate" 2>/dev/null || true
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$candidate" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$candidate" 2>/dev/null; then
      echo "VoiceCodex is still stopping (PID $candidate). Please quit it before rebuilding." >&2
      exit 1
    fi
  done < <(target_pids "$bundle")
}

cd "$ROOT_DIR"
if [[ "$MODE" != "--build-only" ]]; then
  stop_bundle "$APP_BUNDLE"
  stop_bundle "$INSTALL_BUNDLE"
fi

swift build --configuration debug --product "$APP_NAME"
BUILD_BINARY="$(swift build --configuration debug --show-bin-path)/$APP_NAME"
mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.voicecodex-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_BUNDLE="$STAGING_DIR/$APP_NAME.app"
mkdir -p "$STAGED_BUNDLE/Contents/MacOS"
cp "$BUILD_BINARY" "$STAGED_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$STAGED_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/resources/Info.plist" "$STAGED_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_BUNDLE/Contents/Info.plist"
cat > "$STAGING_DIR/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
/usr/bin/codesign --force --sign - --options runtime \
  --entitlements "$STAGING_DIR/entitlements.plist" "$STAGED_BUNDLE"
/usr/bin/codesign --verify --strict "$STAGED_BUNDLE"
rm -rf "$APP_BUNDLE"
mv "$STAGED_BUNDLE" "$APP_BUNDLE"

LAUNCH_BUNDLE="$APP_BUNDLE"
if $INSTALL_APP; then
  if [[ -e "$INSTALL_BUNDLE" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALL_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
      echo "Refusing to replace a different app at $INSTALL_BUNDLE" >&2
      exit 1
    fi
    stop_bundle "$INSTALL_BUNDLE"
  fi
  mkdir -p "$(dirname "$INSTALL_BUNDLE")"
  rm -rf "$INSTALL_BUNDLE"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
  LAUNCH_BUNDLE="$INSTALL_BUNDLE"
fi

echo "Built $LAUNCH_BUNDLE"
case "$MODE" in
  --build-only) exit 0 ;;
  --debug) /usr/bin/lldb -- "$LAUNCH_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs)
    /usr/bin/open -n "$LAUNCH_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    /usr/bin/open -n "$LAUNCH_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    /usr/bin/open -n "$LAUNCH_BUNDLE"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.3
      if [[ -n "$(target_pids "$LAUNCH_BUNDLE")" ]]; then
        echo "Verified running app: $LAUNCH_BUNDLE"
        exit 0
      fi
    done
    echo "The app opened but its process was not found at the expected bundle path." >&2
    exit 1
    ;;
  run) /usr/bin/open -n "$LAUNCH_BUNDLE" ;;
esac
