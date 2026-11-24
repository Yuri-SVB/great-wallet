import 'dart:ffi';
import 'dart:io';

/// Locates and opens the great-wall-core shared library (`burning_ship_engine`).
///
/// The Rust engine is built as a `cdylib` (great-wall-core/burning_ship/
/// rust_engine/Cargo.toml). great-wallet pins great-wall-core as a flat
/// submodule, so the canonical build output sits at:
///
///   great-wall-core/burning_ship/rust_engine/target/release/
///       lib<name>.{so,dylib}  |  <name>.dll
///
/// `native/build_core.sh` builds it there. Packaged builds bundle the library
/// next to the executable instead; both locations are probed.
class CoreLibraryLoader {
  const CoreLibraryLoader();

  static const String _baseName = 'burning_ship_engine';

  /// Platform-specific shared-library file name.
  static String get fileName {
    if (Platform.isWindows) return '$_baseName.dll';
    if (Platform.isMacOS) return 'lib$_baseName.dylib';
    return 'lib$_baseName.so'; // Linux and other ELF targets.
  }

  /// Open the engine library, trying each candidate path in order.
  ///
  /// Throws a [CoreLibraryNotFound] with the probed paths if none resolve, so
  /// the failure is actionable ("run native/build_core.sh") rather than an
  /// opaque `Invalid argument` from `dlopen`.
  DynamicLibrary open({List<String>? searchPaths}) {
    final List<String> candidates = searchPaths ?? defaultSearchPaths();
    final List<String> tried = <String>[];
    for (final String path in candidates) {
      tried.add(path);
      if (File(path).existsSync()) {
        return DynamicLibrary.open(path);
      }
    }
    // Last resort: let the dynamic linker search its own paths (LD_LIBRARY_PATH,
    // rpath, the executable's directory on Windows/macOS bundles).
    try {
      return DynamicLibrary.open(fileName);
    } on ArgumentError {
      throw CoreLibraryNotFound(fileName, tried);
    }
  }

  /// Default probe order: alongside the executable first (packaged builds),
  /// then the submodule's cargo output (development builds).
  List<String> defaultSearchPaths() {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String sep = Platform.pathSeparator;
    String join(List<String> parts) => parts.join(sep);
    return <String>[
      join(<String>[exeDir, fileName]),
      join(<String>[exeDir, 'lib', fileName]),
      // app/ is a sibling of the great-wall-core submodule inside great-wallet.
      join(<String>[
        '..',
        'great-wall-core',
        'burning_ship',
        'rust_engine',
        'target',
        'release',
        fileName,
      ]),
    ];
  }
}

/// Raised when the engine shared library cannot be located.
class CoreLibraryNotFound implements Exception {
  CoreLibraryNotFound(this.fileName, this.triedPaths);

  final String fileName;
  final List<String> triedPaths;

  @override
  String toString() =>
      'CoreLibraryNotFound: could not find $fileName. Build the app with '
      './build.sh at the repository\'s root, or the engine alone with '
      'app/native/build_core.sh. Tried:\n'
      '${triedPaths.map((String p) => '  - $p').join('\n')}';
}
