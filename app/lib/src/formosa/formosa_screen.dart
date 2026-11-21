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
    show Clock, GraduationParams, Grade, MemCard, MemSchedule, failureChance;
import 'package:dragon_dice_ui/dragon_dice_ui.dart'
    show DiceRolls, DragonDiceWizard, digestBits;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:formosa/formosa.dart' as formosa;
import 'package:formosa_ui/formosa_ui.dart' show TableTab;

import '../command/command_board.dart';
import '../command/keyboard_layout.dart';
import '../setup/card_stats.dart' show chanceText, dateText, durationText;
import '../setup/fact_review.dart' show FactCheck, FactReviewFrame;
import '../setup/provisional_key.dart';
import '../setup/setup_crypto.dart' show SetupCrypto;
import 'pass_vault.dart';

/// The device's clock, for F4's cards.
class FormosaClock implements Clock {
  const FormosaClock();

  @override
  DateTime now() => DateTime.now();
}

/// F4's schedule: SM-2 as the setup's cards, on the device's clock.
const MemSchedule kFormosaSchedule = MemSchedule(FormosaClock());

/// The graduation gate's target gap `T`, as the Great Wall's default.
const Duration kFormosaGateGap = Duration(days: 7);

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
    this.gateGap = kFormosaGateGap,
    this.epsilon = GraduationParams.defaultEpsilon,
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

  /// The graduation gate's defaults: the provisional key may be retired once
  /// the chance of recalling fewer than `k` sentences after [gateGap] is at
  /// most [epsilon]. Each vault can set its own (T and ε…).
  final Duration gateGap;
  final double epsilon;

  @override
  State<FormosaScreen> createState() => _FormosaScreenState();
}

class _FormosaScreenState extends State<FormosaScreen> {
  formosa.ThemeSet? _themes;
  _View _view = _View.start;
  final TextEditingController _path = TextEditingController();
  // The log, newest first (shown at the bottom); the status is its last
  // line.
  final List<String> _log = <String>[];
  String get _status => _log.isEmpty ? '' : _log.first;
  set _status(String s) {
    _log.insert(0, s);
    if (_log.length > _kLogLines) _log.removeLast();
  }

  // The board: its context, the panel folded away (F1), the explanation of
  // the control under the pointer, and the keys' letters.
  final FocusNode _root = FocusNode(debugLabel: 'formosa');
  CommandContext _context = CommandContext.vault;
  bool _panelHidden = false;
  String? _explaining;
  final KeyboardLayout _layout = KeyboardLayout.buildDefault;

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

  // The open vault, the entries whose secret is shown, and the selection:
  // the folder (null: all), the entry and the sentence.
  OpenVault? _vault;
  final Set<String> _shown = <String>{};
  String? _folder;
  String? _selected;
  int? _selectedSlot;

