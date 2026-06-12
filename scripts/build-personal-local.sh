#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="TypeWhisper"
PROJECT="TypeWhisper.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build-personal"
LOCK_DIR="$PROJECT_DIR/.typewhisper-personal-build.lock"
APP_NAME="TypeWhisper Personal"
DIST_DIR="$BUILD_DIR/dist"
PERSONAL_BUNDLE_ID="${PERSONAL_BUNDLE_ID:-com.typewhisper.mac.personal}"
PERSONAL_WIDGET_BUNDLE_ID="${PERSONAL_WIDGET_BUNDLE_ID:-$PERSONAL_BUNDLE_ID.widgets}"
CLONED_SOURCE_PACKAGES_DIR="${CLONED_SOURCE_PACKAGES_DIR:-$PROJECT_DIR/build-sourcepackages}"
TIMESTAMP_URL="${TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
TIMESTAMP_ATTEMPTS="${TIMESTAMP_ATTEMPTS:-5}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-NotaryProfile}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-1h}"

SIGN=false
PACKAGE=false
NOTARIZE=false
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=true ;;
    --package) PACKAGE=true ;;
    --notarize) SIGN=true; PACKAGE=true; NOTARIZE=true ;;
    *) echo "Unknown option: $arg"; echo "Usage: $0 [--sign] [--package] [--notarize]"; exit 1 ;;
  esac
done

if [[ "$NOTARIZE" == true ]]; then
  for tool in xcrun ditto hdiutil python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "ERROR: Required notarization tool not found: $tool"
      exit 1
    fi
  done

  if ! xcrun notarytool history -p "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: Could not use notarytool profile: $NOTARY_KEYCHAIN_PROFILE"
    echo "Set NOTARY_KEYCHAIN_PROFILE or run: xcrun notarytool store-credentials \"$NOTARY_KEYCHAIN_PROFILE\""
    exit 1
  fi
fi

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

MOUNT_POINT=""
TEMP_PATHS=()

cleanup_on_exit() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  for path in "${TEMP_PATHS[@]:-}"; do
    rm -rf "$path"
  done
  release_build_lock
}

take_build_lock
trap cleanup_on_exit EXIT

echo "=== TypeWhisper Personal Build ==="
echo "Bundle ID: $PERSONAL_BUNDLE_ID"
echo "Widget Bundle ID: $PERSONAL_WIDGET_BUNDLE_ID"
echo "SwiftPM checkouts: ${CLONED_SOURCE_PACKAGES_DIR:-Xcode default}"
echo "Sign: $SIGN"
echo "Package: $PACKAGE"
echo "Notarize: $NOTARIZE"
if [[ "$NOTARIZE" == true ]]; then
  echo "Notary profile: $NOTARY_KEYCHAIN_PROFILE"
fi
echo ""

if [[ -d "$BUILD_DIR" ]]; then
  chflags -R nouchg,noschg,nohidden "$BUILD_DIR" 2>/dev/null || true
  xattr -cr "$BUILD_DIR" 2>/dev/null || true
fi
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

sign_with_retries() {
  local target="$1"
  shift

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  local timestamp_arg=(--timestamp=none)
  if [[ "$SIGN" == true ]]; then
    timestamp_arg=(--timestamp="$TIMESTAMP_URL")
  fi

  local attempt
  for ((attempt = 1; attempt <= TIMESTAMP_ATTEMPTS; attempt++)); do
    if codesign --force \
      "${timestamp_arg[@]}" \
      "$@" \
      --sign "$IDENTITY" \
      "$target"; then
      return 0
    fi

    echo "WARNING: timestamp signing failed for $target on attempt $attempt" >&2
    if [[ "$attempt" -lt "$TIMESTAMP_ATTEMPTS" ]]; then
      sleep 5
    fi
  done

  return 1
}

sign_if_exists() {
  local target="$1"
  shift
  sign_with_retries "$target" "$@"
}

sign_nested_runtime_if_exists() {
  local target="$1"
  shift
  sign_with_retries "$target" --options runtime --generate-entitlement-der "$@"
}

sign_app_bundle() {
  sign_with_retries "$APP_PATH" \
    --options runtime \
    --generate-entitlement-der \
    --entitlements "$SIGNING_DIR/TypeWhisper.personal.entitlements"
}

app_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST"
}

submit_for_notarization() {
  local artifact="$1"
  local output_json="$2"
  local log_json="$3"

  echo "Submitting for notarization: $artifact"
  xcrun notarytool submit "$artifact" \
    -p "$NOTARY_KEYCHAIN_PROFILE" \
    --wait \
    --timeout "$NOTARY_TIMEOUT" \
    --output-format json | tee "$output_json"

  local submission_id
  local status
  submission_id="$(python3 - <<'PY' "$output_json"
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("id", ""))
PY
)"
  status="$(python3 - <<'PY' "$output_json"
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("status", ""))
PY
)"

  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" -p "$NOTARY_KEYCHAIN_PROFILE" > "$log_json" || true
  fi

  if [[ "$status" != "Accepted" ]]; then
    echo "ERROR: Notarization failed for $artifact with status: $status"
    if [[ -f "$log_json" ]]; then
      python3 -m json.tool "$log_json" | sed -n '1,240p'
    fi
    return 1
  fi
}

