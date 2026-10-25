/// Spaced-repetition **score tracking** for the orbit deck — protocol 0.5.0,
/// review mode 1 (no TLP).
///
/// A card's front is θ_i_j (the board's fractal) and its back is p_i_j (the
/// placed point). Both are sensitive and are NEVER stored here — they are gated
/// by the hard derivation itself and re-derived when the user studies. What this
/// layer keeps is ONLY the third stream: the per-card memory history (its
/// spaced-repetition schedule). A card is identified purely by its position
/// `(stageIndex, boardIndex)` within a named deck, which reveals nothing about
/// θ or p.
///
/// Modes 2 (TLP-encrypted fronts + KDF'd p-vault) and 3 (device-dependent
/// subdecks exhausting the 3-of-s combinations) build on top of this; they are
/// deliberately out of scope here.
library;

/// How well the user recalled a card, mapped to an SM-2 quality grade.
enum ReviewGrade {
  /// Failed to recall — the card lapses and comes back immediately.
  again,

  /// Recalled, but with difficulty.
  hard,

  /// Recalled correctly.
  good,

  /// Recalled effortlessly.
  easy,
}

/// The persisted memory history of a single card — position + SM-2 schedule.
/// Contains NO θ_i_j / p_i_j / coordinates; only scheduling numbers.
class OrbitCardScore {
  OrbitCardScore({
    required this.stageIndex,
    required this.boardIndex,
    this.repetitions = 0,
    this.intervalDays = 0,
    this.easeFactor = 2.5,
    this.due,
    this.lastReviewed,
    this.lapses = 0,
  });

  /// Which stage this card's board belongs to (0 = stage 0, `1..N` deep).
  final int stageIndex;

  /// Which board within the stage (`0..t_i-1`).
  final int boardIndex;

  /// Consecutive successful recalls (resets to 0 on a lapse).
  int repetitions;

  /// Current inter-review interval, in days.
  int intervalDays;

  /// SM-2 ease factor (>= 1.3); higher = intervals grow faster.
  double easeFactor;

  /// When this card is next due. Null ⇒ new (never reviewed).
  DateTime? due;

  /// When this card was last reviewed. Null ⇒ new.
  DateTime? lastReviewed;

  /// How many times the card has lapsed (been graded [ReviewGrade.again]).
  int lapses;

  /// A never-reviewed card.
  bool get isNew => lastReviewed == null;

  /// Whether the card is due at [now] (new cards are always due).
  bool isDue(DateTime now) => due == null || !due!.isAfter(now);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stage': stageIndex,
        'board': boardIndex,
        'reps': repetitions,
        'intervalDays': intervalDays,
        'ease': easeFactor,
        'due': due?.toIso8601String(),
        'last': lastReviewed?.toIso8601String(),
        'lapses': lapses,
      };

  factory OrbitCardScore.fromJson(Map<String, dynamic> j) => OrbitCardScore(
        stageIndex: (j['stage'] as num).toInt(),
        boardIndex: (j['board'] as num).toInt(),
        repetitions: (j['reps'] as num?)?.toInt() ?? 0,
        intervalDays: (j['intervalDays'] as num?)?.toInt() ?? 0,
        easeFactor: (j['ease'] as num?)?.toDouble() ?? 2.5,
        due: _parseDate(j['due']),
        lastReviewed: _parseDate(j['last']),
        lapses: (j['lapses'] as num?)?.toInt() ?? 0,
      );

  static DateTime? _parseDate(Object? v) =>
      (v is String && v.isNotEmpty) ? DateTime.tryParse(v) : null;

  @override
  String toString() =>
      'OrbitCardScore(s$stageIndex/b$boardIndex reps=$repetitions '
      'ivl=${intervalDays}d ease=${easeFactor.toStringAsFixed(2)} '
      'lapses=$lapses)';
}

/// The classic SM-2 scheduler (SuperMemo-2 / Anki-style). Pure: it mutates and
/// returns the passed [OrbitCardScore] with an updated schedule.
class OrbitReviewScheduler {
  const OrbitReviewScheduler();

  static const double minEase = 1.3;

  /// Apply [grade] to [score], reviewed at [now] (defaults to `DateTime.now()`).
  /// Follows SM-2: a fail (`again`) resets the streak and re-queues at 1 day;
  /// a pass grows the interval by the ease factor; the ease factor is nudged by
  /// the grade and floored at [minEase].
  OrbitCardScore review(OrbitCardScore score, ReviewGrade grade,
      {DateTime? now}) {
    final DateTime at = now ?? DateTime.now();
    final int q = _quality(grade);

    if (q < 3) {
      // Lapse: relearn from scratch, back tomorrow.
      score.repetitions = 0;
      score.intervalDays = 1;
      score.lapses += 1;
    } else {
      if (score.repetitions == 0) {
        score.intervalDays = 1;
      } else if (score.repetitions == 1) {
        score.intervalDays = 6;
      } else {
        score.intervalDays = (score.intervalDays * score.easeFactor).round();
        if (score.intervalDays < 1) score.intervalDays = 1;
      }
      score.repetitions += 1;
    }

    // SM-2 ease update, floored at 1.3.
    final double ef =
        score.easeFactor + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02));
    score.easeFactor = ef < minEase ? minEase : ef;

    score.lastReviewed = at;
    final DateTime day = DateTime(at.year, at.month, at.day);
    score.due = day.add(Duration(days: score.intervalDays));
    return score;
  }

  int _quality(ReviewGrade g) {
    switch (g) {
      case ReviewGrade.again:
        return 1;
      case ReviewGrade.hard:
        return 3;
      case ReviewGrade.good:
        return 4;
      case ReviewGrade.easy:
        return 5;
    }
  }
}

/// Reconcile a deck's card keys (the boards of a completed setup) with the
/// scores loaded from disk: keep every existing score, add a fresh
/// [OrbitCardScore] for any board that has none, and drop scores whose board no
/// longer exists (e.g. a smaller tier). Order follows [cardKeys].
List<OrbitCardScore> reconcileDeck(
  List<({int stageIndex, int boardIndex})> cardKeys,
  List<OrbitCardScore> loaded,
) {
  final Map<String, OrbitCardScore> byKey = <String, OrbitCardScore>{
    for (final OrbitCardScore s in loaded) '${s.stageIndex}:${s.boardIndex}': s,
  };
  return <OrbitCardScore>[
    for (final ({int stageIndex, int boardIndex}) k in cardKeys)
      byKey['${k.stageIndex}:${k.boardIndex}'] ??
          OrbitCardScore(stageIndex: k.stageIndex, boardIndex: k.boardIndex),
  ];
}
