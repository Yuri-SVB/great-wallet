import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'fixed.dart';
import 'library_loader.dart';

/// Length in bytes of an orbit point `o_i` (and of `theta`, `K_i`) — a SHA-256
/// digest. Mirrors `ORBIT_POINT_LEN` in the engine (orbit.rs) and
/// `ORBIT_POINT_BYTES` in the Python bridge (burning_ship_engine.py).
/// Width of an orbit point / digest, in bytes (protocol 0.5.0: SHA-512).
const int kOrbitPointLen = 64;

/// Digest width of the deprecated 0.3.0 chain, in bytes (SHA-256 / Argon2-256).
/// Deliberately separate from [kOrbitPointLen]: widening the orbit must not move
/// the chain, which still derives its stage reservoirs from a 32-byte digest.
const int kChainDigestLen = 32;

/// Raw `dart:ffi` binding to great-wall-core's C ABI
/// (great-wall-core/burning_ship/rust_engine/src/ffi.rs).
///
/// This is the *only* place in great-wallet that talks to the engine's
/// `extern "C"` symbols. It is a faithful Dart port of the Python ctypes
/// bridge (great-wall-core/burning_ship/burning_ship_engine.py): same
/// argument order, same raw-`i64` fixed-point convention, same buffer
/// ownership rules.
///
/// Per great-wall-docs/great-wall-ux/TECH_STACK.md §"FFI: hybrid", the
/// per-frame pixel-buffer path (`renderViewport*`) uses raw `dart:ffi` to
/// avoid bridge overhead and copies; the control plane (encode/decode/argon2)
/// rides the same binding for simplicity.
///
/// SECURITY: nothing here logs coordinates, escape counts, decoded bits, or
/// `(o, p, q)`. Those are coercion-relevant (SCOPE.md invariants) and stay in
/// ephemeral buffers that callers are expected to zero and free.
class GreatWallCoreBindings {
  GreatWallCoreBindings._(this._lib) {
    _renderViewport = _lib.lookupFunction<_RenderViewportC, _RenderViewportDart>(
      'bs_render_viewport',
    );
    _renderViewportGeneric =
        _lib.lookupFunction<_RenderViewportGenericC, _RenderViewportGenericDart>(
      'bs_render_viewport_generic',
    );
    _renderViewportGenericU32 = _lib.lookupFunction<_RenderViewportGenericU32C,
        _RenderViewportGenericU32Dart>(
      'bs_render_viewport_generic_u32',
    );
    _encode = _lib.lookupFunction<_EncodeC, _EncodeDart>('bs_encode');
    _encodeResultPoint =
        _lib.lookupFunction<_EncodeResultPointC, _EncodeResultPointDart>(
      'bs_encode_result_point',
    );
    _encodeResultFinalRect =
        _lib.lookupFunction<_EncodeResultFinalRectC, _EncodeResultFinalRectDart>(
      'bs_encode_result_final_rect',
    );
    _encodeResultFree =
        _lib.lookupFunction<_EncodeResultFreeC, _EncodeResultFreeDart>(
      'bs_encode_result_free',
    );
    _decodeFull =
        _lib.lookupFunction<_DecodeFullC, _DecodeFullDart>('bs_decode_full');
    _leafAreasCompute =
        _lib.lookupFunction<_LeafAreasComputeC, _LeafAreasComputeDart>(
      'bs_leaf_areas_compute',
    );
    _leafAreasStatus =
        _lib.lookupFunction<_LeafAreasStatusC, _LeafAreasStatusDart>(
      'bs_leaf_areas_status',
    );
    _leafAreasCount =
        _lib.lookupFunction<_LeafAreasCountC, _LeafAreasCountDart>(
      'bs_leaf_areas_count',
    );
    _leafAreasRect =
        _lib.lookupFunction<_LeafAreasRectC, _LeafAreasRectDart>(
      'bs_leaf_areas_rect',
    );
    _leafAreasPath =
        _lib.lookupFunction<_LeafAreasPathC, _LeafAreasPathDart>(
      'bs_leaf_areas_path',
    );
    _leafAreasFree =
        _lib.lookupFunction<_LeafAreasFreeC, _LeafAreasFreeDart>(
      'bs_leaf_areas_free',
    );
    _canonicalIslandCompute =
        _lib.lookupFunction<_CanonicalIslandComputeC, _CanonicalIslandComputeDart>(
      'bs_canonical_island_compute',
    );
    _canonicalIslandFound =
        _lib.lookupFunction<_CanonicalIslandFoundC, _CanonicalIslandFoundDart>(
      'bs_canonical_island_found',
    );
    _canonicalIslandMeta =
        _lib.lookupFunction<_CanonicalIslandMetaC, _CanonicalIslandMetaDart>(
      'bs_canonical_island_meta',
    );
    _canonicalIslandNumPoints = _lib.lookupFunction<_CanonicalIslandNumPointsC,
        _CanonicalIslandNumPointsDart>('bs_canonical_island_num_points');
    _canonicalIslandPoints =
        _lib.lookupFunction<_CanonicalIslandPointsC, _CanonicalIslandPointsDart>(
      'bs_canonical_island_points',
    );
    _canonicalIslandFree =
        _lib.lookupFunction<_CanonicalIslandFreeC, _CanonicalIslandFreeDart>(
      'bs_canonical_island_free',
    );
    _orbitArgon2Single = _lib.lookupFunction<_Argon2SingleC, _Argon2SingleDart>(
        'bs_orbit_argon2_single');
    _argon2Single =
        _lib.lookupFunction<_Argon2SingleC, _Argon2SingleDart>('bs_argon2_single');
    _argon2idMaster =
        _lib.lookupFunction<_Argon2idMasterC, _Argon2idMasterDart>(
      'bs_argon2id_master',
    );
    _saltPepperCanonicalize =
        _lib.lookupFunction<_SaltPepperCanonicalizeC, _SaltPepperCanonicalizeDart>(
            'bs_salt_pepper_canonicalize');
    _chainInput =
        _lib.lookupFunction<_ChainInputC, _ChainInputDart>('bs_chain_input');
    _orbitRoot =
        _lib.lookupFunction<_OrbitRootC, _OrbitRootDart>('bs_orbit_root');
    _theta = _lib.lookupFunction<_ThetaC, _ThetaDart>('bs_theta');
    _masterSecret =
        _lib.lookupFunction<_MasterSecretC, _MasterSecretDart>('bs_master_secret');
    _orbitCommitment = _lib
        .lookupFunction<_MasterSecretC, _MasterSecretDart>('bs_orbit_commitment');
    _exportKey =
        _lib.lookupFunction<_MasterSecretC, _MasterSecretDart>('bs_export_key');
    _orbitAdvance =
        _lib.lookupFunction<_OrbitAdvanceC, _OrbitAdvanceDart>('bs_orbit_advance');
    _shamirInterp =
        _lib.lookupFunction<_ShamirInterpC, _ShamirInterpDart>('bs_shamir_interp');
    _shamirEval =
        _lib.lookupFunction<_ShamirEvalC, _ShamirEvalDart>('bs_shamir_eval');
    _shamirGenShares =
        _lib.lookupFunction<_ShamirGenSharesC, _ShamirGenSharesDart>(
      'bs_shamir_generate_resistance_shares',
    );
    _setupTierThresholds =
        _lib.lookupFunction<_SetupTierThresholdsC, _SetupTierThresholdsDart>(
      'bs_setup_tier_thresholds',
    );
    _setupTierSubstandard =
        _lib.lookupFunction<_SetupTierSubstandardC, _SetupTierSubstandardDart>(
      'bs_setup_tier_substandard',
    );
    _encodeParams =
        _lib.lookupFunction<_EncodeParamsC, _EncodeParamsDart>('bs_encode_params');
    _encodeArea =
        _lib.lookupFunction<_EncodeAreaC, _EncodeAreaDart>('bs_encode_area');
    _bitsPerPoint = _lib
        .lookupFunction<_BitsPerPointC, _BitsPerPointDart>('bs_bits_per_point');
    _getPrecision =
        _lib.lookupFunction<_GetPrecisionC, _GetPrecisionDart>('bs_get_precision');
    _engineVersion =
        _lib.lookupFunction<_EngineVersionC, _EngineVersionDart>(
      'bs_engine_version',
    );
  }

