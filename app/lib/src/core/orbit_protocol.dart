import 'dart:typed_data';

import '../ffi/core_bindings.dart';
import 'encoding_constants.dart';
import 'great_wall_core.dart';

/// App-level orchestration of the 0.5.0 **orbit** protocol — the Dart peer of
/// great-wall-core/burning_ship/protocol.py (`encode_orbit` / `decode_orbit`).
///
/// The orbit replaces the 0.3.0 single-point chain with, per deep stage, `t_i`
/// (= `r_i`) fractal boards whose 32-bit points are combined by Shamir into the
/// stage's polynomial `Sh_i` and per-stage master secret
/// `K_i = TH(master-secret, o_i ‖ Sh_i)`; the orbit then advances memory-hard
/// from the domain-separated commitment, `o_{i+1} = H*(u_i)` with
/// `u_i = H(o_i ‖ Sh_i)`. `t_i` comes from the
/// engine's canonical tier table ([GreatWallCore.setupTierThresholds]); the deep
/// stages enforce `r_i > 2`, with the substandard entry exception surfaced by
/// [GreatWallCore.setupTierSubstandard].
///
/// This class is pure orchestration over the engine primitives (all determinism
/// lives in the Rust engine and is shared byte-for-byte with the reference); it
/// holds no coercion-relevant state of its own beyond the transient buffers the
/// primitives already zero. The single memory-hard step is injectable
/// ([OrbitAdvanceFn]) so the whole flow is testable with a cheap deterministic
/// advance — matching protocol.py's `advance_fn` seam.
class OrbitProtocol {
  OrbitProtocol(
    this.core, {
    this.params,
    this.area,
    this.iterations = 1,
    this.profile = Argon2Profile.basic,
  });

  final GreatWallCore core;

  /// Discovery params for the per-board encode/decode. Defaults to the engine's
  /// canonical [GreatWallCore.encodeParams]; tests pass lighter params for speed
  /// (encode and decode MUST use the same — a mismatch changes the bijection).
  final CoreDiscoveryParams? params;

  /// Encode area for the per-board encode/decode. Defaults to the engine's
  /// canonical [GreatWallCore.encodeArea].
  final FixedRect? area;

  /// `D` — Argon2d passes per orbit advance (the memory-hard step's cost).
  final int iterations;

  /// Argon2 profile for the memory-hard advance.
  final Argon2Profile profile;

  CoreDiscoveryParams get _params => params ?? core.encodeParams;
  FixedRect get _area => area ?? core.encodeArea;

  static const int _bitsPerPoint = EncodingConstants.bitsPerPoint;

  /// `theta_i_j = H(o_i ‖ j)` split into the raw `(o, p, q)` u64 reservoirs by
  /// the standard byte attribution — the first three big-endian u64s of the
  /// digest (unchanged from the prototype; `_orbit_params` in protocol.py). The
  /// u64s are carried in Dart `int`s as raw 64-bit patterns (the same convention
  /// the rest of the FFI uses — e.g. `q = -1` is `0xFFFF…FFFF`), so they marshal
  /// to the engine's `Uint64` params unchanged.
  ({int o, int p, int q}) orbitParams(Uint8List oI, int j) {
    final Uint8List h = core.theta(oI, j);
    final ByteData bd = ByteData.sublistView(h);
    return (
      o: bd.getUint64(0, Endian.big),
      p: bd.getUint64(8, Endian.big),
      q: bd.getUint64(16, Endian.big),
    );
  }

  /// Pack a [_bitsPerPoint]-bit list (MSB first, matching the engine's
  /// `bits_to_bytes`) into the u32 Shamir point value (`_bits_to_u32`).
  static int bitsToU32(List<int> bits) {
    int y = 0;
    for (final int b in bits) {
      y = ((y << 1) | (b & 1)) & 0xFFFFFFFF;
    }
    return y;
  }

  /// Unpack a u32 value to a [_bitsPerPoint]-bit list (MSB first) — the exact
  /// inverse of [bitsToU32]. Trivial bit repacking (no field arithmetic): used to
  /// turn an engine-computed Shamir share value into the bits to encode onto its
  /// board.
  static List<int> u32ToBits(int y) =>
      <int>[for (int i = _bitsPerPoint - 1; i >= 0; i--) (y >> i) & 1];

