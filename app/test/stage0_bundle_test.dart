import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart' show Argon2Profile;
import 'package:great_wallet_app/src/setup/fact_cards.dart';
import 'package:great_wallet_app/src/setup/stage0_bundle.dart';

/// Stage 0's bundle, with a cheap stand-in for the hardening: SHA-512 chained
/// [passes] times, salted by the profile, so a wrong `m` or `D` gives another
/// key just as Argon2 would.
void main() {
  int calls = 0;
  Future<Uint8List> harden(
      Uint8List input, Argon2Profile profile, int passes) async {
    calls++;
    List<int> x = <int>[profile.value, ...input];
    for (int i = 0; i < passes; i++) {
      x = crypto.sha512.convert(x).bytes;
    }
    return Uint8List.fromList(x);
  }

  final Uint8List sh = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
  final List<Uint8List> theta = <Uint8List>[
    for (int j = 1; j <= kMapsPerStage; j++) Uint8List(64)..fillRange(0, 64, j),
  ];
  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 1));
  final MemSchedule schedule = MemSchedule(clock);
  const Cues cues = Cues(rhoNum: 1, rhoDen: 2, exponent: 2, visible: 0);
  final List<MemCard> cards = <MemCard>[
    schedule.grade(MemCard.map(0, 1, cues), Grade.good),
    MemCard.map(0, 4, cues),
    MemCard.fact(selectionFact(0)),
  ];
  const String sigma = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';

  Future<Uint8List> seal({List<MemCard>? with_, int passes = 3}) =>
      Stage0Bundle.seal(
        contents: Stage0Contents(
            sigma: sigma, cards: with_ ?? cards, studied: const <int>[1, 4]),
        shBytes: sh,
        profile: Argon2Profile.basic,
        passes: passes,
        theta: theta,
        harden: harden,
        random: Random(7),
      );

  test('opens with Sh₀ and gives back σ, the records and the maps studied',
      () async {
    final Uint8List file = await seal();
    final Stage0Contents back = await Stage0Bundle.open(file, sh, harden);
    expect(back.sigma, sigma);
    expect(back.studied, <int>[1, 4]);
    expect(back.cards.map((MemCard c) => c.id),
        cards.map((MemCard c) => c.id));
    expect(back.cards.first.repetitions, 1);
  });

  test('the header is in the clear: m, D, the salt and θ₀', () async {
    final Uint8List file = await seal(passes: 5);
    final Stage0Header h = Stage0Bundle.header(file);
    expect(h.profile, Argon2Profile.basic);
    expect(h.passes, 5);
    expect(h.salt, hasLength(16));
    expect(h.theta.map((Uint8List t) => t.first),
        <int>[for (int j = 1; j <= kMapsPerStage; j++) j]);
    expect(Stage0Bundle.isBundle(file), isTrue);
    expect(Stage0Bundle.isBundle(Uint8List.fromList(<int>[1, 2, 3])), isFalse);
  });

  test('the key is Sh₀ hardened D times: wrong points do not open it',
      () async {
    final Uint8List file = await seal();
    calls = 0;
    final Uint8List wrong = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 9]);
    await expectLater(
        Stage0Bundle.open(file, wrong, harden), throwsFormatException);
    expect(calls, 1, reason: 'one hardened derivation per guess');
  });

  test('an altered header does not open', () async {
    final Map<String, dynamic> json =
        jsonDecode(utf8.decode(await seal())) as Map<String, dynamic>;
    final List<Object?> t = List<Object?>.from(json['theta'] as List<Object?>);
    t[0] = 'ff' * 64;
    json['theta'] = t;
    final Uint8List altered = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    await expectLater(
        Stage0Bundle.open(altered, sh, harden), throwsFormatException);
  });

  test('its size says nothing of the cards inside', () async {
    final int one = (await seal(with_: cards.sublist(0, 1))).length;
    final int all = (await seal()).length;
    expect(one, all);
  });

  test('the default D aims at about two minutes', () {
    expect(Stage0Bundle.defaultPasses(2), 60);
    expect(Stage0Bundle.defaultPasses(0.7), 172);
    expect(Stage0Bundle.defaultPasses(500), 1);
  });
}