  /// Open the engine library and bind its symbols. Verifies the fixed-point
  /// layout matches [kFracBits] so a future engine ABI drift fails loudly.
  factory GreatWallCoreBindings.open({CoreLibraryLoader loader = const CoreLibraryLoader()}) {
    final GreatWallCoreBindings b = GreatWallCoreBindings._(loader.open());
    final int frac = b.precision().fracBits;
    if (frac != kFracBits) {
      throw StateError(
        'Engine fixed-point layout changed: expected $kFracBits fractional '
        'bits (I4F60), engine reports $frac. Update fixed.dart before '
        'encoding anything — coordinates would otherwise be misscaled.',
      );
    }
    return b;
  }

  final DynamicLibrary _lib;

  late final _RenderViewportDart _renderViewport;
  late final _RenderViewportGenericDart _renderViewportGeneric;
  late final _RenderViewportGenericU32Dart _renderViewportGenericU32;
  late final _EncodeDart _encode;
  late final _EncodeResultPointDart _encodeResultPoint;
  late final _EncodeResultFinalRectDart _encodeResultFinalRect;
  late final _EncodeResultFreeDart _encodeResultFree;
  late final _DecodeFullDart _decodeFull;
  late final _LeafAreasComputeDart _leafAreasCompute;
  late final _LeafAreasStatusDart _leafAreasStatus;
  late final _LeafAreasCountDart _leafAreasCount;
  late final _LeafAreasRectDart _leafAreasRect;
  late final _LeafAreasPathDart _leafAreasPath;
  late final _LeafAreasFreeDart _leafAreasFree;
  late final _CanonicalIslandComputeDart _canonicalIslandCompute;
  late final _CanonicalIslandFoundDart _canonicalIslandFound;
  late final _CanonicalIslandMetaDart _canonicalIslandMeta;
  late final _CanonicalIslandNumPointsDart _canonicalIslandNumPoints;
  late final _CanonicalIslandPointsDart _canonicalIslandPoints;
  late final _CanonicalIslandFreeDart _canonicalIslandFree;
  late final _Argon2SingleDart _argon2Single;
  late final _Argon2SingleDart _orbitArgon2Single;
  late final _Argon2idMasterDart _argon2idMaster;
  late final _SaltPepperCanonicalizeDart _saltPepperCanonicalize;
  late final _ChainInputDart _chainInput;
  late final _OrbitRootDart _orbitRoot;
  late final _ThetaDart _theta;
  late final _MasterSecretDart _masterSecret;
  late final _MasterSecretDart _orbitCommitment;
  late final _MasterSecretDart _exportKey;
  late final _OrbitAdvanceDart _orbitAdvance;
  late final _ShamirInterpDart _shamirInterp;
  late final _ShamirEvalDart _shamirEval;
  late final _ShamirGenSharesDart _shamirGenShares;
  late final _SetupTierThresholdsDart _setupTierThresholds;
  late final _SetupTierSubstandardDart _setupTierSubstandard;
  late final _EncodeParamsDart _encodeParams;
  late final _EncodeAreaDart _encodeArea;
  late final _BitsPerPointDart _bitsPerPoint;
  late final _GetPrecisionDart _getPrecision;
  late final _EngineVersionDart _engineVersion;

  // -------------------------------------------------------------------------
  // Metadata
  // -------------------------------------------------------------------------

  /// `(fracBits, intBits)` of the engine's fixed-point type.
  ({int fracBits, int intBits}) precision() {
    final Pointer<Uint32> frac = calloc<Uint32>();
    final Pointer<Uint32> intb = calloc<Uint32>();
    try {
      _getPrecision(frac, intb);
      return (fracBits: frac.value, intBits: intb.value);
    } finally {
      calloc
        ..free(frac)
        ..free(intb);
    }
  }

