#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-${VERSION:-}}"
INPUT_DIR="${PACKAGE_INPUT_DIR:-angle-artifacts}"
OUTPUT_DIR="${PACKAGE_OUTPUT_DIR:-dist}"
ARTIFACT_ID="${ARTIFACT_ID:-angle-natives}"
EXPECTED_CLASSIFIERS="${PACKAGE_EXPECTED_CLASSIFIERS:-}"

require_jar_entry() {
  local jar_file="$1"
  local entry_pattern="$2"
  local description="$3"

  jar tf "$jar_file" | grep -Eq "$entry_pattern" || {
    echo "Missing $description in $jar_file" >&2
    exit 1
  }
}

if [[ -z "$VERSION" ]]; then
  echo "Usage: VERSION=<version> $0 [version]" >&2
  exit 1
fi

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Input directory not found: $INPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/${ARTIFACT_ID}-${VERSION}.jar"
rm -f "$OUTPUT_DIR/${ARTIFACT_ID}-${VERSION}-"*.jar

BUNDLE_DIR="$(mktemp -d)"
trap 'rm -rf "$BUNDLE_DIR"' EXIT

found_artifacts=0
packaged_artifacts=0
seen_classifiers=
shopt -s nullglob
for artifact_dir in "$INPUT_DIR"/*; do
  [[ -d "$artifact_dir" ]] || continue
  found_artifacts=1

  classifier="$(basename "$artifact_dir")"
  jar_file="$OUTPUT_DIR/${ARTIFACT_ID}-${VERSION}-${classifier}.jar"
  packaged_artifacts=1
  seen_classifiers="$seen_classifiers $classifier"
  rsync -a "$artifact_dir/" "$BUNDLE_DIR/"
  jar cf "$jar_file" -C "$artifact_dir" .

  case "$classifier" in
    natives-linux|natives-linux-arm64)
      require_jar_entry "$jar_file" '^native/angle/linux/[^/]+/libEGL\.so$' 'libEGL.so'
      require_jar_entry "$jar_file" '^native/angle/linux/[^/]+/libGLESv2\.so$' 'libGLESv2.so'
      ;;
    natives-macos|natives-macos-arm64)
      require_jar_entry "$jar_file" '^native/angle/osx/[^/]+/libEGL\.dylib$' 'libEGL.dylib'
      require_jar_entry "$jar_file" '^native/angle/osx/[^/]+/libGLESv2\.dylib$' 'libGLESv2.dylib'
      ;;
    natives-windows|natives-windows-arm64)
      require_jar_entry "$jar_file" '^native/angle/windows/[^/]+/libEGL\.dll$' 'libEGL.dll'
      require_jar_entry "$jar_file" '^native/angle/windows/[^/]+/libGLESv2\.dll$' 'libGLESv2.dll'
      ;;
  esac
done
shopt -u nullglob

if [[ "$found_artifacts" -eq 0 || "$packaged_artifacts" -eq 0 ]]; then
  echo "No desktop/native staged artifacts found in $INPUT_DIR" >&2
  exit 1
fi

if [[ -n "$EXPECTED_CLASSIFIERS" ]]; then
  missing_classifiers=0
  for expected_classifier in $EXPECTED_CLASSIFIERS; do
    case " $seen_classifiers " in
      *" $expected_classifier "*) ;;
      *)
        echo "Missing staged classifier: $expected_classifier" >&2
        missing_classifiers=1
        ;;
    esac
  done

  if [[ "$missing_classifiers" -ne 0 ]]; then
    exit 1
  fi
fi

jar cf "$OUTPUT_DIR/${ARTIFACT_ID}-${VERSION}.jar" -C "$BUNDLE_DIR" .
