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
platform="${1:-linux}"
shift || true

# The platform runner is generated, not committed (see .gitignore). --empty
# leaves out the template's counter test, and .metadata keeps its committed
# Flutter revision, so creating the runner leaves the tree as it was.
runner="$platform"
case "$platform" in
  apk | appbundle) runner=android ;;
  ipa) runner=ios ;;
esac
if [ ! -d "$runner" ]; then
  flutter create --empty --platforms="$runner" --org org.greatwall \
    --project-name great_wallet .
  git checkout -- .metadata
fi

commit="$(git -C "$root" rev-parse HEAD)"
if [ -n "$(git -C "$root" status --porcelain --ignore-submodules=none)" ]; then
  echo "The working tree has changes: this build is not commit $commit." >&2
  echo "Building without a digest; the supply-chain card will score only Again." >&2
  commit=""
fi
flutter build "$platform" --release --dart-define=GW_COMMIT="$commit" "$@"