  /// The engine algorithm version string (e.g. `"0.1.0"`). A mismatch between
  /// the version the app was tested against and the linked engine is a signal
  /// that encodings may not be reproducible.
  String engineVersion() {
    const int bufLen = 32;
    final Pointer<Uint8> buf = calloc<Uint8>(bufLen);
    try {
      final int len = _engineVersion(buf, bufLen);
      final int n = len < bufLen ? len : bufLen - 1;
      return String.fromCharCodes(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  // -------------------------------------------------------------------------
  // Rendering (per-frame hot path)
  // -------------------------------------------------------------------------

  /// Render the canonical (stage-1) Burning Ship escape-count map into [out].
  ///
  /// `out` must hold `width * height` bytes. The engine writes `0` for
  /// non-escaping pixels and `(escape_count % 255) + 1` otherwise — the same
  /// `u8` encoding the Python bridge documents. Coordinate convention:
  /// pixel `(cx, cy)` samples `(originRe + cx*step, originIm + cy*step)`.
  void renderViewport({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int maxIter,
    required Pointer<Uint8> out,
  }) {
    _renderViewport(originRe, originIm, step, width, height, maxIter, out);
  }

  /// Render the perturbed (stage-2) Burning Ship using the entropy reservoirs
  /// `(o, p, q)` (each a raw `u64`, exactly as the engine and Python bridge
  /// expect — see argon2_pipeline.py / constants.py §"Perturbation encoding").
  void renderViewportGeneric({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int maxIter,
    required int o,
    required int p,
    required int q,
    required Pointer<Uint8> out,
  }) {
    _renderViewportGeneric(
      originRe,
      originIm,
      step,
      width,
      height,
      maxIter,
      o,
      p,
      q,
      out,
    );
  }

  /// Render the perturbed Burning Ship with **exact** escape counts
  /// (`bs_render_viewport_generic_u32`): one `u32` per pixel carrying the true
  /// count, with [maxIter] written for a non-escaping point.
  ///
  /// The `u8` sibling folds counts as `(e % 255) + 1`, which is fine for
  /// colouring but merges level sets 255 apart — and at the encode cap of 1024
  /// that aliases four ways. The canvas needs the unfolded value to flood fill
  /// a canonical island, whose shape is the connected region whose count equals
  /// the island's, so this is the path the renderer uses.
  void renderViewportGenericU32({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int maxIter,
    required int o,
    required int p,
    required int q,
    required Pointer<Uint32> out,
  }) {
    _renderViewportGenericU32(
      originRe,
      originIm,
      step,
      width,
      height,
      maxIter,
      o,
      p,
      q,
      out,
    );
  }

  // -------------------------------------------------------------------------
  // Encode / decode (bijection)
  // -------------------------------------------------------------------------

  /// Encode [bits] (a list of 0/1) into a fractal location under [params] and
  /// the perturbation reservoirs `(o, p, q)`. Returns the encoded point as raw
  /// I4F60 `i64` coordinates, plus the **leaf rectangle** the bisection settled
  /// on (its centre is the master-secret export's per-stage coordinate — see
  /// `MasterSecret.leafCentreRaw`).
  ///
  /// `area` bounds are raw `i64`. The opaque result handle is queried and freed
  /// internally; only the point and leaf rect are returned (the app does not
  /// surface bisection steps — that is debug-mode UX territory).
  ({int reRaw, int imRaw, FixedRect leafRect}) encodePoint({
    required List<int> bits,
    required FixedRect area,
    required CoreDiscoveryParams params,
    required int o,
    required int p,
    required int q,
    String pathPrefix = 'O',
  }) {
    final Pointer<Uint8> bitsPtr = calloc<Uint8>(bits.length);
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(pathPrefix);
    final Pointer<Int64> reOut = calloc<Int64>();
    final Pointer<Int64> imOut = calloc<Int64>();
    // bs_encode_result_final_rect writes four separate Fixed (i64) out-params.
    final Pointer<Int64> reMinOut = calloc<Int64>();
    final Pointer<Int64> reMaxOut = calloc<Int64>();
    final Pointer<Int64> imMinOut = calloc<Int64>();
    final Pointer<Int64> imMaxOut = calloc<Int64>();
    try {
      bitsPtr.asTypedList(bits.length).setAll(0, bits);
      final Pointer<Void> handle = _encode(
        bitsPtr,
        bits.length,
        area.reMin,
        area.reMax,
        area.imMin,
        area.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        o,
        p,
        q,
        ppPtr,
        ppLen,
      );
      if (handle == nullptr) {
        throw StateError('bs_encode returned NULL handle');
      }
      try {
        _encodeResultPoint(handle, reOut, imOut);
        _encodeResultFinalRect(
          handle,
          reMinOut,
          reMaxOut,
          imMinOut,
          imMaxOut,
        );
        return (
          reRaw: reOut.value,
          imRaw: imOut.value,
          leafRect: FixedRect(
            reMin: reMinOut.value,
            reMax: reMaxOut.value,
            imMin: imMinOut.value,
            imMax: imMaxOut.value,
          ),
        );
      } finally {
        _encodeResultFree(handle);
      }
    } finally {
      _zeroAndFree(bitsPtr, bits.length);
      if (ppPtr != nullptr) calloc.free(ppPtr);
      calloc
        ..free(reOut)
        ..free(imOut)
        ..free(reMinOut)
        ..free(reMaxOut)
        ..free(imMinOut)
        ..free(imMaxOut);
    }
  }

  /// Decode a fractal point (raw I4F60 coordinates) back to [numBits] bits,
  /// also returning the leaf rectangle and a validity flag.
  ///
  /// `valid == false` means the point fell in a contracted-away region — i.e.
  /// the user clicked off any encodable leaf. The caller (Setup/Train) uses
  /// this to reject a stray tap without leaking *where* it landed.
  CoreDecodeResult decodeFull({
    required int pointReRaw,
    required int pointImRaw,
    required int numBits,
    required FixedRect area,
    required CoreDiscoveryParams params,
    required int o,
    required int p,
    required int q,
    String pathPrefix = 'O',
  }) {
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(pathPrefix);
    final int pathBufLen = pathPrefix.length + numBits + 2;
    final Pointer<Uint8> outBits = calloc<Uint8>(numBits);
    final Pointer<Int64> outRect = calloc<Int64>(4);
    final Pointer<Uint8> outValid = calloc<Uint8>();
    final Pointer<Uint8> outPath = calloc<Uint8>(pathBufLen);
    final Pointer<Uint32> outPathLen = calloc<Uint32>();
    try {
      _decodeFull(
        pointReRaw,
        pointImRaw,
        numBits,
        area.reMin,
        area.reMax,
        area.imMin,
        area.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        o,
        p,
        q,
        ppPtr,
        ppLen,
        outBits,
        outRect,
        outValid,
        outPath,
        pathBufLen,
        outPathLen,
      );
      final List<int> bits = List<int>.from(outBits.asTypedList(numBits));
      final FixedRect rect = FixedRect(
        reMin: outRect[0],
        reMax: outRect[1],
        imMin: outRect[2],
        imMax: outRect[3],
      );
      // The bisection path — the leaf's canonical identity, needed to resolve
      // its canonical island. (Coercion-relevant, like the bits: never logged.)
      final int plen = outPathLen.value;
      final int take = plen < pathBufLen ? plen : pathBufLen - 1;
      final String path = String.fromCharCodes(outPath.asTypedList(take));
      return CoreDecodeResult(
        bits: bits,
        leafRect: rect,
        valid: outValid.value != 0,
        path: path,
      );
    } finally {
      _zeroAndFree(outBits, numBits);
      if (ppPtr != nullptr) calloc.free(ppPtr);
      calloc
        ..free(outRect)
        ..free(outValid)
        ..free(outPath)
        ..free(outPathLen);
    }
  }

  // -------------------------------------------------------------------------
  // Viewport leaf-area enumeration
  // -------------------------------------------------------------------------

  /// Enumerate the distinct canonical leaf areas present in a view
  /// (`bs_leaf_areas_*`). The view is described as for [renderViewport]: pixel
  /// `(col, row)` samples `(originRe + col*step, originIm + col*step)`; the scan
  /// steps by [scanStep] pixels. `(o, p, q)` must select the same fractal the
  /// points were encoded on (`(0,0,0)` for the canonical stage, the stage's
  /// reservoirs otherwise) — leaf membership is meaningless on any other surface.
  ///
  /// Returns either the (capped) list of leaf areas — each a leaf rectangle in
  /// raw I4F60 bounds plus its bisection path (canonical identity) — or a
  /// "too many" result when more than [maxLeaves] distinct areas are present.
  /// The opaque handle is queried and freed internally.
  CoreLeafAreasResult enumerateLeafAreas({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int scanStep,
    required int maxLeaves,
    required int maxDecodes,
    required FixedRect area,
    required CoreDiscoveryParams params,
    required int numBits,
    required int o,
    required int p,
    required int q,
    String pathPrefix = 'O',
  }) {
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(pathPrefix);
    // A leaf path is the prefix plus one direction letter per bisection level.
    final int pathBufLen = pathPrefix.length + numBits + 2;
    final Pointer<Int64> outRect = calloc<Int64>(4);
    final Pointer<Uint8> outPath = calloc<Uint8>(pathBufLen);
    try {
      final Pointer<Void> handle = _leafAreasCompute(
        originRe,
        originIm,
        step,
        width,
        height,
        scanStep,
        maxLeaves,
        maxDecodes,
        area.reMin,
        area.reMax,
        area.imMin,
        area.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        numBits,
        o,
        p,
        q,
        ppPtr,
        ppLen,
      );
      if (handle == nullptr) {
        throw StateError('bs_leaf_areas_compute returned NULL handle');
      }
      try {
        // status: 0 = list available; 1 = too many leaves; 2 = decode budget
        // hit (zoom-out). Both non-zero outcomes mean "zoom in".
        if (_leafAreasStatus(handle) != 0) {
          return CoreLeafAreasResult.tooMany(maxLeaves);
        }
        final int count = _leafAreasCount(handle);
        final List<CoreLeafArea> leaves = <CoreLeafArea>[];
        for (int i = 0; i < count; i++) {
          _leafAreasRect(handle, i, outRect);
          final FixedRect rect = FixedRect(
            reMin: outRect[0],
            reMax: outRect[1],
            imMin: outRect[2],
            imMax: outRect[3],
          );
          final int len = _leafAreasPath(handle, i, outPath, pathBufLen);
          final int take = len < pathBufLen ? len : pathBufLen - 1;
          final String path = String.fromCharCodes(outPath.asTypedList(take));
          leaves.add(CoreLeafArea(rect: rect, path: path));
        }
        return CoreLeafAreasResult.leaves(leaves);
      } finally {
        _leafAreasFree(handle);
      }
    } finally {
      if (ppPtr != nullptr) calloc.free(ppPtr);
      // The path bytes are directional bits; wipe them before freeing.
      _zeroAndFree(outPath, pathBufLen);
      calloc.free(outRect);
    }
  }

  /// Select a leaf area's canonical island (`bs_canonical_island_*`) and return
  /// its shape: the flood points (raw I4F60, interleaved `[re, im]`) plus the
  /// cell size `pixelDeltaRaw`, bbox, escape count and pixel count. [path] is
  /// the leaf's bisection path; `(o, p, q)` must select the same fractal the
  /// leaf was decoded on. [params] is a visualisation choice (resolution / flood
  /// cap), independent of the encoder's. Returns null if no island is found.
  CoreCanonicalIsland? canonicalIsland({
    required FixedRect leafRect,
    required CoreDiscoveryParams params,
    required int o,
    required int p,
    required int q,
    required String path,
  }) {
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(path);
    final Pointer<Uint32> outEscape = calloc<Uint32>();
    final Pointer<Uint64> outPixelCount = calloc<Uint64>();
    final Pointer<Int64> outPixelDelta = calloc<Int64>();
    final Pointer<Int64> outBbox = calloc<Int64>(4);
    try {
      final Pointer<Void> handle = _canonicalIslandCompute(
        leafRect.reMin,
        leafRect.reMax,
        leafRect.imMin,
        leafRect.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        o,
        p,
        q,
        ppPtr,
        ppLen,
      );
      if (handle == nullptr) {
        throw StateError('bs_canonical_island_compute returned NULL handle');
      }
      try {
        if (_canonicalIslandFound(handle) == 0) return null;
        _canonicalIslandMeta(
          handle, outEscape, outPixelCount, outPixelDelta, outBbox);
        final int n = _canonicalIslandNumPoints(handle);
        // 2 Fixed per point; guard the zero case so calloc gets a valid size.
        final Pointer<Int64> outPts = calloc<Int64>(n == 0 ? 1 : n * 2);
        try {
          final int written = _canonicalIslandPoints(handle, outPts, n);
          final List<int> pointsRaw =
              List<int>.from(outPts.asTypedList(written * 2));
          return CoreCanonicalIsland(
            escapeCount: outEscape.value,
            pixelCount: outPixelCount.value,
            pixelDeltaRaw: outPixelDelta.value,
            bbox: FixedRect(
              reMin: outBbox[0],
              reMax: outBbox[1],
              imMin: outBbox[2],
              imMax: outBbox[3],
            ),
            pointsRaw: pointsRaw,
          );
        } finally {
          calloc.free(outPts);
        }
      } finally {
        _canonicalIslandFree(handle);
      }
    } finally {
      if (ppPtr != nullptr) calloc.free(ppPtr);
      calloc
        ..free(outEscape)
        ..free(outPixelCount)
        ..free(outPixelDelta)
        ..free(outBbox);
    }
  }

  // -------------------------------------------------------------------------
  // Argon2 (stage-1 bits -> 256-bit digest)
  // -------------------------------------------------------------------------

  /// Run a single Argon2d pass on [input] under [profile]. Returns the
  /// [kChainDigestLen]-byte digest. Iteration (feeding the digest back in for
  /// `gui_iterations` cycles) is driven from Dart so progress can be reported
  /// and the run cancelled between passes — matching `run_argon2_iterative` in
  /// argon2_pipeline.py.
  ///
  /// **Legacy 0.3.0 chain width.** The orbit's `H*` is [orbitArgon2Single], at
  /// [kOrbitPointLen]. The two are not prefixes of one another: Argon2's output
  /// length feeds its final hash, so the same input at 32 and 64 bytes differs
  /// throughout.
  Uint8List argon2Single(Uint8List input, Argon2Profile profile) {
    final Pointer<Uint8> inPtr = calloc<Uint8>(input.length);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kChainDigestLen);
    try {
      inPtr.asTypedList(input.length).setAll(0, input);
      _argon2Single(inPtr, input.length, profile.value, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kChainDigestLen));
    } finally {
      _zeroAndFree(inPtr, input.length);
      _zeroAndFree(outPtr, kChainDigestLen);
    }
  }

  /// `H*` for the orbit — one Argon2d pass returning [kOrbitPointLen] bytes
  /// (`bs_orbit_argon2_single`). The memory-hard step of the 0.5.0 advance,
  /// driven in a loop from Dart so each pass can be reported and checkpointed.
  Uint8List orbitArgon2Single(Uint8List input, Argon2Profile profile) {
    final Pointer<Uint8> inPtr = calloc<Uint8>(input.length);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kOrbitPointLen);
    try {
      inPtr.asTypedList(input.length).setAll(0, input);
      _orbitArgon2Single(inPtr, input.length, profile.value, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kOrbitPointLen));
    } finally {
      _zeroAndFree(inPtr, input.length);
      _zeroAndFree(outPtr, kOrbitPointLen);
    }
  }

  /// Derive the orbit root `o_0 = H(sigma)` (SHA-512) from the Namtso salt
  /// [sigma] (`bs_orbit_root`). This is the sole seam between Namtso and the
  /// orbit protocol: the app harvests [sigma] from Namtso (the flat submodule
  /// `namtso-the-sacred-salt`, via its CLI) and the engine consumes it here —
  /// great-wall-core never depends on Namtso itself (ARCHITECTURE.md
  /// §"Submodule Rules": no nested submodules; the core takes a pre-harvested
  /// sigma). Returns the [kOrbitPointLen]-byte root.
  ///
  /// SECURITY: [sigma] is public (a precomputation-ruling-out salt), but the
  /// returned root seeds the coercion-relevant orbit, so callers zero it after
  /// use. The input/output buffers here are zeroed and freed on every path.
  Uint8List orbitRoot(Uint8List sigma) {
    final Pointer<Uint8> inPtr = calloc<Uint8>(sigma.length);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kOrbitPointLen);
    try {
      inPtr.asTypedList(sigma.length).setAll(0, sigma);
      _orbitRoot(inPtr, sigma.length, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kOrbitPointLen));
    } finally {
      _zeroAndFree(inPtr, sigma.length);
      _zeroAndFree(outPtr, kOrbitPointLen);
    }
  }

  /// `theta_i_j = H(o_i ‖ j)` — the 32-byte fractal-parameter digest of board
  /// `j` at orbit point [oI] (`bs_theta`). The `(o, p, q)` attribution over this
  /// digest is applied downstream (see `_orbit_params` in protocol.py); this is
  /// the same cheap `H` = SHA-256 the Python bridge exposes. [oI] must be 32
  /// bytes.
  ///
  /// SECURITY: [oI] is coercion-relevant (an orbit point). Zeroed before free.
  Uint8List theta(Uint8List oI, int j) {
    assert(oI.length == kOrbitPointLen, 'o_i must be $kOrbitPointLen bytes');
    final Pointer<Uint8> oPtr = calloc<Uint8>(kOrbitPointLen);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kOrbitPointLen);
    try {
      oPtr.asTypedList(kOrbitPointLen).setAll(0, oI);
      _theta(oPtr, j, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kOrbitPointLen));
    } finally {
      _zeroAndFree(oPtr, kOrbitPointLen);
      _zeroAndFree(outPtr, kOrbitPointLen);
    }
  }

  /// `K_i = TH(master-secret, o_i ‖ Sh_i)` — the per-stage master secret
  /// (`bs_master_secret`). **Domain-separated from `u_i`**, so it does not
  /// advance the orbit; use [orbitCommitment] for that. [oI] is the
  /// [kOrbitPointLen]-byte orbit point; [sh] is the serialized Shamir polynomial
  /// ([shToBytes]).
  ///
  /// Internal — a holder receives [exportKey] of this, never this.
  ///
  /// SECURITY: both inputs and the output are coercion-relevant; every buffer is
  /// zeroed before free.
  Uint8List masterSecret(Uint8List oI, Uint8List sh) {
    assert(oI.length == kOrbitPointLen, 'o_i must be $kOrbitPointLen bytes');
    final Pointer<Uint8> oPtr = calloc<Uint8>(kOrbitPointLen);
    final int m = sh.isEmpty ? 1 : sh.length;
    final Pointer<Uint8> shPtr = calloc<Uint8>(m);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kOrbitPointLen);
    try {
      oPtr.asTypedList(kOrbitPointLen).setAll(0, oI);
      if (sh.isNotEmpty) shPtr.asTypedList(sh.length).setAll(0, sh);
      _masterSecret(oPtr, shPtr, sh.length, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kOrbitPointLen));
    } finally {
      _zeroAndFree(oPtr, kOrbitPointLen);
      _zeroAndFree(shPtr, m);
      _zeroAndFree(outPtr, kOrbitPointLen);
    }
  }

  /// One orbit step: `K_i = H(o_i ‖ Sh_i)` and `o_{i+1} = H*(K_i)` over [steps]
  /// (`D`) memory-hard Argon2d passes at [profile] (`bs_orbit_advance`). Returns
  /// `(k, next)`, each [kOrbitPointLen] bytes. `K_i` and `u_i` are
  /// domain-separated, so the returned key does not advance the orbit. The engine
  /// zeroizes the raw `{o_i, Sh_i}` copies before the memory-hard step.
  ///
  /// WARNING: this is the heavy, blocking memory-hard call (>= 1 GiB per pass) —
  /// callers run it off the UI isolate, exactly like [argon2idMaster].
  ({Uint8List k, Uint8List next}) orbitAdvance(
    Uint8List oI,
    Uint8List sh,
    int steps,
    Argon2Profile profile,
  ) {
    assert(oI.length == kOrbitPointLen, 'o_i must be $kOrbitPointLen bytes');
    final Pointer<Uint8> oPtr = calloc<Uint8>(kOrbitPointLen);
    final int m = sh.isEmpty ? 1 : sh.length;
    final Pointer<Uint8> shPtr = calloc<Uint8>(m);
    final Pointer<Uint8> outK = calloc<Uint8>(kOrbitPointLen);
    final Pointer<Uint8> outNext = calloc<Uint8>(kOrbitPointLen);
    try {
      oPtr.asTypedList(kOrbitPointLen).setAll(0, oI);
      if (sh.isNotEmpty) shPtr.asTypedList(sh.length).setAll(0, sh);
      _orbitAdvance(oPtr, shPtr, sh.length, steps, profile.value, outK, outNext);
      return (
        k: Uint8List.fromList(outK.asTypedList(kOrbitPointLen)),
        next: Uint8List.fromList(outNext.asTypedList(kOrbitPointLen)),
      );
    } finally {
      _zeroAndFree(oPtr, kOrbitPointLen);
      _zeroAndFree(shPtr, m);
      _zeroAndFree(outK, kOrbitPointLen);
      _zeroAndFree(outNext, kOrbitPointLen);
    }
  }

  /// `u_i = H(o_i ‖ Sh_i)` — the orbit-advance commitment
  /// (`bs_orbit_commitment`), the value `H*` consumes.
  ///
  /// **Not** [masterSecret]: as of 0.5.0 the two are domain-separated. A caller
  /// streaming the advance pass by pass MUST seed from this, not from `K_i`.
  Uint8List orbitCommitment(Uint8List oI, Uint8List sh) {
    assert(oI.length == kOrbitPointLen, 'o_i must be $kOrbitPointLen bytes');
    final Pointer<Uint8> oPtr = calloc<Uint8>(kOrbitPointLen);
    final int m = sh.isEmpty ? 1 : sh.length;
    final Pointer<Uint8> shPtr = calloc<Uint8>(m);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kOrbitPointLen);
    try {
      oPtr.asTypedList(kOrbitPointLen).setAll(0, oI);
      if (sh.isNotEmpty) shPtr.asTypedList(sh.length).setAll(0, sh);
      _orbitCommitment(oPtr, shPtr, sh.length, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kOrbitPointLen));
    } finally {
      _zeroAndFree(oPtr, kOrbitPointLen);
      _zeroAndFree(shPtr, m);
      _zeroAndFree(outPtr, kOrbitPointLen);
    }
  }

  /// `K_i^L = TH(export-label, K_i ‖ L)` — the exported key for the canonicalised
  /// label [label] (`bs_export_key`). Applied for **every** label including the
  /// empty one, so `K_i` itself is never handed out.
  Uint8List exportKey(Uint8List kI, Uint8List label) {
    assert(kI.length == kOrbitPointLen, 'K_i must be $kOrbitPointLen bytes');
    final Pointer<Uint8> kPtr = calloc<Uint8>(kOrbitPointLen);
    final int m = label.isEmpty ? 1 : label.length;
    final Pointer<Uint8> lPtr = calloc<Uint8>(m);
    final Pointer<Uint8> outPtr = calloc<Uint8>(kOrbitPointLen);
    try {
      kPtr.asTypedList(kOrbitPointLen).setAll(0, kI);
      if (label.isNotEmpty) lPtr.asTypedList(label.length).setAll(0, label);
      _exportKey(kPtr, lPtr, label.length, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(kOrbitPointLen));
    } finally {
      _zeroAndFree(kPtr, kOrbitPointLen);
      _zeroAndFree(lPtr, m);
      _zeroAndFree(outPtr, kOrbitPointLen);
    }
  }

  /// Interpolate the **full** Shamir polynomial `Sh` over GF(2^32) from `t`
  /// points (`bs_shamir_interp`). [xs]/[ys] are the `t` abscissae/points; returns
  /// the `t` coefficients (ascending powers). `Sh` is the whole polynomial
  /// (`t·32` bits) — NOT the constant term `f(0)`; subset-invariance of `Sh` is
  /// load-bearing (DESIGN.md §"Shamir over the fractal points").
  List<int> shamirInterp(List<int> xs, List<int> ys) {
    final int t = xs.length;
    assert(t == ys.length, 'xs and ys must have equal length');
    if (t == 0) return const <int>[];
    final Pointer<Uint32> xsPtr = calloc<Uint32>(t);
    final Pointer<Uint32> ysPtr = calloc<Uint32>(t);
    final Pointer<Uint32> outPtr = calloc<Uint32>(t);
    try {
      xsPtr.asTypedList(t).setAll(0, xs);
      ysPtr.asTypedList(t).setAll(0, ys);
      _shamirInterp(xsPtr, ysPtr, t, outPtr);
      return List<int>.from(outPtr.asTypedList(t));
    } finally {
      // Coefficients are coercion-relevant (they reconstruct K_i): wipe them.
      xsPtr.asTypedList(t).fillRange(0, t, 0);
      ysPtr.asTypedList(t).fillRange(0, t, 0);
      outPtr.asTypedList(t).fillRange(0, t, 0);
      calloc
        ..free(xsPtr)
        ..free(ysPtr)
        ..free(outPtr);
    }
  }

  /// Evaluate the Shamir polynomial [sh] (`t` ascending `u32` coefficients) at
  /// abscissa [x] over GF(2^32) (`bs_shamir_eval`). The field arithmetic lives in
  /// the engine — never re-implemented Dart-side (an independent Dart reference
  /// exists only in tests, as a cross-check oracle).
  int shamirEval(List<int> sh, int x) {
    final int t = sh.length;
    if (t == 0) return 0;
    final Pointer<Uint32> shPtr = calloc<Uint32>(t);
    try {
      shPtr.asTypedList(t).setAll(0, sh);
      return _shamirEval(shPtr, t, x & 0xFFFFFFFF);
    } finally {
      shPtr.asTypedList(t).fillRange(0, t, 0); // Sh is coercion-relevant.
      calloc.free(shPtr);
    }
  }

  /// Generate the next [count] **forgetting-resistance** share values from the
  /// Shamir polynomial [sh] — `f(resistance_abscissa(k))` for `k` in `0..count`
  /// (`bs_shamir_generate_resistance_shares`). Both the GF(2^32) evaluation and
  /// the reserved-abscissa convention stay inside the engine.
  List<int> generateResistanceShares(List<int> sh, int count) {
    final int t = sh.length;
    if (t == 0 || count <= 0) return const <int>[];
    final Pointer<Uint32> shPtr = calloc<Uint32>(t);
    final Pointer<Uint32> outPtr = calloc<Uint32>(count);
    try {
      shPtr.asTypedList(t).setAll(0, sh);
      _shamirGenShares(shPtr, t, count, outPtr);
      return List<int>.from(outPtr.asTypedList(count));
    } finally {
      shPtr.asTypedList(t).fillRange(0, t, 0);
      outPtr.asTypedList(count).fillRange(0, count, 0);
      calloc
        ..free(shPtr)
        ..free(outPtr);
    }
  }

  /// Serialize Shamir `Sh` coefficients (`u32` list) to big-endian bytes — the
  /// wire form matching `shamir::sh_to_bytes` / the Python bridge, fed to
  /// [masterSecret] and [orbitAdvance]. Pure Dart (no FFI); kept here so the
  /// serialization lives beside its only consumers.
  static Uint8List shToBytes(List<int> coeffs) {
    final Uint8List out = Uint8List(coeffs.length * 4);
    for (int i = 0; i < coeffs.length; i++) {
      final int c = coeffs[i];
      out[i * 4] = (c >> 24) & 0xFF;
      out[i * 4 + 1] = (c >> 16) & 0xFF;
      out[i * 4 + 2] = (c >> 8) & 0xFF;
      out[i * 4 + 3] = c & 0xFF;
    }
    return out;
  }

  /// Canonical per-stage Shamir thresholds `t_i` for a setup [level] (1-based):
  /// index 0 is stage 0, `1..N` the deep stages (`t_i == r_i`, `t_i·32` bits)
  /// (`bs_setup_tier_thresholds`). Query-then-fill, like the Python bridge.
  /// Returns `[]` for an invalid level (`0` or `> MAX_SETUP_LEVEL`).
  List<int> setupTierThresholds(int level) {
    final int count = _setupTierThresholds(level, nullptr, 0);
    if (count == 0) return const <int>[];
    final Pointer<Uint32> buf = calloc<Uint32>(count);
    try {
      _setupTierThresholds(level, buf, count);
      return List<int>.from(buf.asTypedList(count));
    } finally {
      calloc.free(buf);
    }
  }

  /// Whether a setup [level] is the **substandard** entry tier (Setup 1, whose
  /// single deep stage carries only 64 bits) (`bs_setup_tier_substandard`).
  /// UIs MUST surface this loudly wherever Setup 1 is offered.
  bool setupTierSubstandard(int level) => _setupTierSubstandard(level) != 0;

  /// Run the **master-secret export** — one Argon2id pass over the reproducible
  /// setup-transcript [message] (`bs_argon2id_master`). Uses the fixed master
  /// profile (Argon2id, `m = 64 MiB`, `t = 8`, `p = 2`) and the fixed salt
  /// `b"greatwall"`; all per-setup uniqueness rides in [message]. Returns
  /// [outLen] bytes (the protocol's `l = 1024`); the consumer takes only what it
  /// needs.
  ///
  /// This is a heavy, blocking native call — callers run it off the UI isolate
  /// (see `GreatWallCore.argon2idMaster`).
  Uint8List argon2idMaster(Uint8List message, {int outLen = 1024}) {
    final int inLen = message.isEmpty ? 1 : message.length;
    final Pointer<Uint8> inPtr = calloc<Uint8>(inLen);
    final Pointer<Uint8> outPtr = calloc<Uint8>(outLen);
    try {
      if (message.isNotEmpty) {
        inPtr.asTypedList(message.length).setAll(0, message);
      }
      _argon2idMaster(inPtr, message.length, outPtr, outLen);
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    } finally {
      _zeroAndFree(inPtr, inLen);
      _zeroAndFree(outPtr, outLen);
    }
  }

  /// Canonicalise a Stage-0 salt/pepper string via the engine (the protocol
  /// rule: uppercase ASCII, keep only `A-Z0-9-`). Returns the canonical string.
  /// Defined in the shared engine so it is byte-identical to great-wall-core
  /// (`bs_salt_pepper_canonicalize`).
  String saltPepperCanonicalize(String text) {
    final (Pointer<Uint8> inPtr, int inLen) = _allocAscii(text);
    try {
      final int n = _saltPepperCanonicalize(inPtr, inLen, nullptr, 0);
      if (n == 0) return '';
      final Pointer<Uint8> outPtr = calloc<Uint8>(n);
      try {
        _saltPepperCanonicalize(inPtr, inLen, outPtr, n);
        return String.fromCharCodes(outPtr.asTypedList(n));
      } finally {
        _zeroAndFree(outPtr, n);
      }
    } finally {
      if (inPtr != nullptr) _zeroAndFree(inPtr, inLen);
    }
  }

  /// Build one chain link's Argon2 input via the engine: the canonical
  /// salt/pepper bytes followed by `bits_to_bytes(priorBits)`
  /// (`bs_chain_input`). [text] is the raw salt/pepper; [priorBits] is the
  /// concatenated bits (0/1) of every preceding point. Single source of truth
  /// shared with great-wall-core, so the same text yields the same seed.
  Uint8List chainInput(String text, List<int> priorBits) {
    final (Pointer<Uint8> tPtr, int tLen) = _allocAscii(text);
    final int nBits = priorBits.length;
    final Pointer<Uint8> bPtr = nBits == 0 ? nullptr : calloc<Uint8>(nBits);
    try {
      if (nBits != 0) bPtr.asTypedList(nBits).setAll(0, priorBits);
      final int n = _chainInput(tPtr, tLen, bPtr, nBits, nullptr, 0);
      final Pointer<Uint8> outPtr = calloc<Uint8>(n == 0 ? 1 : n);
      try {
        _chainInput(tPtr, tLen, bPtr, nBits, outPtr, n);
        return Uint8List.fromList(outPtr.asTypedList(n));
      } finally {
        _zeroAndFree(outPtr, n == 0 ? 1 : n);
      }
    } finally {
      if (tPtr != nullptr) _zeroAndFree(tPtr, tLen);
      if (bPtr != nullptr) _zeroAndFree(bPtr, nBits);
    }
  }

  // -------------------------------------------------------------------------
  // Canonical protocol parameters (engine is the single source of truth)
  // -------------------------------------------------------------------------

  /// The canonical encode/decode discovery parameters, read straight from the
  /// engine (`bs_encode_params`). The wallet must not hard-code these — a stale
  /// copy (`maxIter = 64`) is what stalled deep-zoom encodes; the engine
  /// dictates the protocol.
  CoreDiscoveryParams encodeParams() {
    final Pointer<Uint32> maxIter = calloc<Uint32>();
    final Pointer<Uint32> targetGood = calloc<Uint32>();
    final Pointer<Uint64> maxFloodPoints = calloc<Uint64>();
    final Pointer<Uint64> minGridCells = calloc<Uint64>();
    final Pointer<Uint32> pMaxShift = calloc<Uint32>();
    final Pointer<Uint32> exclusionThresholdNum = calloc<Uint32>();
    final Pointer<Uint64> rngSeed = calloc<Uint64>();
    try {
      _encodeParams(maxIter, targetGood, maxFloodPoints, minGridCells,
          pMaxShift, exclusionThresholdNum, rngSeed);
      return CoreDiscoveryParams(
        maxIter: maxIter.value,
        targetGood: targetGood.value,
        maxFloodPoints: maxFloodPoints.value,
        minGridCells: minGridCells.value,
        pMaxShift: pMaxShift.value,
        exclusionThresholdNum: exclusionThresholdNum.value,
        rngSeed: rngSeed.value,
      );
    } finally {
      calloc
        ..free(maxIter)
        ..free(targetGood)
        ..free(maxFloodPoints)
        ..free(minGridCells)
        ..free(pMaxShift)
        ..free(exclusionThresholdNum)
        ..free(rngSeed);
    }
  }

  /// The canonical encode area as raw I4F60 `i64` bounds (`bs_encode_area`).
  FixedRect encodeArea() {
    final Pointer<Int64> reMin = calloc<Int64>();
    final Pointer<Int64> reMax = calloc<Int64>();
    final Pointer<Int64> imMin = calloc<Int64>();
    final Pointer<Int64> imMax = calloc<Int64>();
    try {
      _encodeArea(reMin, reMax, imMin, imMax);
      return FixedRect(
        reMin: reMin.value,
        reMax: reMax.value,
        imMin: imMin.value,
        imMax: imMax.value,
      );
    } finally {
      calloc
        ..free(reMin)
        ..free(reMax)
        ..free(imMin)
        ..free(imMax);
    }
  }

  /// Bits encoded per fractal point/stage (`bs_bits_per_point`).
  int bitsPerPoint() => _bitsPerPoint();

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  (Pointer<Uint8>, int) _allocAscii(String s) {
    if (s.isEmpty) return (nullptr, 0);
    final List<int> bytes = s.codeUnits;
    final Pointer<Uint8> ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return (ptr, bytes.length);
  }

  void _zeroAndFree(Pointer<Uint8> ptr, int len) {
    // Wipe secret-bearing buffers before returning them to the allocator.
    ptr.asTypedList(len).fillRange(0, len, 0);
    calloc.free(ptr);
  }
}

