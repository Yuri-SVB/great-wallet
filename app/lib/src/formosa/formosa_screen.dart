/// F4 — Formosa: a lightweight password manager ([PassVault]) for the less
/// critical secrets (general passwords, the Flying Turtle wallet's seed…),
/// separate from the setup, with no wrench-attack goal and no time-lock. Its
/// master secret is `n` raw Formosa sentences, one theme each; any `k` open
/// it. Entries are typed in, or generated as Formosa passwords from system
/// randomness or Dragon Dice.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show Clock, Grade, MemCard, MemSchedule;
import 'package:dragon_dice_ui/dragon_dice_ui.dart'
    show DiceRolls, DragonDiceWizard, digestBits;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:formosa/formosa.dart' as formosa;
import 'package:formosa_ui/formosa_ui.dart' show TableTab;

import '../command/command_board.dart' show DeadGlyph, SweatGlyph;
import '../setup/card_stats.dart' show dateText;
import '../setup/fact_review.dart' show FactCheck, FactReviewFrame;
import 'pass_vault.dart';

/// The device's clock, for F4's cards.
class FormosaClock implements Clock {
  const FormosaClock();

  @override
  DateTime now() => DateTime.now();
}

/// F4's schedule: SM-2 as the setup's cards, on the device's clock.
const MemSchedule kFormosaSchedule = MemSchedule(FormosaClock());

/// Where the formosa package's themes are bundled.
const String _kThemesAssets = 'packages/formosa/themes/';
const String _kJson = '.json';

/// The themes bundled with the app (the formosa package's `themes/`).
Future<formosa.ThemeSet> loadBundledThemes(AssetBundle bundle) async {
  final AssetManifest manifest =
      await AssetManifest.loadFromAssetBundle(bundle);
  final Map<String, String> texts = <String, String>{};
  for (final String asset in manifest.listAssets()) {
    if (!asset.startsWith(_kThemesAssets) || !asset.endsWith(_kJson)) continue;
    final String name =
        asset.substring(_kThemesAssets.length, asset.length - _kJson.length);
    if (name.contains('/')) continue;
    texts[name] = await bundle.loadString(asset);
  }
  return formosa.ThemeSet.fromJson(texts);
}

/// What F4 shows.
enum _View { start, create, unlock, entries }

/// F4's screen.
class FormosaScreen extends StatefulWidget {
  const FormosaScreen({
    super.key,
    this.themes,
    this.onFunctionKey,
    this.derive = argon2idKdf,
    this.kdf = const KdfParams(),
    this.schedule = kFormosaSchedule,
  });

  /// The Formosa themes; loaded from the app's bundle when null.
  final formosa.ThemeSet? themes;

  /// F2 or F3 pressed here: the shell shows Setup or Train.
  final ValueChanged<LogicalKeyboardKey>? onFunctionKey;

  /// The wrappings' key derivation, and its default settings for a new vault
  /// (RFC 9106's first recommendation; Advanced changes them).
  final VaultKdf derive;
  final KdfParams kdf;

  /// The cards' schedule (the device's clock by default).
  final MemSchedule schedule;

  @override
  State<FormosaScreen> createState() => _FormosaScreenState();
}

class _FormosaScreenState extends State<FormosaScreen> {
  formosa.ThemeSet? _themes;
  _View _view = _View.start;
  final TextEditingController _path = TextEditingController();
  String _status = '';

  // Busy: a derivation (or several) in flight.
  String? _busy;
  double? _progress;

  // A new vault.
  int _k = _kDefaultK;
  int _n = _kDefaultK + _kDefaultForgiven;
  late KdfParams _kdf = widget.kdf;
  final Map<int, String> _slotThemes = <int, String>{};
  final Map<int, List<int>> _newSentences = <int, List<int>>{};
  bool _advanced = false;

  // Opening a vault: its file, its clear part, a field per slot.
  Uint8List? _file;
  VaultHeader? _header;
  final Map<int, TextEditingController> _inputs =
      <int, TextEditingController>{};

  // The open vault.
  OpenVault? _vault;
  final Set<String> _shown = <String>{};

  // The clipboard, cleared [_kClipboardClear] after a copy if still ours.
  Timer? _clipTimer;

  /// `k` by default: 4 sentences, 132 bits; and the sentences forgiven.
  static const int _kDefaultK = 4;
  static const int _kDefaultForgiven = 2;

  /// The most sentences a vault takes (C(n, k) wrappings grow fast).
  static const int _kMaxSentences = 9;

  /// The Dragon Dice margin below 128 bits: a short output cut from a digest
  /// can be tabulated (Formosa's rule).
  static const int _kDiceMargin = 8;
  static const int _kDiceMarginBelow = 128;

  /// Formosa passwords: strengths offered, and the default.
  static const List<int> _kStrengths = <int>[64, 96, 128, 160, 192, 224, 256];
  static const int _kDefaultStrength = 128;

