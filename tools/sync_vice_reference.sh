#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/VICE-Team/svn-mirror.git"
DEST="${1:-external/vice-svn-mirror}"

mkdir -p "$(dirname "$DEST")"

if [[ ! -d "$DEST/.git" ]]; then
  echo "Cloning VICE mirror into $DEST"
  git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$DEST"
else
  echo "Updating existing checkout in $DEST"
  git -C "$DEST" fetch --depth 1 origin
  git -C "$DEST" reset --hard origin/master
fi

git -C "$DEST" sparse-checkout set \
  vice/src/c64 \
  vice/src/scpu64 \
  vice/src/core \
  vice/doc

echo
printf 'VICE reference checkout ready at %s\n' "$DEST"
printf 'Suggested starting points:\n'
printf '  %s\n' \
  "vice/src/c64/c64.c" \
  "vice/src/scpu64/scpu64.c" \
  "vice/src/c64/c64cia1.c" \
  "vice/src/c64/c64cia2.c" \
  "vice/src/c64/c64meminit.c" \
  "vice/src/scpu64/scpu64meminit.c" \
  "vice/src/core/ciacore.c" \
  "vice/doc/CIA-README.txt"