/// Argon2 cost profile. Values match the Rust `PROFILE_*` constants and the
/// Python bridge (burning_ship_engine.py).
enum Argon2Profile {
  /// Mobile-accessible: 1 GiB.
  basic(0),

  /// Desktop-only: 32 GiB.
  advanced(1),

  /// Server-class: 128 GiB.
  greatWall(2);

  const Argon2Profile(this.value);
  final int value;
}

/// A rectangle in the complex plane, as raw I4F60 `i64` bounds.
class FixedRect {
  const FixedRect({
    required this.reMin,
    required this.reMax,
    required this.imMin,
    required this.imMax,
  });

  factory FixedRect.fromDoubles(
    double reMin,
    double reMax,
    double imMin,
    double imMax,
  ) =>
      FixedRect(
        reMin: fixedFromDouble(reMin),
        reMax: fixedFromDouble(reMax),
        imMin: fixedFromDouble(imMin),
        imMax: fixedFromDouble(imMax),
      );

  final int reMin;
  final int reMax;
  final int imMin;
  final int imMax;
}

/// Discovery / bisection parameters. Integer-only, mirroring the Rust
/// `DiscoveryParams`. These are *protocol* values that determine encode output;
/// the engine is their single source of truth ([GreatWallCoreBindings
/// .encodeParams], backed by `bs_encode_params`). All fields are required on
/// purpose — there are deliberately no defaults, so a stale literal (e.g. a
/// `maxIter` of 64) can never silently stand in for the engine's value.
class CoreDiscoveryParams {
  const CoreDiscoveryParams({
    required this.maxIter,
    required this.targetGood,
    required this.maxFloodPoints,
    required this.minGridCells,
    required this.pMaxShift,
    required this.exclusionThresholdNum,
    required this.rngSeed,
  });

