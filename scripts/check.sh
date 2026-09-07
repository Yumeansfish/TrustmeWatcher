#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NPM_BIN="${NPM_BIN:-npm}"

step() {
  printf '\n==> %s\n' "$1"
}

require_dir() {
  if [[ ! -d "$ROOT_DIR/$1" ]]; then
    echo "Required release source directory missing: $1" >&2
    exit 1
  fi
}

require_dir backend
require_dir frontend
require_dir activitywatch
require_dir trustme-xai

step "Locked repository inputs"
echo "ActivityWatch d3affdc895a3c5aa586283200b039b4c6a17b0f8"
if find "$ROOT_DIR/activitywatch" -name .git -print -quit | grep -q .; then
  echo "Vendored ActivityWatch source contains nested Git metadata" >&2
  exit 1
fi
git -C "$ROOT_DIR" submodule status --recursive

step "Root script ruff"
(cd "$ROOT_DIR" && "$PYTHON_BIN" -m ruff check scripts)

step "Root composition tests"
(cd "$ROOT_DIR" && "$PYTHON_BIN" -m pytest -q scripts/tests)

step "XAI packaging contract"
XAI_CONTRACT_RESOURCE="$({
  cd "$ROOT_DIR/trustme-xai"
  PYTHONPATH="$ROOT_DIR/trustme-xai/src${PYTHONPATH:+:$PYTHONPATH}" \
    "$PYTHON_BIN" -c \
      'from trustme_xai.inference.compact_contract import COMPACT_CONTRACT_RESOURCE; print(COMPACT_CONTRACT_RESOURCE)'
})"
[[ -f "$ROOT_DIR/trustme-xai/src/trustme_xai/inference/$XAI_CONTRACT_RESOURCE" ]] \
  || { echo "Missing XAI contract resource: $XAI_CONTRACT_RESOURCE" >&2; exit 1; }
for packaging_script in \
  scripts/activitywatch_patches.py \
  scripts/build_binaries.sh \
  scripts/build_windows.ps1 \
  scripts/compose_activitywatch.py \
  scripts/release_macos.sh; do
  grep -Fq "$XAI_CONTRACT_RESOURCE" "$ROOT_DIR/$packaging_script" \
    || { echo "$packaging_script does not package $XAI_CONTRACT_RESOURCE" >&2; exit 1; }
done

step "XAI pytest"
(
  cd "$ROOT_DIR/trustme-xai"
  PYTHONPATH="$ROOT_DIR/trustme-xai/src${PYTHONPATH:+:$PYTHONPATH}" \
    "$PYTHON_BIN" -m pytest
)

step "XAI ruff"
(cd "$ROOT_DIR/trustme-xai" && "$PYTHON_BIN" -m ruff check src tests)

step "Backend pytest"
(
  cd "$ROOT_DIR/backend"
  PYTHONPATH="$ROOT_DIR/trustme-xai/src${PYTHONPATH:+:$PYTHONPATH}" \
    "$PYTHON_BIN" -m pytest
)

step "Backend ruff"
(cd "$ROOT_DIR/backend" && "$PYTHON_BIN" -m ruff check src tests)

step "Frontend contracts"
"$PYTHON_BIN" "$ROOT_DIR/scripts/sync_frontend_contracts.py" --check

step "Frontend typecheck"
(cd "$ROOT_DIR/frontend" && "$NPM_BIN" run typecheck)

step "Frontend node tests"
(cd "$ROOT_DIR/frontend" && "$NPM_BIN" run test:node)

step "Frontend route component smoke"
(cd "$ROOT_DIR/frontend" && "$NPM_BIN" run test:components)

step "Frontend production build"
(cd "$ROOT_DIR/frontend" && "$NPM_BIN" run build)