  // Entries held to copy into another vault, and the file they are from: in
  // memory only, across a lock, until pasted or discarded.
  final List<VaultEntry> _held = <VaultEntry>[];
  String? _heldFrom;

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
  static const int _kByteValues = 256;
  static const int _kLogLines = 50;
  static const double _kPanelPadding = 8;
  static const double _kFolderPaneWidth = 220;
  static const double _kDetailPaneWidth = 360;
  static const double _kFolderIndent = 12;
  static const double _kFormWidth = 1000;
  static const double _kSlotLabelWidth = 90;
  static const double _kThemeWidth = 170;
  static const double _kPercentScale = 100;
  static const double _kGateFieldWidth = 160;
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
    _discardHeld();
    _root.dispose();
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
      _context = CommandContext.vault;
      _folder = null;
      _selected = null;
      _selectedSlot = null;
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
        _context = CommandContext.entries;
        _busy = 'Wrapping it for the provisional key…';
        _progress = null;
      });
      final Uint8List? key = await _newKey(SetupCrypto.keyLenBytes);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _status = 'Vault created: any $_k of its $_n sentences open it'
            '${key == null ? '.' : ', and the provisional key alone until '
                'you retire it.'}';
      });
      if (key != null) await _showKey(key);
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
        _context = CommandContext.entries;
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

  /// Review the next card due, longest-due first: the sentences' before the
  /// entries'.
  Future<void> _nextDue() async {
    final OpenVault v = _vault!;
    final List<MemCard> sentences = widget.schedule.queue(v.header.cards).due;
    if (sentences.isNotEmpty) return _reviewSentence(v, sentences.first);
    final List<MemCard> due = widget.schedule.queue(v.contents.cards).due;
    if (due.isEmpty) {
      _say('Nothing is due. The sentences and the entries you memorise have '
          'cards.');
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

  /// Review sentence [card] of the open vault: typed from memory, checked
  /// against the vault's copy, then graded by you (a miss: Again).
  Future<void> _reviewSentence(OpenVault v, MemCard card) async {
    final int slot = _slotOfCard(card)!;
    final VaultSlot s =
        v.header.slots.firstWhere((VaultSlot x) => x.id == slot);
    // The field's controller outlives the dialog's exit transition.
    final TextEditingController typed = TextEditingController();
    _inputs[slot] = typed;
    final DialogRoute<Grade> route = DialogRoute<Grade>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => FactReviewFrame(
        title: 'Sentence $slot (${s.theme})',
        about: 'Type it from memory: the first letters of each word, then '
            'complete them, or Moon Cake. If in doubt, the lower grade: a '
            'sentence remembered only after a long effort is Hard, or Again.',
        body: _sentenceField(s, 'Sentence $slot'),
        reveal: _themes![s.theme].toRawSentence(v.contents.sentences[slot]!),
        check: () async {
          final List<int>? bits = _bitsOf(s);
          final bool hit =
              bits != null && listEquals(bits, v.contents.sentences[slot]);
          return FactCheck(
              hit: hit, message: hit ? 'Right.' : 'Missed — it is not that.');
        },
      ),
    );
    final Grade? g = await Navigator.of(context).push(route);
    unawaited(route.completed.whenComplete(() {
      if (identical(_inputs[slot], typed)) _inputs.remove(slot);
      typed.dispose();
    }));
    if (g == null || !mounted) return;
    final MemCard next = widget.schedule.grade(card, g);
    setState(() => v.header = v.header.withCards(<MemCard>[
          for (final MemCard c in v.header.cards)
            c.factId == card.factId ? next : c,
        ]));
    await _save();
    _say('Sentence $slot: graded ${g.name}.'
        '${next.due == null ? '' : ' Next review ${dateText(next.due!)}.'}');
  }

  Future<void> _copy(VaultEntry e) => _copyText(e.secret, e.label);

  /// [text] to the clipboard, blind, cleared after [_kClipboardClear] unless
  /// something else was copied since.
  Future<void> _copyText(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    _clipTimer?.cancel();
    _clipTimer = Timer(_kClipboardClear, () async {
      final ClipboardData? now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
    _say('$what: copied. The clipboard is not air-gapped; it is cleared in '
        '${_kClipboardClear.inSeconds} s.');
  }

  // --- the provisional key ------------------------------------------------------

  /// The open vault wrapped for a fresh random key of [lenBytes] bytes:
  /// the key, or null (and why, in the status) if that failed.
  Future<Uint8List?> _newKey(int lenBytes) async {
    final ({String? error, Uint8List? key}) r =
        await _resealKey(newLen: lenBytes);
    if (r.error != null) _say(r.error!);
    return r.key;
  }

  /// The open vault wrapped for [ownKey] (copied: the caller wipes its own),
  /// or for a fresh random key of [newLen] bytes; written at once.
  Future<({String? error, Uint8List? key})> _resealKey(
      {Uint8List? ownKey, required int newLen}) async {
    final OpenVault? v = _vault;
    if (v == null) return (error: 'The vault is locked.', key: null);
    final Random rng = Random.secure();
    final Uint8List key = ownKey == null
        ? Uint8List.fromList(
            List<int>.generate(newLen, (_) => rng.nextInt(_kByteValues)))
        : Uint8List.fromList(ownKey);
    try {
      final (Uint8List file, OpenVault next) =
          await PassVault.addProvisional(v, key, derive: widget.derive);
      await _write(file);
      if (mounted) setState(() => _vault = next);
      return (error: null, key: key);
    } on Object catch (e) {
      wipeKey(key);
      return (error: 'Could not save: $e', key: null);
    }
  }

  /// The key dialog (shared with the Great Wall) for [key], which already
  /// opens the vault; it wipes [key] on close.
  Future<void> _showKey(Uint8List key) => showKeyDialog(
        context,
        key: key,
        reseal: _resealKey,
        sealed: 'this vault',
        intro: 'Saved. Keep the key OFFLINE: until you retire it at '
            'graduation it opens this vault alone, without the sentences. '
            'Then destroy it (shred / burn).',
        voice: KeyVoice(toast: _say),
        copy: (String hex, int bits) =>
            unawaited(_copyText(hex, 'The $bits-bit provisional key')),
      );

  /// A provisional key for a vault that has none (it was retired).
  Future<void> _addKey() async {
    setState(() => _busy = 'Wrapping it for a provisional key…');
    final Uint8List? key = await _newKey(SetupCrypto.keyLenBytes);
    if (!mounted) return;
    setState(() => _busy = null);
    if (key == null) return;
    _say('A provisional key: it opens the vault alone until you retire it.');
    await _showKey(key);
  }

  /// The graduation gate for [h] at now + `T`: the chance of recalling fewer
  /// than `k` of its sentences, each by its forgetting curve (one never
  /// graded counts as forgotten), and whether it is at most `ε`.
  ({double failure, bool passes}) _gate(VaultHeader h,
      {Duration? gap, double? epsilon}) {
    final MemSchedule schedule = widget.schedule;
    final DateTime at = schedule.clock.now().add(gap ?? _gapOf(h));
    final double failure = failureChance(<double>[
      for (final VaultSlot s in h.slots)
        if (h.cardOf(s.id) case final MemCard c when c.isGraded)
          schedule.recall(c, at) ?? 0
        else
          0,
    ], h.k);
    return (failure: failure, passes: failure <= (epsilon ?? _epsilonOf(h)));
  }

  /// [h]'s gate settings: its own, else the defaults.
  Duration _gapOf(VaultHeader h) =>
      h.gapSeconds == null ? widget.gateGap : Duration(seconds: h.gapSeconds!);
  double _epsilonOf(VaultHeader h) => h.epsilon ?? widget.epsilon;

  /// Set the open vault's `T` and `ε`, the gate previewed as you type; an
  /// empty field returns to the default.
  Future<void> _setGate() async {
    final OpenVault v = _vault!;
    final VaultHeader h = v.header;
    final ({int? gapSeconds, double? epsilon})? set =
        await showDialog<({int? gapSeconds, double? epsilon})>(
      context: context,
      builder: (BuildContext _) => _GateDialog(
        header: h,
        defaultGap: widget.gateGap,
        defaultEpsilon: widget.epsilon,
        preview: (Duration gap, double epsilon) =>
            _gate(h, gap: gap, epsilon: epsilon),
      ),
    );
    if (set == null || !mounted) return;
    setState(() => v.header =
        h.withGate(gapSeconds: set.gapSeconds, epsilon: set.epsilon));
    await _save();
    _say('Graduation: T ${durationText(_gapOf(v.header))}, '
        'ε ${chanceText(_epsilonOf(v.header))}.');
  }

  /// Retire the provisional key, at the green light: a confirmation, then
  /// every `k`-subset rewrapped under a new data key.
  Future<void> _retireKey() async {
    final OpenVault v = _vault!;
    final VaultHeader h = v.header;
    final int wraps =
        PassVault.subsets(<int>[for (final VaultSlot s in h.slots) s.id], h.k)
            .length;
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Retire the provisional key'),
        content: SizedBox(
          width: _kWidth,
          child: Text('Green light: after ${durationText(_gapOf(h))}, '
              '${chanceText(_gate(h).failure)} chance of recalling fewer than '
              '${h.k} of the ${h.n} sentences.\n\n'
              'From now on only ${h.k} sentences open the vault. It is '
              'rewrapped under a new data key ($wraps derivations), so the key '
              'opens no later copy — but a backup of an earlier copy still '
              'opens with it. Destroy every copy of the key (shred / burn), and '
              'every earlier copy of the vault you do not need.'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Retire it')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() {
      _busy = 'Rewrapping for every ${h.k} of ${h.n} sentences under a new '
          'data key…';
      _progress = 0;
    });
    try {
      final (Uint8List file, OpenVault next) =
          await PassVault.retireProvisional(v, derive: widget.derive,
              onProgress: (int d, int t) {
        if (mounted) setState(() => _progress = d / t);
      });
      await _write(file);
      if (!mounted) return;
      setState(() {
        _vault = next;
        _status = 'Provisional key retired: only ${h.k} of the ${h.n} '
            'sentences open the vault now. Destroy every copy of the key.';
      });
    } on Object catch (e) {
      _say('Could not retire the key: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _progress = null;
        });
      }
    }
  }

  /// Open the vault with its provisional key, scanned or typed: nothing is
  /// graded.
  Future<void> _unlockWithKey() async {
    final Uint8List? key = await showDialog<Uint8List>(
      context: context,
      builder: (BuildContext _) => const _KeyEntryDialog(),
    );
    if (key == null || !mounted) return;
    setState(() {
      _busy = 'Opening with the provisional key…';
      _progress = null;
    });
    try {
      final OpenVault v =
          await PassVault.openWithKey(_file!, key, derive: widget.derive);
      if (!mounted) return;
      setState(() {
        _vault = v;
        _clearInputs();
        _view = _View.entries;
        _context = CommandContext.entries;
        _status = 'Open with the provisional key: no sentence is graded.';
      });
    } on FormatException {
      _say('This key does not open the vault.');
    } finally {
      wipeKey(key);
      if (mounted) setState(() => _busy = null);
    }
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

  // --- copying entries between vaults -------------------------------------------

  static String _entriesText(int n) => '$n entr${n == 1 ? 'y' : 'ies'}';

  /// Whether [e], of the open vault, is held.
  bool _isHeld(VaultEntry e) =>
      _heldFrom == _path.text.trim() &&
      _held.any((VaultEntry h) => h.id == e.id);

  /// Hold [e] to copy it into another vault, or let it go. Holding from
  /// another vault than the held entries' lets those go first.
  void _toggleHold(VaultEntry e) {
    final String path = _path.text.trim();
    setState(() {
      if (_heldFrom != path) _discardHeld();
      _heldFrom = path;
      _isHeld(e)
          ? _held.removeWhere((VaultEntry h) => h.id == e.id)
          : _held.add(e);
      if (_held.isEmpty) _heldFrom = null;
    });
  }

  void _discardHeld() {
    _held.clear();
    _heldFrom = null;
  }

  /// The held entries copied into the open vault, each with a new id and no
  /// card (not memorised here). Nothing is removed from the other vault.
  Future<void> _paste() async {
    final OpenVault v = _vault!;
    final int stamp = DateTime.now().microsecondsSinceEpoch;
    final int n = _held.length;
    final String from = _heldFrom!;
    setState(() {
      for (int i = 0; i < n; i++) {
        final VaultEntry e = _held[i];
        v.contents.entries.add(VaultEntry(
            id: '$stamp-$i',
            label: e.label,
            secret: e.secret,
            login: e.login,
            folder: e.folder,
            note: e.note,
            mnemonic: e.mnemonic));
      }
      _discardHeld();
    });
    await _save();
    _say('${_entriesText(n)} copied from $from.');
  }

  /// Whether the held entries can be pasted here: into an open vault, not
  /// their own.
  bool get _canPaste =>
      _view == _View.entries && _heldFrom != _path.text.trim();

  // --- the selection ------------------------------------------------------------

  /// The folder shown: the one picked while it still exists, else all.
  String? get _shownFolder => _folders().contains(_folder) ? _folder : null;

  /// The entries in the folder shown (and its subfolders), by folder, then
  /// label.
  List<VaultEntry> _listed() {
    final String? f = _shownFolder;
    return <VaultEntry>[
      for (final VaultEntry e in _vault!.contents.entries)
        if (f == null || e.folder == f || e.folder.startsWith('$f/')) e,
    ]..sort((VaultEntry a, VaultEntry b) => a.folder == b.folder
        ? a.label.compareTo(b.label)
        : a.folder.compareTo(b.folder));
  }

  /// The entry selected: the one picked while it is listed, else the first.
  VaultEntry? get _current {
    final List<VaultEntry> listed = _listed();
    for (final VaultEntry e in listed) {
      if (e.id == _selected) return e;
    }
    return listed.firstOrNull;
  }

  /// The sentence selected: the one picked while it lives, else the first.
  VaultSlot? get _currentSlot {
    final List<VaultSlot> slots = _vault!.header.slots;
    for (final VaultSlot s in slots) {
      if (s.id == _selectedSlot) return s;
    }
    return slots.firstOrNull;
  }

  /// The selection moved by [delta] in the context's list (arrow keys).
  void _move(int delta) {
    if (_vault == null) return;
    setState(() {
      if (_context == CommandContext.entries) {
        final List<VaultEntry> l = _listed();
        final VaultEntry? c = _current;
        if (c == null) return;
        _selected = l[(l.indexOf(c) + delta).clamp(0, l.length - 1)].id;
      } else if (_context == CommandContext.sentences) {
        final List<VaultSlot> l = _vault!.header.slots;
        final VaultSlot? c = _currentSlot;
        if (c == null) return;
        _selectedSlot = l[(l.indexOf(c) + delta).clamp(0, l.length - 1)].id;
      }
    });
  }

  /// The folder shown moved by [delta] in the folders pane: all entries,
  /// then each folder (Left and Right).
  void _moveFolder(int delta) {
    if (_vault == null || _context != CommandContext.entries) return;
    final List<String?> l = <String?>[null, ..._folders()];
    setState(() =>
        _folder = l[(l.indexOf(_shownFolder) + delta).clamp(0, l.length - 1)]);
  }

  /// The entry dialog, for [entry] (edited) or a new one.
  Future<VaultEntry?> _entryDialog([VaultEntry? entry]) =>
      showDialog<VaultEntry>(
        context: context,
        builder: (BuildContext ctx) => _EntryDialog(
          themes: _themes!,
          strengths: _kStrengths,
          defaultStrength: _kDefaultStrength,
          rollBits: _rollBits,
          entry: entry,
          folders: _folders(),
        ),
      );

  /// The open vault's folders, each with its parents, sorted.
  List<String> _folders() {
    final Set<String> all = <String>{};
    for (final VaultEntry e in _vault!.contents.entries) {
      if (e.folder.isEmpty) continue;
      final List<String> parts = e.folder.split('/');
      for (int i = 1; i <= parts.length; i++) {
        all.add(parts.take(i).join('/'));
      }
    }
    return all.toList()..sort();
  }

  Future<void> _addEntry() async {
    final VaultEntry? e = await _entryDialog();
    if (e == null || !mounted) return;
    setState(() {
      _vault!.contents.entries.add(e);
      _selected = e.id;
    });
    await _save();
    _say('${e.label}: added.');
  }

  /// Edit [e] in place. A new secret starts its card afresh, if memorised.
  Future<void> _editEntry(VaultEntry e) async {
    final VaultEntry? edited = await _entryDialog(e);
    if (edited == null || !mounted) return;
    final VaultContents c = _vault!.contents;
    setState(() {
      c.entries[c.entries.indexOf(e)] = edited;
      if (edited.secret != e.secret && _entryCard(e) != null) {
        c.cards
          ..removeWhere((MemCard x) => x.factId == entryFact(e.id))
          ..add(MemCard.fact(entryFact(e.id)));
      }
    });
    await _save();
    _say('${edited.label}: saved.');
  }

  // --- the views --------------------------------------------------------------

  /// Whether a text field has the keys: the board's letters type then.
  bool get _typing {
    final BuildContext? c = FocusManager.instance.primaryFocus?.context;
    if (c == null) return false;
    return c.widget is EditableText ||
        c.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _setContext(CommandContext c) => setState(() {
        _context = c;
        _panelHidden = false;
        _explaining = null;
      });

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = e.logicalKey;
    if (key == LogicalKeyboardKey.f1) {
      setState(() => _panelHidden = !_panelHidden);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _root.requestFocus(); // out of any field: the board's keys again
      return KeyEventResult.handled;
    }
    if (!_typing &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      _move(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (!_typing &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _moveFolder(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      return KeyEventResult.handled;
    }
    final KeyEventResult board = _boardKey(e);
    if (board == KeyEventResult.handled) return board;
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

  /// A board key, by position: Alt + a top-row key picks the context;
  /// alone, it runs the context's command there.
  KeyEventResult _boardKey(KeyEvent e) {
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    if (_typing || kb.isControlPressed || kb.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final int at = kBoardKeys.indexOf(e.physicalKey);
    if (at < 0) return KeyEventResult.ignored;
    if (kb.isAltPressed) {
      for (final CommandContext c in kFormosaContexts) {
        if (c.key == at) {
          _setContext(c);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    final BoardCommand? c = _board()[at];
    if (c != null && c.enabled) c.run();
    return KeyEventResult.handled;
  }

  /// The context's commands, each at its board key; null where none is.
  List<BoardCommand?> _board() {
    final bool idle = _busy == null && _themes != null;
    final OpenVault? v = _vault;
    final bool open = v != null && idle;
    final List<BoardCommand?> b =
        List<BoardCommand?>.filled(kBoardKeys.length, null);
    void put(int at, String name, IconData icon, String help, VoidCallback run,
            {bool enabled = true}) =>
        b[at] = BoardCommand(
            name: name, help: help, icon: icon, run: run, enabled: enabled);
    switch (_context) {
      case CommandContext.vault:
        put(
            0,
            'New vault',
            Icons.add_box_outlined,
            'Makes a vault at the file path: its sentences, then Create.',
            _startCreate,
            enabled: idle && _view == _View.start);
        put(
            1,
            'Open',
            Icons.folder_open,
            'Opens the vault at the file path: its sentences, then Open.',
            _openFile,
            enabled: idle && _view == _View.start);
        put(
            2,
            'Open with the provisional key',
            Icons.key,
            'Opens it with its provisional key, scanned or typed; nothing is '
                'graded.',
            _unlockWithKey,
            enabled:
                idle && _view == _View.unlock && _header?.provisional != null);
        put(3, 'Lock', Icons.lock_outline,
            'Closes the vault, or leaves making or opening one.', _lock,
            enabled: idle && _view != _View.start);
        put(
            4,
            'Next due',
            Icons.school_outlined,
            'Reviews the next card due: the sentences\', then the memorised '
                'entries\'.',
            _nextDue,
            enabled: open);
        put(
            5,
            'T and ε',
            Icons.tune,
            'Sets this vault\'s graduation gate: the gap T and the threshold '
                'ε.',
            _setGate,
            enabled: open);
        put(
            6,
            'Retire the provisional key',
            Icons.key_off,
            'At the green light: from then on only k sentences open the vault.',
            _retireKey,
            enabled:
                open && v.header.provisional != null && _gate(v.header).passes);
        put(7, 'Add a provisional key', Icons.vpn_key_outlined,
            'A key that opens the vault alone, until you retire it.', _addKey,
            enabled: open && v.header.provisional == null);
      case CommandContext.entries:
        final VaultEntry? e = v == null ? null : _current;
        final bool on = open && e != null;
        put(0, 'Add entry', Icons.add,
            'A new entry: label, login, folder, secret and note.', _addEntry,
            enabled: open);
        put(
            1,
            'Edit entry',
            Icons.edit_outlined,
            'Edits the entry selected; a new secret starts its card afresh.',
            () => _editEntry(e!),
            enabled: on);
        put(2, 'Copy secret', Icons.copy,
            'Copies its secret, blind; cleared in 30 s.', () => _copy(e!),
            enabled: on);
        put(
            3,
            'Copy login',
            Icons.person_outline,
            'Copies its login, blind; cleared in 30 s.',
            () => _copyText(e!.login, '${e.label}\'s login'),
            enabled: on && e.login.isNotEmpty);
        b[4] = BoardCommand(
            name: 'Show secret',
            help: 'Shows or hides its secret on screen.',
            icon: Icons.visibility_outlined,
            active: e != null && _shown.contains(e.id),
            enabled: on,
            run: () => setState(() => _shown.contains(e!.id)
                ? _shown.remove(e.id)
                : _shown.add(e.id)));
        b[5] = BoardCommand(
            name: 'Memorise',
            help: 'Gives it a CPNF card, reviewed through Next due; again, '
                'drops it.',
            icon: Icons.school_outlined,
            active: e != null && _entryCard(e) != null,
            enabled: on,
            run: () => _toggleMemorise(e!));
        b[6] = BoardCommand(
            name: 'Hold to copy',
            help: 'Holds it to paste into another vault; again, lets it go.',
            icon: Icons.outbox_outlined,
            active: e != null && _isHeld(e),
            enabled: on,
            run: () => _toggleHold(e!));
        put(7, 'Remove entry', Icons.delete_outline,
            'Removes the entry selected, and its card.', () => _remove(e!),
            enabled: on);
        put(8, 'Paste held entries', Icons.move_to_inbox,
            'Copies the held entries into this vault.', _paste,
            enabled: open && _held.isNotEmpty && _canPaste);
        put(9, 'Discard held entries', Icons.clear_all,
            'Lets the held entries go.', () => setState(_discardHeld),
            enabled: _held.isNotEmpty);
      case CommandContext.sentences:
        put(
            0,
            'New sentence (system random)',
            Icons.casino_outlined,
            'A sentence to add, in the theme chosen, from system randomness.',
            () => _generateAdded(dice: false),
            enabled: open);
        put(
            1,
            'New sentence (Dragon Dice)',
            Icons.casino,
            'A sentence to add, in the theme chosen, from Dragon Dice.',
            () => _generateAdded(dice: true),
            enabled: open);
        put(2, 'Keep the new sentence, and rewrap', Icons.save_outlined,
            'Adds the new sentence: every k of n is wrapped anew.', _keepAdded,
            enabled: open && _added != null);
        final VaultSlot? s = v == null ? null : _currentSlot;
        put(
            3,
            'Retire the sentence',
            Icons.remove_circle_outline,
            'Retires the sentence selected: every k of the rest is wrapped '
                'anew.',
            () => _retire(s!),
            enabled: open && s != null && v.header.n > v.header.k);
      default: // the setup's contexts
    }
    return b;
  }

  /// The bottom panel, as the setup's: the board and the log, or, folded
  /// away (F1), one status line.
  Widget _panel() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget fold = IconButton(
      tooltip: _panelHidden ? 'Restore (F1)' : 'Collapse (F1)',
      icon: Icon(
          _panelHidden ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
      onPressed: () => setState(() => _panelHidden = !_panelHidden),
    );
    if (_panelHidden) {
      return Material(
        color: cs.surfaceContainerHighest,
        child: Row(
          children: <Widget>[
            const SizedBox(width: _kGap),
            Expanded(
                child: Text(_busy ?? _status,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            fold,
          ],
        ),
      );
    }
    final String? explaining = _explaining;
    return Material(
      color: cs.surfaceContainerHighest,
      child: SizedBox(
        height: kBoardHeight + _kPanelPadding * 2,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(_kPanelPadding),
              child: CommandBoard(
                active: _context,
                contexts: kFormosaContexts,
                commands: _board(),
                layout: _layout,
                colour: cs.onSurface,
                onContext: _setContext,
                onExplain: (String? s) => setState(() => _explaining = s),
                onCue: (String _) {},
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const SizedBox(width: _kGap),
                      const Expanded(child: Text('Log')),
                      fold,
                    ],
                  ),
                  if (_busy != null) ...<Widget>[
                    Text(_busy!),
                    LinearProgressIndicator(value: _progress),
                  ],
                  Expanded(
                    child: explaining != null
                        ? Padding(
                            padding: const EdgeInsets.all(_kGap),
                            child: Text(explaining))
                        // Newest at the bottom, where it stays anchored.
                        : ListView(
                            reverse: true,
                            padding:
                                const EdgeInsets.symmetric(horizontal: _kGap),
                            children: <Widget>[
                              for (final String line in _log) Text(line),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _themes == null
        ? Center(child: Text(_status.isEmpty ? 'Loading Formosa…' : _status))
        : switch (_view) {
            _View.start => _startView(),
            _View.create => _createView(),
            _View.unlock => _unlockView(),
            _View.entries => switch (_context) {
                CommandContext.vault => _keyPanel(_vault!),
                CommandContext.sentences => _sentencesPanel(_vault!),
                _ => _entriesView(),
              },
          };
    final Widget main =
        _view == _View.entries && _context != CommandContext.vault
            ? body
            : Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: _kFormWidth,
                  // A form scrolls only in a window too small for it.
                  child: SingleChildScrollView(child: body),
                ),
              );
    return Focus(
      focusNode: _root,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(_kGap * 2, _kGap, _kGap * 2, 0),
            child: Text(
                _held.isEmpty
                    ? 'Formosa — passwords'
                    : 'Formosa — passwords · ${_entriesText(_held.length)} '
                        'held to copy into another vault, in memory only: '
                        'lock, open the other vault, then paste (Entries).',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(_kGap * 2),
              child: main,
            ),
          ),
          _panel(),
        ],
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
          const Text('Then New vault or Open, on the Vault board.'),
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
            ],
          ),
        ],
      );

  /// Sentence [id] of a new vault, on one line: its theme, a draw from
  /// system randomness or Dragon Dice, and the sentence drawn.
  Widget _newSlotRow(int id) {
    final List<int>? bits = _newSentences[id];
    final formosa.Mnemonic m = _themes![_slotThemes[id]!];
    return Row(
      children: <Widget>[
        SizedBox(width: _kSlotLabelWidth, child: Text('Sentence $id')),
        SizedBox(
          width: _kThemeWidth,
          child: DropdownButton<String>(
            isExpanded: true,
            isDense: true,
            value: _slotThemes[id],
            items: <DropdownMenuItem<String>>[
              for (final String t in _sentenceThemes)
                DropdownMenuItem<String>(
                    value: t, child: Text(t, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (String? t) => setState(() {
              _slotThemes[id] = t!;
              _newSentences.remove(id);
            }),
          ),
        ),
        IconButton(
            tooltip: 'System random',
            onPressed: () => _generate(id, dice: false),
            icon: const Icon(Icons.casino_outlined)),
        IconButton(
            tooltip: 'Dragon Dice',
            onPressed: () => _generate(id, dice: true),
            icon: const Icon(Icons.casino)),
        Expanded(
          child: bits == null
              ? const SizedBox.shrink()
              : SelectableText(m.toRawSentence(bits)),
        ),
      ],
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
            child: _sentenceField(
                s, 'Sentence ${s.id} (${s.theme}) · ${_dueText(h, s.id)}'),
          ),
        const SizedBox(height: _kGap),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
              onPressed: _busy == null ? _unlock : null,
              child: const Text('Open')),
        ),
      ],
    );
  }

  /// Slot [s]'s sentence field, labelled [label]: hidden, with word
  /// completion and Moon Cake; its mark shows a whole raw sentence.
  Widget _sentenceField(VaultSlot s, String label) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _inputs[s.id]!,
        builder: (BuildContext _, TextEditingValue __, Widget? ___) => Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _inputs[s.id],
                obscureText: true,
                onSubmitted: (_) => _complete(s),
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: label,
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
      );

  /// Three panes: the folders, the entries listed, the entry selected.
  Widget _entriesView() {
    final OpenVault v = _vault!;
    final String? folder = _shownFolder;
    final VaultEntry? current = _current;
    Widget folderTile(String? f) => ListTile(
          dense: true,
          selected: f == folder,
          contentPadding: EdgeInsets.only(
              left: f == null
                  ? 0
                  : _kFolderIndent * ('/'.allMatches(f).length + 1)),
          leading: Icon(f == null ? Icons.folder_special : Icons.folder),
          title: Text(f == null ? 'All entries' : f.split('/').last),
          onTap: () => setState(() => _folder = f),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: _kFolderPaneWidth,
          child: ListView(
            children: <Widget>[
              folderTile(null),
              for (final String f in _folders()) folderTile(f),
            ],
          ),
        ),
        const VerticalDivider(width: _kGap * 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('${_entriesText(v.contents.entries.length)} · any '
                  '${v.header.k} of ${v.header.n} sentences open it.'),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    for (final VaultEntry e in _listed())
                      ListTile(
                        dense: true,
                        selected: e.id == current?.id,
                        title: Text(e.label),
                        subtitle: Text(<String>[
                          if (folder == null && e.folder.isNotEmpty)
                            'in ${e.folder}',
                          if (e.login.isNotEmpty) e.login,
                        ].join(' · ')),
                        onTap: () => setState(() => _selected = e.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: _kGap * 2),
        SizedBox(
          width: _kDetailPaneWidth,
          child: current == null
              ? const Text('No entry here: Add entry, on the Entries board.')
              : _entryDetails(current),
        ),
      ],
    );
  }

  /// Entry [e] in full: its secret hidden unless shown.
  Widget _entryDetails(VaultEntry e) {
    final MemCard? card = _entryCard(e);
    return ListView(
      children: <Widget>[
        Text(e.label, style: Theme.of(context).textTheme.titleMedium),
        if (e.folder.isNotEmpty) Text('Folder: ${e.folder}'),
        if (e.login.isNotEmpty) Text('Login: ${e.login}'),
        Text('Secret: ${_shown.contains(e.id) ? e.secret : '••••••••'}'),
        if (e.note.isNotEmpty) Text('Note: ${e.note}'),
        Text(card == null
            ? 'Not memorised.'
            : 'Memorised${card.due == null ? '' : ': next review '
                '${dateText(card.due!)}'}.'),
        if (_isHeld(e)) const Text('Held to copy into another vault.'),
      ],
    );
  }

  /// The provisional key and the graduation gate that retires it.
  Widget _keyPanel(OpenVault v) {
    final VaultHeader h = v.header;
    final ({double failure, bool passes}) g = _gate(h);
    final bool kept = h.provisional != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Graduation: after ${durationText(_gapOf(h))}, '
            '${chanceText(g.failure)} chance of recalling fewer than ${h.k} of '
            'the ${h.n} sentences (ε ${chanceText(_epsilonOf(h))}): '
            '${g.passes ? 'green light' : 'not yet'}.'),
        Text(kept
            ? 'The provisional key opens the vault alone, until you retire it.'
            : 'No provisional key: only ${h.k} sentences open the vault.'),
      ],
    );
  }

  /// The master secret's sentences, each with when it is next due; adding
  /// one on the right — each change rewraps the vault.
  Widget _sentencesPanel(OpenVault v) {
    final VaultHeader h = v.header;
    final VaultSlot? current = _currentSlot;
    final formosa.Mnemonic? m =
        _added == null ? null : _themes![_addTheme ?? _sentenceThemes.first];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Sentences: any ${h.k} of ${h.n} open the vault. Each is '
                  'reviewed when you enter it to open the vault, or through '
                  'Next due.'),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    for (final VaultSlot s in h.slots)
                      ListTile(
                        dense: true,
                        selected: s.id == current?.id,
                        title: Text('Sentence ${s.id} (${s.theme})'),
                        subtitle: Text(_dueText(h, s.id)),
                        onTap: () => setState(() => _selectedSlot = s.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: _kGap * 2),
        SizedBox(
          width: _kDetailPaneWidth,
          child: ListView(
            children: <Widget>[
              const Text('Add a sentence, in the theme:'),
              DropdownButton<String>(
                isExpanded: true,
                value: _addTheme ?? _sentenceThemes.first,
                items: <DropdownMenuItem<String>>[
                  for (final String t in _sentenceThemes)
                    DropdownMenuItem<String>(
                        value: t,
                        child: Text(t, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (String? t) => setState(() {
                  _addTheme = t;
                  _added = null;
                }),
              ),
              if (m != null) SelectableText(m.toRawSentence(_added!)),
            ],
          ),
        ),
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
        reveal: widget.entry.secret,
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
    this.entry,
    this.folders = const <String>[],
  });

  /// The entry edited; null for a new one.
  final VaultEntry? entry;

  /// The vault's folders, suggested.
  final List<String> folders;
  final formosa.ThemeSet themes;
  final List<int> strengths;
  final int defaultStrength;
  final Future<List<int>?> Function(int bits, String purpose) rollBits;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late final TextEditingController _label =
      TextEditingController(text: widget.entry?.label);
  late final TextEditingController _login =
      TextEditingController(text: widget.entry?.login);
  late final TextEditingController _folder =
      TextEditingController(text: widget.entry?.folder);
  late final TextEditingController _secret =
      TextEditingController(text: widget.entry?.secret);
  late final TextEditingController _note =
      TextEditingController(text: widget.entry?.note);
  late String _theme = widget.themes.names.contains(formosa.kDefaultTheme)
      ? formosa.kDefaultTheme
      : widget.themes.names.first;
  late int _strength = widget.defaultStrength;
  late String _mnemonic = widget.entry?.mnemonic ?? '';

  static const int _kBitsPerByte = 8;

  @override
  void dispose() {
    _label.dispose();
    _login.dispose();
    _folder.dispose();
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
      title: Text(widget.entry == null ? 'Add entry' : 'Edit entry'),
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
                controller: _login,
                decoration:
                    const InputDecoration(labelText: 'Login (optional)'),
              ),
              const SizedBox(height: _FormosaScreenState._kGap),
              DropdownMenu<String>(
                controller: _folder,
                expandedInsets: EdgeInsets.zero,
                enableFilter: true,
                requestFocusOnTap: true,
                label: const Text('Folder (optional, e.g. Work/Mail)'),
                dropdownMenuEntries: <DropdownMenuEntry<String>>[
                  for (final String f in widget.folders)
                    DropdownMenuEntry<String>(value: f, label: f),
                ],
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
              id: widget.entry?.id ??
                  '${DateTime.now().microsecondsSinceEpoch}',
              label: _label.text.trim(),
              secret: _secret.text,
              login: _login.text.trim(),
              folder: normalFolder(_folder.text),
              note: _note.text.trim(),
              mnemonic: _mnemonic,
            ));
          },
          child: Text(widget.entry == null ? 'Add' : 'Save'),
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

/// The provisional key, to open the vault: scanned from its QR (the Great
/// Wall's serves too), or typed as 32 or 64 hex digits.
class _KeyEntryDialog extends StatefulWidget {
  const _KeyEntryDialog();

  @override
  State<_KeyEntryDialog> createState() => _KeyEntryDialogState();
}

class _KeyEntryDialogState extends State<_KeyEntryDialog> {
  final TextEditingController _hex = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final Uint8List? k = await scanKey(context);
    if (k == null || !mounted) return;
    if (!SetupCrypto.isValidKeyLen(k.length)) {
      wipeKey(k);
      setState(() => _error = 'That QR is not a valid provisional key.');
      return;
    }
    Navigator.of(context).pop(k);
  }

  void _typed() {
    try {
      final Uint8List k = SetupCrypto.hexToKey(_hex.text);
      _hex.clear();
      Navigator.of(context).pop(k);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Open with the provisional key'),
        content: SizedBox(
          width: _FormosaScreenState._kWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _hex,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _typed(),
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Key — 32 or 64 hex digits',
                  errorText: _error,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          if (keyScanSupported)
            TextButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan'),
            ),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(onPressed: _typed, child: const Text('Open')),
        ],
      );
}

/// The gate's `T` (days) and `ε` (%) for one vault, the gate previewed as
/// you type. Pops the settings to keep (null for a default), or null.
class _GateDialog extends StatefulWidget {
  const _GateDialog({
    required this.header,
    required this.defaultGap,
    required this.defaultEpsilon,
    required this.preview,
  });

  final VaultHeader header;
  final Duration defaultGap;
  final double defaultEpsilon;
  final ({double failure, bool passes}) Function(Duration gap, double epsilon)
      preview;

  @override
  State<_GateDialog> createState() => _GateDialogState();
}

class _GateDialogState extends State<_GateDialog> {
  late final TextEditingController _days = TextEditingController(
      text: widget.header.gapSeconds == null
          ? ''
          : '${widget.header.gapSeconds! / Duration.secondsPerDay}');
  late final TextEditingController _percent = TextEditingController(
      text: widget.header.epsilon == null
          ? ''
          : '${widget.header.epsilon! * _FormosaScreenState._kPercentScale}');

  @override
  void dispose() {
    _days.dispose();
    _percent.dispose();
    super.dispose();
  }

  /// A positive number in [c], or null (empty: the default).
  static double? _positive(TextEditingController c) {
    final double? v = double.tryParse(c.text.trim());
    return v != null && v > 0 ? v : null;
  }

  bool _invalid(TextEditingController c) =>
      c.text.trim().isNotEmpty && _positive(c) == null;

  @override
  Widget build(BuildContext context) {
    final double? days = _positive(_days);
    final double? pct = _positive(_percent);
    final Duration gap = days == null
        ? widget.defaultGap
        : Duration(seconds: (days * Duration.secondsPerDay).round());
    final double eps = pct == null
        ? widget.defaultEpsilon
        : pct / _FormosaScreenState._kPercentScale;
    final ({double failure, bool passes}) g = widget.preview(gap, eps);
    final VaultHeader h = widget.header;
    Widget field(TextEditingController c, String label, String hint) =>
        SizedBox(
          width: _FormosaScreenState._kGateFieldWidth,
          child: TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: label,
              hintText: hint,
              errorText: _invalid(c) ? 'a positive number' : null,
            ),
          ),
        );
    return AlertDialog(
      title: const Text('Graduation: T and ε'),
      content: SizedBox(
        width: _FormosaScreenState._kWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('The provisional key may be retired once the chance of '
                'recalling fewer than k sentences after T is at most ε. Each '
                'sentence counts by its forgetting curve; one never graded '
                'counts as forgotten. An empty field keeps the default.'),
            const SizedBox(height: _FormosaScreenState._kGap),
            Wrap(
              spacing: _FormosaScreenState._kGap,
              children: <Widget>[
                field(_days, 'T (days)', durationText(widget.defaultGap)),
                field(_percent, 'ε (%)', chanceText(widget.defaultEpsilon)),
              ],
            ),
            const SizedBox(height: _FormosaScreenState._kGap),
            Text('After ${durationText(gap)}, ${chanceText(g.failure)} chance '
                'of recalling fewer than ${h.k} of the ${h.n} sentences: '
                '${g.passes ? 'green light' : 'not yet'}.'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _invalid(_days) || _invalid(_percent)
              ? null
              : () => Navigator.of(context).pop((
                    gapSeconds: days == null ? null : gap.inSeconds,
                    epsilon: pct == null ? null : eps,
                  )),
          child: const Text('Set'),
        ),
      ],
    );
  }
}
