/// Fact cards: what a setup asks you to recall besides its maps — the Namtso
/// salt, the setup's parameters (`m`, `D`, `N`), the build you can rebuild
/// (supply chain), and your own cards. Their
/// cards live in the CPNF deck (ids only); the answers of your own cards ride
/// in the setup's encrypted payload ([CustomFact]).
library;

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show CardKind, MemCard, MemSchedule;

/// The Namtso salt's card (always on): its date re-harvested, or σ itself.
const String kSaltFact = 'salt';

/// The setup's parameters (always on), recalled for a hard reset on a new
/// device: the Argon2 memory profile `m`, the Argon2 derivation iterations
/// per stage `D`, and the number of deep stages `N`.
const String kProfileFact = 'm';
const String kIterationsFact = 'D';
const String kStagesFact = 'N';
const List<String> kParameterFacts = <String>[
  kProfileFact,
  kIterationsFact,
  kStagesFact,
];

/// The maps (fractal slots) of a stage, numbered from 1.
const int kMapsPerStage = 9;

/// The prefix of the selection cards' ids, `maps:<stage>`: which of a stage's
/// maps you study, so a map that looks like another is not the one tried.
const String kSelectionPrefix = 'maps:';

/// The selection card of [stage].
String selectionFact(int stage) => '$kSelectionPrefix$stage';

/// The stage a selection card is for, or null for any other fact.
int? selectionStage(String factId) => factId.startsWith(kSelectionPrefix)
    ? int.tryParse(factId.substring(kSelectionPrefix.length))
    : null;

/// Whether the maps ticked, [given], are exactly the ones studied, [studied].
bool selectionMatches(Set<int> given, Set<int> studied) =>
    given.length == studied.length && given.containsAll(studied);

/// Whether a fact card holds until [at]: its chance of recall then, by the
/// forgetting curve, is at least the chance when due (`r*`). A fact is one
/// answer with no forgiveness, so it gates graduation this way, not by `ε`.
bool factHolds(MemSchedule schedule, MemCard card, DateTime at) =>
    (schedule.recall(card, at) ?? 0) >= schedule.forgetting.retentionAtDue;

/// The supply-chain card (optional): the release's commit digest, pasted
/// after cloning, building and running it anew.
const String kProvenanceFact = 'provenance';

/// The prefix of your own cards' ids.
const String kCustomPrefix = 'misc:';

/// Your own cards: at most this many, each prompt and answer at most this
/// many characters (so the setup fits its padded size).
const int kMaxCustomFacts = 64;
const int kMaxFactChars = 256;

/// The commit this build was made from, embedded by `build.sh`
/// (`--dart-define=GW_COMMIT=…`); empty when built without it.
const String kBuildCommit = String.fromEnvironment('GW_COMMIT');

/// A full commit digest's length in hex digits.
const int kCommitHexDigits = 40;

/// One of your own cards: a prompt and its answer.
class CustomFact {
  const CustomFact({
    required this.id,
    required this.prompt,
    required this.answer,
  });

  /// Its card's fact id, `misc:<n>`.
  final String id;
  final String prompt;
  final String answer;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'prompt': prompt,
        'answer': answer,
      };

  /// Throws a [FormatException] that echoes no value on any bad field.
  factory CustomFact.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? prompt = json['prompt'];
    final Object? answer = json['answer'];
    if (id is! String ||
        !id.startsWith(kCustomPrefix) ||
        prompt is! String ||
        answer is! String ||
        prompt.trim().isEmpty ||
        answer.trim().isEmpty ||
        prompt.length > kMaxFactChars ||
        answer.length > kMaxFactChars) {
      throw const FormatException('bad fact');
    }
    return CustomFact(id: id, prompt: prompt, answer: answer);
  }
}

/// Whether [card] is a fact this app reviews.
bool isReviewedFact(MemCard card) =>
    card.kind == CardKind.fact &&
    (card.factId == kSaltFact ||
        kParameterFacts.contains(card.factId) ||
        card.factId.startsWith(kSelectionPrefix) ||
        card.factId == kProvenanceFact ||
        card.factId.startsWith(kCustomPrefix));

/// A fact card's name.
String factName(MemCard card, Map<String, CustomFact> custom) =>
    switch (card.factId) {
      kSaltFact => 'Salt (Namtso)',
      kProfileFact => 'Memory profile (m)',
      kIterationsFact => 'Derivation steps (D)',
      kStagesFact => 'Deep stages (N)',
      kProvenanceFact => 'Supply chain',
      final String id when selectionStage(id) != null =>
        'Maps you study, stage ${selectionStage(id)}',
      final String id => custom[id]?.prompt ?? id,
    };

/// Text as compared: trimmed, inner spaces collapsed, any case.
String _normal(String s) =>
    s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Whether [given] is [answer], ignoring case and extra spaces.
bool answerMatches(String given, String answer) =>
    _normal(given) == _normal(answer);

/// Hex as compared: no spaces, an optional `0x`, any case.
String _hex(String s) =>
    s.replaceAll(RegExp(r'\s'), '').toLowerCase().replaceFirst('0x', '');

/// Whether the σ [given] (hex) is the stored [sigma].
bool sigmaMatches(String given, String sigma) =>
    _hex(given).isNotEmpty && _hex(given) == _hex(sigma);

/// Whether the pasted commit digest [given] is this build's [commit]: null
/// when the build's digest is unknown (built without `build.sh`).
bool? digestMatches(String given, {String commit = kBuildCommit}) {
  if (commit.length != kCommitHexDigits) return null;
  return _hex(given) == commit.toLowerCase();
}

/// The deep stage whose orbit point `o_i` is [data] (64 bytes unburied), or
/// null: [orbits] holds each stage's `o_i`, null where there is none.
int? buriedStage(List<int> data, List<List<int>?> orbits) {
  for (int i = 0; i < orbits.length; i++) {
    final List<int>? o = orbits[i];
    if (o == null || o.length != data.length) continue;
    bool same = true;
    for (int k = 0; same && k < o.length; k++) {
      same = o[k] == data[k];
    }
    if (same) return i;
  }
  return null;
}

/// [hex] as bytes, or null if it is not whole hex bytes.
List<int>? hexBytes(String hex) {
  final String h = _hex(hex);
  if (h.isEmpty || h.length.isOdd || !RegExp(r'^[0-9a-f]+$').hasMatch(h)) {
    return null;
  }
  return <int>[
    for (int i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ];
}
