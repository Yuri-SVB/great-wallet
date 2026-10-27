import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/core/landmark_path.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';

/// The landmark path through the Dart bindings and the worker isolate,
/// against great-wall-core's frozen vector
/// (test_vectors/landmark-v<version>/landmark_plain.json, the board (0, 0, 0)).
/// Skipped unless the engine opens and the great-wall-core submodule holds the
/// vector for the engine's landmark-path version.
void main() {
  GreatWallCore? core;
  String? openError;

  setUpAll(() {
    try {
      core = GreatWallCore.open();
    } on CoreLibraryNotFound catch (e) {
      openError = e.toString();
    } on ArgumentError catch (e) {
      openError = 'engine library unusable: $e';
    }
  });

  test('wipe zeroes a path and toString never shows it', () {
    final LandmarkFeature f = LandmarkFeature(
      kind: LandmarkKind.leaf,
      ladderIndex: 3,
      bottom: 40,
      seedRe: 1,
      seedIm: 2,
      barycentreRe: 3,
      barycentreIm: 4,
      bboxReMin: 5,
      bboxReMax: 6,
      bboxImMin: 7,
      bboxImMax: 8,
      cellCount: 9,
      cellRaw: 10,
      cellsOriginRe: 11,
      cellsOriginIm: 12,
      cellsWidth: 2,
      cellsHeight: 1,
      cells: Uint8List.fromList(<int>[1, 1]),
    );
    final LandmarkPath path = LandmarkPath(
      version: '0.1.0',
      stops: <LandmarkFeature>[f],
      hops: Int64List.fromList(<int>[42]),
    );
    expect(path.toString(), isNot(contains('40')));
    expect(f.toString(), 'LandmarkFeature(<redacted>)');
    path.wipe();
    expect(<int>[f.bottom, f.barycentreRe, f.cellRaw, f.cellsWidth], <int>[0, 0, 0, 0]);
    expect(f.cells, <int>[0, 0]);
    expect(path.hops, <int>[0]);
  });

  test('the plain board matches the frozen vector', () async {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine not available: $openError');
      return;
    }
    final String version = c.bindings.landmarkPathVersion();
    final File file = File('../great-wall-core/burning_ship/test_vectors/'
        'landmark-v$version/landmark_plain.json');
    if (!file.existsSync()) {
      markTestSkipped('no vector at ${file.path}');
      return;
    }
    final Map<String, dynamic> doc =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(doc['version'], version);
    final Map<String, dynamic> params = doc['params'] as Map<String, dynamic>;
    final LandmarkParams p = c.landmarkParams;
    expect(
      <int>[p.floodCells, p.seedGrid, p.shells, p.keep, p.metricFracBits],
      <dynamic>[
        params['flood_cells'],
        params['seed_grid'],
        params['shells'],
        params['keep'],
        params['metric_frac_bits'],
      ],
      reason: 'the vector was frozen under the engine defaults',
    );
    final Map<String, dynamic> board = doc['board'] as Map<String, dynamic>;
    final Map<String, dynamic> leaf = doc['leaf'] as Map<String, dynamic>;
    final List<dynamic> rect = leaf['rect'] as List<dynamic>;

    final LandmarkPath? path = await c.landmarkPath(
      leafRect: FixedRect(
        reMin: rect[0] as int,
        reMax: rect[1] as int,
        imMin: rect[2] as int,
        imMax: rect[3] as int,
      ),
      path: leaf['path'] as String,
      o: board['o'] as int,
      p: board['p'] as int,
      q: board['q'] as int,
    );
    expect(path, isNotNull);
    final List<dynamic> stops = doc['stops'] as List<dynamic>;
    expect(path!.stops.length, stops.length);
    const List<String> kinds = <String>['outer_shell', 'fiord', 'feature', 'leaf'];
    for (int k = 0; k < stops.length; k++) {
      final Map<String, dynamic> want = stops[k] as Map<String, dynamic>;
      final LandmarkFeature got = path.stops[k];
      expect(kinds[got.kind.index], want['kind'], reason: 'stop $k kind');
      expect(
        <int>[
          got.ladderIndex,
          got.bottom,
          got.seedRe,
          got.seedIm,
          got.barycentreRe,
          got.barycentreIm,
          got.bboxReMin,
          got.bboxReMax,
          got.bboxImMin,
          got.bboxImMax,
          got.cellCount,
          got.cellRaw,
          got.cellsOriginRe,
          got.cellsOriginIm,
          got.cellsWidth,
          got.cellsHeight,
        ],
        <dynamic>[
          want['ladder_index'],
          want['bottom'],
          ...want['seed'] as List<dynamic>,
          ...want['barycentre'] as List<dynamic>,
          ...want['bbox'] as List<dynamic>,
          want['cell_count'],
          want['cell'],
          ...want['cells_origin'] as List<dynamic>,
          want['cells_w'],
          want['cells_h'],
        ],
        reason: 'stop $k',
      );
      expect(crypto.sha256.convert(got.cells).toString(), want['cells_sha256'],
          reason: 'stop $k cells');
    }
    expect(path.hops, doc['hops']);
    path.wipe();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
