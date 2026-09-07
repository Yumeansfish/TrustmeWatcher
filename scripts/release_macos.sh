#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build}"
COMPOSED_DIR="${COMPOSED_DIR:-$BUILD_ROOT/composed/activitywatch}"

APP_NAME="${APP_NAME:-trust-me}"
BUNDLE_ID="${BUNDLE_ID:-io.github.yumeansfish.trustme}"
APP_PATH="${APP_PATH:-$BUILD_ROOT/bin/app/$APP_NAME.app}"
DMG_PATH="${DMG_PATH:-$BUILD_ROOT/dist/$APP_NAME.dmg}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"

DMGBUILD_VERSION="${DMGBUILD_VERSION:-1.6.5}"
RELEASE_TOOLS_VENV="$BUILD_ROOT/.release-tools"
DMG_SETTINGS="${DMG_SETTINGS:-$COMPOSED_DIR/scripts/package/dmgbuild-settings.py}"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-${APPLE_PERSONALID:-}}"
ENTITLEMENTS_FILE="${ENTITLEMENTS_FILE:-$COMPOSED_DIR/scripts/package/entitlements.plist}"

NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
APPLE_EMAIL="${APPLE_EMAIL:-${NOTARY_APPLE_ID:-}}"
APPLE_PASSWORD="${APPLE_PASSWORD:-${NOTARY_PASSWORD:-}}"
APPLE_TEAMID="${APPLE_TEAMID:-${APPLE_TEAM_ID:-}}"

die() {
  echo "release_macos: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null \
    || die "missing $2 in $1"
}

select_python() {
  local candidate
  for candidate in \
    "${BUILD_PYTHON:-}" \
    "$BUILD_ROOT/.build-tools/bin/python" \
    "$BUILD_ROOT/python-3.11/bin/python3.11" \
    python3.11 \
    python3; do
    if [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  die "Python is required to create the isolated dmgbuild environment"
}

ensure_dmgbuild() {
  local installed=""

  if [[ -x "$RELEASE_TOOLS_VENV/bin/python" ]]; then
    installed="$($RELEASE_TOOLS_VENV/bin/python - <<'PY' 2>/dev/null || true
from importlib.metadata import version
print(version("dmgbuild"))
PY
)"
  fi

  if [[ "$installed" != "$DMGBUILD_VERSION" ]]; then
    echo "==> Creating isolated dmgbuild environment"
    rm -rf "$RELEASE_TOOLS_VENV"
    "$PYTHON_BIN" -m venv "$RELEASE_TOOLS_VENV"
    "$RELEASE_TOOLS_VENV/bin/python" -m pip install \
      --disable-pip-version-check \
      "dmgbuild==$DMGBUILD_VERSION"
  fi
}

verify_app_identity() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local actual_name actual_bundle_id executable
  local payload_executable required_resource

  require_file "$plist"
  plutil -lint "$plist" >/dev/null
  actual_name="$(plist_value "$plist" CFBundleName)"
  actual_bundle_id="$(plist_value "$plist" CFBundleIdentifier)"
  executable="$(plist_value "$plist" CFBundleExecutable)"

  [[ "$actual_name" == "$APP_NAME" ]] \
    || die "unexpected CFBundleName: $actual_name (expected $APP_NAME)"
  [[ "$actual_bundle_id" == "$BUNDLE_ID" ]] \
    || die "unexpected CFBundleIdentifier: $actual_bundle_id (expected $BUNDLE_ID)"

  if [[ -x "$app/Contents/MacOS/$executable" ]]; then
    :
  elif [[ -x "$app/Contents/$executable" ]]; then
    :
  else
    die "app executable is missing or not executable: $executable"
  fi

  for payload_executable in \
    aw-qt \
    aw-server \
    aw-watcher-afk \
    aw-watcher-window \
    aw-watcher-input; do
    [[ -x "$app/Contents/MacOS/$payload_executable" ]] \
      || die "app payload is missing executable: $payload_executable"
  done

  for required_resource in \
    aw_server/settings/aw-category-export.json \
    aw_server/static/index.html \
    trustme_xai/action_classifier.joblib \
    trustme_xai/current.joblib \
    trustme_xai/feature_pipeline/category_rules.json \
    trustme_xai/feature_pipeline/behavior_state_model.json \
    trustme_xai/inference/compact_aw_v2.json; do
    require_file "$app/Contents/Resources/$required_resource"
  done
  [[ ! -e "$app/Contents/Resources/aw_server/deployment.toml" ]] \
    || die "app payload must not contain deployment.toml"

  codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
    || die "app payload has an invalid code signature: $app"
}

