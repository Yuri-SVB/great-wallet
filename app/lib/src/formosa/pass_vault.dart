/// F4's vault: a lightweight password manager whose master secret is `n` raw
/// Formosa sentences (33 bits each, no checksum), any `k` of which open it.
///
/// **k-of-n by exhaustive rekeying**, not Shamir: the sentences are
/// independent secrets, and a random data key is wrapped once per `k`-subset
/// of them — C(n, k) wrappings. Each wrapping's key is Argon2id over the whole
/// `k`-tuple: hardening each sentence alone would let an attacker harden each
/// slot's 2³³ candidates once, then try combinations cheaply. So opening costs
/// one derivation, and rewrapping C(n, k).
///
/// No sentence has a check of its own (it would be a 33-bit oracle): a
/// sentence is checked only by opening, then against the vault's copy.
///
/// **The provisional key**, until the sentences graduate: one more wrapping
/// of the data key, under Argon2id over a random 128- or 256-bit key kept
/// outside the app (a QR, a password manager; the Great Wall's own can be
/// reused). It opens the vault alone. Retiring it rewraps every `k`-subset
/// under a new data key, so the retired key opens no later copy.
///
/// The file is JSON. In the clear, as the encryption's associated data: the
/// version, the KDF settings, `k`, the slots (id and theme), the sentences'
/// cards, the wrappings, each labelled by its slots, and the provisional
/// key's wrapping while there is one. Inside, under the data key, padded
/// to a multiple of [PassVault.paddingStep]: the sentences and the entries.
/// No wrench-attack resistance is aimed at (F4 holds less critical secrets),
/// and nothing is time-locked.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show MemCard;
import 'package:cryptography/cryptography.dart';

import '../setup/setup_crypto.dart' show SetupCrypto;

/// Bits in a raw Formosa sentence (formosa's `kRawSentenceBits`).
const int kSentenceBits = 33;

/// The fact id of slot [slot]'s sentence card, and of entry [id]'s card.
String sentenceFact(int slot) => 'sentence:$slot';
String entryFact(String id) => 'entry:$id';

List<Map<String, dynamic>> _cardsJson(List<MemCard> cards) =>
    <Map<String, dynamic>>[for (final MemCard c in cards) c.toJson()];

List<MemCard> _cardsOf(Object? json) {
  if (json == null) return <MemCard>[];
  if (json is! List) throw const FormatException('bad cards');
  return <MemCard>[
    for (final Object? c in json)
      if (c is Map<String, dynamic>)
        MemCard.fromJson(c)
      else
        throw const FormatException('bad cards'),
  ];
}

/// Argon2id settings. The default is RFC 9106's first recommendation
/// (2 GiB, one pass, four lanes), per wrapping.
class KdfParams {
  const KdfParams({
    this.memoryKiB = defaultMemoryKiB,
    this.iterations = defaultIterations,
    this.parallelism = defaultParallelism,
  });

  static const int defaultMemoryKiB = 2 * 1024 * 1024;
  static const int defaultIterations = 1;
  static const int defaultParallelism = 4;

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'm': memoryKiB,
        't': iterations,
        'p': parallelism,
      };

  factory KdfParams.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw const FormatException('bad kdf');
    final Object? m = json['m'], t = json['t'], p = json['p'];
    if (m is! int || t is! int || p is! int || m < 8 * p || t < 1 || p < 1) {
      throw const FormatException('bad kdf');
    }
    return KdfParams(memoryKiB: m, iterations: t, parallelism: p);
  }
}

/// Derives a wrapping key: Argon2id over [password] with [salt]. Injected,
/// so tests run with light settings.
typedef VaultKdf = Future<Uint8List> Function(
    Uint8List password, Uint8List salt, KdfParams params);

