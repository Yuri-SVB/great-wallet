import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/core/orbit_protocol.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';
import 'package:great_wallet_app/src/setup/orbit_vault.dart';
import 'package:great_wallet_app/src/setup/setup_crypto.dart';
import 'package:great_wallet_app/src/setup/setup_vault.dart';

/// Phase-1 tests for the **settled orbit provisional key**: the encrypted
/// envelope it rides in, and the capture → seal → open → restore algebra that
/// rebuilds a setup from it *without a single Argon2 advance*
/// (`next-steps/orbit-save-load-and-cpnf-rederivation-plan.md` §3.7).
///
/// Two layers, mirroring the rest of this suite:
///  1. **Envelope** (pure Dart, always runs): the file is opaque — no cleartext
///     coordinate, a one-byte flip anywhere in the ciphertext fails, a wrong key
///     fails, and a chain vault and an orbit vault never load as each other.
///  2. **Restore algebra** (needs the engine; skips with a reason otherwise):
///     an orbit built stage-by-stage exactly as `setup_screen.dart` builds it —
///     placed points encoded under `orbitParams(o_i, slot-1)`, `Sh_i`
///     interpolated at abscissa = slot index, `K_i = H(o_i ‖ Sh_i)` — is
///     captured into an [OrbitVault], sealed, opened, and rebuilt from the file
///     alone. Every `K_i` must come back identical and every unplaced slot must
///     *regenerate*, never having been stored.
///
/// Scope note: the screen's `_exportOrbitVault` / `_restoreOrbitVault` are
/// private `State` members, so layer 2 reproduces their field layout rather than
/// calling them. Driving the real screen needs a widget test with the engine
/// linked, and that gap is the one the plan's §7 verification note already
/// flags — this file narrows it to the wiring, not the protocol.
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

  // A 128-bit key supplied by the test, so a seal is deterministic apart from
  // the envelope's random salt/nonce.
  final Uint8List testKey =
      Uint8List.fromList(List<int>.generate(16, (int i) => 0xA0 + i));
  final Uint8List wrongKey =
      Uint8List.fromList(List<int>.generate(16, (int i) => 0x5A + i));

  OrbitVault envelopeVault() => OrbitVault(
        sigma: 'C0FFEE0123456789',
        iterations: 3,
        profile: Argon2Profile.basic,
        stages: <OrbitVaultStage>[
          OrbitVaultStage(
            required: 2,
            orbit: null,
            points: <OrbitVaultPoint>[
              OrbitVaultPoint(slot: 1, reRaw: 111222333, imRaw: 444555666),
              OrbitVaultPoint(slot: 2, reRaw: 777888999, imRaw: 121212121),
            ],
          ),
          OrbitVaultStage(
            required: 2,
            orbit: <int>[for (int i = 0; i < 32; i++) 0x40 + i],
            points: <OrbitVaultPoint>[
              OrbitVaultPoint(slot: 1, reRaw: 313131313, imRaw: 989898989),
              OrbitVaultPoint(slot: 3, reRaw: 565656565, imRaw: 434343434),
            ],
          ),
        ],
      );

  group('envelope', () {
    // Argon2id (64 MiB, t=3) runs once per seal and once per open, and this
    // group does a handful — well past the 30 s default.
    const Timeout slow = Timeout(Duration(minutes: 10));

    test('round-trips through seal/open and leaks nothing in cleartext',
        () async {
      final OrbitVault vault = envelopeVault();
      final SealedVault sealed = await SetupCrypto.sealPayload(
        vault.toJson(),
        providedKey: testKey,
      );
      final String onDisk = utf8.decode(sealed.fileBytes);

      // The envelope's cleartext is exactly its own header — the payload
      // contributes nothing outside `ct`, so there is no field to leak from.
      final Map<String, dynamic> env =
          jsonDecode(onDisk) as Map<String, dynamic>;
      expect(env.keys.toSet(),
          <String>{'f', 'v', 'kdf', 'cipher', 'nonce', 'ct', 'tag'});

      // And nothing coercion-relevant survives in the clear: not σ, not a
      // single raw coordinate, not the payload's own field names.
      for (final String needle in <String>[
        'sigma',
        'points',
        'orbit',
        vault.sigma,
      ]) {
        expect(onDisk.contains(needle), isFalse,
            reason: '"$needle" must not appear in cleartext');
      }
      for (final OrbitVaultStage s in vault.stages) {
        for (final OrbitVaultPoint p in s.points) {
          expect(onDisk.contains('${p.reRaw}'), isFalse,
              reason: 'a placed coordinate must not appear in cleartext');
          expect(onDisk.contains('${p.imRaw}'), isFalse,
              reason: 'a placed coordinate must not appear in cleartext');
        }
      }

      final OrbitVault back = OrbitVault.fromJson(
          await SetupCrypto.openPayload(sealed.fileBytes, testKey));
      expect(back.sigma, vault.sigma);
      expect(back.iterations, vault.iterations);
      expect(back.profile, vault.profile);
      expect(back.stages.length, 2);
      expect(back.stages[0].orbit, isNull);
      expect(back.stages[1].orbit, hasLength(32));
      expect(back.stages[1].points[1].slot, 3);
      expect(back.stages[1].points[1].reRaw, 565656565);
    }, timeout: slow);

    test('a wrong key and a one-byte flip both fail to open', () async {
      final SealedVault sealed = await SetupCrypto.sealPayload(
        envelopeVault().toJson(),
        providedKey: testKey,
      );

      await expectLater(
        SetupCrypto.openPayload(sealed.fileBytes, wrongKey),
        throwsFormatException,
      );

      // Flip one bit inside the base64 ciphertext. GCM authenticates the whole
      // payload, so a doctored o_i or coordinate is as unopenable as a wrong
      // key — which is exactly why restore does no re-derivation integrity
      // check of its own.
      final Map<String, dynamic> env = jsonDecode(utf8.decode(sealed.fileBytes))
          as Map<String, dynamic>;
      final Uint8List ct = base64.decode(env['ct'] as String);
      ct[ct.length ~/ 2] ^= 0x01;
      env['ct'] = base64.encode(ct);
      final Uint8List tampered =
          Uint8List.fromList(utf8.encode(jsonEncode(env)));

      await expectLater(
        SetupCrypto.openPayload(tampered, testKey),
        throwsFormatException,
      );
    }, timeout: slow);
  });

  group('chain / orbit discrimination', () {
    // Payload-level, so no Argon2: this is the check `_openVaultFile` makes
    // after decrypting, and both directions must fail rather than misread.
    test('an orbit payload does not load as a legacy chain vault', () {
      expect(() => SetupVault.fromJson(envelopeVault().toJson()),
          throwsFormatException);
    });

    test('a legacy chain payload does not load as an orbit vault', () {
      final SetupVault chain = SetupVault(
        text: 'SALT-1',
        iterations: 7,
        profile: Argon2Profile.basic,
        stages: <VaultStage>[
          VaultStage(o: 1, p: 2, q: 3, reRaw: 4, imRaw: 5),
        ],
      );
      expect(() => OrbitVault.fromJson(chain.toJson()), throwsFormatException);
    });
  });

  group('capture / restore algebra', () {
    // Canonical engine params (what the screen encodes with), so this is the
    // real bijection, not a fast-params stand-in. A handful of encodes.
    const Timeout slow = Timeout(Duration(minutes: 10));

    test('restores every K_i from the file alone, with no advance', () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final OrbitProtocol protocol = OrbitProtocol(c);

      // The single memory-hard step, counted. The whole point of the vault is
      // that a restore never reaches it: the file carries o_1 verbatim.
      int advances = 0;
      Uint8List advance(Uint8List o, Uint8List shBytes) {
        advances++;
        return Uint8List.fromList(crypto.sha256
            .convert(<int>[...o, ...shBytes, ...utf8.encode('ORBIT-ADVANCE')])
            .bytes);
      }

      // --- build the orbit exactly as setup_screen.dart does ----------------
      const String sigmaHex = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';
      final Uint8List sigma = _parseHex(sigmaHex)!;
      // Which slots the holder placed at each stage. Deliberately not 1..r_i:
      // every slot is operationally equal, and the vault must carry whichever
      // ones were actually used.
      const List<List<int>> placedSlots = <List<int>>[
        <int>[1, 2],
        <int>[1, 3],
      ];
      const List<int> requiredFractals = <int>[2, 2];
      final List<List<int>> chunks = <List<int>>[
        _chunk(0x13572468),
        _chunk(0x2468ACE0),
        _chunk(0x0F1E2D3C),
        _chunk(0x5A5A1234),
      ];

      final List<Uint8List> orbits = <Uint8List>[c.orbitRoot(sigma)];
      final List<Uint8List> masters = <Uint8List>[];
      final List<List<int>> polys = <List<int>>[];
      final List<List<({int reRaw, int imRaw})>> points =
          <List<({int reRaw, int imRaw})>>[];
      int chunkAt = 0;
      for (int i = 0; i < placedSlots.length; i++) {
        final List<({int reRaw, int imRaw})> stagePoints =
            <({int reRaw, int imRaw})>[];
        final List<int> xs = <int>[];
        final List<int> ys = <int>[];
        for (final int slot in placedSlots[i]) {
          final List<int> bits = chunks[chunkAt++];
          final ({int o, int p, int q}) prm =
              protocol.orbitParams(orbits[i], slot - 1);
          final EncodedPoint pt = c
              .encodeStage(List<int>.of(bits), o: prm.o, p: prm.p, q: prm.q)
              .first;
          stagePoints.add((reRaw: pt.reRaw, imRaw: pt.imRaw));
          xs.add(slot);
          ys.add(OrbitProtocol.bitsToU32(bits));
        }
        points.add(stagePoints);
        final List<int> sh = c.shamirInterp(xs, ys);
        polys.add(sh);
        final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
        masters.add(c.masterSecret(orbits[i], shBytes));
        if (i + 1 < placedSlots.length) {
          orbits.add(advance(orbits[i], shBytes));
        }
      }
      expect(advances, 1, reason: 'one advance to reach the second stage');

      // --- capture (the _exportOrbitVault field layout) ----------------------
      final OrbitVault captured = OrbitVault(
        sigma: sigmaHex,
        iterations: 4,
        profile: Argon2Profile.basic,
        stages: <OrbitVaultStage>[
          for (int i = 0; i < placedSlots.length; i++)
            OrbitVaultStage(
              required: requiredFractals[i],
              orbit: i == 0 ? null : List<int>.of(orbits[i]),
              points: <OrbitVaultPoint>[
                for (int k = 0; k < placedSlots[i].length; k++)
                  OrbitVaultPoint(
                    slot: placedSlots[i][k],
                    reRaw: points[i][k].reRaw,
                    imRaw: points[i][k].imRaw,
                  ),
              ],
            ),
        ],
      );
      // Only the placed slots ride in the file; the rest re-derive on load.
      for (int i = 0; i < placedSlots.length; i++) {
        expect(captured.stages[i].points.length, requiredFractals[i]);
      }
      expect(captured.stages[0].orbit, isNull,
          reason: 'o_0 re-derives from σ and must not be stored');

      final SealedVault sealed = await SetupCrypto.sealPayload(
        captured.toJson(),
        providedKey: testKey,
      );
      final OrbitVault loaded = OrbitVault.fromJson(
          await SetupCrypto.openPayload(sealed.fileBytes, testKey));

      // --- restore (the _restoreOrbitVault walk) ----------------------------
      final int advancesBeforeRestore = advances;
      final Uint8List restoredSigma = _parseHex(loaded.sigma)!;
      for (int i = 0; i < loaded.stages.length; i++) {
        final OrbitVaultStage stage = loaded.stages[i];
        final Uint8List oI = i == 0
            ? c.orbitRoot(restoredSigma)
            : Uint8List.fromList(stage.orbit!);
        expect(oI, orbits[i], reason: 'stage $i: o_i comes back byte-identical');

        final List<int> xs = <int>[];
        final List<int> ys = <int>[];
        for (final OrbitVaultPoint p in stage.points) {
          final ({int o, int p, int q}) prm =
              protocol.orbitParams(oI, p.slot - 1);
          final CoreDecodeResult d = c.decodePoint(
              reRaw: p.reRaw, imRaw: p.imRaw, o: prm.o, p: prm.p, q: prm.q);
          expect(d.valid, isTrue,
              reason: 'stage $i slot ${p.slot}: the stored point must decode');
          xs.add(p.slot);
          ys.add(OrbitProtocol.bitsToU32(d.bits));
        }
        final List<int> sh = c.shamirInterp(xs, ys);
        final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
        expect(c.masterSecret(oI, shBytes), masters[i],
            reason: 'stage $i: K_i is identical to the pre-save one');

        // The unplaced slots were never in the file — they come back by
        // evaluating the re-interpolated Sh_i at their own slot index.
        final Set<int> stored =
            <int>{for (final OrbitVaultPoint p in stage.points) p.slot};
        for (int slot = 1; slot <= 6; slot++) {
          if (stored.contains(slot)) continue;
          expect(c.shamirEval(sh, slot), c.shamirEval(polys[i], slot),
              reason: 'stage $i slot $slot: the derived share regenerates');
        }
      }

      expect(advances, advancesBeforeRestore,
          reason: 'a restore runs no memory-hard advance at all');
    }, timeout: slow);
  });
}

/// 32 bits of [value], MSB first — the `bitsToU32` convention.
List<int> _chunk(int value) =>
    <int>[for (int i = 31; i >= 0; i--) (value >> i) & 1];

/// The screen's σ parser (`setup_screen.dart` `_parseHex`).
Uint8List? _parseHex(String s) {
  final String h = s.replaceAll(RegExp(r'\s'), '');
  if (h.isEmpty || h.length.isOdd) return null;
  final Uint8List out = Uint8List(h.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    final int? b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}
