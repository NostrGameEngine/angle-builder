#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"

if [[ -z "${MAVEN_TOKEN:-}" ]]; then
  echo "MAVEN_TOKEN is required for GitHub Packages publishing." >&2
  exit 1
fi

OWNER_LC="$(echo "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
REPO_NAME="${GITHUB_REPOSITORY#*/}"
REPO_URL="https://maven.pkg.github.com/${OWNER_LC}/${REPO_NAME}"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
DIST_PATH="${WORKSPACE_DIR}/dist"

echo "GROUP_ID=${GROUP_ID:-org.ngengine}" >> "$GITHUB_ENV"
echo "ARTIFACT_ID=angle-natives" >> "$GITHUB_ENV"
echo "DIST_DIR=${DIST_PATH}" >> "$GITHUB_ENV"
echo "GITHUB_MAVEN_URL=${REPO_URL}" >> "$GITHUB_ENV"

if [[ "${FORCE_DISABLE_SONATYPE:-false}" == "true" ]]; then
  echo "ENABLE_SONATYPE_PUBLISH=false" >> "$GITHUB_ENV"
  echo "Sonatype publishing is disabled for this run."
  exit 0
fi

if [[ -n "${SONATYPE_USERNAME:-}" && -n "${SONATYPE_PASSWORD:-}" && -n "${GPG_PRIVATE_KEY:-}" && -n "${GPG_PASSPHRASE:-}" ]]; then
  echo "ENABLE_SONATYPE_PUBLISH=true" >> "$GITHUB_ENV"
  echo "Sonatype publishing is enabled."
else
  echo "ENABLE_SONATYPE_PUBLISH=false" >> "$GITHUB_ENV"
  echo "Sonatype publishing is disabled (missing SONATYPE and/or GPG secrets)."
fi