  final int maxIter;
  final int targetGood;
  final int maxFloodPoints;
  final int minGridCells;
  final int pMaxShift;
  final int exclusionThresholdNum;
  final int rngSeed;
}

/// Result of [GreatWallCoreBindings.decodeFull].
class CoreDecodeResult {
  const CoreDecodeResult({
    required this.bits,
    required this.leafRect,
    required this.valid,
    required this.path,
  });

  final List<int> bits;
  final FixedRect leafRect;
  final bool valid;

  /// The bisection path — the leaf area's canonical identity, used to resolve
  /// its canonical island. Empty when not requested. Never logged.
  final String path;
}

/// One leaf area from [GreatWallCoreBindings.enumerateLeafAreas]: the leaf
/// rectangle in raw I4F60 bounds, plus its bisection [path] — the canonical
/// identity, stable across frames and zoom levels.
class CoreLeafArea {
  const CoreLeafArea({required this.rect, required this.path});

  final FixedRect rect;
  final String path;
}

/// Result of [GreatWallCoreBindings.enumerateLeafAreas]: either the (capped)
/// list of distinct leaf areas present, or [tooMany] meaning more than
/// [maxLeaves] are present and the UX should prompt the user to zoom in.
class CoreLeafAreasResult {
  const CoreLeafAreasResult.leaves(this.leaves)
      : tooMany = false,
        maxLeaves = 0;

