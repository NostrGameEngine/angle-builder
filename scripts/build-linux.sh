#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${STEAMRT_IMAGE:-registry.gitlab.steamos.cloud/steamrt/sniper/sdk}"
CONTAINER_NAME="${CONTAINER_NAME:-angle-build-linux}"

tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args=(-it)
fi

exec podman run --rm "${tty_args[@]}" --name="$CONTAINER_NAME" \
  -v "$ROOT_DIR":/workspace:z \
  -w /workspace \
  "$IMAGE" \
  bash -lc './scripts/build-linux-in-container.sh'
