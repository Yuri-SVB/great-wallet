/// Great Wallet — app-level orchestration.
///
/// Public surface of the integration layer that wires great-wall-ux to
/// great-wall-core. See great-wall-docs/great-wallet/ARCHITECTURE.md.
library;

export 'src/app/mode_shell.dart';
export 'src/core/core_escape_count_source.dart';
export 'src/core/encoding_constants.dart';
export 'src/core/entropy.dart';
export 'src/core/great_wall_core.dart';
export 'src/core/orbit_protocol.dart';
export 'src/core/stage_params.dart';
export 'src/ffi/core_bindings.dart' show Argon2Profile, FixedRect, CoreDiscoveryParams, CoreDecodeResult;
export 'src/ffi/fixed.dart';
export 'src/ffi/library_loader.dart' show CoreLibraryLoader, CoreLibraryNotFound;
export 'src/setup/orbit_review.dart';
export 'src/setup/orbit_score_store.dart';
export 'src/setup/setup_screen.dart';
