import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
          const VaultEntry(id: 'e1', label: 'Mail', secret: 'hunter2'),
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