/// The default [VaultKdf]: Argon2id (package:cryptography), in a worker
/// isolate — at the default settings it takes seconds.
Future<Uint8List> argon2idKdf(
        Uint8List password, Uint8List salt, KdfParams params) =>
    Isolate.run(() async {
      final SecretKey key = await Argon2id(
        memory: params.memoryKiB,
        iterations: params.iterations,
        parallelism: params.parallelism,
        hashLength: PassVault.keyLength,
      ).deriveKey(secretKey: SecretKey(password), nonce: salt);
      return Uint8List.fromList(await key.extractBytes());
    });

/// A slot of the master secret: its id (stable while it lives) and the
/// Formosa theme its sentence is in.
class VaultSlot {
  const VaultSlot(this.id, this.theme);

  final int id;
  final String theme;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'theme': theme};
}

/// An entry of the manager.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.label,
    required this.secret,
    this.note = '',
    this.mnemonic = '',
  });

  final String id;
  final String label;

  /// What is copied: a password, a seed, anything.
  final String secret;
  final String note;

  /// For a Formosa password, its sentences (the password is their letters).
  final String mnemonic;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'secret': secret,
        if (note.isNotEmpty) 'note': note,
        if (mnemonic.isNotEmpty) 'mnemonic': mnemonic,
      };

  factory VaultEntry.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw const FormatException('bad entry');
    final Object? id = json['id'],
        label = json['label'],
        secret = json['secret'];
    final Object? note = json['note'] ?? '', mnemonic = json['mnemonic'] ?? '';
    if (id is! String ||
        label is! String ||
        secret is! String ||
        note is! String ||
        mnemonic is! String) {
      throw const FormatException('bad entry');
    }
    return VaultEntry(
        id: id, label: label, secret: secret, note: note, mnemonic: mnemonic);
  }
}

/// A wrapping of the data key: its salt, nonce and sealed key.
typedef KeyWrap = ({List<int> salt, List<int> nonce, List<int> sealed});

/// The clear part of a vault file.
class VaultHeader {
  const VaultHeader({
    required this.kdf,
    required this.k,
    required this.slots,
    required this.wraps,
    this.cards = const <MemCard>[],
    this.provisional,
  });

  final KdfParams kdf;
  final int k;
  final List<VaultSlot> slots;

  /// The sentences' cards, one per slot ([sentenceFact]): in the clear, so the
  /// app tells which are due without opening the vault — F4 has no
  /// wrench-attack goal.
  final List<MemCard> cards;

  /// The provisional key's wrapping of the data key, until it is retired.
  final KeyWrap? provisional;

  /// This header with [cards] in place of its own.
  VaultHeader withCards(List<MemCard> cards) => VaultHeader(
      kdf: kdf,
      k: k,
      slots: slots,
      wraps: wraps,
      cards: cards,
      provisional: provisional);

  /// This header with [provisional] in place of its own.
  VaultHeader withProvisional(KeyWrap? provisional) => VaultHeader(
      kdf: kdf,
      k: k,
      slots: slots,
      wraps: wraps,
      cards: cards,
      provisional: provisional);

  /// Slot [slot]'s card, if it has one.
  MemCard? cardOf(int slot) {
    for (final MemCard c in cards) {
      if (c.factId == sentenceFact(slot)) return c;
    }
    return null;
  }

  /// Each wrapping of the data key: its slots (ascending ids), salt, nonce
  /// and sealed key.
  final List<
      ({
        List<int> slots,
        List<int> salt,
        List<int> nonce,
        List<int> sealed
      })> wraps;

  int get n => slots.length;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': PassVault.formatVersion,
        'kdf': kdf.toJson(),
        'k': k,
        'cards': _cardsJson(cards),
        'slots': <Map<String, dynamic>>[
          for (final VaultSlot s in slots) s.toJson()
        ],
        'wraps': <Map<String, dynamic>>[
          for (final w in wraps)
            <String, dynamic>{
              'slots': w.slots,
              'salt': _hex(w.salt),
              'nonce': _hex(w.nonce),
              'key': base64Encode(w.sealed),
            },
        ],
        if (provisional case final KeyWrap p)
          'prov': <String, dynamic>{
            'salt': _hex(p.salt),
            'nonce': _hex(p.nonce),
            'key': base64Encode(p.sealed),
          },
      };

  List<int> get _aad => utf8.encode(jsonEncode(toJson()));
}