  const CoreLeafAreasResult.tooMany(this.maxLeaves)
      : leaves = const <CoreLeafArea>[],
        tooMany = true;

  final List<CoreLeafArea> leaves;
  final bool tooMany;
  final int maxLeaves;
}

/// A leaf area's canonical island from [GreatWallCoreBindings.canonicalIsland]:
/// the island's flood points as interleaved raw I4F60 `[re, im]` cell centres,
/// plus the cell size [pixelDeltaRaw] (raw Fixed), bbox, escape count and pixel
/// count. The union of `pixelDeltaRaw`-sized cells at the points is its shape.
class CoreCanonicalIsland {
  const CoreCanonicalIsland({
    required this.escapeCount,
    required this.pixelCount,
    required this.pixelDeltaRaw,
    required this.bbox,
    required this.pointsRaw,
  });

  final int escapeCount;
  final int pixelCount;
  final int pixelDeltaRaw;
  final FixedRect bbox;

  /// Interleaved `[re0, im0, re1, im1, ...]` cell centres as raw I4F60 `i64`.
  final List<int> pointsRaw;
}

// ---------------------------------------------------------------------------
// C ABI typedefs (native + Dart signatures)
// ---------------------------------------------------------------------------

typedef _RenderViewportC = Void Function(
  Double, Double, Double, Int32, Int32, Uint32, Pointer<Uint8>);