  static const Duration _kClipboardClear = Duration(seconds: 30);
  static const double _kGap = 12;
  static const double _kWidth = 720;
  static const double _kDiceWidth = 860;
  static const double _kDiceHeight = 640;
  static const double _kTableWidth = 1100;
  static const double _kTableHeight = 720;

  @override
  void initState() {
    super.initState();
    final formosa.ThemeSet? given = widget.themes;
    if (given != null) {
      _themes = given;
    } else {
      unawaited(loadBundledThemes(rootBundle).then((formosa.ThemeSet t) {
        if (mounted) setState(() => _themes = t);
      }, onError: (Object e) {
        if (mounted) setState(() => _status = 'Formosa themes not found: $e');
      }));
    }
  }

  @override
  void dispose() {
    _clipTimer?.cancel();
    _path.dispose();
    for (final TextEditingController c in _inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The themes a sentence can be in: themed ones first, then BIP39's.
  List<String> get _sentenceThemes {
    final List<String> names = _themes!.names.toList()..sort();
    return <String>[
      for (final String n in names)
        if (!n.startsWith(formosa.kDefaultTheme)) n,
      for (final String n in names)
        if (n.startsWith(formosa.kDefaultTheme)) n,
    ];
  }

  void _say(String s) => setState(() => _status = s);

  // --- files -----------------------------------------------------------------

  Future<void> _openFile() async {
    final String path = _path.text.trim();
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException {
      _say('No file at $path.');
      return;
    }
    final VaultHeader h;
    try {
      h = PassVault.header(bytes);
    } on FormatException {
      _say('That file is not a Formosa vault.');
      return;
    }
    setState(() {
      _file = bytes;
      _header = h;
      _clearInputs();
      for (final VaultSlot s in h.slots) {
        _inputs[s.id] = TextEditingController();
      }
      _view = _View.unlock;
      _status = 'Enter at least ${h.k} of its ${h.n} sentences.';
    });
  }

  Future<void> _write(Uint8List bytes) async {
    final String path = _path.text.trim();
    final File tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  Future<void> _save() async {
    final OpenVault? v = _vault;
    if (v == null) return;
    try {
      await _write(await PassVault.save(v));
    } on Object catch (e) {
      _say('Could not save: $e');
    }
  }

  void _clearInputs() {
    for (final TextEditingController c in _inputs.values) {
      c.dispose();
    }
    _inputs.clear();
  }

  void _lock() {
    setState(() {
      _vault = null;
      _shown.clear();
      _file = null;
      _header = null;
      _clearInputs();
      _view = _View.start;
      _status = 'Locked.';
    });
  }

  // --- a new vault ------------------------------------------------------------

  void _startCreate() {
    if (_path.text.trim().isEmpty) {
      _say('Enter the vault file\'s path first.');
      return;
    }
    final List<String> themes = _sentenceThemes;
    setState(() {
      _slotThemes.clear();
      _newSentences.clear();
      for (int id = 1; id <= _n; id++) {
        _slotThemes[id] = themes[(id - 1) % themes.length];
      }
      _view = _View.create;
      _status = 'Generate each sentence, and learn it: it is the master '
          'secret, with no checksum.';
    });
  }

  void _setSizes({int? k, int? n}) {
    final int nk = k ?? _k;
    final int nn = n ?? _n;
    if (nk < PassVault.minK || nn < nk || nn > _kMaxSentences) return;
    final List<String> themes = _sentenceThemes;
    setState(() {
      _k = nk;
      _n = nn;
      for (int id = 1; id <= _n; id++) {
        _slotThemes.putIfAbsent(id, () => themes[(id - 1) % themes.length]);
      }
      _slotThemes.removeWhere((int id, _) => id > _n);
      _newSentences.removeWhere((int id, _) => id > _n);
    });
  }

  /// Bits from Dragon Dice: the first [bits] of the rolls' digest; null if
  /// cancelled.
  Future<List<int>?> _rollBits(int bits, String purpose) async {
    DiceRolls? rolled;
    final int target = bits < _kDiceMarginBelow ? bits + _kDiceMargin : bits;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => Dialog(
        child: SizedBox(
          width: _kDiceWidth,
          height: _kDiceHeight,
          child: DragonDiceWizard(
            targetBits: target.toDouble(),
            purpose: purpose,
            systemRandomByDefault: true,
            onDone: (DiceRolls r) {
              rolled = r;
              Navigator.of(ctx).pop();
            },
            onCancel: () => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
    final DiceRolls? r = rolled;
    if (r == null) return null;
    final Uint8List digest = r.digest();
    r.wipe();
    final List<int> out = digestBits(digest, bits);
    digest.fillRange(0, digest.length, 0);
    return out;
  }

  Future<void> _generate(int id, {required bool dice}) async {
    final formosa.Mnemonic m = _themes![_slotThemes[id]!];
    List<int>? bits;
    if (dice) {
      bits =
          await _rollBits(kSentenceBits, 'Sentence $id, $kSentenceBits bits');
    } else {
      bits = m.rawBits(m.generateRaw());
    }
    if (bits == null || !mounted) return;
    setState(() => _newSentences[id] = bits!);
  }

  Future<void> _create() async {
    if (_newSentences.length < _n) {
      _say('Generate every sentence first.');
      return;
    }
    final List<VaultSlot> slots = <VaultSlot>[
      for (int id = 1; id <= _n; id++) VaultSlot(id, _slotThemes[id]!),
    ];
    setState(() {
      _busy = 'Wrapping the vault for every $_k of the $_n sentences…';
      _progress = 0;
    });
    try {
      final (Uint8List file, OpenVault v) = await PassVault.create(
        slots: slots,
        k: _k,
        kdf: _kdf,
        contents: VaultContents(sentences: <int, List<int>>{
          for (final MapEntry<int, List<int>> e in _newSentences.entries)
            e.key: List<int>.of(e.value),
        }),
        derive: widget.derive,
        onProgress: (int done, int total) {
          if (mounted) setState(() => _progress = done / total);
        },
      );
      await _write(file);
      if (!mounted) return;
      setState(() {
        _vault = v;
        _newSentences.clear();
        _view = _View.entries;
        _status = 'Vault created: any $_k of its $_n sentences open it.';
      });
    } on Object catch (e) {
      _say('Could not create the vault: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _progress = null;
        });
      }
    }
  }

  // --- opening ----------------------------------------------------------------

  /// The 33 bits a slot's field holds, words completed; null if it is not a
  /// whole raw sentence of the slot's theme.
  List<int>? _bitsOf(VaultSlot s) {
    final String text = _inputs[s.id]?.text.trim() ?? '';
    if (text.isEmpty) return null;
    final formosa.Mnemonic m = _themes![s.theme];
    try {
      return m.rawBits(m.expand(text.toLowerCase()));
    } on Object {
      return null;
    }
  }

  void _complete(VaultSlot s) {
    final TextEditingController c = _inputs[s.id]!;
    final formosa.Mnemonic m = _themes![s.theme];
    final String done = m.expand(c.text.trim().toLowerCase());
    c.value = TextEditingValue(
        text: done, selection: TextSelection.collapsed(offset: done.length));
    setState(() {});
  }

  Future<void> _moonCake(VaultSlot s) async {
    final formosa.Mnemonic m = _themes![s.theme];
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Dialog(
        child: SizedBox(
          width: _kTableWidth,
          height: _kTableHeight,
          child: TableTab(
            theme: m.theme,
            page: (Widget body, {bool themeEnabled = true}) => body,
            onPhrase: (String phrase) {
              _inputs[s.id]!.text = phrase;
              Navigator.of(ctx).pop();
            },
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _unlock() async {
    final VaultHeader h = _header!;
    final Map<int, List<int>> entered = <int, List<int>>{
      for (final VaultSlot s in h.slots)
        if (_bitsOf(s) case final List<int> bits) s.id: bits,
    };
    if (entered.length < h.k) {
      _say('Enter at least ${h.k} whole sentences.');
      return;
    }
    setState(() {
      _busy = 'Opening: one derivation per try…';
      _progress = null;
    });
    try {
      final Opened o =
          await PassVault.open(_file!, entered, derive: widget.derive);
      if (!mounted) return;
      setState(() => _busy = null);
      final ({Map<int, Grade> graded, List<int> early})? g =
          await _gradeEntered(o.vault, entered.keys, o.wrong);
      if (g == null || !mounted) return;
      setState(() {
        _vault = o.vault;
        _clearInputs();
        _view = _View.entries;
        _status = <String>[
          'Open.',
          if (o.wrong.isNotEmpty)
            '${_slotsText(o.wrong)} not the vault\'s: graded again.',
          for (final Grade grade in Grade.values)
            if (<int>[
              for (final MapEntry<int, Grade> e in g.graded.entries)
                if (e.value == grade && !o.wrong.contains(e.key)) e.key,
            ]..sort()
                case final List<int> slots when slots.isNotEmpty)
              '${_slotsText(slots)} graded ${grade.name}.',
          if (g.early.isNotEmpty)
            '${_slotsText(g.early)} not due yet: practice.',
        ].join(' ');
      });
      await _save();
    } on FormatException {
      _say('These sentences do not open the vault.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Grade the sentences [entered] at an opening, as you grade them: each
  /// right and due takes your grade; each wrong one only Again, whether due or
  /// not — a forgotten sentence must come back soon; each right before due is
  /// practice, its schedule untouched. Those not entered are not reviewed.
  /// Returns the slots by what they got, or null if the screen went away.
  Future<({Map<int, Grade> graded, List<int> early})?> _gradeEntered(
      OpenVault v, Iterable<int> entered, List<int> wrong) async {
    final MemSchedule schedule = widget.schedule;
    final DateTime now = schedule.clock.now();
    final List<int> early = <int>[];
    final List<int> due = <int>[];
    for (final int slot in (List<int>.of(entered)..sort())) {
      final MemCard? c = v.header.cardOf(slot);
      if (c == null) continue;
      if (wrong.contains(slot) || c.isDue(now)) {
        due.add(slot);
      } else {
        early.add(slot);
      }
    }
    Map<int, Grade> graded = <int, Grade>{};
    if (due.isNotEmpty) {
      final Map<int, Grade>? g = await showDialog<Map<int, Grade>>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext _) =>
            _GradeSentencesDialog(due: due, wrong: wrong, early: early),
      );
      if (g == null || !mounted) return null;
      graded = g;
    }
    v.header = v.header.withCards(<MemCard>[
      for (final MemCard c in v.header.cards)
        if (_slotOfCard(c) case final int slot when graded.containsKey(slot))
          schedule.grade(c, graded[slot]!)
        else
          c,
    ]);
    return (graded: graded, early: early);
  }

  static int? _slotOfCard(MemCard c) {
    const String prefix = 'sentence:';
    return c.factId.startsWith(prefix)
        ? int.tryParse(c.factId.substring(prefix.length))
        : null;
  }

  static String _slotsText(List<int> slots) => slots.length == 1
      ? 'Sentence ${slots.single}'
      : 'Sentences ${(List<int>.of(slots)..sort()).join(', ')}';

  /// When slot [slot]'s card is next due, in words.
  String _dueText(VaultHeader h, int slot) {
    final MemCard? c = h.cardOf(slot);
    final DateTime? due = c?.due;
    if (c == null) return '';
    return due == null || !due.isAfter(widget.schedule.clock.now())
        ? 'due'
        : 'next review ${dateText(due)}';
  }

  // --- sentences: added or retired, then rewrapped ------------------------------

  String? _addTheme;
  List<int>? _added;

  Future<void> _generateAdded({required bool dice}) async {
    final formosa.Mnemonic m = _themes![_addTheme ?? _sentenceThemes.first];
    final List<int>? bits = dice
        ? await _rollBits(kSentenceBits, 'A new sentence, $kSentenceBits bits')
        : m.rawBits(m.generateRaw());
    if (bits == null || !mounted) return;
    setState(() => _added = bits);
  }

  Future<void> _rewrap(List<VaultSlot> slots, String done) async {
    final OpenVault v = _vault!;
    setState(() {
      _busy = 'Rewrapping for every ${v.header.k} of ${slots.length} '
          'sentences…';
      _progress = 0;
    });
    try {
      final (Uint8List file, OpenVault next) = await PassVault.rewrap(v,
          slots: slots,
          k: v.header.k,
          derive: widget.derive, onProgress: (int d, int t) {
        if (mounted) setState(() => _progress = d / t);
      });
      await _write(file);
      if (!mounted) return;
      setState(() {
        _vault = next;
        _status = done;
      });
    } on Object catch (e) {
      _say('Could not rewrap: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _keepAdded() async {
    final OpenVault v = _vault!;
    final List<int>? bits = _added;
    if (bits == null) return;
    final int id = v.header.slots
            .map((VaultSlot s) => s.id)
            .fold(0, (int a, int b) => max(a, b)) +
        1;
    v.contents.sentences[id] = bits;
    final String theme = _addTheme ?? _sentenceThemes.first;
    setState(() => _added = null);
    await _rewrap(<VaultSlot>[...v.header.slots, VaultSlot(id, theme)],
        'Sentence $id added: learn it — it has a card of its own.');
  }

  Future<void> _retire(VaultSlot s) async {
    final OpenVault v = _vault!;
    if (v.header.n <= v.header.k) {
      _say('Retiring it would leave fewer than ${v.header.k} sentences.');
      return;
    }
    await _rewrap(<VaultSlot>[
      for (final VaultSlot o in v.header.slots)
        if (o.id != s.id) o,
    ], 'Sentence ${s.id} retired: it no longer opens the vault.');
  }

  // --- entries ----------------------------------------------------------------

  /// Entry [e]'s card, if you memorise it.
  MemCard? _entryCard(VaultEntry e) {
    for (final MemCard c in _vault!.contents.cards) {
      if (c.factId == entryFact(e.id)) return c;
    }
    return null;
  }

  Future<void> _toggleMemorise(VaultEntry e) async {
    final List<MemCard> cards = _vault!.contents.cards;
    final bool on = _entryCard(e) == null;
    setState(() {
      cards.removeWhere((MemCard c) => c.factId == entryFact(e.id));
      if (on) cards.add(MemCard.fact(entryFact(e.id)));
    });
    await _save();
    _say(on
        ? '${e.label}: memorised — Next due reviews it.'
        : '${e.label}: no longer memorised.');
  }

  /// Review the entry cards due, longest-due first.
  Future<void> _nextDue() async {
    final OpenVault v = _vault!;
    final List<MemCard> due = widget.schedule.queue(v.contents.cards).due;
    if (due.isEmpty) {
      _say('No entry is due.');
      return;
    }
    final MemCard card = due.first;
    final VaultEntry e = v.contents.entries
        .firstWhere((VaultEntry x) => entryFact(x.id) == card.factId);
    final Grade? g = await showDialog<Grade>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => _SecretReviewDialog(entry: e),
    );
    if (g == null || !mounted) return;
    final int at = v.contents.cards.indexOf(card);
    final MemCard next = widget.schedule.grade(card, g);
    setState(() => v.contents.cards[at] = next);
    await _save();
    _say('${e.label}: graded ${g.name}.'
        '${next.due == null ? '' : ' Next review ${dateText(next.due!)}.'}');
  }

  Future<void> _copy(VaultEntry e) async {
    await Clipboard.setData(ClipboardData(text: e.secret));
    _clipTimer?.cancel();
    _clipTimer = Timer(_kClipboardClear, () async {
      final ClipboardData? now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == e.secret) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
    _say('${e.label}: copied. The clipboard is not air-gapped; it is cleared '
        'in ${_kClipboardClear.inSeconds} s.');
  }

  Future<void> _remove(VaultEntry e) async {
    setState(() {
      _vault!.contents.entries.remove(e);
      _vault!.contents.cards
          .removeWhere((MemCard c) => c.factId == entryFact(e.id));
    });
    await _save();
    _say('${e.label}: removed.');
  }

  Future<void> _addEntry() async {
    final VaultEntry? e = await showDialog<VaultEntry>(
      context: context,
      builder: (BuildContext ctx) => _EntryDialog(
        themes: _themes!,
        strengths: _kStrengths,
        defaultStrength: _kDefaultStrength,
        rollBits: _rollBits,
      ),
    );
    if (e == null || !mounted) return;
    setState(() => _vault!.contents.entries.add(e));
    await _save();
    _say('${e.label}: added.');
  }

  // --- the views --------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = e.logicalKey;
    if (key == LogicalKeyboardKey.f2 || key == LogicalKeyboardKey.f3) {
      widget.onFunctionKey?.call(key);
      return KeyEventResult.handled;
    }
    final String? mode = switch (key) {
      LogicalKeyboardKey.f5 => 'Accelerate',
      LogicalKeyboardKey.f6 => 'Inherit',
      _ => null,
    };
    if (key == LogicalKeyboardKey.f4) {
      _say('Formosa (current mode).');
    } else if (mode != null) {
      _say('$mode mode is not available yet.');
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _themes == null
        ? Center(child: Text(_status.isEmpty ? 'Loading Formosa…' : _status))
        : switch (_view) {
            _View.start => _startView(),
            _View.create => _createView(),
            _View.unlock => _unlockView(),
            _View.entries => _entriesView(),
          };
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: _kWidth,
          child: ListView(
            padding: const EdgeInsets.all(_kGap * 2),
            children: <Widget>[
              Text('Formosa — passwords',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: _kGap),
              body,
              if (_busy != null) ...<Widget>[
                const SizedBox(height: _kGap),
                Text(_busy!),
                LinearProgressIndicator(value: _progress),
              ],
              if (_status.isNotEmpty && _themes != null) ...<Widget>[
                const SizedBox(height: _kGap),
                Text(_status),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _startView() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
              'A password manager for the less critical secrets, apart from '
              'the setup. Its master secret is a few Formosa sentences, any k '
              'of which open it; CPNF keeps them from being forgotten.'),
          const SizedBox(height: _kGap),
          TextField(
            controller: _path,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Vault file',
            ),
          ),
          const SizedBox(height: _kGap),
          Wrap(
            spacing: _kGap,
            children: <Widget>[
              FilledButton(
                  onPressed: _busy == null ? _openFile : null,
                  child: const Text('Open')),
              OutlinedButton(
                  onPressed: _busy == null ? _startCreate : null,
                  child: const Text('New vault')),
            ],
          ),
        ],
      );

  Widget _createView() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Any $_k of $_n sentences open it: ${_k * kSentenceBits} bits '
              '(${PassVault.minK * kSentenceBits} at the least, $_kDefaultK × '
              '$kSentenceBits = ${_kDefaultK * kSentenceBits} recommended), '
              '${_n - _k} forgiven.'),
          Row(
            children: <Widget>[
              const Text('k'),
              IconButton(
                  onPressed: () => _setSizes(k: _k - 1),
                  icon: const Icon(Icons.remove)),
              Text('$_k'),
              IconButton(
                  onPressed: () => _setSizes(k: _k + 1),
                  icon: const Icon(Icons.add)),
              const SizedBox(width: _kGap * 2),
              const Text('n'),
              IconButton(
                  onPressed: () => _setSizes(n: _n - 1),
                  icon: const Icon(Icons.remove)),
              Text('$_n'),
              IconButton(
                  onPressed: () => _setSizes(n: _n + 1),
                  icon: const Icon(Icons.add)),
            ],
          ),
          for (int id = 1; id <= _n; id++) _newSlotRow(id),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Advanced: key derivation'),
            value: _advanced,
            onChanged: (bool on) => setState(() => _advanced = on),
          ),
          if (_advanced) _kdfFields(),
          const SizedBox(height: _kGap),
          Wrap(
            spacing: _kGap,
            children: <Widget>[
              FilledButton(
                  onPressed: _busy == null ? _create : null,
                  child: const Text('Create')),
              TextButton(
                  onPressed: _busy == null ? _lock : null,
                  child: const Text('Cancel')),
            ],
          ),
        ],
      );

  Widget _newSlotRow(int id) {
    final List<int>? bits = _newSentences[id];
    final formosa.Mnemonic m = _themes![_slotThemes[id]!];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _kGap / 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: _kGap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('Sentence $id'),
              DropdownButton<String>(
                value: _slotThemes[id],
                items: <DropdownMenuItem<String>>[
                  for (final String t in _sentenceThemes)
                    DropdownMenuItem<String>(value: t, child: Text(t)),
                ],
                onChanged: (String? t) => setState(() {
                  _slotThemes[id] = t!;
                  _newSentences.remove(id);
                }),
              ),
              TextButton(
                  onPressed: () => _generate(id, dice: false),
                  child: const Text('System random')),
              TextButton(
                  onPressed: () => _generate(id, dice: true),
                  child: const Text('Dragon Dice')),
            ],
          ),
          if (bits != null) SelectableText(m.toRawSentence(bits)),
        ],
      ),
    );
  }

  Widget _kdfFields() {
    Widget field(String label, int value, void Function(int) set) => SizedBox(
          width: _kWidth / 4,
          child: TextFormField(
            initialValue: '$value',
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: label),
            onChanged: (String s) {
              final int? v = int.tryParse(s);
              if (v != null && v > 0) set(v);
            },
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('Argon2id per wrapping; RFC 9106\'s first recommendation by '
            'default (2 GiB, one pass, four lanes). Every wrapping costs '
            'one: C(n, k) of them to create.'),
        const SizedBox(height: _kGap / 2),
        Wrap(
          spacing: _kGap,
          children: <Widget>[
            field(
                'Memory (KiB)',
                _kdf.memoryKiB,
                (int v) => _kdf = KdfParams(
                    memoryKiB: v,
                    iterations: _kdf.iterations,
                    parallelism: _kdf.parallelism)),
            field(
                'Passes',
                _kdf.iterations,
                (int v) => _kdf = KdfParams(
                    memoryKiB: _kdf.memoryKiB,
                    iterations: v,
                    parallelism: _kdf.parallelism)),
            field(
                'Lanes',
                _kdf.parallelism,
                (int v) => _kdf = KdfParams(
                    memoryKiB: _kdf.memoryKiB,
                    iterations: _kdf.iterations,
                    parallelism: v)),
          ],
        ),
      ],
    );
  }

  Widget _unlockView() {
    final VaultHeader h = _header!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Any ${h.k} of its ${h.n} sentences: type the first letters of '
            'each word and complete them, or pick them on the Table Selector '
            '(Moon Cake).'),
        for (final VaultSlot s in h.slots)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: _kGap / 2),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _inputs[s.id],
                    obscureText: true,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _complete(s),
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      labelText: 'Sentence ${s.id} (${s.theme}) · '
                          '${_dueText(h, s.id)}',
                      suffixIcon: Icon(_bitsOf(s) != null
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Complete the words',
                  onPressed: () => _complete(s),
                  icon: const Icon(Icons.auto_fix_high),
                ),
                IconButton(
                  tooltip: 'Table Selector (Moon Cake)',
                  onPressed: () => _moonCake(s),
                  icon: const Icon(Icons.grid_on),
                ),
              ],
            ),
          ),
        const SizedBox(height: _kGap),
        Wrap(
          spacing: _kGap,
          children: <Widget>[
            FilledButton(
                onPressed: _busy == null ? _unlock : null,
                child: const Text('Open')),
            TextButton(
                onPressed: _busy == null ? _lock : null,
                child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }

  Widget _entriesView() {
    final OpenVault v = _vault!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('${v.contents.entries.length} entr'
            '${v.contents.entries.length == 1 ? 'y' : 'ies'} · any '
            '${v.header.k} of ${v.header.n} sentences open it.'),
        for (final VaultEntry e in v.contents.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(e.label),
            subtitle: Text(_shown.contains(e.id)
                ? '${e.secret}${e.note.isEmpty ? '' : '\n${e.note}'}'
                : '••••••••${e.note.isEmpty ? '' : '\n${e.note}'}'),
            trailing: Wrap(
              children: <Widget>[
                IconButton(
                  tooltip: 'Copy',
                  onPressed: () => _copy(e),
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: _shown.contains(e.id) ? 'Hide' : 'Show',
                  onPressed: () => setState(() => _shown.contains(e.id)
                      ? _shown.remove(e.id)
                      : _shown.add(e.id)),
                  icon: Icon(_shown.contains(e.id)
                      ? Icons.visibility_off
                      : Icons.visibility),
                ),
                IconButton(
                  tooltip: _entryCard(e) == null
                      ? 'Memorise it (a CPNF card)'
                      : 'Memorised: stop reviewing it',
                  onPressed: () => _toggleMemorise(e),
                  icon: Icon(_entryCard(e) == null
                      ? Icons.school_outlined
                      : Icons.school),
                ),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () => _remove(e),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        const SizedBox(height: _kGap),
        Wrap(
          spacing: _kGap,
          children: <Widget>[
            FilledButton(onPressed: _addEntry, child: const Text('Add entry')),
            OutlinedButton(
                onPressed: _busy == null ? _nextDue : null,
                child: const Text('Next due')),
            OutlinedButton(onPressed: _lock, child: const Text('Lock')),
          ],
        ),
        const Divider(height: _kGap * 3),
        _sentencesPanel(v),
      ],
    );
  }

  /// The master secret's sentences: when each is next due, retiring one,
  /// adding one — each change rewraps the vault.
  Widget _sentencesPanel(OpenVault v) {
    final VaultHeader h = v.header;
    final formosa.Mnemonic? m =
        _added == null ? null : _themes![_addTheme ?? _sentenceThemes.first];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Sentences: any ${h.k} of ${h.n} open the vault. Each is reviewed '
            'when you enter it to open it.'),
        for (final VaultSlot s in h.slots)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Sentence ${s.id} (${s.theme})'),
            subtitle: Text(_dueText(h, s.id)),
            trailing: TextButton(
              onPressed: _busy == null && h.n > h.k ? () => _retire(s) : null,
              child: const Text('Retire'),
            ),
          ),
        Wrap(
          spacing: _kGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            const Text('Add a sentence'),
            DropdownButton<String>(
              value: _addTheme ?? _sentenceThemes.first,
              items: <DropdownMenuItem<String>>[
                for (final String t in _sentenceThemes)
                  DropdownMenuItem<String>(value: t, child: Text(t)),
              ],
              onChanged: (String? t) => setState(() {
                _addTheme = t;
                _added = null;
              }),
            ),
            TextButton(
                onPressed: () => _generateAdded(dice: false),
                child: const Text('System random')),
            TextButton(
                onPressed: () => _generateAdded(dice: true),
                child: const Text('Dragon Dice')),
          ],
        ),
        if (m != null) ...<Widget>[
          SelectableText(m.toRawSentence(_added!)),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy == null ? _keepAdded : null,
              child: const Text('Keep it, and rewrap'),
            ),
          ),
        ],
      ],
    );
  }
}

