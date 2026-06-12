#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="TypeWhisper"
PROJECT="TypeWhisper.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build-personal"
LOCK_DIR="$PROJECT_DIR/.typewhisper-personal-build.lock"
APP_NAME="TypeWhisper Personal"
PERSONAL_BUNDLE_ID="${PERSONAL_BUNDLE_ID:-com.typewhisper.mac.personal}"
PERSONAL_WIDGET_BUNDLE_ID="${PERSONAL_WIDGET_BUNDLE_ID:-$PERSONAL_BUNDLE_ID.widgets}"
CLONED_SOURCE_PACKAGES_DIR="${CLONED_SOURCE_PACKAGES_DIR:-$PROJECT_DIR/build-sourcepackages}"
TIMESTAMP_URL="${TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
TIMESTAMP_ATTEMPTS="${TIMESTAMP_ATTEMPTS:-5}"

SIGN=false
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=true ;;
    *) echo "Unknown option: $arg"; echo "Usage: $0 [--sign]"; exit 1 ;;
  esac
done

take_build_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return
  fi

  local existing_pid=""
  if [[ -f "$LOCK_DIR/pid" ]]; then
    existing_pid="$(cat "$LOCK_DIR/pid")"
  fi

  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "ERROR: Another personal build is already running with PID $existing_pid"
    exit 1
  fi

  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  echo "$$" > "$LOCK_DIR/pid"
}

release_build_lock() {
  rm -rf "$LOCK_DIR"
}

take_build_lock
trap release_build_lock EXIT

echo "=== TypeWhisper Personal Build ==="
echo "Bundle ID: $PERSONAL_BUNDLE_ID"
echo "Widget Bundle ID: $PERSONAL_WIDGET_BUNDLE_ID"
echo "SwiftPM checkouts: ${CLONED_SOURCE_PACKAGES_DIR:-Xcode default}"
echo "Sign: $SIGN"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$CLONED_SOURCE_PACKAGES_DIR"

PACKAGE_ARGS=()
if [[ -n "$CLONED_SOURCE_PACKAGES_DIR" ]]; then
  PACKAGE_ARGS=(-clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR")
fi

XCODEBUILD_OUTPUT_ARGS=()
if [[ "${XCODEBUILD_VERBOSE:-false}" != "true" ]]; then
  XCODEBUILD_OUTPUT_ARGS=(-quiet)
fi

echo "--- Resolving Swift packages ---"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  "${PACKAGE_ARGS[@]}"

echo "--- Building Release with TYPEWHISPER_PERSONAL_BUILD ---"
set -o pipefail
xcodebuild -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  "${PACKAGE_ARGS[@]}" \
  "${XCODEBUILD_OUTPUT_ARGS[@]}" \
  -destination 'platform=macOS,arch=arm64' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) TYPEWHISPER_PERSONAL_BUILD' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO | tee "$BUILD_DIR/build.log"

bash "$PROJECT_DIR/scripts/check_first_party_warnings.sh" "$BUILD_DIR/build.log"

BUILT_APP_PATH="$BUILD_DIR/Build/Products/Release/TypeWhisper.app"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "ERROR: App not found at $BUILT_APP_PATH"
  exit 1
fi

rm -rf "$APP_PATH"
mv "$BUILT_APP_PATH" "$APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/TypeWhisperWidgetExtension.appex"
WIDGET_INFO_PLIST="$WIDGET_PATH/Contents/Info.plist"
SIGNING_DIR="$BUILD_DIR/signing"

plist_set_string() {
  local plist="$1"
  local key="$2"
  local value="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
  fi
}

plist_delete_if_present() {
  local plist="$1"
  local key="$2"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist"
  fi
}

team_id_from_identity() {
  sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p' <<< "$1" | tail -1
}

sign_if_exists() {
  local target="$1"
  shift
  if [[ -e "$target" ]]; then
    codesign --force "$@" "$target"
  fi
}

sign_nested_runtime_if_exists() {
  local target="$1"
  shift
  if [[ -e "$target" ]]; then
    codesign --force --options runtime --timestamp=none --generate-entitlement-der "$@" "$target"
  fi
}

sign_app_bundle() {
  local timestamp_arg=(--timestamp=none)

  if [[ "$SIGN" == true ]]; then
    local attempt
    timestamp_arg=(--timestamp="$TIMESTAMP_URL")
    for ((attempt = 1; attempt <= TIMESTAMP_ATTEMPTS; attempt++)); do
      if codesign --force \
        --options runtime \
        "${timestamp_arg[@]}" \
        --generate-entitlement-der \
        --entitlements "$SIGNING_DIR/TypeWhisper.personal.entitlements" \
        --sign "$IDENTITY" \
        "$APP_PATH"; then
        return 0
      fi

      echo "WARNING: app timestamp signing failed on attempt $attempt" >&2
      if [[ "$attempt" -lt "$TIMESTAMP_ATTEMPTS" ]]; then
        sleep 5
      fi
    done

    return 1
  fi

  codesign --force \
    --options runtime \
    "${timestamp_arg[@]}" \
    --generate-entitlement-der \
    --entitlements "$SIGNING_DIR/TypeWhisper.personal.entitlements" \
    --sign "$IDENTITY" \
    "$APP_PATH"
}