  /// Encode [stageChunks] onto the orbit's fractals for [setupLevel].
  ///
  /// `stageChunks[i]` is a list of `t_i` bit-lists (each [_bitsPerPoint] long) —
  /// one 32-bit value per fractal of stage `i`. Returns the per-stage
  /// [OrbitStage]s and the terminal `K_N`. [advanceFn] overrides the default
  /// memory-hard advance (tests inject a cheap deterministic one).
  ///
  /// Throws [ArgumentError] on a shape mismatch (invalid level, wrong stage /
  /// board / bit counts) — the same guards protocol.py raises.
  Future<({List<OrbitStage> stages, Uint8List k})> encodeOrbit(
    Uint8List sigma,
    int setupLevel,
    List<List<List<int>>> stageChunks, {
    OrbitAdvanceFn? advanceFn,
  }) async {
    final List<int> thresholds = _requireThresholds(setupLevel);
    if (stageChunks.length != thresholds.length) {
      throw ArgumentError(
        'expected ${thresholds.length} stages for setup $setupLevel, '
        'got ${stageChunks.length}',
      );
    }
    final OrbitAdvanceFn advance = advanceFn ?? _defaultAdvance;

    Uint8List o = core.orbitRoot(sigma);
    final List<OrbitStage> stages = <OrbitStage>[];
    Uint8List k = Uint8List(0);
    for (int i = 0; i < thresholds.length; i++) {
      final int tI = thresholds[i];
      final List<List<int>> chunks = stageChunks[i];
      if (chunks.length != tI) {
        throw ArgumentError('stage $i: expected $tI points, got ${chunks.length}');
      }
      final List<({int o, int p, int q})> fractals = <({int o, int p, int q})>[];
      final List<({int reRaw, int imRaw})> points = <({int reRaw, int imRaw})>[];
      final List<int> xs = <int>[];
      final List<int> ys = <int>[];
      for (int j = 0; j < tI; j++) {
        final List<int> chunk = chunks[j];
        if (chunk.length != _bitsPerPoint) {
          throw ArgumentError(
            'stage $i fractal $j: expected $_bitsPerPoint bits, '
            'got ${chunk.length}',
          );
        }
        final ({int o, int p, int q}) prm = orbitParams(o, j);
        final ({int reRaw, int imRaw, FixedRect leafRect}) res =
            core.bindings.encodePoint(
          bits: chunk,
          area: _area,
          params: _params,
          o: prm.o,
          p: prm.p,
          q: prm.q,
        );
        fractals.add(prm);
        points.add((reRaw: res.reRaw, imRaw: res.imRaw));
        xs.add(j + 1); // primary abscissa (positive)
        ys.add(bitsToU32(chunk));
      }
      final List<int> sh = core.shamirInterp(xs, ys);
      final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
      k = core.masterSecret(o, shBytes);
      stages.add(OrbitStage(
        index: i,
        oBytes: o,
        threshold: tI,
        fractals: fractals,
        points: points,
        sh: sh,
        k: k,
      ));
      o = await advance(o, shBytes);
    }
    return (stages: stages, k: k);
  }

