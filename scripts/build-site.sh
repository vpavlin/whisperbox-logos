#!/usr/bin/env bash
# Wrap site/whisperbox.html (body-level source, also published as a preview) into a
# standalone site/index.html for GitHub Pages. Re-run after editing the source.
# Everything up to and including the first </style> line (title, meta, links, styles)
# goes into <head>; the rest goes into <body>. Assets live in site/assets/ and are
# referenced with relative paths, so the site works at github.io/<repo>/ and at a
# domain root. To publish: copy site/index.html and site/assets/ to the gh-pages branch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/site/whisperbox.html"
grep -q '^</style>' "$SRC" || { echo "no </style> line in $SRC" >&2; exit 1; }
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
  awk '{ print } /^<\/style>/ { exit }' "$SRC"
  printf '</head>\n<body>\n'
  awk 'body { print } /^<\/style>/ { body = 1 }' "$SRC"
  printf '\n</body>\n</html>\n'
} > "$ROOT/site/index.html"
echo "wrote site/index.html"
