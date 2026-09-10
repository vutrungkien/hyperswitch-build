#!/usr/bin/env bash
# scripts/apply.sh <upstream-checkout-dir> - apply every patches/*.patch (in order) to a clean checkout of the Hyperswitch tag in VERSION.
# Fails loudly on the first patch that does not apply (upgrade time: rebase the patch, bump VERSION/PATCHLEVEL).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?usage: apply.sh <upstream-checkout-dir>}"
cd "$TARGET"
if [ -f "$HERE/VERSION" ]; then
  want=$(tr -d ' \r\n' < "$HERE/VERSION")
  have=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)
  echo "upstream checkout: $have (VERSION wants $want)"
fi
shopt -s nullglob
patches=("$HERE"/patches/*.patch)
[ ${#patches[@]} -gt 0 ] || { echo "no patches"; exit 1; }
for p in "${patches[@]}"; do
  git apply --check "$p"
  git apply "$p"
  echo "applied $(basename "$p")"
done
git diff --stat