  /// Inverse of [encodeOrbit]. `stagePoints[i]` is a list of `t_i`
  /// `(reRaw, imRaw)` pairs (the points placed/clicked on stage `i`'s fractals).
  /// Returns the recovered per-fractal bit-lists and the terminal `K_N`.
  /// [advanceFn] / [params] / [area] MUST match those used to encode.
  Future<({List<List<List<int>>> stageChunks, Uint8List k})> decodeOrbit(
    Uint8List sigma,
    int setupLevel,
    List<List<({int reRaw, int imRaw})>> stagePoints, {
    OrbitAdvanceFn? advanceFn,
  }) async {
    final List<int> thresholds = _requireThresholds(setupLevel);
    if (stagePoints.length != thresholds.length) {
      throw ArgumentError(
        'expected ${thresholds.length} stages for setup $setupLevel, '
        'got ${stagePoints.length}',
      );
    }
    final OrbitAdvanceFn advance = advanceFn ?? _defaultAdvance;

    Uint8List o = core.orbitRoot(sigma);
    final List<List<List<int>>> outChunks = <List<List<int>>>[];
    Uint8List k = Uint8List(0);
    for (int i = 0; i < thresholds.length; i++) {
      final int tI = thresholds[i];
      final List<({int reRaw, int imRaw})> pts = stagePoints[i];
      if (pts.length != tI) {
        throw ArgumentError('stage $i: expected $tI points, got ${pts.length}');
      }
      final List<List<int>> chunks = <List<int>>[];
      final List<int> xs = <int>[];
      final List<int> ys = <int>[];
      for (int j = 0; j < tI; j++) {
        final ({int reRaw, int imRaw}) pt = pts[j];
        final ({int o, int p, int q}) prm = orbitParams(o, j);
        final CoreDecodeResult res = core.bindings.decodeFull(
          pointReRaw: pt.reRaw,
          pointImRaw: pt.imRaw,
          numBits: _bitsPerPoint,
          area: _area,
          params: _params,
          o: prm.o,
          p: prm.p,
          q: prm.q,
        );
        final List<int> bits = res.bits;
        chunks.add(bits);
        xs.add(j + 1);
        ys.add(bitsToU32(bits));
      }
      final List<int> sh = core.shamirInterp(xs, ys);
      final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
      k = core.masterSecret(o, shBytes);
      outChunks.add(chunks);
      o = await advance(o, shBytes);
    }
    return (stageChunks: outChunks, k: k);
  }

  List<int> _requireThresholds(int setupLevel) {
    final List<int> thresholds = core.setupTierThresholds(setupLevel);
    if (thresholds.isEmpty) {
      throw ArgumentError('invalid setup level $setupLevel');
    }
    return thresholds;
  }

  /// Default advance: `o_{i+1} = H*(u_i)` via the memory-hard engine call, run
  /// off the UI isolate ([GreatWallCore.advanceOrbit]). Only the next orbit point
  /// is needed here; `K_i` is already the stage's recorded master secret.
  Future<Uint8List> _defaultAdvance(Uint8List o, Uint8List shBytes) async {
    final ({Uint8List k, Uint8List next}) r =
        await core.advanceOrbit(o, shBytes, steps: iterations, profile: profile);
    return r.next;
  }
}

/// The memory-hard advance seam: `(o_i, Sh_i bytes) -> o_{i+1}`. Injectable so
/// the orbit orchestration is testable with a cheap deterministic advance;
/// production uses [OrbitProtocol]'s default (Argon2d via the engine).
typedef OrbitAdvanceFn = Future<Uint8List> Function(
    Uint8List o, Uint8List shBytes);

/// One stage of an orbit encode/decode — the Dart peer of protocol.py's
/// `OrbitStage`. Every field except [index]/[threshold] is coercion-relevant;
/// callers that persist any of it own wiping it.
class OrbitStage {
  const OrbitStage({
    required this.index,
    required this.oBytes,
    required this.threshold,
    required this.fractals,
    required this.points,
    required this.sh,
    required this.k,
  });

  /// Stage index (0 = stage 0, `1..N` = deep stages).
  final int index;

  /// The orbit point `o_i` for this stage ([kOrbitPointLen] bytes).
  final Uint8List oBytes;

  /// `t_i` (= `r_i`), the number of fractals/points this stage carries.
  final int threshold;

  /// The per-fractal raw `(o, p, q)` reservoirs, one per board.
  final List<({int o, int p, int q})> fractals;

  /// The per-fractal encoded points as raw I4F60 `(reRaw, imRaw)`, one per board.
  final List<({int reRaw, int imRaw})> points;

  /// The full Shamir polynomial `Sh_i` (`t_i` u32 coefficients, ascending power).
  final List<int> sh;

  /// `K_i = H(o_i ‖ Sh_i)`. A true per-stage master secret for `i > 0`.
  final Uint8List k;

  /// Redacted: a stage's fractal params, points, Sh and K_i are all
  /// coercion-relevant (SCOPE.md — never logged).
  @override
  String toString() => 'OrbitStage(index: $index, threshold: $threshold, '
      '<redacted>)';
}
