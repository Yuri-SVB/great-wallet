#!/usr/bin/env bash
# Build Great Wallet for this computer, in one step: ./build.sh
#
# Linux, macOS, or Windows (from Git Bash). Safe to run again: each run
#   1. checks the tools it needs, and prints how to install any that are missing;
#   2. fetches the libraries the app is built from, at the commits this one pins;
#   3. builds the native parts (the engine and Namtso);
#   4. builds the app with this commit embedded, for the supply-chain card;
#   5. copies the native parts into the app, so it runs from any directory.
#
# A working tree with changes is not this commit: it builds without the commit
# embedded, and the supply-chain card then scores only Again.
#
# Usage: ./build.sh [more `flutter build` arguments]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

case "$(uname -s)" in
  Linux*) os=linux ;;
  Darwin*) os=macos ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) echo "This script builds on Linux, macOS or Windows (Git Bash), not $(uname -s)." >&2; exit 1 ;;
esac

# The libraries the app is built from. Star Clock joins when the app uses it.
submodules=(great-wall-core great-wall-ux dragon-dice celestial-peace-nf-core formosa
  namtso-the-sacred-salt)
engine="great-wall-core/burning_ship/rust_engine/target/release"
namtso="namtso-the-sacred-salt/target/release"

# --- 1. tools ----------------------------------------------------------------

linux_packages() {
  local id=""
  [ -r /etc/os-release ] && id="$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}")"
  local apt="sudo apt-get install build-essential clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good"
  local dnf="sudo dnf install gcc gcc-c++ clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel gstreamer1-devel gstreamer1-plugins-base-devel gstreamer1-plugins-good"
  local pacman="sudo pacman -S --needed base-devel clang cmake ninja pkgconf gtk3 xz gstreamer gst-plugins-base gst-plugins-good"
  case " $id " in
    *" debian "* | *" ubuntu "*) echo "  $apt" ;;
    *" fedora "* | *" rhel "*) echo "  $dnf" ;;
    *" arch "*) echo "  $pacman" ;;
    *) printf '  Debian, Ubuntu: %s\n  Fedora: %s\n  Arch: %s\n' "$apt" "$dnf" "$pacman" ;;
  esac
}

missing=()
need() { command -v "$1" >/dev/null 2>&1 || missing+=("$1"); }
need git
need flutter
need cargo
case "$os" in
  linux)
    for tool in cc clang++ cmake ninja pkg-config; do need "$tool"; done
    if command -v pkg-config >/dev/null 2>&1; then
      for lib in gtk+-3.0 gstreamer-1.0 gstreamer-app-1.0 gstreamer-audio-1.0; do
        pkg-config --exists "$lib" || missing+=("$lib")
      done
      # Needed only to run: without them the app aborts as it starts.
      plugins="$(pkg-config --variable=pluginsdir gstreamer-1.0 2>/dev/null || true)"
      for plugin in playback autodetect wavparse; do
        [ -e "$plugins/libgst$plugin.so" ] || missing+=("gstreamer-plugin-$plugin")
      done
    fi
    ;;
  macos) need xcodebuild; need pod ;;
esac
if [ "${#missing[@]}" -gt 0 ]; then
  {
    echo "Missing: ${missing[*]}"
    echo
    echo "Install what is missing, then run ./build.sh again:"
    case " ${missing[*]} " in *" flutter "*)
      echo "  Flutter: https://docs.flutter.dev/get-started/install" ;; esac
    case " ${missing[*]} " in *" cargo "*)
      echo "  Rust: https://rustup.rs" ;; esac
    case "$os" in
      linux) linux_packages ;;
      macos)
        echo "  Xcode, from the App Store, then: sudo xcodebuild -runFirstLaunch"
        echo "  CocoaPods: brew install cocoapods" ;;
    esac
  } >&2
  exit 1
fi

# --- 2. libraries -------------------------------------------------------------

if [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$root" ]; then
  echo "This folder is not a git clone. Clone it instead of downloading it:" >&2
  echo "  git clone https://github.com/Yuri-SVB/great-wallet.git" >&2
  exit 1
fi
# .gitmodules names SSH hosts; anyone can fetch the libraries over https.
over_https=(-c url.https://github.com/.insteadOf=git@github.com:
  -c url.https://github.com/.insteadOf=git@github.com-yuri-svb:)
for s in "${submodules[@]}"; do
  pinned="$(git rev-parse "HEAD:$s")"
  if [ ! -e "$s/.git" ]; then
    git "${over_https[@]}" submodule update --init -- "$s"
  elif [ "$(git -C "$s" rev-parse HEAD)" != "$pinned" ]; then
    # Moved only when nobody is working in it: no branch checked out, no changes.
    if ! git -C "$s" symbolic-ref -q HEAD >/dev/null &&
       [ -z "$(git -C "$s" status --porcelain)" ]; then
      echo "$s: moving to the pinned commit ${pinned:0:12}"
      git "${over_https[@]}" submodule update -- "$s"
    else
      echo "$s: left as it is (a branch or changes in it), not at the pinned commit" >&2
    fi
  fi
done

# --- 3. native parts ----------------------------------------------------------

app/native/build_core.sh
app/native/build_namtso.sh

# --- 4. the app ----------------------------------------------------------------

cd app
# The platform runner is generated, not committed (see app/.gitignore). --empty
# leaves out the template's counter test, and .metadata keeps its committed
# Flutter revision, so creating the runner leaves the tree as it was.
if [ ! -d "$os" ]; then
  flutter create --empty --platforms="$os" --org org.greatwall --project-name great_wallet .
  git checkout -- .metadata
fi

commit="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain --ignore-submodules=none)" ]; then
  echo "The working tree has changes: this build is not commit $commit." >&2
  echo "Building without a digest; the supply-chain card will score only Again." >&2
  commit=""
fi
flutter build "$os" --release --dart-define=GW_COMMIT="$commit" "$@"

# --- 5. native parts into the app ----------------------------------------------

cd "$root"
case "$os" in
  linux)
    bundle="$(ls -d app/build/linux/*/release/bundle | head -n 1)"
    cp "$engine/libburning_ship_engine.so" "$bundle/lib/"
    cp "$namtso/namtso" "$bundle/"
    run="$root/$bundle/great_wallet"
    ;;
  macos)
    bundle="app/build/macos/Build/Products/Release/great_wallet.app"
    cp "$engine/libburning_ship_engine.dylib" "$namtso/namtso" "$bundle/Contents/MacOS/"
    # Code added to a signed app must be signed, and the app sealed again.
    codesign --force --sign - "$bundle/Contents/MacOS/libburning_ship_engine.dylib" \
      "$bundle/Contents/MacOS/namtso"
    codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$bundle"
    run="open $root/$bundle"
    ;;
  windows)
    bundle="$(ls -d app/build/windows/*/runner/Release | head -n 1)"
    cp "$engine/burning_ship_engine.dll" "$namtso/namtso.exe" "$bundle/"
    run="$root/$bundle/great_wallet.exe"
    ;;
esac

echo
echo "Built: $root/$bundle"
echo "Run:   $run"
