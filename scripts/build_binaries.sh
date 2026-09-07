#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build}"
COMPOSED_DIR="${COMPOSED_DIR:-$BUILD_ROOT/composed/activitywatch}"
XAI_DIR="${XAI_DIR:-$ROOT_DIR/trustme-xai}"

APP_NAME="${APP_NAME:-trust-me}"
BUNDLE_ID="${BUNDLE_ID:-io.github.yumeansfish.trustme}"
RELEASE_VERSION="${RELEASE_VERSION:-0.0.0}"

# ActivityWatch pins this Poetry version in its own release workflow. PyInstaller
# and its hooks are installed from the composed source's root poetry.lock.
POETRY_VERSION="1.4.2"
PBS_INSTALLER_VERSION="${PBS_INSTALLER_VERSION:-2026.6.10}"
TOOLS_VENV="$BUILD_ROOT/.build-tools"
BUILD_VENV="$BUILD_ROOT/.build-venv"
BOOTSTRAP_VENV="$BUILD_ROOT/.python-bootstrap"
LOCAL_PYTHON_DIR="$BUILD_ROOT/python-3.11"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build_binaries.sh server|app

The composed ActivityWatch tree must already exist at:
  $BUILD_ROOT/composed/activitywatch

Outputs:
  server  $BUILD_ROOT/bin/server/aw-server/
  app     $BUILD_ROOT/bin/app/$APP_NAME.app
EOF
}

die() {
  echo "build_binaries: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "required directory not found: $1"
}

python_is_supported() {
  "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(sys.version_info[:2] != (3, 11))
PY
}

bootstrap_build_python() {
  local bootstrap_python

  bootstrap_python="$(command -v python3 || true)"
  [[ -n "$bootstrap_python" ]] \
    || die "python3 is required to bootstrap the isolated Python 3.11 runtime"

  echo "==> Bootstrapping isolated Python 3.11" >&2
  rm -rf "$BOOTSTRAP_VENV" "$LOCAL_PYTHON_DIR"
  "$bootstrap_python" -m venv "$BOOTSTRAP_VENV" >&2
  "$BOOTSTRAP_VENV/bin/python" -m pip install \
    --disable-pip-version-check \
    "pbs-installer[download,install]==$PBS_INSTALLER_VERSION" >&2
  "$BOOTSTRAP_VENV/bin/pbs-install" \
    3.11 \
    -d "$LOCAL_PYTHON_DIR" >&2

  python_is_supported "$LOCAL_PYTHON_DIR/bin/python3.11" \
    || die "the bootstrapped Python 3.11 runtime is unusable"
}

