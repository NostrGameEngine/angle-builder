#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"

ARTIFACT_ID="${ARTIFACT_ID:-angle-natives}"
VERSION="${QUICK_VERSION:-}"

if [[ -z "$VERSION" ]]; then
  VERSION="quicktest-$(date -u +%Y%m%d%H%M%S)"
fi

echo "VERSION=${VERSION}" >> "$GITHUB_ENV"

mkdir -p dist/empty
echo "quick test artifact" > dist/empty/README.txt

jar --create --file "dist/${ARTIFACT_ID}-${VERSION}.jar" -C dist/empty .
jar --create --file "dist/${ARTIFACT_ID}-${VERSION}-natives-linux.jar" -C dist/empty .
jar --create --file "dist/${ARTIFACT_ID}-${VERSION}-natives-windows.jar" -C dist/empty .

ls -la dist