/// An entry's card: its secret typed from memory, matched exactly.
class _SecretReviewDialog extends StatefulWidget {
  const _SecretReviewDialog({required this.entry});

  final VaultEntry entry;

  @override
  State<_SecretReviewDialog> createState() => _SecretReviewDialogState();
}

class _SecretReviewDialogState extends State<_SecretReviewDialog> {
  final TextEditingController _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: widget.entry.label,
        about: 'Type its secret from memory: only an exact match counts.',
        body: TextField(
          controller: _typed,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            labelText: 'Secret',
          ),
        ),
        check: () async {
          final bool hit = _typed.text == widget.entry.secret;
          return FactCheck(
              hit: hit, message: hit ? 'Right.' : 'Missed — it is not that.');
        },
      );
}

/// Adding an entry: its label and note, and its secret — typed, or a Formosa
/// password generated from system randomness or Dragon Dice.
class _EntryDialog extends StatefulWidget {
  const _EntryDialog({
    required this.themes,
    required this.strengths,
    required this.defaultStrength,
    required this.rollBits,
  });

  final formosa.ThemeSet themes;
  final List<int> strengths;
  final int defaultStrength;
  final Future<List<int>?> Function(int bits, String purpose) rollBits;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  final TextEditingController _label = TextEditingController();
  final TextEditingController _secret = TextEditingController();
  final TextEditingController _note = TextEditingController();
  late String _theme = widget.themes.names.contains(formosa.kDefaultTheme)
      ? formosa.kDefaultTheme
      : widget.themes.names.first;
  late int _strength = widget.defaultStrength;
  String _mnemonic = '';