select_build_python() {
  local candidate

  if [[ -n "${BUILD_PYTHON:-}" ]]; then
    python_is_supported "$BUILD_PYTHON" \
      || die "BUILD_PYTHON must be Python 3.11: $BUILD_PYTHON"
    printf '%s\n' "$BUILD_PYTHON"
    return
  fi

  for candidate in \
    "$LOCAL_PYTHON_DIR/bin/python3.11" \
    python3.11 \
    python3; do
    if command -v "$candidate" >/dev/null 2>&1 && python_is_supported "$candidate"; then
      if [[ "$candidate" != "python3" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
      if [[ "$("$candidate" -c 'import sys; print(sys.version_info[:2])')" == "(3, 11)" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    fi
  done

  bootstrap_build_python
  printf '%s\n' "$LOCAL_PYTHON_DIR/bin/python3.11"
}

install_xai_runtime() {
  local server_dir="$COMPOSED_DIR/aw-server"

  require_file "$XAI_DIR/pyproject.toml"
  require_file "$server_dir/trustme_xai/action_classifier.joblib"
  require_file "$server_dir/trustme_xai/current.joblib"
  echo "==> Installing Trustme XAI runtime"
  "$BUILD_VENV/bin/python" -m pip install "$XAI_DIR" -r "$ROOT_DIR/backend/requirements.txt"
  "$BUILD_VENV/bin/python" - "$server_dir" <<'PY'
from pathlib import Path
import sys

server_dir = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(server_dir))

from trustme_xai.inference.model_runtime import load_model_bundle
from trustme_xai.contracts import MODEL_TARGETS
from trustme_xai.inference.action_classifier import (
    load_action_classifier_runtime,
)
from trustme_xai.inference.action_classifier_contract import (
    ACTION_CLASSIFIER_MODEL_VERSION,
)
from trustme_xai.inference.compact_contract import COMPACT_MODEL_VERSION

bundle = load_model_bundle(server_dir / "trustme_xai" / "current.joblib")
if (
    bundle.feature_set != COMPACT_MODEL_VERSION
    or bundle.targets != MODEL_TARGETS
):
    raise SystemExit(
        "bundled model does not expose the expected compact runtime contract"
    )
classifier = load_action_classifier_runtime(
    server_dir / "trustme_xai" / "action_classifier.joblib"
)
if classifier.model_version != ACTION_CLASSIFIER_MODEL_VERSION:
    raise SystemExit("bundled action classifier does not expose the expected contract")
print("==> Verified bundled model-output artifact")
PY
}

ensure_poetry() {
  local rebuild=0

  if [[ ! -x "$TOOLS_VENV/bin/poetry" ]]; then
    rebuild=1
  elif [[ "$($TOOLS_VENV/bin/poetry --version 2>/dev/null || true)" != "Poetry (version $POETRY_VERSION)" ]]; then
    rebuild=1
  fi

  if [[ "$rebuild" == "1" ]]; then
    echo "==> Creating isolated Poetry environment"
    rm -rf "$TOOLS_VENV"
    "$BUILD_PYTHON_BIN" -m venv "$TOOLS_VENV"
    "$TOOLS_VENV/bin/python" -m pip install \
      --disable-pip-version-check \
      "poetry==$POETRY_VERSION"
  fi
}

create_build_environment() {
  echo "==> Creating isolated binary build environment"
  rm -rf "$BUILD_VENV"
  "$BUILD_PYTHON_BIN" -m venv "$BUILD_VENV"

  export VIRTUAL_ENV="$BUILD_VENV"
  export PATH="$BUILD_VENV/bin:$TOOLS_VENV/bin:$PATH"
  export POETRY_VIRTUALENVS_CREATE=false
  export POETRY_NO_INTERACTION=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_INPUT=1
  export PIP_REQUIRE_VIRTUALENV=true
}

poetry_install() {
  local project_dir="$1"
  shift
  (
    cd "$project_dir"
    "$TOOLS_VENV/bin/poetry" install --no-interaction "$@"
  )
}

build_module() {
  local module="$1"
  echo "==> Building upstream module $module"
  make -C "$COMPOSED_DIR/$module" build SKIP_WEBUI=true
}

restore_vendored_packages() {
  local wheel_dir="$BUILD_ROOT/.vendored-wheels"
  local module
  local modules=(aw-core aw-client)

  if [[ "$TARGET" == "app" ]]; then
    # aw-watcher-input's lock references aw-watcher-afk through Git. Install a
    # wheel from the composed source last so the app cannot pick up another
    # revision of that package.
    modules+=(aw-watcher-afk)
  fi

  rm -rf "$wheel_dir"
  mkdir -p "$wheel_dir"
  for module in "${modules[@]}"; do
    local module_dist="$COMPOSED_DIR/$module/dist"
    local built_wheels
    rm -rf "$module_dist"
    (
      cd "$COMPOSED_DIR/$module"
      "$TOOLS_VENV/bin/poetry" build --format wheel
    )
    built_wheels=("$module_dist"/*.whl)
    [[ "${#built_wheels[@]}" -eq 1 && -f "${built_wheels[0]}" ]] \
      || die "expected one wheel for $module in $module_dist"
    cp "${built_wheels[0]}" "$wheel_dir/"
  done

  local wheels=("$wheel_dir"/*.whl)
  "$BUILD_VENV/bin/python" -m pip install \
    --no-deps \
    --force-reinstall \
    "${wheels[@]}"

  verify_vendored_packages "${modules[@]}"
}

verify_vendored_packages() {
  "$BUILD_VENV/bin/python" - "$COMPOSED_DIR" "$@" <<'PY'
from __future__ import annotations

import importlib.metadata
import importlib.util
import sys
import sysconfig
import tomllib
from pathlib import Path


source_root = Path(sys.argv[1]).resolve()
modules = sys.argv[2:]
site_packages = Path(sysconfig.get_paths()["purelib"]).resolve()
package_dirs = {
    "aw-core": ("aw_core", "aw_datastore", "aw_query", "aw_transform", "aw_cli"),
    "aw-client": ("aw_client",),
    "aw-watcher-afk": ("aw_watcher_afk",),
}

for module in modules:
    pyproject = source_root / module / "pyproject.toml"
    metadata = tomllib.loads(pyproject.read_text(encoding="utf-8"))["tool"]["poetry"]
    distribution_name = metadata["name"]
    expected_version = metadata["version"]
    installed_version = importlib.metadata.version(distribution_name)
    if installed_version != expected_version:
        raise SystemExit(
            f"{distribution_name} version mismatch: "
            f"installed {installed_version}, composed {expected_version}"
        )

    for package_dir in package_dirs[module]:
        source_dir = source_root / module / package_dir
        installed_dir = site_packages / package_dir
        for source_file in source_dir.rglob("*.py"):
            installed_file = installed_dir / source_file.relative_to(source_dir)
            if not installed_file.is_file():
                raise SystemExit(f"composed Python file was not installed: {installed_file}")
            if installed_file.read_bytes() != source_file.read_bytes():
                raise SystemExit(
                    f"installed Python file does not match composed source: {installed_file}"
                )

        spec = importlib.util.find_spec(package_dir)
        if spec is None:
            raise SystemExit(f"unable to resolve installed package: {package_dir}")
        if spec.origin is None:
            search_locations = {
                Path(location).resolve()
                for location in (spec.submodule_search_locations or ())
            }
            if installed_dir not in search_locations:
                raise SystemExit(
                    f"{package_dir} resolves outside the build environment: "
                    f"{sorted(str(location) for location in search_locations)}"
                )
        else:
            origin = Path(spec.origin).resolve()
            try:
                origin.relative_to(installed_dir)
            except ValueError:
                raise SystemExit(
                    f"{package_dir} resolves outside the build environment: {origin}"
                ) from None

    print(f"==> Verified composed {distribution_name} {installed_version}")
PY
}

verify_locked_pyinstaller() {
  "$BUILD_VENV/bin/python" - "$COMPOSED_DIR/poetry.lock" <<'PY'
from importlib.metadata import version
from pathlib import Path
import re
import sys

lock_text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r'\[\[package\]\]\s+name = "pyinstaller"\s+version = "([^"]+)"',
    lock_text,
)
if match is None:
    raise SystemExit("unable to find PyInstaller in the upstream poetry.lock")

expected = match.group(1)
installed = version("pyinstaller")
if installed != expected:
    raise SystemExit(
        f"PyInstaller does not match upstream lock: {installed} != {expected}"
    )
print(f"==> Verified upstream-locked PyInstaller {installed}")
PY
}

set_server_version() {
  local server_dir="$COMPOSED_DIR/aw-server"
  local version="${RELEASE_VERSION#v}"

  [[ -n "$version" && "$version" != *$'\n'* && "$version" != *$'\r'* ]] \
    || die "RELEASE_VERSION is invalid: $RELEASE_VERSION"

  (
    cd "$server_dir"
    "$TOOLS_VENV/bin/poetry" version "$version" >/dev/null
  )
  "$BUILD_VENV/bin/python" - "$server_dir/aw_server/__about__.py" "$version" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")
updated, replacements = re.subn(
    r'^__version__ = "[^"]+"$',
    f'__version__ = "v{version}"',
    text,
    flags=re.MULTILINE,
)
if replacements != 1:
    raise SystemExit(
        f"expected exactly one static aw-server version in {path}; found {replacements}"
    )
path.write_text(updated, encoding="utf-8")
PY
  echo "==> Set composed aw-server version to v$version"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null \
    || die "missing $2 in $1"
}

verify_app() {
  local app_path="$1"
  local plist="$app_path/Contents/Info.plist"
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

  if [[ -x "$app_path/Contents/MacOS/$executable" ]]; then
    :
  elif [[ -x "$app_path/Contents/$executable" ]]; then
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
    [[ -x "$app_path/Contents/MacOS/$payload_executable" ]] \
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
    require_file "$app_path/Contents/Resources/$required_resource"
  done
  [[ ! -e "$app_path/Contents/Resources/aw_server/deployment.toml" ]] \
    || die "app payload must not contain deployment.toml"

  [[ "$("$app_path/Contents/MacOS/aw-server" --version)" == "v${RELEASE_VERSION#v}" ]] \
    || die "app's aw-server reports the wrong release version"
  codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 \
    || die "app payload has an invalid code signature"
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

TARGET="$1"
case "$TARGET" in
  server|app) ;;
  *)
    usage
    exit 2
    ;;
esac

[[ -n "$APP_NAME" && "$APP_NAME" != */* ]] \
  || die "APP_NAME must be a non-empty filename component"
[[ -n "$BUNDLE_ID" ]] || die "BUNDLE_ID must not be empty"

require_cmd make
require_cmd git
require_dir "$COMPOSED_DIR"
require_dir "$XAI_DIR"
require_file "$COMPOSED_DIR/pyproject.toml"
require_file "$COMPOSED_DIR/poetry.lock"
require_file "$COMPOSED_DIR/aw-server/aw_server/static/index.html"
[[ ! -e "$COMPOSED_DIR/aw-server/aw_server/deployment.toml" ]] \
  || die "composed source must not contain deployment.toml"

mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
COMPOSED_DIR="$(cd "$COMPOSED_DIR" && pwd)"
XAI_DIR="$(cd "$XAI_DIR" && pwd)"
TOOLS_VENV="$BUILD_ROOT/.build-tools"
BUILD_VENV="$BUILD_ROOT/.build-venv"
BOOTSTRAP_VENV="$BUILD_ROOT/.python-bootstrap"
LOCAL_PYTHON_DIR="$BUILD_ROOT/python-3.11"

# The default BUILD_ROOT lives below this repository's ignored build/ path.
# Poetry asks the nearest Git worktree for ignored files while building wheels;
# without a ceiling it therefore excludes every composed Python source file and
# produces metadata-only wheels. The composed tree is a standalone build input,
# so prevent VCS discovery from escaping BUILD_ROOT.
export GIT_CEILING_DIRECTORIES="$BUILD_ROOT${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}"

# Keep Poetry and pip state inside BUILD_ROOT as well as their installed
# packages. A developer's global Poetry config or cache must not affect a
# release build.
export POETRY_CONFIG_DIR="$BUILD_ROOT/.poetry/config"
export POETRY_CACHE_DIR="$BUILD_ROOT/.poetry/cache"
export POETRY_DATA_DIR="$BUILD_ROOT/.poetry/data"
export POETRY_KEYRING_ENABLED=false
export PIP_CACHE_DIR="$BUILD_ROOT/.pip-cache"
export PYINSTALLER_CONFIG_DIR="$BUILD_ROOT/.pyinstaller"
mkdir -p \
  "$POETRY_CONFIG_DIR" \
  "$POETRY_CACHE_DIR" \
  "$POETRY_DATA_DIR" \
  "$PIP_CACHE_DIR" \
  "$PYINSTALLER_CONFIG_DIR"

BUILD_PYTHON_BIN="$(select_build_python)"
ensure_poetry
create_build_environment

echo "==> Installing upstream-locked build tools"
poetry_install "$COMPOSED_DIR" --no-root

MODULES=(aw-core aw-client aw-server)
if [[ "$TARGET" == "app" ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || die "the app target requires macOS"
  require_cmd ditto
  require_cmd codesign
  require_cmd plutil
  require_cmd swiftc
  require_file "$COMPOSED_DIR/aw.spec"
  require_file "$COMPOSED_DIR/aw-qt/media/logo/logo.icns"
  MODULES+=(aw-qt aw-watcher-afk aw-watcher-window aw-watcher-input)
fi

for module in "${MODULES[@]}"; do
  require_dir "$COMPOSED_DIR/$module"
  require_file "$COMPOSED_DIR/$module/pyproject.toml"
  require_file "$COMPOSED_DIR/$module/poetry.lock"
  build_module "$module"
done

# Match the upstream release workflow: module installs provide their runtime
# dependencies, then the root lock restores the exact PyInstaller toolchain.
poetry_install "$COMPOSED_DIR" --no-root
restore_vendored_packages
verify_locked_pyinstaller
install_xai_runtime
set_server_version

if [[ "$TARGET" == "server" ]]; then
  SERVER_OUTPUT="$BUILD_ROOT/bin/server/aw-server"
  echo "==> Packaging aw-server with its upstream PyInstaller spec"
  rm -rf "$COMPOSED_DIR/aw-server/build" "$COMPOSED_DIR/aw-server/dist"
  (
    cd "$COMPOSED_DIR/aw-server"
    "$BUILD_VENV/bin/pyinstaller" --clean --noconfirm aw-server.spec
  )

  SERVER_SOURCE="$COMPOSED_DIR/aw-server/dist/aw-server"
  require_file "$SERVER_SOURCE/aw-server"
  rm -rf "$SERVER_OUTPUT"
  mkdir -p "$SERVER_OUTPUT"
  cp -R "$SERVER_SOURCE/." "$SERVER_OUTPUT/"
  [[ -x "$SERVER_OUTPUT/aw-server" ]] \
    || die "packaged server executable is not executable"
  [[ "$("$SERVER_OUTPUT/aw-server" --version)" == "v${RELEASE_VERSION#v}" ]] \
    || die "packaged server reports the wrong release version"
  for required_path in \
    aw_server/settings/aw-category-export.json \
    aw_server/static/index.html \
    trustme_xai/action_classifier.joblib \
    trustme_xai/current.joblib \
    trustme_xai/feature_pipeline/category_rules.json \
    trustme_xai/feature_pipeline/behavior_state_model.json \
    trustme_xai/inference/compact_aw_v2.json; do
    require_file "$SERVER_OUTPUT/$required_path"
  done
  [[ ! -e "$SERVER_OUTPUT/aw_server/deployment.toml" ]] \
    || die "server payload must not contain deployment.toml"

  echo "==> Server binary ready: $SERVER_OUTPUT"
  exit 0
fi

APP_OUTPUT_DIR="$BUILD_ROOT/bin/app"
APP_OUTPUT="$APP_OUTPUT_DIR/$APP_NAME.app"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-${APPLE_PERSONALID:-}}"

echo "==> Packaging macOS app with the upstream root aw.spec"
rm -rf "$COMPOSED_DIR/build" "$COMPOSED_DIR/dist"
(
  cd "$COMPOSED_DIR"
  APP_NAME="$APP_NAME" \
  BUNDLE_ID="$BUNDLE_ID" \
  RELEASE_VERSION="$RELEASE_VERSION" \
  APPLE_PERSONALID="$SIGN_IDENTITY" \
    "$BUILD_VENV/bin/pyinstaller" --clean --noconfirm aw.spec
)

APP_SOURCE="$COMPOSED_DIR/dist/$APP_NAME.app"
if [[ ! -d "$APP_SOURCE" ]]; then
  die "aw.spec did not produce $APP_SOURCE; ensure compose patched aw.spec to read APP_NAME, BUNDLE_ID, and RELEASE_VERSION"
fi

rm -rf "$APP_OUTPUT"
mkdir -p "$APP_OUTPUT_DIR"
ditto "$APP_SOURCE" "$APP_OUTPUT"
verify_app "$APP_OUTPUT"

echo "==> macOS app ready: $APP_OUTPUT"
