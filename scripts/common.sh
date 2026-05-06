#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  WORK_DIR_DEFAULT="${RUNNER_TEMP:-/tmp}/angle-builder-build"
else
  WORK_DIR_DEFAULT="$ROOT_DIR/build"
fi
WORK_DIR="${WORK_DIR:-$WORK_DIR_DEFAULT}"
ANGLE_DIR="${ANGLE_DIR:-$WORK_DIR/angle}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/angle-artifacts}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$ROOT_DIR/.cache/depot_tools}"
ANGLE_PINNED_COMMIT="${ANGLE_PINNED_COMMIT:-${ANGLE_COMMIT:-84399673e381a301f2d4fd394a3a09450013feae}}"

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(basename "$0")" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

ensure_dir() {
  mkdir -p "$1"
}

retry_cmd() {
  local attempts="$1"
  local delay_seconds="$2"
  shift 2

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      return 1
    fi

    log "Command failed (attempt $attempt/$attempts): $*"
    log "Retrying in ${delay_seconds}s"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

host_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) fail "Unsupported host OS: $(uname -s)" ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$(uname -m)" ;;
  esac
}

ensure_depot_tools() {
  if [[ -d "$DEPOT_TOOLS_DIR/.git" ]]; then
    return
  fi
  ensure_dir "$(dirname "$DEPOT_TOOLS_DIR")"
  log "Cloning depot_tools into $DEPOT_TOOLS_DIR"
  git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
}

prepend_depot_tools() {
  export PATH="$DEPOT_TOOLS_DIR:$PATH"
}

ensure_angle_checkout() {
  ensure_depot_tools
  prepend_depot_tools

  if [[ -d "$ANGLE_DIR/.git" ]]; then
    log "Using existing ANGLE checkout at $ANGLE_DIR"
  elif [[ -d "$ANGLE_DIR" ]]; then
    fail "ANGLE source tree exists but is not a git checkout: $ANGLE_DIR"
  elif [[ -e "$ANGLE_DIR" ]]; then
    fail "ANGLE path exists but is not a directory, and will not be deleted: $ANGLE_DIR"
  else
    ensure_dir "$ANGLE_DIR"
    if [[ "$(basename "$ANGLE_DIR")" != "angle" ]]; then
      fail "ANGLE_DIR must be named 'angle' when using depot_tools fetch: $ANGLE_DIR"
    fi
    log "Fetching ANGLE with depot_tools"
    pushd "$ANGLE_DIR" >/dev/null
    retry_cmd 3 15 fetch angle
    popd >/dev/null
  fi

  [[ -d "$ANGLE_DIR/.git" ]] || fail "ANGLE checkout was not created at $ANGLE_DIR"

  log "Checking out pinned ANGLE commit: $ANGLE_PINNED_COMMIT"
  git -C "$ANGLE_DIR" checkout --force --detach "$ANGLE_PINNED_COMMIT"

  # Keep DEPS in sync for the exact ANGLE checkout before building.
  pushd "$ANGLE_DIR" >/dev/null
  retry_cmd 3 15 gclient sync
  popd >/dev/null
}

apply_patches() {
  local patch
  if [[ ! -d "$ROOT_DIR/patches" ]]; then
    return
  fi
  shopt -s nullglob
  for patch in "$ROOT_DIR"/patches/*.patch; do
    if git -C "$ANGLE_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "Patch already applied: $(basename "$patch")"
    elif git -C "$ANGLE_DIR" apply --check "$patch" >/dev/null 2>&1; then
      log "Applying patch: $(basename "$patch")"
      git -C "$ANGLE_DIR" apply "$patch"
    else
      fail "Patch does not apply cleanly: $patch"
    fi
  done
  shopt -u nullglob
}

build_info_file() {
  local target_dir="$1"
  local angle_commit="unknown"
  local angle_branch="unknown"
  ensure_dir "$target_dir"

  if git -C "$ANGLE_DIR" rev-parse HEAD >/dev/null 2>&1; then
    angle_commit="$(git -C "$ANGLE_DIR" rev-parse HEAD)"
    angle_branch="$(git -C "$ANGLE_DIR" rev-parse --abbrev-ref HEAD)"
  fi

  cat > "$target_dir/ANGLE_BUILD_INFO.txt" <<EOF_INFO
ANGLE_COMMIT=$angle_commit
ANGLE_BRANCH=$angle_branch
HOST_OS=$(host_os)
HOST_ARCH=$(host_arch)
BUILT_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_INFO
}

require_staged_file() {
  local stage_dir="$1"
  local file_name="$2"
  [[ -f "$stage_dir/$file_name" ]] || fail "Missing staged runtime library: $stage_dir/$file_name"
}

jar_create() {
  local output="$1"
  local input_dir="$2"
  ensure_dir "$(dirname "$output")"
  (cd "$input_dir" && jar cf "$output" .)
}