/// What the vault holds inside: each slot's sentence (its 33 bits) and the
/// entries.
class VaultContents {
  VaultContents({
    required this.sentences,
    List<VaultEntry>? entries,
    List<MemCard>? cards,
  })  : entries = entries ?? <VaultEntry>[],
        cards = cards ?? <MemCard>[];

  final Map<int, List<int>> sentences;
  final List<VaultEntry> entries;

  /// The entries' cards ([entryFact]), for the entries you memorise.
  final List<MemCard> cards;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sentences': <String, String>{
          for (final MapEntry<int, List<int>> e in sentences.entries)
            '${e.key}': e.value.join(),
        },
        'entries': <Map<String, dynamic>>[
          for (final VaultEntry e in entries) e.toJson(),
        ],
        'cards': _cardsJson(cards),
      };

  factory VaultContents.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw const FormatException('bad vault');
    final Object? sentences = json['sentences'], entries = json['entries'];
    if (sentences is! Map<String, dynamic> || entries is! List) {
      throw const FormatException('bad vault');
    }
    return VaultContents(
      sentences: <int, List<int>>{
        for (final MapEntry<String, dynamic> e in sentences.entries)
          int.parse(e.key): _bits(e.value),
      },
      entries: <VaultEntry>[
        for (final Object? e in entries) VaultEntry.fromJson(e)
      ],
      cards: _cardsOf(json['cards']),
    );
  }
}

/// An open vault: its header, its contents and its data key, held while it
/// is open so a save needs no derivation.
class OpenVault {
  OpenVault(this.header, this.contents, this._dataKey);

  /// Replaced as its cards are graded; a save writes it.
  VaultHeader header;
  final VaultContents contents;
  final SecretKey _dataKey;
}

/// The outcome of opening: the vault, and the slots entered whose sentence is
/// not the vault's (wrong, though the others opened it).
typedef Opened = ({OpenVault vault, List<int> wrong});

/// Create, open and save F4's vault.
abstract final class PassVault {
  static const int formatVersion = 1;

  /// Bytes of the data key and of every wrapping key (AES-256).
  static const int keyLength = 32;

  /// The minimum `k`: two sentences, 66 bits.
  static const int minK = 2;

  /// The padded payload is a multiple of this.
  static const int paddingStep = 64 * 1024;

  static const int _saltLen = 16;
  static const int _nonceLen = 12;
  static const int _tagLen = 16;
  static const int _lengthLen = 4;
  static const int _sentenceBytes = 5; // 33 bits, zero-padded
  static final List<int> _tag = utf8.encode('greatwall-formosa-vault-v1');
  static final List<int> _provisionalTag =
      utf8.encode('greatwall-formosa-vault-v1 provisional');
  static final List<int> _provisionalAad = utf8.encode('provisional');
  static final AesGcm _aes = AesGcm.with256bits();

  /// Every k-subset of [ids] (ascending), in lexicographic order.
  static List<List<int>> subsets(List<int> ids, int k) {
    final List<int> sorted = List<int>.of(ids)..sort();
    final List<List<int>> out = <List<int>>[];
    void pick(int from, List<int> chosen) {
      if (chosen.length == k) {
        out.add(List<int>.of(chosen));
        return;
      }
      for (int i = from; i <= sorted.length - (k - chosen.length); i++) {
        pick(i + 1, <int>[...chosen, sorted[i]]);
      }
    }

    pick(0, <int>[]);
    return out;
  }

  /// The password a wrapping's key derives from: the tag, then each slot's
  /// id and sentence, in ascending id order.
  static Uint8List wrapPassword(
      List<int> slots, Map<int, List<int>> sentences) {
    final BytesBuilder b = BytesBuilder()..add(_tag);
    for (final int id in slots) {
      final List<int> bits = sentences[id]!;
      b
        ..addByte(id >> 8)
        ..addByte(id & 0xFF)
        ..add(_packBits(bits));
    }
    return b.toBytes();
  }

