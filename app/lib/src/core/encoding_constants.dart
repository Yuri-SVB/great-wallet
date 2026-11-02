/// App-side protocol constants.
///
/// The values that determine encode/decode *output* — the discovery params and
/// the encode area — are NOT kept here: they are read from the engine at
/// runtime ([GreatWallCore.encodeParams] / [GreatWallCore.encodeArea], backed
/// by `bs_encode_params` / `bs_encode_area`), because the engine alone dictates
/// the protocol. A hand-mirrored copy is exactly what drifted before (the
/// wallet held `maxIter = 64` while the protocol moved to 1024, stalling
/// deep-zoom encodes).
///
/// What remains here is structural — values used in compile-time `const`
/// contexts that the engine still validates at startup (see
/// [GreatWallCore]'s bits-per-point check).
class EncodingConstants {
  EncodingConstants._();

  /// Bits encoded per fractal point — and, under the chained protocol, per
  /// stage (one point = one stage = one 32-bit chunk). The engine
  /// (`bs_bits_per_point`) is the authority; [GreatWallCore] asserts this
  /// matches it on open, so a stale value fails loudly instead of mis-encoding.
  static const int bitsPerPoint = 32;

  /// The all-zero perturbation reservoirs that yield the pure canonical Burning
  /// Ship formula. The chained wallet flow no longer uses a canonical fractal
  /// (Stage 0 is text; every fractal is chain-derived), so these are retained
  /// only as the engine's `(0,0,0)` baseline for non-chained / viewer use.
  static const int canonicalO = 0;
  static const int canonicalP = 0;
  static const int canonicalQ = 0;

  /// Default escape-iteration cap for *rendering* the fractal canvas
  /// (constants.py: `DEFAULT_MAX_ITER`). This is a purely visual knob — it
  /// colours pixels and does not affect which bits a point encodes to — and is
  /// not a determinism-critical protocol value, so it stays app-side.
  ///
  /// Kept small (fast): rendering cost scales with the cap for non-escaping
  /// (interior) pixels, so a high cap makes zooming into high-escape-count voids
  /// laggy. The rare leaf that sits deep in such a void — invisible at this cap
  /// because the void renders as featureless — is reached with the `Alt+L` deep
  /// render toggle, which raises the cap to the engine's encode cap
  /// (`GreatWallCore.encodeParams.maxIter`) so the rendered boundary matches
  /// where the encoder actually lands leaves. The deep value is read from the
  /// engine at runtime, never mirrored here, so it can never drift from it.
  static const int renderMaxIterFast = 64;

  /// Number of fractal point stages for an entropy width: one 32-bit point per
  /// fractal (`entropy_bits / BITS_PER_POINT`). The text Stage 0 is separate and
  /// not counted here. The inverse — entropy width for a chosen stage count — is
  /// simply `pointStages × bitsPerPoint`; the Setup flow lets the user pick any
  /// count in `1..SetupController.maxPointStages` (every value is a valid setup),
  /// rather than a fixed mini/default/large preset.
  static int nStagesFor(int entropyBits) => entropyBits ~/ bitsPerPoint;

  /// Cap on leaf-area scan samples **per axis**, regardless of canvas size, so
  /// the grid can't explode on a large window (the scan is `pixels / step`).
  /// The source raises the step to honour this; the decode budget below is the
  /// hard cost cap.
  static const int leafEnumMaxAxisSamples = 64;

  /// Backstop cap on island **discoveries** (bisection-tree node expansions)
  /// per leaf-area scan — the zoom-out guard. The engine memoizes the area tree,
  /// so points sharing a path prefix reuse the expensive upper-level
  /// discoveries; in practice even a zoom-out scan now finishes in a fraction of
  /// a second. This bound only catches a pathological view; it is generous so it
  /// never falsely aborts a legitimate one. Hitting it yields a "zoom in" result.
  static const int leafEnumMaxDecodes = 4000;
}
