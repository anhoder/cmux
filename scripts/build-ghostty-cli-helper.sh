#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-ghostty-cli-helper.sh [--universal] --output <path>

Options:
  --universal      Build a universal macOS helper (arm64 + x86_64).
  --output <path>  Destination path for the built helper.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"

OUTPUT_PATH=""
UNIVERSAL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      UNIVERSAL="true"
      shift
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  echo "Missing required --output path" >&2
  usage >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is required to build the Ghostty CLI helper" >&2
  exit 1
fi

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "error: Ghostty submodule is missing at $GHOSTTY_DIR" >&2
  exit 1
fi

build_helper() {
  local prefix="$1"
  local target="${2:-}"
  local args=(
    zig build
    cli-helper
    -Dapp-runtime=none
    -Demit-macos-app=false
    -Demit-xcframework=false
    -Doptimize=ReleaseFast
    --prefix
    "$prefix"
  )

  if [[ -n "$target" ]]; then
    args+=("-Dtarget=$target")
  fi

  (
    cd "$GHOSTTY_DIR"
    "${args[@]}"
  )
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ "$UNIVERSAL" == "true" ]]; then
  ARM64_PREFIX="$TMP_DIR/arm64"
  X86_PREFIX="$TMP_DIR/x86_64"
  build_helper "$ARM64_PREFIX" "aarch64-macos"
  build_helper "$X86_PREFIX" "x86_64-macos"
  /usr/bin/lipo -create \
    "$ARM64_PREFIX/bin/ghostty" \
    "$X86_PREFIX/bin/ghostty" \
    -output "$OUTPUT_PATH"
else
  HOST_PREFIX="$TMP_DIR/host"
  build_helper "$HOST_PREFIX"
  install -m 755 "$HOST_PREFIX/bin/ghostty" "$OUTPUT_PATH"
fi

chmod +x "$OUTPUT_PATH"
