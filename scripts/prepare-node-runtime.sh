#!/bin/bash
# Obtain the official portable runtime rather than relying on Homebrew libraries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=24.14.1
case "$(uname -m)" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;;
esac
CACHE="${LINKDESK_NODE_CACHE:-$ROOT/.build/node-runtime}"
NAME="node-v$VERSION-darwin-$ARCH"
mkdir -p "$CACHE"
if [[ ! -x "$CACHE/$NAME/bin/node" || ! -f "$CACHE/$NAME/LICENSE" ]]; then
  STAGE="$(mktemp -d "$CACHE/download-XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  curl --fail --location --silent --show-error "https://nodejs.org/dist/v$VERSION/SHASUMS256.txt" -o "$STAGE/SHASUMS256.txt"
  curl --fail --location --silent --show-error "https://nodejs.org/dist/v$VERSION/$NAME.tar.gz" -o "$STAGE/$NAME.tar.gz"
  (cd "$STAGE" && awk -v name="$NAME.tar.gz" '$2 == name { print }' SHASUMS256.txt > checksum && [[ -s checksum ]] && shasum -a 256 -c checksum >&2)
  tar -xzf "$STAGE/$NAME.tar.gz" -C "$STAGE"
  mv "$STAGE/$NAME" "$CACHE/$NAME"
fi
printf '%s\n' "$CACHE/$NAME/bin/node"
