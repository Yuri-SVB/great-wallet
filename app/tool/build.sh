#!/usr/bin/env bash
# Build the app with the great-wallet commit it is built from embedded
# (GW_COMMIT), so the supply-chain card can check the digest you paste after
# cloning and building a release anew. A working tree with changes is not that
# commit: it builds without a digest, and the card then scores only Again.
#
# Usage: app/tool/build.sh [platform] [more `flutter build` arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(git rev-parse --show-toplevel)"
commit="$(git -C "$root" rev-parse HEAD)"
if [ -n "$(git -C "$root" status --porcelain --ignore-submodules=none)" ]; then
  echo "The working tree has changes: this build is not commit $commit." >&2
  echo "Building without a digest; the supply-chain card will score only Again." >&2
  commit=""
fi
platform="${1:-linux}"
shift || true
flutter build "$platform" --release --dart-define=GW_COMMIT="$commit" "$@"