  /// A new vault file: [contents] under a fresh data key, wrapped for every
  /// [k]-subset of [slots].
  static Future<(Uint8List, OpenVault)> create({
    required List<VaultSlot> slots,
    required int k,
    required VaultContents contents,
    KdfParams kdf = const KdfParams(),
    VaultKdf derive = argon2idKdf,
    Random? random,
    void Function(int done, int total)? onProgress,
  }) async {
    final Random rng = random ?? Random.secure();
    final SecretKey dataKey = SecretKey(_bytes(rng, keyLength));
    final VaultHeader header = await _wrapAll(
        slots: slots,
        k: k,
        kdf: kdf,
        sentences: contents.sentences,
        dataKey: dataKey,
        derive: derive,
        rng: rng,
        onProgress: onProgress);
    final OpenVault v = OpenVault(header, contents, dataKey);
    return (await save(v, random: rng), v);
  }

  /// [v] rewrapped for [slots] and [k] (sentences added or retired): every
  /// wrapping anew, the data key kept — and so the provisional key's
  /// wrapping, if any.
  static Future<(Uint8List, OpenVault)> rewrap(
    OpenVault v, {
    required List<VaultSlot> slots,
    required int k,
    VaultKdf derive = argon2idKdf,
    Random? random,
    void Function(int done, int total)? onProgress,
  }) async {
    final Random rng = random ?? Random.secure();
    final VaultHeader header = await _wrapAll(
        slots: slots,
        k: k,
        kdf: v.header.kdf,
        sentences: v.contents.sentences,
        dataKey: v._dataKey,
        derive: derive,
        rng: rng,
        previous: v.header.cards,
        onProgress: onProgress);
    // A retired sentence leaves the vault entirely.
    v.contents.sentences
        .removeWhere((int id, _) => !slots.any((VaultSlot s) => s.id == id));
    final OpenVault next = OpenVault(
        header.withProvisional(v.header.provisional), v.contents, v._dataKey);
    return (await save(next, random: rng), next);
  }

  /// [v] with the provisional [key] (16 or 32 bytes): one more wrapping of
  /// its data key, one derivation. Replaces the key it had, if any.
  static Future<(Uint8List, OpenVault)> addProvisional(
    OpenVault v,
    Uint8List key, {
    VaultKdf derive = argon2idKdf,
    Random? random,
  }) async {
    if (!SetupCrypto.isValidKeyLen(key.length)) {
      throw ArgumentError('a provisional key has 16 or 32 bytes');
    }
    final Random rng = random ?? Random.secure();
    final Uint8List salt = _bytes(rng, _saltLen);
    final Uint8List password = _provisionalPassword(key);
    final Uint8List kek = await derive(password, salt, v.header.kdf);
    password.fillRange(0, password.length, 0);
    final SecretBox box = await _aes.encrypt(await v._dataKey.extractBytes(),
        secretKey: SecretKey(kek),
        nonce: _bytes(rng, _nonceLen),
        aad: _provisionalAad);
    kek.fillRange(0, kek.length, 0);
    final OpenVault next = OpenVault(
        v.header.withProvisional((
          salt: salt,
          nonce: box.nonce,
          sealed: <int>[...box.cipherText, ...box.mac.bytes],
        )),
        v.contents,
        v._dataKey);
    return (await save(next, random: rng), next);
  }