  static const int _kBitsPerByte = 8;

  @override
  void dispose() {
    _label.dispose();
    _secret.dispose();
    _note.dispose();
    super.dispose();
  }

  void _take(String mnemonic) {
    final formosa.Mnemonic m = widget.themes[_theme];
    setState(() {
      _mnemonic = mnemonic;
      _secret.text = m.formatMnemonic(mnemonic).split('\n').first;
    });
  }

  Future<void> _roll() async {
    final List<int>? bits =
        await widget.rollBits(_strength, 'A Formosa password, $_strength bits');
    if (bits == null || !mounted) return;
    final Uint8List bytes = Uint8List(_strength ~/ _kBitsPerByte);
    for (int i = 0; i < _strength; i++) {
      bytes[i ~/ _kBitsPerByte] |=
          bits[i] << (_kBitsPerByte - 1 - i % _kBitsPerByte);
    }
    _take(widget.themes[_theme].toMnemonic(bytes));
    bytes.fillRange(0, bytes.length, 0);
  }

  @override
  Widget build(BuildContext context) {
    final List<String> names = widget.themes.names.toList()..sort();
    return AlertDialog(
      title: const Text('Add entry'),
      content: SizedBox(
        width: _FormosaScreenState._kWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _label,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Label'),
              ),
              TextField(
                controller: _secret,
                decoration: const InputDecoration(
                    labelText: 'Secret (typed, or generated below)'),
                onChanged: (_) => setState(() => _mnemonic = ''),
              ),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note'),
              ),
              const SizedBox(height: _FormosaScreenState._kGap),
              Wrap(
                spacing: _FormosaScreenState._kGap,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  DropdownButton<String>(
                    value: _theme,
                    items: <DropdownMenuItem<String>>[
                      for (final String t in names)
                        DropdownMenuItem<String>(value: t, child: Text(t)),
                    ],
                    onChanged: (String? t) => setState(() => _theme = t!),
                  ),
                  DropdownButton<int>(
                    value: _strength,
                    items: <DropdownMenuItem<int>>[
                      for (final int s in widget.strengths)
                        DropdownMenuItem<int>(value: s, child: Text('$s bits')),
                    ],
                    onChanged: (int? s) => setState(() => _strength = s!),
                  ),
                  TextButton(
                    onPressed: () => _take(widget.themes[_theme].generate(
                        strength: _strength, random: Random.secure())),
                    child: const Text('System random'),
                  ),
                  TextButton(
                      onPressed: _roll, child: const Text('Dragon Dice')),
                ],
              ),
              if (_mnemonic.isNotEmpty) SelectableText(_mnemonic),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_label.text.trim().isEmpty || _secret.text.isEmpty) return;
            Navigator.of(context).pop(VaultEntry(
              id: '${DateTime.now().microsecondsSinceEpoch}',
              label: _label.text.trim(),
              secret: _secret.text,
              note: _note.text.trim(),
              mnemonic: _mnemonic,
            ));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Grading the sentences of an opening: each right and due one takes the