notarize_app_bundle() {
  local notary_dir="$1"
  local app_zip="$notary_dir/TypeWhisper-Personal-app-notary.zip"

  echo "--- Notarizing App ---"
  ditto -c -k --keepParent "$APP_PATH" "$app_zip"
  submit_for_notarization \
    "$app_zip" \
    "$notary_dir/app-notary-submit.json" \
    "$notary_dir/app-notary-log.json"

  echo "--- Stapling App ---"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl -a -vvv -t exec "$APP_PATH"
}

package_artifacts() {
  local version="$1"
  local zip_path="$2"
  local dmg_path="$3"
  local stage_dir

  echo "--- Creating ZIP ---"
  mkdir -p "$DIST_DIR"
  rm -f "$zip_path"
  ditto -c -k --keepParent "$APP_PATH" "$zip_path"

  echo "--- Creating DMG ---"
  stage_dir="$(mktemp -d "$BUILD_DIR/dmg-stage.XXXXXX")"
  TEMP_PATHS+=("$stage_dir")
  rm -f "$dmg_path"
  cp -R "$APP_PATH" "$stage_dir/"
  ln -s /Applications "$stage_dir/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null

  if [[ "$SIGN" == true ]]; then
    codesign --force --timestamp=none --sign "$IDENTITY" "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path"
  fi

  echo "ZIP: $zip_path"
  echo "DMG: $dmg_path"
}

notarize_dmg() {
  local dmg_path="$1"
  local notary_dir="$2"

  echo "--- Notarizing DMG ---"
  submit_for_notarization \
    "$dmg_path" \
    "$notary_dir/dmg-notary-submit.json" \
    "$notary_dir/dmg-notary-log.json"

  echo "--- Stapling DMG ---"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl -a -vvv -t open --context context:primary-signature "$dmg_path"
}

verify_packaged_artifacts() {
  local zip_path="$1"
  local dmg_path="$2"
  local temp_dir

  echo "--- Verifying ZIP payload ---"
  temp_dir="$(mktemp -d "$BUILD_DIR/package-verify.XXXXXX")"
  TEMP_PATHS+=("$temp_dir")
  mkdir -p "$temp_dir/zip"
  ditto -x -k "$zip_path" "$temp_dir/zip"
  codesign --verify --deep --strict --verbose=2 "$temp_dir/zip/$APP_NAME.app"
  if [[ "$NOTARIZE" == true ]]; then
    xcrun stapler validate "$temp_dir/zip/$APP_NAME.app"
    spctl -a -vvv -t exec "$temp_dir/zip/$APP_NAME.app"
  fi

  echo "--- Verifying DMG payload ---"
  local attach_output
  attach_output="$(hdiutil attach "$dmg_path" -nobrowse -readonly)"
  MOUNT_POINT="$(printf '%s\n' "$attach_output" | awk 'index($0,"/Volumes/"){print substr($0,index($0,"/Volumes/")); exit}')"
  if [[ -z "$MOUNT_POINT" ]]; then
    printf '%s\n' "$attach_output"
    echo "ERROR: Could not find DMG mount point"
    return 1
  fi

  codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/$APP_NAME.app"
  if [[ "$NOTARIZE" == true ]]; then
    xcrun stapler validate "$MOUNT_POINT/$APP_NAME.app"
    spctl -a -vvv -t exec "$MOUNT_POINT/$APP_NAME.app"
  fi
  hdiutil detach "$MOUNT_POINT" >/dev/null
  MOUNT_POINT=""
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

sign_if_exists "$APP_PATH/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle"

sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"

sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/Sparkle.framework"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/MediaRemoteAdapter.framework"
sign_nested_runtime_if_exists "$APP_PATH/Contents/Frameworks/TypeWhisperPluginSDK.framework"

sign_nested_runtime_if_exists "$APP_PATH/Contents/MacOS/typewhisper-cli"
sign_nested_runtime_if_exists "$WIDGET_PATH" \
  --entitlements "$SIGNING_DIR/TypeWhisperWidgetExtension.personal.entitlements"

while IFS= read -r plugin_bundle; do
  sign_nested_runtime_if_exists "$plugin_bundle"
done < <(find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -type d -name '*.bundle' -print | sort)

sign_app_bundle

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION="$(app_version)"
ZIP_PATH="$DIST_DIR/TypeWhisper-Personal-v${VERSION}-DeveloperID-arm64.zip"
DMG_PATH="$DIST_DIR/TypeWhisper-Personal-v${VERSION}-DeveloperID-arm64.dmg"
NOTARY_DIR="$BUILD_DIR/notary-diagnostics/$(date +%Y%m%d-%H%M%S)"

if [[ "$NOTARIZE" == true ]]; then
  mkdir -p "$NOTARY_DIR"
  notarize_app_bundle "$NOTARY_DIR"
fi

if [[ "$PACKAGE" == true ]]; then
  package_artifacts "$VERSION" "$ZIP_PATH" "$DMG_PATH"
  if [[ "$NOTARIZE" == true ]]; then
    notarize_dmg "$DMG_PATH" "$NOTARY_DIR"
  fi
  verify_packaged_artifacts "$ZIP_PATH" "$DMG_PATH"
  shasum -a 256 "$DMG_PATH" "$ZIP_PATH"
fi

echo ""
echo "=== Done ==="
echo "App: $APP_PATH"
if [[ "$PACKAGE" == true ]]; then
  echo "DMG: $DMG_PATH"
  echo "ZIP: $ZIP_PATH"
fi
if [[ "$NOTARIZE" == true ]]; then
  echo "Notary diagnostics: $NOTARY_DIR"
fi
echo "Updates: disabled"
