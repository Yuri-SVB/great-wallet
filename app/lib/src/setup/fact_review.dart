/// The review dialogs of the fact cards: an answer is checked, then graded —
/// the four grades after a find, Again only after a miss (or a find that may
/// not be scored). Each returns the grade, or null when nothing is graded
/// (cancelled before the check, or practice).
library;

import 'dart:async';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show Grade, MemCard;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../command/command_board.dart' show DeadGlyph, SweatGlyph;
import 'fact_cards.dart';

/// What a checked answer shows.
class FactCheck {
  const FactCheck(
      {required this.hit, required this.message, this.scored = true});

  final bool hit;
  final String message;

  /// Whether a hit may take a grade above Again.
  final bool scored;
}

/// Width of the fact dialogs.
const double _kFactDialogWidth = 460;
const double _kGap = 12;

/// The frame every fact dialog shares: [about], the inputs ([body]), Check
/// (running [check]), the result, and the grades. [practice], when set, is
/// why the attempt is practice: nothing is graded.
class FactReviewFrame extends StatefulWidget {
  const FactReviewFrame({
    super.key,
    required this.title,
    required this.about,
    required this.body,
    required this.check,
    this.practice,
  });

  final String title;
  final String about;
  final Widget body;
  final Future<FactCheck> Function() check;
  final String? practice;

  @override
  State<FactReviewFrame> createState() => _FactReviewFrameState();
}

class _FactReviewFrameState extends State<FactReviewFrame> {
  FactCheck? _result;
  bool _checking = false;

  Future<void> _check() async {
    if (_checking || _result != null) return;
    setState(() => _checking = true);
    FactCheck r;
    try {
      r = await widget.check();
    } on Object catch (e) {
      // The check could not run (a harvest that failed): nothing is decided.
      if (mounted) {
        setState(() => _checking = false);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (mounted) {
      setState(() {
        _checking = false;
        _result = r;
      });
    }
  }

  /// Leave: nothing graded before the check or in practice; after a miss, or
  /// a find that may not be scored, Again.
  void _leave() {
    final FactCheck? r = _result;
    if (r == null || widget.practice != null) {
      Navigator.of(context).pop();
    } else if (!(r.hit && r.scored)) {
      Navigator.of(context).pop(Grade.again);
    }
    // After a scored find a grade is chosen: there is no leaving without one.
  }

  @override
  Widget build(BuildContext context) {
    final FactCheck? r = _result;
    final bool grading = r != null && widget.practice == null;
    final bool fourGrades = grading && r.hit && r.scored;
    final Color ink = Theme.of(context).colorScheme.onSurface;
    Widget grade(Grade g, Widget icon, String label) => TextButton.icon(
          onPressed: () => Navigator.of(context).pop(g),
          icon: icon,
          label: Text(label),
        );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _leave,
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: _kFactDialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(widget.about),
                const SizedBox(height: _kGap),
                AbsorbPointer(absorbing: r != null, child: widget.body),
                if (_checking) ...<Widget>[
                  const SizedBox(height: _kGap),
                  const LinearProgressIndicator(),
                ],
                if (r != null) ...<Widget>[
                  const SizedBox(height: _kGap),
                  Text(
                    widget.practice == null
                        ? r.message
                        : '${r.message} (Practice: ${widget.practice}.)',
                    style: TextStyle(
                      color: r.hit
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          if (r == null) ...<Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _checking ? null : () => unawaited(_check()),
              child: const Text('Check'),
            ),
          ] else if (!grading)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            )
          else ...<Widget>[
            grade(Grade.again, DeadGlyph(colour: ink), 'Again'),
            if (fourGrades) ...<Widget>[
              grade(Grade.hard, SweatGlyph(colour: ink), 'Hard'),
              grade(Grade.good, const Icon(Icons.sentiment_satisfied), 'Good'),
              grade(Grade.easy, const Icon(Icons.sentiment_very_satisfied),
                  'Easy'),
            ],
          ],
        ],
      ),
    );
  }
}

/// One of your own cards: its prompt, and the answer typed.
class CustomFactDialog extends StatefulWidget {
  const CustomFactDialog({super.key, required this.fact, this.practice});

  final CustomFact fact;
  final String? practice;

  @override
  State<CustomFactDialog> createState() => _CustomFactDialogState();
}

class _CustomFactDialogState extends State<CustomFactDialog> {
  final TextEditingController _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: widget.fact.prompt,
        about: 'Your own card: type its answer (case and extra spaces do not '
            'count).',
        practice: widget.practice,
        body: TextField(
          controller: _answer,
          autofocus: true,
          maxLength: kMaxFactChars,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            labelText: 'Answer',
          ),
        ),
        check: () async {
          final bool hit = answerMatches(_answer.text, widget.fact.answer);
          return FactCheck(
            hit: hit,
            message: hit
                ? 'Right.'
                : 'Missed — the answer is "${widget.fact.answer}".',
          );
        },
      );
}

