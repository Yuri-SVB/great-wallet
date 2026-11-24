# Great Wallet

**Coercion-resistant Bitcoin self-custody.** The Dart and Flutter desktop application that integrates the Great Wall libraries into one product.

This is the parent repository: it pins every library to a compatible
commit and carries the application source. The libraries have no
submodules of their own.

**Status:** In development. Proof of concept — do not put savings behind it.

**Documentation:** [great-wall-docs/great-wallet](https://github.com/Yuri-SVB/great-wall-docs/tree/main/great-wallet)
— design, architecture and threat model live there, not here.

## Build

One step, on Linux, macOS or Windows:

```sh
git clone https://github.com/Yuri-SVB/great-wallet.git
cd great-wallet
./build.sh
```

`build.sh` fetches the libraries the app is built from, builds the native parts
(the engine and Namtso) and then the app, with this commit embedded for the
supply-chain card. It ends by printing where the app is and how to start it. Run
it again after a `git pull`: it fetches and rebuilds only what changed.

If a tool is missing, it says which, prints the command that installs it, and
stops. What it needs:

| Platform | Needs |
|---|---|
| All | Git, [Flutter](https://docs.flutter.dev/get-started/install), [Rust](https://rustup.rs) |
| Linux | a C compiler, Clang, CMake, Ninja, pkg-config, and the GTK 3 and GStreamer headers (commands below) |
| macOS | Xcode, then `sudo xcodebuild -runFirstLaunch`; CocoaPods (`brew install cocoapods`) |
| Windows | Visual Studio 2022 with *Desktop development with C++*; Git for Windows. Run `./build.sh` from Git Bash. |

On Linux:

```sh
# Debian, Ubuntu
sudo apt-get install build-essential clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good
# Fedora
sudo dnf install gcc gcc-c++ clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel gstreamer1-devel gstreamer1-plugins-base-devel gstreamer1-plugins-good
# Arch
sudo pacman -S --needed base-devel clang cmake ninja pkgconf gtk3 xz gstreamer gst-plugins-base gst-plugins-good
```

**Tested on Linux (Ubuntu) only.** The macOS and Windows paths, and the Fedora
and Arch commands, are untested; `flutter doctor` reports what Flutter itself
still lacks. Known gaps on macOS: Flutter's generated app is sandboxed, which may
block Namtso's network access and opening a setup file by its path, and the QR
scanner needs a camera usage description the generated app lacks.

A working tree with changes builds without the commit embedded; the
supply-chain card then scores only Again.

## Clone

This repository carries every library as a flat submodule, and one of them is
`great-wall-docs` — the documentation for the whole ecosystem, including this
application. A clone without submodules gets the application source and no
documentation at all, which is why this README carries clone instructions and
the library READMEs do not.

```sh
git clone --recursive git@github.com:Yuri-SVB/Great-Wallet.git

# or, after a flat clone:
git submodule update --init
```

The submodule URLs are SSH. Without an SSH key on GitHub, fetch them over https:

```sh
git -c url.https://github.com/.insteadOf=git@github.com: \
    -c url.https://github.com/.insteadOf=git@github.com-yuri-svb: \
    submodule update --init
```

`--init` without `--recursive` is deliberate. The libraries are flat and hold
no submodules of their own, so recursion buys nothing here and would re-fetch
`great-wall-docs` under any library that still vendors a copy.

Once cloned, start at
[`great-wall-docs/great-wallet/ARCHITECTURE.md`](great-wall-docs/great-wallet/ARCHITECTURE.md)
— it describes every component and the dependency graph. The threat model sits
beside it, and each library's design lives in its own directory there.

**⚡ Support:** [github.com/Yuri-SVB/SUPPORT](https://github.com/Yuri-SVB/SUPPORT) — free software, nothing gated.

## License

MIT or Apache-2.0, at your option.
