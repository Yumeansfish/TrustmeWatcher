#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${APP_PATH:-/Applications/trust-me.app}"
BUILD_ROOT="${BUILD_ROOT:-/private/tmp/trustme-release-build}"
RUNTIME_ROOT="${RUNTIME_ROOT:-$HOME/Library/Application Support/TrustmeWatcher/runtime}"
SYSTEM_BIN_DIR="${SYSTEM_BIN_DIR:-$HOME/.local/bin}"
SERVER_LINK="${SERVER_LINK:-$SYSTEM_BIN_DIR/aw-server}"
SERVER_BUNDLE_DIR="${SERVER_BUNDLE_DIR:-$BUILD_ROOT/bin/server/aw-server}"
SERVER_URL="${SERVER_URL:-}"
AW_SERVER_CONFIG_PATH="${AW_SERVER_CONFIG_PATH:-$HOME/Library/Application Support/activitywatch/aw-server/aw-server.toml}"
START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-30}"
VERIFY_CODE_SIGNATURES="${VERIFY_CODE_SIGNATURES:-1}"

SKIP_BUILD=0
RESTART_APP=1
ROLLBACK_ARMED=0
APP_WAS_RUNNING=0
STAGING_DIR=""
HEALTH_RESPONSE=""
LOCK_DIR=""
LOCK_HELD=0

usage() {
  cat <<'EOF'
Build and deploy the current frontend/backend into the installed local Trust-me app.

Usage:
  scripts/update_local_app.sh [--skip-build] [--no-restart]

Options:
  --skip-build  Reuse BUILD_ROOT/bin/server/aw-server instead of rebuilding.
  --no-restart  Install the runtime but do not stop, start, or health-check the app.
  -h, --help    Show this help.

The updater intentionally keeps aw-qt and all OS watchers byte-for-byte unchanged.
It installs aw-server outside the app bundle and makes the original launcher select it.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
    return
  fi
  stat -c '%a' "$1"
}

configured_server_port() {
  python3 - "$AW_SERVER_CONFIG_PATH" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
section = ""
if path.is_file():
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "server":
            continue
        match = re.fullmatch(r"port\s*=\s*[\"']?(\d+)[\"']?", line)
        if match:
            print(match.group(1))
            raise SystemExit
print("5600")
PY
}

server_url_port() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

port = urlsplit(sys.argv[1]).port
if port is None:
    raise SystemExit("server URL has no port")
print(port)
PY
}

app_process_ids() {
  pgrep -f "$APP_MACOS_DIR/" 2>/dev/null || true
}

runtime_process_ids() {
  pgrep -f "$RUNTIME_ROOT/aw-server-" 2>/dev/null || true
}

linked_server_process_ids() {
  pgrep -f "$SERVER_LINK" 2>/dev/null || true
}

managed_process_ids() {
  {
    app_process_ids
    runtime_process_ids
    linked_server_process_ids
  } | awk 'NF && !seen[$0]++'
}

app_is_running() {
  [[ -n "$(app_process_ids)" ]]
}

launcher_is_running() {
  [[ -n "$(pgrep -f "$APP_MACOS_DIR/aw-qt" 2>/dev/null || true)" ]]
}

wait_for_managed_exit() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [[ -n "$(managed_process_ids)" ]]; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 1
  done
}

signal_managed_processes() {
  local signal="$1"
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done < <(managed_process_ids)
}

request_app_quit() {
  local bundle_id=""
  if [[ -f "$APP_PATH/Contents/Info.plist" && -x /usr/libexec/PlistBuddy ]]; then
    bundle_id="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
    )"
  fi

  if [[ -n "$bundle_id" ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application id \"$bundle_id\" to quit" \
      >/dev/null 2>&1 || true
  fi
}

stop_managed_app() {
  [[ -n "$(managed_process_ids)" ]] || return 0

  echo "==> Stopping the installed Trust-me app"
  request_app_quit
  if wait_for_managed_exit 10; then
    return 0
  fi

  signal_managed_processes TERM
  if wait_for_managed_exit 5; then
    return 0
  fi

  signal_managed_processes KILL
  wait_for_managed_exit 3
}

start_app() {
  PATH="$SYSTEM_BIN_DIR:$PATH" open -n "$APP_PATH"
}

deployed_server_owns_listener() {
  local executable_pids
  local listener_pids
  local executable_pid
  local listener_pid

  executable_pids="$(lsof -t "$DEPLOYED_RUNTIME/aw-server" 2>/dev/null || true)"
  listener_pids="$(
    lsof -nP -iTCP:"$SERVER_PORT" -sTCP:LISTEN -t 2>/dev/null || true
  )"
  for executable_pid in $executable_pids; do
    for listener_pid in $listener_pids; do
      if [[ "$executable_pid" == "$listener_pid" ]]; then
        return 0
      fi
    done
  done
  return 1
}