/// What the supply-chain card is, for "What is this?".
const String kProvenanceAbout =
    'Supply chain: could you rebuild this app yourself, as after a hard reset '
    'on a new device? Clone the great-wallet repository anew, check out this '
    'release, build it (dependencies included), run it, and paste the '
    'release\'s commit digest from `git log` (all 40 hex digits). Only with '
    '"$kProvenanceConfirm" ticked can it be scored above Again.';

/// The supply-chain card's confirmation.
const String kProvenanceConfirm = 'I was able to clone, build and run the app.';

/// The supply-chain card: the release's digest pasted, and the build
/// confirmed. [commit] is this build's digest (empty: unknown).
class ProvenanceDialog extends StatefulWidget {
  const ProvenanceDialog({
    super.key,
    this.commit = kBuildCommit,
    this.practice,
  });

  final String commit;
  final String? practice;

  @override
  State<ProvenanceDialog> createState() => _ProvenanceDialogState();
}

class _ProvenanceDialogState extends State<ProvenanceDialog> {
  final TextEditingController _digest = TextEditingController();
  bool _built = false;

  @override
  void dispose() {
    _digest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: 'Supply chain',
        about: kProvenanceAbout,
        practice: widget.practice,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _digest,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Release commit digest',
              ),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _built,
              onChanged: (bool? v) => setState(() => _built = v ?? false),
              title: const Text(kProvenanceConfirm),
            ),
          ],
        ),
        check: () async {
          final bool? same = digestMatches(_digest.text, commit: widget.commit);
          if (same == null) {
            return const FactCheck(
              hit: false,
              scored: false,
              message: 'This build\'s digest is unknown (it was built without '
                  'app/tool/build.sh): only Again can be scored.',
            );
          }
          if (!same) {
            return const FactCheck(
                hit: false, message: 'Missed — not this build\'s digest.');
          }
          return FactCheck(
            hit: true,
            scored: _built,
            message: _built
                ? 'Right: this build\'s digest.'
                : 'Right digest — but without the rebuild confirmed, only '
                    'Again can be scored.',
          );
        },
      );
}

/// The memory profile's card (`m`): this setup's profile picked from
/// [labels], [answer] its index.
class ProfileDialog extends StatefulWidget {
  const ProfileDialog({
    super.key,
    required this.labels,
    required this.answer,
    this.practice,
  });

  final List<String> labels;
  final int answer;
  final String? practice;

  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  int? _picked;

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: factName(
            MemCard.fact(kProfileFact), const <String, CustomFact>{}),
        about: 'The Argon2 memory profile this setup derives with, as you would '
            'set it for a hard reset on a new device.',
        practice: widget.practice,
        body: Wrap(
          spacing: _kGap / 2,
          children: <Widget>[
            for (int i = 0; i < widget.labels.length; i++)
              ChoiceChip(
                label: Text(widget.labels[i]),
                selected: _picked == i,
                onSelected: (bool on) =>
                    setState(() => _picked = on ? i : null),
              ),
          ],
        ),
        check: () async {
          final bool hit = _picked == widget.answer;
          return FactCheck(
            hit: hit,
            message: hit
                ? 'Right.'
                : 'Missed — this setup\'s is ${widget.labels[widget.answer]}.',
          );
        },
      );
}

/// A count's card (`D` or `N`, by [factId]): the number typed, compared with
/// this setup's [answer].
class CountDialog extends StatefulWidget {
  const CountDialog({
    super.key,
    required this.factId,
    required this.answer,
    this.practice,
  });

  final String factId;
  final int answer;
  final String? practice;

  @override
  State<CountDialog> createState() => _CountDialogState();
}

class _CountDialogState extends State<CountDialog> {
  final TextEditingController _count = TextEditingController();

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: factName(
            MemCard.fact(widget.factId), const <String, CustomFact>{}),
        about: widget.factId == kStagesFact
            ? 'How many deep stages this setup has, beyond stage 0.'
            : 'How many Argon2 iterations each stage\'s derivation runs (the '
                'derivation steps per stage).',
        practice: widget.practice,
        body: TextField(
          controller: _count,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: widget.factId,
          ),
        ),
        check: () async {
          final bool hit = int.tryParse(_count.text) == widget.answer;
          return FactCheck(
            hit: hit,
            message: hit
                ? 'Right.'
                : 'Missed — this setup\'s is ${widget.answer}.',
          );
        },
      );
}

/// A stage's selection card: which of its [maps] maps you study, ticked from
/// memory and compared with [studied].
class SelectionDialog extends StatefulWidget {
  const SelectionDialog({
    super.key,
    required this.stage,
    required this.maps,
    required this.studied,
    this.practice,
  });

  final int stage;
  final int maps;
  final Set<int> studied;
  final String? practice;

  @override
  State<SelectionDialog> createState() => _SelectionDialogState();
}

class _SelectionDialogState extends State<SelectionDialog> {
  final Set<int> _ticked = <int>{};