has_notary_credentials() {
  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    return 0
  fi
  if [[ -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" && -n "$NOTARY_KEY_PATH" ]]; then
    return 0
  fi
  [[ -n "$APPLE_EMAIL" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAMID" ]]
}

validate_notary_credentials() {
  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    return
  fi

  if [[ -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER_ID" || -n "$NOTARY_KEY_PATH" ]]; then
    [[ -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" && -n "$NOTARY_KEY_PATH" ]] \
      || die "API-key notarization requires NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_KEY_PATH"
    require_file "$NOTARY_KEY_PATH"
    return
  fi

  [[ -n "$APPLE_EMAIL" && -n "$APPLE_PASSWORD" && -n "$APPLE_TEAMID" ]] \
    || die "notarization requires a keychain profile, API-key credentials, or APPLE_EMAIL/APPLE_PASSWORD/APPLE_TEAMID"
}

notary_submit() {
  local artifact="$1"

  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
      --wait
  elif [[ -n "$NOTARY_KEY_ID" ]]; then
    xcrun notarytool submit "$artifact" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --wait
  else
    xcrun notarytool submit "$artifact" \
      --apple-id "$APPLE_EMAIL" \
      --password "$APPLE_PASSWORD" \
      --team-id "$APPLE_TEAMID" \
      --wait
  fi
}

verify_dmg_contents() {
  local mount_dir
  local mounted=0

  mount_dir="$(mktemp -d "$BUILD_ROOT/.dmg-mount.XXXXXX")"
  cleanup_mount() {
    if [[ "$mounted" == "1" ]]; then
      hdiutil detach "$mount_dir" -quiet || true
    fi
    rmdir "$mount_dir" 2>/dev/null || true
  }
  trap cleanup_mount EXIT INT TERM HUP

  hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mount_dir" \
    "$DMG_PATH" >/dev/null
  mounted=1

  [[ -d "$mount_dir/$APP_NAME.app" ]] \
    || die "DMG does not contain $APP_NAME.app"
  verify_app_identity "$mount_dir/$APP_NAME.app"

  cleanup_mount
  trap - EXIT INT TERM HUP
}

[[ "$(uname -s)" == "Darwin" ]] || die "macOS release packaging requires macOS"
[[ "$#" -eq 0 ]] || die "this script accepts configuration through environment variables, not arguments"
[[ -n "$APP_NAME" && "$APP_NAME" != */* ]] \
  || die "APP_NAME must be a non-empty filename component"
[[ -n "$BUNDLE_ID" ]] || die "BUNDLE_ID must not be empty"

require_cmd codesign
require_cmd ditto
require_cmd hdiutil
require_cmd plutil
require_cmd xcrun
require_file "$APP_PATH/Contents/Info.plist"
require_file "$DMG_SETTINGS"
verify_app_identity "$APP_PATH"

if [[ -n "$SIGN_IDENTITY" ]]; then
  require_file "$ENTITLEMENTS_FILE"
  echo "==> Signing $APP_NAME.app"
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  echo "==> No Developer ID supplied; creating an unsigned local package"
fi

if [[ "${NOTARIZE:-auto}" == "auto" ]]; then
  if has_notary_credentials; then
    NOTARIZE=1
  else
    NOTARIZE=0
  fi
fi
case "$NOTARIZE" in
  0|1) ;;
  *) die "NOTARIZE must be auto, 0, or 1" ;;
esac

if [[ "$NOTARIZE" == "1" ]]; then
  [[ -n "$SIGN_IDENTITY" ]] \
    || die "notarization requires DEVELOPER_ID_APPLICATION or APPLE_PERSONALID"
  validate_notary_credentials

  NOTARY_DIR="$BUILD_ROOT/notary"
  APP_ZIP="$NOTARY_DIR/$APP_NAME.zip"
  mkdir -p "$NOTARY_DIR"
  rm -f "$APP_ZIP"

  echo "==> Notarizing $APP_NAME.app"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  notary_submit "$APP_ZIP"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  rm -f "$APP_ZIP"
fi

mkdir -p "$BUILD_ROOT" "$(dirname "$DMG_PATH")"
PYTHON_BIN="$(select_python)"
ensure_dmgbuild

echo "==> Creating $DMG_PATH with ActivityWatch's dmgbuild settings"
rm -f "$DMG_PATH"
"$RELEASE_TOOLS_VENV/bin/dmgbuild" \
  -s "$DMG_SETTINGS" \
  -D "app=$APP_PATH" \
  "$VOLUME_NAME" \
  "$DMG_PATH"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing $(basename "$DMG_PATH")"
  codesign \
    --force \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Notarizing $(basename "$DMG_PATH")"
  notary_submit "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

echo "==> Verifying disk image"
hdiutil verify "$DMG_PATH" >/dev/null
verify_dmg_contents

echo "==> macOS release ready: $DMG_PATH"
