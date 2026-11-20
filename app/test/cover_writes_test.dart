import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/cover_writes.dart';

/// Cover writes: the setup file rewritten with its own bytes at random times.
void main() {
  test('a rewrite keeps the bytes and leaves no temporary file', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gw-cover');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File f = File('${dir.path}/setup.gw')
      ..writeAsBytesSync(<int>[1, 2, 3, 250]);
    await rewriteSame(f.path);
    expect(f.readAsBytesSync(), <int>[1, 2, 3, 250]);
    expect(File('${f.path}.tmp').existsSync(), isFalse);
    // No file, nothing written.
    await rewriteSame('${dir.path}/none.gw');
    expect(File('${dir.path}/none.gw').existsSync(), isFalse);
  });

  test('delays are random, never below the minimum, around the mean', () {
    final CoverWrites w = CoverWrites(
      write: () async {},
      random: math.Random(7),
      mean: const Duration(minutes: 30),
      min: const Duration(minutes: 1),
    );
    const int n = 2000;
    final List<Duration> d = <Duration>[for (int i = 0; i < n; i++) w.nextDelay()];
    expect(d.every((Duration x) => x >= const Duration(minutes: 1)), isTrue);
    expect(d.toSet().length, greaterThan(n * 9 ~/ 10));
    final double meanMin =
        d.fold<int>(0, (int s, Duration x) => s + x.inSeconds) / n / 60;
    expect(meanMin, closeTo(30, 3));
  });
}
