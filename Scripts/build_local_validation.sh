#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_TEMPLATE_APP="/Applications/AIUsageBar.app"
# Fall back to an install from before the AIUsageBar rename.
[[ -d "$DEFAULT_TEMPLATE_APP" ]] || DEFAULT_TEMPLATE_APP="/Applications/CodexBar Monterey.app"
TEMPLATE_APP="${AIUSAGEBAR_LOCAL_TEMPLATE_APP:-$DEFAULT_TEMPLATE_APP}"
DISPLAY_NAME="${AIUSAGEBAR_LOCAL_DISPLAY_NAME:-AIUsageBar Local Validation}"
APP_VERSION="${AIUSAGEBAR_LOCAL_VERSION:-0.0.0}"
BUNDLE_ID="${AIUSAGEBAR_LOCAL_BUNDLE_ID:-io.github.troicc.aiusagebar}"
BUILD_NUMBER="${AIUSAGEBAR_LOCAL_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
OUTPUT_DIR="${AIUSAGEBAR_LOCAL_OUTPUT_DIR:-$(mktemp -d /private/tmp/aiusagebar-local-validation.XXXXXX)}"
OUTPUT_APP="$OUTPUT_DIR/$DISPLAY_NAME.app"

[[ -d "$TEMPLATE_APP" ]] || {
  echo "Template app not found: $TEMPLATE_APP" >&2
  echo "Install any previously validated AIUsageBar bundle, or set AIUSAGEBAR_LOCAL_TEMPLATE_APP." >&2
  exit 1
}
[[ "$DISPLAY_NAME" != */* ]] || { echo "Display name must not contain '/'." >&2; exit 1; }
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "AIUSAGEBAR_LOCAL_VERSION must be a semantic version such as 0.10.0." >&2
  exit 1
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "AIUSAGEBAR_LOCAL_BUILD_NUMBER must contain digits only." >&2
  exit 1
}
[[ ! -e "$OUTPUT_APP" ]] || { echo "Output already exists: $OUTPUT_APP" >&2; exit 1; }
[[ "$OUTPUT_APP" != "$TEMPLATE_APP" ]] || { echo "Output must differ from the template app." >&2; exit 1; }

TEMPLATE_PLIST="$TEMPLATE_APP/Contents/Info.plist"
TEMPLATE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TEMPLATE_PLIST")"
# Templates from before the rename use the old executable and helper names.
LEGACY_EXECUTABLE="CodexBarMonterey"
LEGACY_HELPER="CodexBarCLI"
[[ "$TEMPLATE_EXECUTABLE" == "AIUsageBar" || "$TEMPLATE_EXECUTABLE" == "$LEGACY_EXECUTABLE" ]] || {
  echo "Unexpected template executable: $TEMPLATE_EXECUTABLE" >&2
  exit 1
}
TEMPLATE_HELPER=""
for helper in AIUsageEngine "$LEGACY_HELPER"; do
  if [[ -x "$TEMPLATE_APP/Contents/Helpers/$helper" ]]; then
    TEMPLATE_HELPER="$helper"
    break
  fi
done
[[ -n "$TEMPLATE_HELPER" ]] || {
  echo "Template app has no bundled usage engine helper." >&2
  exit 1
}

BUILD_ROOT="$(mktemp -d /private/tmp/aiusagebar-local-build.XXXXXX)"
cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SOURCE_FILES=("$ROOT"/Sources/AIUsageBar/*.swift)
for arch in arm64 x86_64; do
  ARCH_ROOT="$BUILD_ROOT/$arch"
  mkdir -p "$ARCH_ROOT/module-cache"
  echo "Building local UI shell for $arch..."
  xcrun swiftc -O \
    -target "$arch-apple-macosx12.0" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$ARCH_ROOT/module-cache" \
    "${SOURCE_FILES[@]}" \
    -o "$ARCH_ROOT/AIUsageBar"
done

lipo -create \
  "$BUILD_ROOT/arm64/AIUsageBar" \
  "$BUILD_ROOT/x86_64/AIUsageBar" \
  -output "$BUILD_ROOT/AIUsageBar"

mkdir -p "$OUTPUT_DIR"
ditto "$TEMPLATE_APP" "$OUTPUT_APP"
rm -f "$OUTPUT_APP/Contents/MacOS/$LEGACY_EXECUTABLE"
install -m 755 "$BUILD_ROOT/AIUsageBar" "$OUTPUT_APP/Contents/MacOS/AIUsageBar"
if [[ "$TEMPLATE_HELPER" != "AIUsageEngine" ]]; then
  mv "$OUTPUT_APP/Contents/Helpers/$TEMPLATE_HELPER" "$OUTPUT_APP/Contents/Helpers/AIUsageEngine"
fi

OUTPUT_PLIST="$OUTPUT_APP/Contents/Info.plist"
set_plist_string() {
  local key="$1"
  local value="$2"
  if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$OUTPUT_PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$OUTPUT_PLIST"
  fi
}
set_plist_string CFBundleExecutable AIUsageBar
set_plist_string CFBundleIdentifier "$BUNDLE_ID"
set_plist_string CFBundleDisplayName "$DISPLAY_NAME"
set_plist_string CFBundleName "$DISPLAY_NAME"
set_plist_string CFBundleShortVersionString "$APP_VERSION"
# Declare the in-app Chinese localization so AppKit's own strings match it.
/usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$OUTPUT_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" \
  -c "Add :CFBundleLocalizations:0 string en" \
  -c "Add :CFBundleLocalizations:1 string zh-Hans" "$OUTPUT_PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleAllowMixedLocalizations" "$OUTPUT_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleAllowMixedLocalizations bool true" "$OUTPUT_PLIST"
set_plist_string CFBundleVersion "$BUILD_NUMBER"

codesign --force --deep --sign - "$OUTPUT_APP"

if [[ "${AIUSAGEBAR_LOCAL_SKIP_BUNDLE_SMOKE:-0}" != "1" ]]; then
  "$ROOT/Scripts/check_macos12_compat.sh" "$OUTPUT_APP"
  AIUSAGEBAR_SMOKE_OFFLINE=1 "$ROOT/Scripts/smoke_test_app.sh" "$OUTPUT_APP"
fi

if [[ "${AIUSAGEBAR_LOCAL_RUN_UI_SMOKE:-0}" == "1" ]]; then
  UI_SMOKE_OUTPUT="$(mktemp /private/tmp/aiusagebar-local-ui-smoke.XXXXXX)"
  AIUSAGEBAR_UI_SMOKE_OUTPUT="$UI_SMOKE_OUTPUT" \
    "$OUTPUT_APP/Contents/MacOS/AIUsageBar"
  grep -q '^PASS' "$UI_SMOKE_OUTPUT" || {
    cat "$UI_SMOKE_OUTPUT" >&2
    exit 1
  }
  cat "$UI_SMOKE_OUTPUT"
fi

echo
echo "Local validation app: $OUTPUT_APP"
echo "Note: the UI shell is current, but the usage engine and Sparkle were copied from: $TEMPLATE_APP"
echo "This bundle is ad-hoc signed and is not a release artifact."