TEAM_ID="${TEAM_ID:-}"
IDENTITY="-"

if [[ "$SIGN" == true ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
  if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: No Developer ID Application certificate found in keychain"
    exit 1
  fi
  TEAM_ID="${TEAM_ID:-$(team_id_from_identity "$IDENTITY")}"
  if [[ -z "$TEAM_ID" ]]; then
    echo "ERROR: Could not infer Team ID from signing identity: $IDENTITY"
    echo "Set TEAM_ID=YOUR_TEAM_ID and retry."
    exit 1
  fi
fi

PERSONAL_APP_GROUP_ID="${PERSONAL_APP_GROUP_ID:-${TEAM_ID:+$TEAM_ID.}$PERSONAL_BUNDLE_ID}"

echo "App Group ID: $PERSONAL_APP_GROUP_ID"

plist_set_string "$INFO_PLIST" CFBundleIdentifier "$PERSONAL_BUNDLE_ID"
plist_set_string "$INFO_PLIST" CFBundleName "$APP_NAME"
plist_set_string "$INFO_PLIST" CFBundleDisplayName "$APP_NAME"
plist_set_string "$INFO_PLIST" AppGroupIdentifier "$PERSONAL_APP_GROUP_ID"

plist_delete_if_present "$INFO_PLIST" SUFeedURL
plist_delete_if_present "$INFO_PLIST" SUPublicEDKey
plist_delete_if_present "$INFO_PLIST" TypeWhisperReleaseChannel

if [[ -f "$WIDGET_INFO_PLIST" ]]; then
  plist_set_string "$WIDGET_INFO_PLIST" CFBundleIdentifier "$PERSONAL_WIDGET_BUNDLE_ID"
  plist_set_string "$WIDGET_INFO_PLIST" CFBundleName "$APP_NAME Widgets"
  plist_set_string "$WIDGET_INFO_PLIST" CFBundleDisplayName "$APP_NAME Widgets"
  plist_set_string "$WIDGET_INFO_PLIST" AppGroupIdentifier "$PERSONAL_APP_GROUP_ID"
fi

echo "--- Signing App ---"
if [[ "$SIGN" == true ]]; then
  echo "Using identity: $IDENTITY"
else
  echo "Using ad-hoc identity"
fi

find "$APP_PATH" -name '._*' -delete
xattr -cr "$APP_PATH"

mkdir -p "$SIGNING_DIR"
sed "s|\$(APP_GROUP_ID)|$PERSONAL_APP_GROUP_ID|g" \
  "$PROJECT_DIR/TypeWhisper/Resources/TypeWhisper.entitlements" \
  > "$SIGNING_DIR/TypeWhisper.personal.entitlements"
sed "s|\$(APP_GROUP_ID)|$PERSONAL_APP_GROUP_ID|g" \
  "$PROJECT_DIR/TypeWhisperWidgetExtension/TypeWhisperWidgetExtension.entitlements" \
  > "$SIGNING_DIR/TypeWhisperWidgetExtension.personal.entitlements"

sign_if_exists "$APP_PATH/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle" \
  --timestamp=none \
  --sign "$IDENTITY"

sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  --sign "$IDENTITY"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
  --sign "$IDENTITY"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
  --sign "$IDENTITY"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
  --sign "$IDENTITY"

sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
  --sign "$IDENTITY"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/MediaRemoteAdapter.framework" \
  --sign "$IDENTITY"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/TypeWhisperPluginSDK.framework" \
  --sign "$IDENTITY"

sign_nested_runtime_if_exists "$APP_PATH/Contents/MacOS/typewhisper-cli" \
  --sign "$IDENTITY"
sign_nested_runtime_if_exists "$WIDGET_PATH" \
  --entitlements "$SIGNING_DIR/TypeWhisperWidgetExtension.personal.entitlements" \
  --sign "$IDENTITY"

while IFS= read -r plugin_bundle; do
  sign_nested_runtime_if_exists "$plugin_bundle" \
    --sign "$IDENTITY"
done < <(find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -type d -name '*.bundle' -print | sort)

sign_app_bundle

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo ""
echo "=== Done ==="
echo "App: $APP_PATH"
echo "Updates: disabled"