typedef _RenderViewportDart = void Function(
  double, double, double, int, int, int, Pointer<Uint8>);

typedef _RenderViewportGenericC = Void Function(
  Double, Double, Double, Int32, Int32, Uint32,
  Uint64, Uint64, Uint64, Pointer<Uint8>);
typedef _RenderViewportGenericDart = void Function(
  double, double, double, int, int, int,
  int, int, int, Pointer<Uint8>);

typedef _RenderViewportGenericU32C = Void Function(
  Double, Double, Double, Int32, Int32, Uint32,
  Uint64, Uint64, Uint64, Pointer<Uint32>);
typedef _RenderViewportGenericU32Dart = void Function(
  double, double, double, int, int, int,
  int, int, int, Pointer<Uint32>);

typedef _EncodeC = Pointer<Void> Function(
  Pointer<Uint8>, Uint32,
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64,
  Uint64, Uint32, Uint32,
  Uint64,
  Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32);
typedef _EncodeDart = Pointer<Void> Function(
  Pointer<Uint8>, int,
  int, int, int, int,
  int, int, int,
  int, int, int,
  int,
  int, int, int,
  Pointer<Uint8>, int);

typedef _EncodeResultPointC = Void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>);
typedef _EncodeResultPointDart = void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>);

typedef _EncodeResultFinalRectC = Void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);
typedef _EncodeResultFinalRectDart = void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);