  /// [v] without its provisional key: every `k`-subset rewrapped under a new
  /// data key, C(n, k) derivations, so the retired key opens no later copy.
  static Future<(Uint8List, OpenVault)> retireProvisional(
    OpenVault v, {
    VaultKdf derive = argon2idKdf,
    Random? random,
    void Function(int done, int total)? onProgress,
  }) async {
    final Random rng = random ?? Random.secure();
    final SecretKey dataKey = SecretKey(_bytes(rng, keyLength));
    final VaultHeader header = await _wrapAll(
        slots: v.header.slots,
        k: v.header.k,
        kdf: v.header.kdf,
        sentences: v.contents.sentences,
        dataKey: dataKey,
        derive: derive,
        rng: rng,
        previous: v.header.cards,
        onProgress: onProgress);
    final OpenVault next = OpenVault(header, v.contents, dataKey);
    return (await save(next, random: rng), next);
  }

  /// Open [file] with its provisional [key]. Throws a [FormatException] when
  /// it has none, or [key] is not it.
  static Future<OpenVault> openWithKey(
    Uint8List file,
    Uint8List key, {
    VaultKdf derive = argon2idKdf,
  }) async {
    const FormatException closed =
        FormatException('This key does not open the vault.');
    final (VaultHeader h, List<int> nonce, List<int> sealed) = _parse(file);
    final KeyWrap? p = h.provisional;
    if (p == null) throw closed;
    final Uint8List password = _provisionalPassword(key);
    final Uint8List kek =
        await derive(password, Uint8List.fromList(p.salt), h.kdf);
    password.fillRange(0, password.length, 0);
    final List<int> plainKey;
    try {
      plainKey = await _aes.decrypt(
          SecretBox(p.sealed.sublist(0, p.sealed.length - _tagLen),
              nonce: p.nonce,
              mac: Mac(p.sealed.sublist(p.sealed.length - _tagLen))),
          secretKey: SecretKey(kek),
          aad: _provisionalAad);
    } on SecretBoxAuthenticationError {
      throw closed;
    } finally {
      kek.fillRange(0, kek.length, 0);
    }
    final SecretKey dataKey = SecretKey(plainKey);
    return OpenVault(
        h, await _decryptContents(h, nonce, sealed, dataKey), dataKey);
  }

  static Uint8List _provisionalPassword(Uint8List key) => (BytesBuilder()
        ..add(_provisionalTag)
        ..add(key))
      .toBytes();

  static Future<VaultHeader> _wrapAll({
    required List<VaultSlot> slots,
    required int k,
    required KdfParams kdf,
    required Map<int, List<int>> sentences,
    required SecretKey dataKey,
    required VaultKdf derive,
    required Random rng,
    List<MemCard> previous = const <MemCard>[],
    void Function(int done, int total)? onProgress,
  }) async {
    if (k < minK || k > slots.length) {
      throw ArgumentError('k must be from $minK to the number of sentences');
    }
    for (final VaultSlot s in slots) {
      final List<int>? bits = sentences[s.id];
      if (bits == null || bits.length != kSentenceBits) {
        throw ArgumentError('every slot needs its $kSentenceBits-bit sentence');
      }
    }
    final List<int> plainKey = await dataKey.extractBytes();
    final List<List<int>> all =
        subsets(<int>[for (final VaultSlot s in slots) s.id], k);
    final List<
        ({
          List<int> slots,
          List<int> salt,
          List<int> nonce,
          List<int> sealed
        })> wraps = <({
      List<int> slots,
      List<int> salt,
      List<int> nonce,
      List<int> sealed
    })>[];
    for (final List<int> subset in all) {
      final Uint8List salt = _bytes(rng, _saltLen);
      final Uint8List password = wrapPassword(subset, sentences);
      final Uint8List kek = await derive(password, salt, kdf);
      password.fillRange(0, password.length, 0);
      final SecretBox box = await _aes.encrypt(plainKey,
          secretKey: SecretKey(kek),
          nonce: _bytes(rng, _nonceLen),
          aad: utf8.encode(jsonEncode(subset)));
      kek.fillRange(0, kek.length, 0);
      wraps.add((
        slots: subset,
        salt: salt,
        nonce: box.nonce,
        sealed: <int>[...box.cipherText, ...box.mac.bytes],
      ));
      onProgress?.call(wraps.length, all.length);
    }
    // Each slot's card: the one it had, or a new one for a new sentence.
    final List<MemCard> cards = <MemCard>[
      for (final VaultSlot s in slots)
        <MemCard?>[
              for (final MemCard c in previous)
                if (c.factId == sentenceFact(s.id)) c,
            ].firstOrNull ??
            MemCard.fact(sentenceFact(s.id)),
    ];
    return VaultHeader(
        kdf: kdf, k: k, slots: slots, wraps: wraps, cards: cards);
  }

