import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';

/// Tests for the **streamed, checkpointable orbit advance**
/// ([GreatWallCore.startOrbitAdvance] / [GreatWallCore.resumeOrbitAdvance]).
///
/// `bs_orbit_advance` runs the commitment and all `D` memory-hard passes inside
/// one uninterruptible FFI call. The streamed form decomposes it into the engine
/// primitives it is built from —
///
///     K_i = bs_master_secret(o_i, Sh_i);  d = K_i
///     repeat D times: d = bs_argon2_single(d, profile)   // emit (pass, d)
///     o_{i+1} = d
///
/// — which buys a progress bar, a per-pass checkpoint and a cancel. That is only
/// legitimate if it is **byte-identical** to the one-shot call, so the frozen
/// vectors below pin it. They were produced by driving the built engine's C ABI
/// directly (`bs_orbit_advance` vs `bs_master_secret` + `bs_argon2_single`) and
/// agreeing at `D = 1` and `D = 2`.
///
/// The vector tests run **real Argon2d at the Basic profile — 1 GiB and roughly
/// 35 s per pass**, so they are opt-in: set `GW_SLOW_TESTS=1`. Everything else
/// here is cheap and always runs (given the engine).
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
    } on StateError catch (e) {
      openError = 'engine ABI mismatch: $e';
    }
  });

  final bool slow = Platform.environment['GW_SLOW_TESTS'] == '1';

  // The pinned inputs.
  final Uint8List oI = Uint8List.fromList(List<int>.generate(32, (int i) => i));
  final Uint8List sh =
      Uint8List.fromList(List<int>.generate(16, (int i) => (i * 7 + 3) & 0xFF));

  // The pinned outputs, Basic profile.
  const String kHex =
      'e1615c9eee2bf22e50388c9b9966ef2e03ac3077ca5ccca9feab0ede2fba39db';
  const String pass1Hex =
      'ef3c7fdd8e7c45d3a06cd99dabf51194156162a6bea386597f72d89faa48d542';
  const String pass2Hex =
      '0552a2ec9922f56e5fc2133fd622970c199cf66d3d30ac4d14ed536335d50a14';

  String hex(Uint8List b) =>
      b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

  Uint8List unhex(String s) => Uint8List.fromList(<int>[
        for (int i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ]);

  group('pass-through (D == 0)', () {
    test('yields o_next == K_i and reports one completed step', () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final List<(int, int)> progress = <(int, int)>[];
      final List<(int, String)> checkpoints = <(int, String)>[];
      final OrbitAdvanceJob job = await c.startOrbitAdvance(
        Uint8List.fromList(oI),
        Uint8List.fromList(sh),
        steps: 0,
        onProgress: (int done, int total) => progress.add((done, total)),
        onCheckpoint: (int done, Uint8List d) =>
            checkpoints.add((done, hex(d))),
      );
      final ({Uint8List k, Uint8List next}) r = await job.result;
      expect(hex(r.k), hex(r.next),
          reason: 'zero memory-hard passes means o_{i+1} == K_i');
      expect(progress, <(int, int)>[(1, 1)]);
      expect(checkpoints.single.$1, 1);
      // The commitment is cheap H, so it is pinned even in the fast suite.
      expect(hex(r.k), kHex);
    });

    test('the checkpoint hand-off is a copy, not the returned K_i', () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      Uint8List? handed;
      final OrbitAdvanceJob job = await c.startOrbitAdvance(
        Uint8List.fromList(oI),
        Uint8List.fromList(sh),
        steps: 0,
        onCheckpoint: (int _, Uint8List d) => handed = d,
      );
      final ({Uint8List k, Uint8List next}) r = await job.result;
      // The facade wipes its hand-off copy after the callback returns; the
      // result must be unaffected by that.
      expect(handed, isNotNull);
      expect(handed!.every((int b) => b == 0), isTrue,
          reason: 'the hand-off copy is zeroed once handed over');
      expect(hex(r.k), kHex, reason: 'the returned K_i must survive intact');
    });
  });

  group('resume', () {
    test('a checkpoint at or past the end completes without new work',
        () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      // No FFI and no Argon2 on this path: the checkpoint already holds o_next.
      final Uint8List k = unhex(kHex);
      final Uint8List done = unhex(pass2Hex);
      final OrbitAdvanceJob job = await c.resumeOrbitAdvance(
        k,
        done,
        fromPass: 2,
        steps: 2,
      );
      final ({Uint8List k, Uint8List next}) r = await job.result;
      expect(hex(r.k), kHex);
      expect(hex(r.next), pass2Hex);
    });
  });

  group('frozen vectors (real Argon2d, Basic profile)', () {
    // ~35 s and 1 GiB per pass; 3 passes across the two tests.
    const Timeout long = Timeout(Duration(minutes: 30));

    test('streamed D=2 matches the one-shot advance, pass by pass', () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      if (!slow) {
        markTestSkipped('set GW_SLOW_TESTS=1 (2 x 1 GiB Argon2d passes)');
        return;
      }
      final List<(int, String)> checkpoints = <(int, String)>[];
      final List<(int, int)> progress = <(int, int)>[];
      final OrbitAdvanceJob job = await c.startOrbitAdvance(
        Uint8List.fromList(oI),
        Uint8List.fromList(sh),
        steps: 2,
        onProgress: (int done, int total) => progress.add((done, total)),
        onCheckpoint: (int done, Uint8List d) =>
            checkpoints.add((done, hex(d))),
      );
      final ({Uint8List k, Uint8List next}) r = await job.result;

      expect(hex(r.k), kHex, reason: 'commitment matches bs_orbit_advance');
      expect(hex(r.next), pass2Hex, reason: 'o_next matches bs_orbit_advance');
      // Every intermediate is observable — this is what makes a halt cheap.
      expect(checkpoints, <(int, String)>[(1, pass1Hex), (2, pass2Hex)]);
      expect(progress, <(int, int)>[(1, 2), (2, 2)]);
      // The commitment is NOT counted as a memory-hard pass.
      expect(progress.first.$1, 1);
    }, timeout: long);

    test('resuming from pass 1 lands on the same o_next', () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      if (!slow) {
        markTestSkipped('set GW_SLOW_TESTS=1 (1 x 1 GiB Argon2d pass)');
        return;
      }
      // Exactly the state a halt after pass 1 would have preserved.
      final OrbitAdvanceJob job = await c.resumeOrbitAdvance(
        unhex(kHex),
        unhex(pass1Hex),
        fromPass: 1,
        steps: 2,
      );
      final ({Uint8List k, Uint8List next}) r = await job.result;
      expect(hex(r.next), pass2Hex,
          reason: 'a resumed advance equals an uninterrupted one');
      expect(hex(r.k), kHex,
          reason: 'K_i is carried through, never recomputed from wiped inputs');
    }, timeout: long);
  });
}