typedef _EncodeResultFreeC = Void Function(Pointer<Void>);
typedef _EncodeResultFreeDart = void Function(Pointer<Void>);

typedef _DecodeFullC = Void Function(
  Int64, Int64, Uint32,
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64,
  Uint64, Uint32, Uint32,
  Uint64,
  Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32,
  Pointer<Uint8>, Pointer<Int64>, Pointer<Uint8>,
  Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _DecodeFullDart = void Function(
  int, int, int,
  int, int, int, int,
  int, int, int,
  int, int, int,
  int,
  int, int, int,
  Pointer<Uint8>, int,
  Pointer<Uint8>, Pointer<Int64>, Pointer<Uint8>,
  Pointer<Uint8>, int, Pointer<Uint32>);

typedef _LeafAreasComputeC = Pointer<Void> Function(
  Double, Double, Double, Uint32, Uint32, Uint32, Uint32, Uint32,
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64, Uint64, Uint32, Uint32,
  Uint64, Uint32, Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32);
typedef _LeafAreasComputeDart = Pointer<Void> Function(
  double, double, double, int, int, int, int, int,
  int, int, int, int,
  int, int, int, int, int, int,
  int, int, int, int, int,
  Pointer<Uint8>, int);

typedef _LeafAreasStatusC = Int32 Function(Pointer<Void>);
typedef _LeafAreasStatusDart = int Function(Pointer<Void>);

typedef _LeafAreasCountC = Uint32 Function(Pointer<Void>);
typedef _LeafAreasCountDart = int Function(Pointer<Void>);

typedef _LeafAreasRectC = Void Function(Pointer<Void>, Uint32, Pointer<Int64>);
typedef _LeafAreasRectDart = void Function(Pointer<Void>, int, Pointer<Int64>);

typedef _LeafAreasPathC = Uint32 Function(
  Pointer<Void>, Uint32, Pointer<Uint8>, Uint32);
typedef _LeafAreasPathDart = int Function(
  Pointer<Void>, int, Pointer<Uint8>, int);

typedef _LeafAreasFreeC = Void Function(Pointer<Void>);
typedef _LeafAreasFreeDart = void Function(Pointer<Void>);

typedef _CanonicalIslandComputeC = Pointer<Void> Function(
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64, Uint64, Uint32, Uint32,
  Uint64, Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32);
typedef _CanonicalIslandComputeDart = Pointer<Void> Function(
  int, int, int, int,
  int, int, int, int, int, int,
  int, int, int, int,
  Pointer<Uint8>, int);

typedef _CanonicalIslandFoundC = Int32 Function(Pointer<Void>);
typedef _CanonicalIslandFoundDart = int Function(Pointer<Void>);

typedef _CanonicalIslandMetaC = Void Function(
  Pointer<Void>, Pointer<Uint32>, Pointer<Uint64>, Pointer<Int64>, Pointer<Int64>);
typedef _CanonicalIslandMetaDart = void Function(
  Pointer<Void>, Pointer<Uint32>, Pointer<Uint64>, Pointer<Int64>, Pointer<Int64>);

typedef _CanonicalIslandNumPointsC = Uint32 Function(Pointer<Void>);
typedef _CanonicalIslandNumPointsDart = int Function(Pointer<Void>);

typedef _CanonicalIslandPointsC = Uint32 Function(
  Pointer<Void>, Pointer<Int64>, Uint32);
typedef _CanonicalIslandPointsDart = int Function(
  Pointer<Void>, Pointer<Int64>, int);

typedef _CanonicalIslandFreeC = Void Function(Pointer<Void>);
typedef _CanonicalIslandFreeDart = void Function(Pointer<Void>);

typedef _Argon2SingleC = Void Function(
  Pointer<Uint8>, Uint32, Uint8, Pointer<Uint8>);
typedef _Argon2SingleDart = void Function(
  Pointer<Uint8>, int, int, Pointer<Uint8>);

typedef _OrbitRootC = Void Function(Pointer<Uint8>, Uint32, Pointer<Uint8>);
typedef _OrbitRootDart = void Function(Pointer<Uint8>, int, Pointer<Uint8>);

typedef _ThetaC = Void Function(Pointer<Uint8>, Uint32, Pointer<Uint8>);
typedef _ThetaDart = void Function(Pointer<Uint8>, int, Pointer<Uint8>);

typedef _MasterSecretC = Void Function(
  Pointer<Uint8>, Pointer<Uint8>, Uint32, Pointer<Uint8>);
typedef _MasterSecretDart = void Function(
  Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);

typedef _OrbitAdvanceC = Void Function(
  Pointer<Uint8>, Pointer<Uint8>, Uint32, Uint32, Uint8,
  Pointer<Uint8>, Pointer<Uint8>);
typedef _OrbitAdvanceDart = void Function(
  Pointer<Uint8>, Pointer<Uint8>, int, int, int,
  Pointer<Uint8>, Pointer<Uint8>);

typedef _ShamirInterpC = Void Function(
  Pointer<Uint32>, Pointer<Uint32>, Uint32, Pointer<Uint32>);
typedef _ShamirInterpDart = void Function(
  Pointer<Uint32>, Pointer<Uint32>, int, Pointer<Uint32>);

typedef _ShamirEvalC = Uint32 Function(Pointer<Uint32>, Uint32, Uint32);
typedef _ShamirEvalDart = int Function(Pointer<Uint32>, int, int);

typedef _ShamirGenSharesC = Void Function(
  Pointer<Uint32>, Uint32, Uint32, Pointer<Uint32>);
typedef _ShamirGenSharesDart = void Function(
  Pointer<Uint32>, int, int, Pointer<Uint32>);

typedef _SetupTierThresholdsC = Uint32 Function(Uint32, Pointer<Uint32>, Uint32);
typedef _SetupTierThresholdsDart = int Function(int, Pointer<Uint32>, int);

typedef _SetupTierSubstandardC = Uint8 Function(Uint32);
typedef _SetupTierSubstandardDart = int Function(int);

typedef _Argon2idMasterC = Void Function(
  Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32);
typedef _Argon2idMasterDart = void Function(
  Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _SaltPepperCanonicalizeC = Uint32 Function(
  Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32);
typedef _SaltPepperCanonicalizeDart = int Function(
  Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _ChainInputC = Uint32 Function(
  Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32);
typedef _ChainInputDart = int Function(
  Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _EncodeParamsC = Void Function(Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>);
typedef _EncodeParamsDart = void Function(Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>);

typedef _EncodeAreaC = Void Function(
  Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);
typedef _EncodeAreaDart = void Function(
  Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);

typedef _BitsPerPointC = Uint32 Function();
typedef _BitsPerPointDart = int Function();

typedef _GetPrecisionC = Void Function(Pointer<Uint32>, Pointer<Uint32>);
typedef _GetPrecisionDart = void Function(Pointer<Uint32>, Pointer<Uint32>);

typedef _EngineVersionC = Uint32 Function(Pointer<Uint8>, Uint32);
typedef _EngineVersionDart = int Function(Pointer<Uint8>, int);