  String _list(Set<int> s) => (s.toList()..sort()).join(', ');

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: factName(MemCard.fact(selectionFact(widget.stage)),
            const <String, CustomFact>{}),
        about: 'Tick the maps of stage ${widget.stage} you study — the ones '
            'whose points you recall. Two maps can look alike: knowing which '
            'ones are yours keeps you from trying the wrong one.',
        practice: widget.practice,
        body: Wrap(
          spacing: _kGap / 2,
          children: <Widget>[
            for (int j = 1; j <= widget.maps; j++)
              FilterChip(
                label: Text('$j'),
                selected: _ticked.contains(j),
                onSelected: (bool on) => setState(
                    () => on ? _ticked.add(j) : _ticked.remove(j)),
              ),
          ],
        ),
        check: () async {
          final bool hit = selectionMatches(_ticked, widget.studied);
          return FactCheck(
            hit: hit,
            message: hit
                ? 'Right.'
                : 'Missed — you study maps ${_list(widget.studied)}.',
          );
        },
      );
}

/// The Namtso salt's card: its date, re-harvested and compared with the
/// stored σ, or σ itself; and, optionally, a burial's date and label,
/// unburied and compared with the setup's orbit points (informative only).
class SaltDialog extends StatefulWidget {
  const SaltDialog({
    super.key,
    required this.sigma,
    required this.orbits,
    required this.harvest,
    required this.unbury,
    this.practice,
  });

  /// The stored σ (hex), and each stage's `o_i` (null where none is stored).
  final String sigma;
  final List<List<int>?> orbits;

  /// σ harvested at a date, and the bytes buried under a label at a date, as
  /// hex.
  final Future<String> Function(DateTime date) harvest;
  final Future<String> Function(String label, DateTime date) unbury;
  final String? practice;

  @override
  State<SaltDialog> createState() => _SaltDialogState();
}

class _SaltDialogState extends State<SaltDialog> {
  bool _byDate = true;
  DateTime? _date;
  final TextEditingController _sigma = TextEditingController();
  DateTime? _burialDate;
  final TextEditingController _label = TextEditingController();

  /// Bitcoin's genesis: no date before it can be harvested.
  static final DateTime _genesis = DateTime(2009, 1, 3);

  @override
  void dispose() {
    _sigma.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime? initial) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    return showDatePicker(
      context: context,
      initialDate: initial ?? today,
      firstDate: _genesis,
      lastDate: today,
    );
  }

  static String _day(DateTime? d) => d == null
      ? 'Pick a date'
      : '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  Future<FactCheck> _check() async {
    final bool hit;
    if (_byDate) {
      final DateTime? d = _date;
      if (d == null) {
        return const FactCheck(
            hit: false, scored: false, message: 'Pick the date first.');
      }
      hit = sigmaMatches(await widget.harvest(d), widget.sigma);
    } else {
      hit = sigmaMatches(_sigma.text, widget.sigma);
    }
    String burial = '';
    final DateTime? bd = _burialDate;
    if (bd != null && _label.text.trim().isNotEmpty) {
      try {
        final List<int>? data =
            hexBytes(await widget.unbury(_label.text.trim(), bd));
        final int? stage =
            data == null ? null : buriedStage(data, widget.orbits);
        burial = stage == null
            ? ' The burial does not match any stage of this setup.'
            : ' The burial is stage $stage\'s orbit point.';
      } on Object catch (e) {
        burial = ' Burial not checked: $e';
      }
    }
    return FactCheck(
      hit: hit,
      message: (hit
              ? 'Right: that is this setup\'s σ.'
              : 'Missed — not this '
                  'setup\'s σ.') +
          burial,
    );
  }

  @override
  Widget build(BuildContext context) => FactReviewFrame(
        title: 'Salt (Namtso)',
        about: 'The salt σ roots the whole setup. Give its date (σ is '
            'harvested again from the timechain, which takes the network) or '
            'σ itself. Optionally, a burial\'s date and label, to check it '
            'brings back one of this setup\'s orbit points.',
        practice: widget.practice,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('By date')),
                ButtonSegment<bool>(value: false, label: Text('By σ')),
              ],
              selected: <bool>{_byDate},
              onSelectionChanged: (Set<bool> s) =>
                  setState(() => _byDate = s.first),
            ),
            const SizedBox(height: _kGap),
            if (_byDate)
              OutlinedButton(
                onPressed: () async {
                  final DateTime? d = await _pick(_date);
                  if (d != null) setState(() => _date = d);
                },
                child: Text(_day(_date)),
              )
            else
              TextField(
                controller: _sigma,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'σ (hex)',
                ),
              ),
            const SizedBox(height: _kGap),
            const Text('Burial (optional)'),
            Row(
              children: <Widget>[
                OutlinedButton(
                  onPressed: () async {
                    final DateTime? d = await _pick(_burialDate);
                    if (d != null) setState(() => _burialDate = d);
                  },
                  child: Text(_day(_burialDate)),
                ),
                const SizedBox(width: _kGap),
                Expanded(
                  child: TextField(
                    controller: _label,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Label',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        check: _check,
      );
}
