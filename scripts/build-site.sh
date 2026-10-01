#!/usr/bin/env bash
# Wrap site/whisperbox.html (body-level source, also published as a preview) into a
# standalone site/index.html for GitHub Pages. Re-run after editing the source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
  printf '</head>\n<body>\n'
  cat "$ROOT/site/whisperbox.html"
  printf '\n</body>\n</html>\n'
} > "$ROOT/site/index.html"
echo "wrote site/index.html"