  /// The file for [v]: its contents re-encrypted under its data key, with
  /// the same wrappings — no derivation.
  static Future<Uint8List> save(OpenVault v, {Random? random}) async {
    final Random rng = random ?? Random.secure();
    final List<int> json = utf8.encode(jsonEncode(v.contents.toJson()));
    final int size =
        ((_lengthLen + json.length) / paddingStep).ceil() * paddingStep;
    final Uint8List plain = Uint8List(size);
    ByteData.sublistView(plain).setUint32(0, json.length);
    plain.setRange(_lengthLen, _lengthLen + json.length, json);
    try {
      final SecretBox box = await _aes.encrypt(plain,
          secretKey: v._dataKey,
          nonce: _bytes(rng, _nonceLen),
          aad: v.header._aad);
      return Uint8List.fromList(utf8.encode(jsonEncode(<String, dynamic>{
        ...v.header.toJson(),
        'nonce': _hex(box.nonce),
        'ct': base64Encode(<int>[...box.cipherText, ...box.mac.bytes]),
      })));
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// The clear part of a vault [file]; a [FormatException] if it is not one.
  static VaultHeader header(Uint8List file) => _parse(file).$1;

  /// Whether [file] reads as a vault.
  static bool isVault(Uint8List file) {
    try {
      _parse(file);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Open [file] with the sentences [entered] (slot id → 33 bits), at least
  /// `k` of them: each `k`-subset of them is tried in turn, one derivation
  /// each, until one opens. Throws a [FormatException] when none does.
  static Future<Opened> open(
    Uint8List file,
    Map<int, List<int>> entered, {
    VaultKdf derive = argon2idKdf,
  }) async {
    const FormatException closed =
        FormatException('These sentences do not open the vault.');
    final (VaultHeader h, List<int> nonce, List<int> sealed) = _parse(file);
    final List<int> known = <int>[
      for (final VaultSlot s in h.slots)
        if (entered[s.id]?.length == kSentenceBits) s.id,
    ];
    if (known.length < h.k) throw closed;
    for (final List<int> subset in subsets(known, h.k)) {
      final w = h.wraps.firstWhere((w) => _sameList(w.slots, subset),
          orElse: () => throw const FormatException('bad vault'));
      final Uint8List password = wrapPassword(subset, entered);
      final Uint8List kek =
          await derive(password, Uint8List.fromList(w.salt), h.kdf);
      password.fillRange(0, password.length, 0);
      List<int> plainKey;
      try {
        plainKey = await _aes.decrypt(
            SecretBox(w.sealed.sublist(0, w.sealed.length - _tagLen),
                nonce: w.nonce,
                mac: Mac(w.sealed.sublist(w.sealed.length - _tagLen))),
            secretKey: SecretKey(kek),
            aad: utf8.encode(jsonEncode(subset)));
      } on SecretBoxAuthenticationError {
        continue;
      } finally {
        kek.fillRange(0, kek.length, 0);
      }
      final SecretKey dataKey = SecretKey(plainKey);
      final VaultContents contents =
          await _decryptContents(h, nonce, sealed, dataKey);
      final List<int> wrong = <int>[
        for (final int id in known)
          if (!_sameList(entered[id]!, contents.sentences[id] ?? const <int>[]))
            id,
      ];
      return (vault: OpenVault(h, contents, dataKey), wrong: wrong);
    }
    throw closed;
  }

  static Future<VaultContents> _decryptContents(VaultHeader h, List<int> nonce,
      List<int> sealed, SecretKey dataKey) async {
    const FormatException bad = FormatException('bad vault');
    final List<int> plain;
    try {
      plain = await _aes.decrypt(
          SecretBox(sealed.sublist(0, sealed.length - _tagLen),
              nonce: nonce, mac: Mac(sealed.sublist(sealed.length - _tagLen))),
          secretKey: dataKey,
          aad: h._aad);
    } on SecretBoxAuthenticationError {
      throw bad;
    }
    final int length =
        ByteData.sublistView(Uint8List.fromList(plain)).getUint32(0);
    if (_lengthLen + length > plain.length) throw bad;
    return VaultContents.fromJson(jsonDecode(
        utf8.decode(plain.sublist(_lengthLen, _lengthLen + length))));
  }

  static (VaultHeader, List<int>, List<int>) _parse(Uint8List file) {
    const FormatException bad = FormatException('not a vault');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(file));
    } on Object {
      throw bad;
    }
    if (json is! Map<String, dynamic> || json['v'] != formatVersion) throw bad;
    final Object? k = json['k'], slots = json['slots'], wraps = json['wraps'];
    final Object? nonce = json['nonce'], ct = json['ct'];
    if (k is! int ||
        slots is! List ||
        wraps is! List ||
        nonce is! String ||
        ct is! String) {
      throw bad;
    }
    try {
      final List<VaultSlot> s = <VaultSlot>[
        for (final Object? e in slots)
          if (e is Map<String, dynamic> &&
              e['id'] is int &&
              e['theme'] is String)
            VaultSlot(e['id']! as int, e['theme']! as String)
          else
            throw bad,
      ];
      final List<
          ({
            List<int> slots,
            List<int> salt,
            List<int> nonce,
            List<int> sealed
          })> w = <({
        List<int> slots,
        List<int> salt,
        List<int> nonce,
        List<int> sealed
      })>[
        for (final Object? e in wraps)
          if (e is Map<String, dynamic> &&
              e['slots'] is List &&
              e['salt'] is String &&
              e['nonce'] is String &&
              e['key'] is String)
            (
              slots: <int>[
                for (final Object? v in e['slots']! as List) v! as int
              ],
              salt: _unhex(e['salt']! as String),
              nonce: _unhex(e['nonce']! as String),
              sealed: base64Decode(e['key']! as String),
            )
          else
            throw bad,
      ];
      final Object? prov = json['prov'];
      final KeyWrap? p = switch (prov) {
        null => null,
        {
          'salt': final String salt,
          'nonce': final String nonce,
          'key': final String key,
        } =>
          (salt: _unhex(salt), nonce: _unhex(nonce), sealed: base64Decode(key)),
        _ => throw bad,
      };
      return (
        VaultHeader(
            kdf: KdfParams.fromJson(json['kdf']),
            k: k,
            slots: s,
            wraps: w,
            cards: _cardsOf(json['cards']),
            provisional: p),
        _unhex(nonce),
        base64Decode(ct),
      );
    } on FormatException {
      throw bad;
    } on TypeError {
      throw bad;
    }
  }

  static Uint8List _packBits(List<int> bits) {
    final Uint8List out = Uint8List(_sentenceBytes);
    for (int i = 0; i < bits.length; i++) {
      out[i >> 3] |= bits[i] << (7 - (i & 7));
    }
    return out;
  }

  static Uint8List _bytes(Random rng, int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _bits(Object? s) {
  if (s is! String ||
      s.length != kSentenceBits ||
      !RegExp(r'^[01]+$').hasMatch(s)) {
    throw const FormatException('bad sentence');
  }
  return <int>[for (final int c in s.codeUnits) c - 0x30];
}

String _hex(List<int> b) =>
    b.map((int v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String h) {
  if (h.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(h)) {
    throw const FormatException('bad hex');
  }
  return Uint8List.fromList(<int>[
    for (int i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);
}