/// grade you give it — how hard it came, not only whether it came; each wrong
/// one only Again. Every one is graded before going on.
class _GradeSentencesDialog extends StatefulWidget {
  const _GradeSentencesDialog({
    required this.due,
    required this.wrong,
    required this.early,
  });

  /// The slots to grade (right and due, or wrong), those wrong, and those
  /// right before due (practice, shown only).
  final List<int> due;
  final List<int> wrong;
  final List<int> early;

  @override
  State<_GradeSentencesDialog> createState() => _GradeSentencesDialogState();
}

class _GradeSentencesDialogState extends State<_GradeSentencesDialog> {
  late final Map<int, Grade> _grades = <int, Grade>{
    for (final int s in widget.due)
      if (widget.wrong.contains(s)) s: Grade.again,
  };

  @override
  Widget build(BuildContext context) {
    final Color ink = Theme.of(context).colorScheme.onSurface;
    Widget glyph(Grade g) => switch (g) {
          Grade.again => DeadGlyph(colour: ink),
          Grade.hard => SweatGlyph(colour: ink),
          Grade.good => const Icon(Icons.sentiment_satisfied),
          Grade.easy => const Icon(Icons.sentiment_very_satisfied),
        };
    return AlertDialog(
      title: const Text('Grade the sentences'),
      content: SizedBox(
        width: _FormosaScreenState._kWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text('How hard did each come back? If in doubt, the lower '
                  'grade: a sentence remembered only after a long effort is '
                  'Hard, or Again.'),
              for (final int s in widget.due)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: _FormosaScreenState._kGap / 2),
                  child: Wrap(
                    spacing: _FormosaScreenState._kGap,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      Text('Sentence $s'),
                      if (widget.wrong.contains(s))
                        const Text('not the vault\'s: Again')
                      else
                        SegmentedButton<Grade>(
                          emptySelectionAllowed: true,
                          segments: <ButtonSegment<Grade>>[
                            for (final Grade g in Grade.values)
                              ButtonSegment<Grade>(
                                  value: g,
                                  icon: glyph(g),
                                  label: Text(switch (g) {
                                    Grade.again => 'Again',
                                    Grade.hard => 'Hard',
                                    Grade.good => 'Good',
                                    Grade.easy => 'Easy',
                                  })),
                          ],
                          selected: <Grade>{
                            if (_grades[s] case final Grade g) g,
                          },
                          onSelectionChanged: (Set<Grade> v) => setState(() {
                            v.isEmpty
                                ? _grades.remove(s)
                                : _grades[s] = v.first;
                          }),
                        ),
                    ],
                  ),
                ),
              if (widget.early.isNotEmpty)
                Text('Not due yet, so practice: sentence'
                    '${widget.early.length == 1 ? '' : 's'} '
                    '${widget.early.join(', ')}.'),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: _grades.length == widget.due.length
              ? () => Navigator.of(context).pop(_grades)
              : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
