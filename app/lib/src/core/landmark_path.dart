import 'dart:typed_data';

/// What a landmark is, in great-wall-core's numbering (`FeatureKind`).
enum LandmarkKind {
  /// The encode area's sea outside every land hull: the path's start.
  outerShell,

  /// A pocket of sea inside a land hull, open to the outside.
  fiord,

  /// An island with its shells.
  feature,

  /// The leaf's canonical island with its shells: the path's end.
  leaf,
}

/// The landmark-path parameters (great-wall-core `LandmarkParams`), read from
/// the engine (`bs_landmark_params`) and passed back unchanged. Ratios are
/// `num / den`.
class LandmarkParams {
  const LandmarkParams({
    required this.floodCells,
    required this.scanMaxIter,
    required this.minEscape,
    required this.seedGrid,
    required this.shells,
    required this.reach,
    required this.ladderRatioNum,
    required this.ladderRatioDen,
    required this.leafShareNum,
    required this.leafShareDen,
    required this.keep,
    required this.minCells,
    required this.rhoNum,
    required this.rhoDen,
    required this.badnessExponent,
    required this.badnessChargeNum,
    required this.badnessChargeDen,
    required this.metricFracBits,
    required this.canonicalMaxFloodPoints,
  });

  final int floodCells;
  final int scanMaxIter;
  final int minEscape;
  final int seedGrid;

  /// A feature spans counts `bottom ..= bottom + shells`.
  final int shells;
  final int reach;
  final int ladderRatioNum;
  final int ladderRatioDen;
  final int leafShareNum;
  final int leafShareDen;
  final int keep;
  final int minCells;
  final int rhoNum;
  final int rhoDen;
  final int badnessExponent;
  final int badnessChargeNum;
  final int badnessChargeDen;

  /// Fractional bits of the hop distances.
  final int metricFracBits;
  final int canonicalMaxFloodPoints;
}

/// One stop of a landmark path, as great-wall-core computed it.
///
/// Its identity — [kind], [ladderIndex], [bottom] and the seed — is what core
/// needs to recompute it; the rest are its measures and cells. Integer fields
/// only: coordinates are raw I4F60, the cells a byte per cell (row-major from
/// the lowest imaginary part, non-zero for a cell of the feature).
///
/// Sensitive: a path leads to its leaf, and so to the point. [wipe] zeroes it;
/// [toString] never shows it.
class LandmarkFeature {
  LandmarkFeature({
    required this.kind,
    required this.ladderIndex,
    required this.bottom,
    required this.seedRe,
    required this.seedIm,
    required this.barycentreRe,
    required this.barycentreIm,
    required this.bboxReMin,
    required this.bboxReMax,
    required this.bboxImMin,
    required this.bboxImMax,
    required this.cellCount,
    required this.cellRaw,
    required this.cellsOriginRe,
    required this.cellsOriginIm,
    required this.cellsWidth,
    required this.cellsHeight,
    required this.cells,
  });

  LandmarkKind kind;

  /// Index of the ladder area it was found in (0 for the leaf).
  int ladderIndex;

  /// Its lowest escape count.
  int bottom;

  /// Centre of its first cell in row-major order.
  int seedRe;
  int seedIm;
  int barycentreRe;
  int barycentreIm;

  /// Bounding box of its cell centres.
  int bboxReMin;
  int bboxReMax;
  int bboxImMin;
  int bboxImMax;
  int cellCount;

  /// Cell size.
  int cellRaw;

  /// Centre of cell `(0, 0)` of [cells].
  int cellsOriginRe;
  int cellsOriginIm;
  int cellsWidth;
  int cellsHeight;
  final Uint8List cells;

  /// Zero every field.
  void wipe() {
    kind = LandmarkKind.outerShell;
    ladderIndex = 0;
    bottom = 0;
    seedRe = 0;
    seedIm = 0;
    barycentreRe = 0;
    barycentreIm = 0;
    bboxReMin = 0;
    bboxReMax = 0;
    bboxImMin = 0;
    bboxImMax = 0;
    cellCount = 0;
    cellRaw = 0;
    cellsOriginRe = 0;
    cellsOriginIm = 0;
    cellsWidth = 0;
    cellsHeight = 0;
    cells.fillRange(0, cells.length, 0);
  }

  @override
  String toString() => 'LandmarkFeature(<redacted>)';
}

/// A landmark path: its stops from the outer shell to the leaf feature, and
/// the zoom distance of each hop between consecutive stops (units of
/// `2^-metricFracBits`). [version] is the engine's landmark-path version: a
/// path from another version is recomputed, not reused.
///
/// Sensitive, as [LandmarkFeature] is.
class LandmarkPath {
  LandmarkPath({
    required this.version,
    required this.stops,
    required this.hops,
  });

  final String version;
  final List<LandmarkFeature> stops;
  final Int64List hops;

  /// Zero every stop and hop.
  void wipe() {
    for (final LandmarkFeature s in stops) {
      s.wipe();
    }
    hops.fillRange(0, hops.length, 0);
  }

  @override
  String toString() => 'LandmarkPath(<redacted>)';
}
