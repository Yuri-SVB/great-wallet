import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show FakeClock, Grade, MemCard, MemSchedule;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/formosa/pass_vault.dart';

/// F4's vault: k-of-n over raw sentences, by one wrapping per k-subset.
/// Argon2id runs for real, at light settings.
void main() {
  const KdfParams light =
      KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);
  final Random rng = Random(4);
  List<int> sentence() =>
      <int>[for (int i = 0; i < kSentenceBits; i++) rng.nextInt(2)];
  final List<VaultSlot> slots = <VaultSlot>[
    for (int id = 1; id <= 6; id++) VaultSlot(id, 'theme$id'),
  ];
  final Map<int, List<int>> sentences = <int, List<int>>{
    for (final VaultSlot s in slots) s.id: sentence(),
  };
  int derivations = 0;
  Future<Uint8List> counted(Uint8List p, Uint8List s, KdfParams k) {
    derivations++;
    return argon2idKdf(p, s, k);
  }

  Future<Uint8List> make() async => (await PassVault.create(
        slots: slots,
        k: 4,
        kdf: light,
        contents: VaultContents(sentences: sentences, entries: <VaultEntry>[
          const VaultEntry(
              id: 'e1', label: 'Mail', secret: 'hunter2', login: 'alice'),
        ]),
        derive: counted,
        random: Random(1),
      ))
          .$1;

  test('one wrapping per 4-subset of 6: C(6, 4) = 15 derivations', () async {
    derivations = 0;
    final Uint8List file = await make();
    expect(derivations, 15);
    final VaultHeader h = PassVault.header(file);
    expect(h.n, 6);
    expect(h.k, 4);
    expect(h.wraps, hasLength(15));
    expect(PassVault.isVault(file), isTrue);
  });

  test('any 4 sentences open it, with one derivation', () async {
    final Uint8List file = await make();
    derivations = 0;
    final Opened o = await PassVault.open(
        file,
        <int, List<int>>{
          for (final int id in <int>[2, 3, 5, 6]) id: sentences[id]!
        },
        derive: counted);
    expect(derivations, 1);
    expect(o.wrong, isEmpty);
    expect(o.vault.contents.entries.single.secret, 'hunter2');
    expect(o.vault.contents.entries.single.login, 'alice');
  });

  test('a folder is a normalised path, kept in the file', () {
    expect(normalFolder(' Work / /Mail/ '), 'Work/Mail');
    expect(normalFolder(' / '), isEmpty);
    const VaultEntry e = VaultEntry(
        id: 'e1', label: 'Mail', secret: 'hunter2', folder: 'Work/Mail');
    expect(VaultEntry.fromJson(e.toJson()).folder, 'Work/Mail');
    expect(
        VaultEntry.fromJson(<String, dynamic>{
          ...e.toJson(),
          'folder': 'Work//Mail ',
        }).folder,
        'Work/Mail');
  });

  test('an entry saved before logins reads with none', () {
    final VaultEntry e = VaultEntry.fromJson(
        <String, dynamic>{'id': 'e1', 'label': 'Mail', 'secret': 'hunter2'});
    expect(e.login, isEmpty);
    expect(e.toJson().containsKey('login'), isFalse);
  });

  test('3 do not; 5 with one wrong still open it, and name it', () async {
    final Uint8List file = await make();
    await expectLater(
        PassVault.open(
            file,
            <int, List<int>>{
              for (final int id in <int>[1, 2, 3]) id: sentences[id]!
            },
            derive: counted),
        throwsFormatException);
    final List<int> typo = List<int>.of(sentences[1]!)..[0] ^= 1;
    final Opened o = await PassVault.open(
        file,
        <int, List<int>>{
          1: typo,
          for (final int id in <int>[2, 3, 4, 5]) id: sentences[id]!,
        },
        derive: counted);
    expect(o.wrong, <int>[1]);
  });

  test('a save re-encrypts without deriving; the entries survive', () async {
    final Uint8List file = await make();
    final Opened o = await PassVault.open(
        file,
        <int, List<int>>{
          for (final int id in <int>[1, 2, 3, 4]) id: sentences[id]!
        },
        derive: counted);
    o.vault.contents.entries.add(
        const VaultEntry(id: 'e2', label: 'FT wallet', secret: 'seed words'));
    derivations = 0;
    final Uint8List saved = await PassVault.save(o.vault);
    expect(derivations, 0);
    final Opened again = await PassVault.open(
        saved,
        <int, List<int>>{
          for (final int id in <int>[3, 4, 5, 6]) id: sentences[id]!
        },
        derive: counted);
    expect(again.vault.contents.entries.map((VaultEntry e) => e.label),
        <String>['Mail', 'FT wallet']);
  });

  test('rewrapped for 5 sentences, 3 of them: the retired one no longer opens',
      () async {
    final Uint8List file = await make();
    final Opened o = await PassVault.open(
        file,
        <int, List<int>>{
          for (final int id in <int>[1, 2, 3, 4]) id: sentences[id]!
        },
        derive: counted);
    final List<VaultSlot> kept =
        slots.where((VaultSlot s) => s.id != 6).toList();
    final (Uint8List rewrapped, OpenVault _) =
        await PassVault.rewrap(o.vault, slots: kept, k: 3, derive: counted);
    expect(PassVault.header(rewrapped).wraps, hasLength(10)); // C(5, 3)
    final Opened back = await PassVault.open(
        rewrapped,
        <int, List<int>>{
          for (final int id in <int>[1, 2, 5]) id: sentences[id]!
        },
        derive: counted);
    expect(back.vault.contents.entries.single.label, 'Mail');
    await expectLater(
        PassVault.open(
            rewrapped,
            <int, List<int>>{
              for (final int id in <int>[1, 2, 6]) id: sentences[id]!
            },
            derive: counted),
        throwsFormatException);
  });

  test('each sentence has a card in the clear; a rewrap keeps the kept ones',
      () async {
    final Uint8List file = await make();
    final VaultHeader h = PassVault.header(file);
    expect(h.cards.map((MemCard c) => c.factId),
        <String>[for (int id = 1; id <= 6; id++) sentenceFact(id)]);
    final Opened o = await PassVault.open(
        file,
        <int, List<int>>{
          for (final int id in <int>[1, 2, 3, 4]) id: sentences[id]!
        },
        derive: counted);
    final MemSchedule schedule = MemSchedule(FakeClock(DateTime.utc(2026)));
    final MemCard graded =
        schedule.grade(o.vault.header.cardOf(1)!, Grade.good);
    o.vault.header = o.vault.header.withCards(<MemCard>[
      for (final MemCard c in o.vault.header.cards)
        c.factId == graded.factId ? graded : c,
    ]);
    final List<int> added = sentence();
    o.vault.contents.sentences[7] = added;
    final List<VaultSlot> next = <VaultSlot>[
      ...slots.where((VaultSlot s) => s.id != 6),
      const VaultSlot(7, 'theme7'),
    ];
    final (Uint8List rewrapped, OpenVault v) =
        await PassVault.rewrap(o.vault, slots: next, k: 4, derive: counted);
    final VaultHeader after = PassVault.header(rewrapped);
    expect(after.cardOf(1)!.repetitions, 1, reason: 'kept with its schedule');
    expect(after.cardOf(7)!.repetitions, 0,
        reason: 'a new sentence, a new card');
    expect(after.cardOf(6), isNull, reason: 'retired');
    expect(v.contents.sentences.containsKey(6), isFalse);
    final Opened back = await PassVault.open(
        rewrapped,
        <int, List<int>>{
          for (final int id in <int>[1, 2, 3]) id: sentences[id]!,
          7: added,
        },
        derive: counted);
    expect(back.wrong, isEmpty);
  });

  test('the provisional key opens it alone, until retired under a new data key',
      () async {
    final Uint8List key =
        Uint8List.fromList(List<int>.generate(16, (int i) => 0xA0 + i));
    final Opened o = await PassVault.open(
        await make(),
        <int, List<int>>{
          for (final int id in <int>[1, 2, 3, 4]) id: sentences[id]!
        },
        derive: counted);
    derivations = 0;
    final (Uint8List withKey, OpenVault v) =
        await PassVault.addProvisional(o.vault, key, derive: counted);
    expect(derivations, 1);
    expect(PassVault.header(withKey).provisional, isNotNull);
    expect(
        (await PassVault.openWithKey(withKey, key, derive: counted))
            .contents
            .entries
            .single
            .label,
        'Mail');
    final Uint8List other = Uint8List.fromList(key)..[0] ^= 1;
    await expectLater(PassVault.openWithKey(withKey, other, derive: counted),
        throwsFormatException);

    // A sentence retired: the same data key, so the key still opens it.
    final (Uint8List rewrapped, OpenVault w) = await PassVault.rewrap(v,
        slots: slots.where((VaultSlot s) => s.id != 6).toList(),
        k: 4,
        derive: counted);
    expect((await PassVault.openWithKey(rewrapped, key, derive: counted)),
        isA<OpenVault>());

    // Retired: C(5, 4) wrappings under a new data key; the key opens nothing.
    derivations = 0;
    final (Uint8List retired, OpenVault _) =
        await PassVault.retireProvisional(w, derive: counted);
    expect(derivations, 5);
    expect(PassVault.header(retired).provisional, isNull);
    await expectLater(PassVault.openWithKey(retired, key, derive: counted),
        throwsFormatException);
    final Opened back = await PassVault.open(
        retired,
        <int, List<int>>{
          for (final int id in <int>[2, 3, 4, 5]) id: sentences[id]!
        },
        derive: counted);
    expect(back.vault.contents.entries.single.label, 'Mail');
    expect(
        () => PassVault.addProvisional(back.vault, Uint8List(20),
            derive: counted),
        throwsArgumentError);
  });

  test('the gate\'s T and ε are kept in the clear, through a rewrap', () async {
    final Opened o = await PassVault.open(
        await make(),
        <int, List<int>>{
          for (final int id in <int>[1, 2, 3, 4]) id: sentences[id]!
        },
        derive: counted);
    expect(o.vault.header.gapSeconds, isNull, reason: 'the defaults');
    o.vault.header = o.vault.header
        .withGate(gapSeconds: const Duration(days: 3).inSeconds, epsilon: 1e-3);
    final VaultHeader saved = PassVault.header(await PassVault.save(o.vault));
    expect(saved.gapSeconds, const Duration(days: 3).inSeconds);
    expect(saved.epsilon, 1e-3);
    final (Uint8List rewrapped, OpenVault _) = await PassVault.rewrap(o.vault,
        slots: slots.where((VaultSlot s) => s.id != 6).toList(),
        k: 4,
        derive: counted);
    expect(PassVault.header(rewrapped).epsilon, 1e-3);
    o.vault.header = o.vault.header.withGate();
    expect(PassVault.header(await PassVault.save(o.vault)).epsilon, isNull,
        reason: 'back to the defaults');
  });

  test('the clear part cannot be altered unseen', () async {
    final Map<String, dynamic> json =
        jsonDecode(utf8.decode(await make())) as Map<String, dynamic>;
    (json['slots'] as List<dynamic>)[0] = <String, dynamic>{
      'id': 1,
      'theme': 'other'
    };
    final Uint8List altered = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    await expectLater(
        PassVault.open(
            altered,
            <int, List<int>>{
              for (final int id in <int>[1, 2, 3, 4]) id: sentences[id]!
            },
            derive: counted),
        throwsFormatException);
  });

  test('k below 2 is refused', () {
    expect(
        () => PassVault.create(
            slots: slots,
            k: 1,
            kdf: light,
            contents: VaultContents(sentences: sentences)),
        throwsArgumentError);
  });
}