atomic_symlink() {
  python3 - "$1" "$2" <<'PY'
import os
import secrets
import sys
from pathlib import Path

target = sys.argv[1]
destination = Path(sys.argv[2])
temporary = destination.parent / (
    f".{destination.name}.update.{os.getpid()}.{secrets.token_hex(6)}"
)
try:
    temporary.symlink_to(target)
    os.replace(temporary, destination)
finally:
    temporary.unlink(missing_ok=True)
PY
}

check_for_competing_system_servers() {
  local candidate
  for candidate in /opt/homebrew/bin/aw-server /usr/local/bin/aw-server; do
    if [[ -x "$candidate" ]]; then
      die "Another aw-server would take priority over $SERVER_LINK: $candidate"
    fi
  done
}

restore_previous_link() {
  if [[ "$PREVIOUS_LINK_PRESENT" == "1" ]]; then
    atomic_symlink "$PREVIOUS_LINK_TARGET" "$SERVER_LINK"
  elif [[ -L "$SERVER_LINK" ]]; then
    rm -f "$SERVER_LINK"
  fi
}

rollback() {
  echo "==> Update failed; restoring the previous local runtime" >&2
  if [[ "$RESTART_APP" == "1" ]]; then
    stop_managed_app || \
      echo "Warning: some managed processes did not stop during rollback" >&2
  fi
  restore_previous_link
  chmod "$ORIGINAL_BUNDLED_MODE" "$BUNDLED_SERVER"

  if [[ "$RESTART_APP" == "1" && "$APP_WAS_RUNNING" == "1" ]]; then
    start_app >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
  if [[ -n "$HEALTH_RESPONSE" && -f "$HEALTH_RESPONSE" ]]; then
    rm -f "$HEALTH_RESPONSE"
  fi
  if [[ "$LOCK_HELD" == "1" && -n "$LOCK_DIR" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" != "0" && "$ROLLBACK_ARMED" == "1" ]]; then
    rollback
  fi
  cleanup
  exit "$status"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      ;;
    --no-restart)
      RESTART_APP=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done

trap on_exit EXIT

require_cmd awk
require_cmd python3
require_cmd rsync
require_cmd stat

APP_PATH="${APP_PATH%/}"
APP_MACOS_DIR="$APP_PATH/Contents/MacOS"
BUNDLED_SERVER="$APP_MACOS_DIR/aw-server"
if [[ -z "$SERVER_URL" ]]; then
  SERVER_URL="http://127.0.0.1:$(configured_server_port)"
fi
SERVER_URL="${SERVER_URL%/}"
SERVER_PORT="$(server_url_port "$SERVER_URL")" || \
  die "Unable to determine the port from SERVER_URL: $SERVER_URL"

[[ -d "$APP_MACOS_DIR" ]] || die "Installed app not found: $APP_PATH"
[[ -f "$BUNDLED_SERVER" ]] || die "Bundled aw-server not found: $BUNDLED_SERVER"
[[ ! -L "$BUNDLED_SERVER" ]] || \
  die "Refusing to change a symlinked bundled aw-server: $BUNDLED_SERVER"
[[ -w "$BUNDLED_SERVER" ]] || \
  die "Bundled aw-server is not writable without sudo: $BUNDLED_SERVER"
if [[ "${EUID:-$(id -u)}" == "0" && "${ALLOW_ROOT_FOR_TESTS:-0}" != "1" ]]; then
  die "Do not run this updater with sudo or as root"
fi

mkdir -p "$RUNTIME_ROOT"
chmod 700 "$RUNTIME_ROOT"
LOCK_DIR="$RUNTIME_ROOT/.update-local-app.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_OWNER="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$LOCK_OWNER" =~ ^[0-9]+$ ]] && ! kill -0 "$LOCK_OWNER" 2>/dev/null; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || \
      die "Unable to remove stale updater lock: $LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || \
      die "Another updater acquired the lock: $LOCK_DIR"
  else
    die "Another updater is running (lock: $LOCK_DIR, pid: ${LOCK_OWNER:-unknown})"
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
LOCK_HELD=1

if [[ "$VERIFY_CODE_SIGNATURES" == "1" ]]; then
  require_cmd codesign
fi
if [[ "$RESTART_APP" == "1" ]]; then
  require_cmd curl
  require_cmd lsof
  require_cmd open
  require_cmd pgrep
  check_for_competing_system_servers
fi

if [[ "$SKIP_BUILD" == "0" ]]; then
  echo "==> Building the current frontend and backend"
  require_cmd make
  make -C "$ROOT_DIR" binary-server BUILD_ROOT="$BUILD_ROOT"
else
  echo "==> Reusing server runtime from $SERVER_BUNDLE_DIR"
fi

[[ -d "$SERVER_BUNDLE_DIR" ]] || \
  die "Server runtime directory not found: $SERVER_BUNDLE_DIR"
[[ -x "$SERVER_BUNDLE_DIR/aw-server" ]] || \
  die "Packaged aw-server is missing or not executable"
[[ -f "$SERVER_BUNDLE_DIR/aw_server/static/index.html" ]] || \
  die "Packaged frontend index is missing"

if [[ "$VERIFY_CODE_SIGNATURES" == "1" ]]; then
  codesign --verify --deep "$APP_PATH" >/dev/null 2>&1 || \
    die "Installed app has an invalid code signature"
fi
ORIGINAL_BUNDLED_MODE="$(file_mode "$BUNDLED_SERVER")"

PREVIOUS_LINK_PRESENT=0
PREVIOUS_LINK_TARGET=""
if [[ -L "$SERVER_LINK" ]]; then
  PREVIOUS_LINK_PRESENT=1
  PREVIOUS_LINK_TARGET="$(readlink "$SERVER_LINK")"
elif [[ -e "$SERVER_LINK" ]]; then
  die "Refusing to replace non-symlink path: $SERVER_LINK"
fi

echo "==> Installing an external aw-server runtime"
mkdir -p "$SYSTEM_BIN_DIR"
STAGING_DIR="$(mktemp -d "$RUNTIME_ROOT/aw-server-XXXXXX")"
rsync -a "$SERVER_BUNDLE_DIR/" "$STAGING_DIR/"
DEPLOYED_RUNTIME="$STAGING_DIR"

[[ -x "$DEPLOYED_RUNTIME/aw-server" ]] || \
  die "Installed aw-server runtime is incomplete: $DEPLOYED_RUNTIME"
[[ -f "$DEPLOYED_RUNTIME/aw_server/static/index.html" ]] || \
  die "Installed frontend runtime is incomplete: $DEPLOYED_RUNTIME"
if [[ "$VERIFY_CODE_SIGNATURES" == "1" ]]; then
  codesign --verify "$DEPLOYED_RUNTIME/aw-server" >/dev/null 2>&1 || \
    die "Packaged aw-server has an invalid code signature"
fi

if app_is_running; then
  APP_WAS_RUNNING=1
fi
ROLLBACK_ARMED=1

if [[ "$RESTART_APP" == "1" ]]; then
  stop_managed_app || die "Failed to stop the installed app processes"
fi

atomic_symlink "$DEPLOYED_RUNTIME/aw-server" "$SERVER_LINK"

# aw-qt prefers executable bundled modules. Removing only this execute bit makes
# it discover ~/.local/bin/aw-server while every signed binary stays untouched.
chmod a-x "$BUNDLED_SERVER"

if [[ "$RESTART_APP" == "1" ]]; then
  echo "==> Starting the installed Trust-me app"
  start_app

  HEALTH_RESPONSE="$(mktemp)"
  HEALTH_DEADLINE=$((SECONDS + START_TIMEOUT_SECONDS))
  until curl --noproxy '*' -fsSL --max-time 2 \
    "$SERVER_URL/" -o "$HEALTH_RESPONSE" \
    >/dev/null 2>&1; do
    if (( SECONDS >= HEALTH_DEADLINE )); then
      die "aw-server did not become healthy at $SERVER_URL"
    fi
    sleep 1
  done

  curl --noproxy '*' -fsS --max-time 5 \
    "$SERVER_URL/api/0/info" >/dev/null || \
    die "aw-server API health check failed"
  deployed_server_owns_listener || \
    die "The new aw-server runtime does not own port $SERVER_PORT"

  EXPECTED_ASSET="$(python3 - "$DEPLOYED_RUNTIME/aw_server/static/index.html" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"assets/index-[^\"']+\.js", text)
if not match:
    raise SystemExit("unable to find the built frontend asset")
print(match.group(0))
PY
)"
  grep -F "$EXPECTED_ASSET" "$HEALTH_RESPONSE" >/dev/null || \
    die "The running app is not serving the newly built frontend"

  sleep 2
  launcher_is_running || die "aw-qt stopped shortly after launch"
  curl --noproxy '*' -fsS --max-time 5 \
    "$SERVER_URL/api/0/info" >/dev/null || \
    die "aw-server stopped shortly after launch"
  deployed_server_owns_listener || \
    die "The new aw-server runtime stopped owning port $SERVER_PORT"
fi

ROLLBACK_ARMED=0
STAGING_DIR=""

echo
echo "Local Trust-me app updated successfully."
echo "Runtime: $DEPLOYED_RUNTIME"
echo "Server:  $SERVER_URL"
echo "aw-qt and all OS watchers are unchanged."
