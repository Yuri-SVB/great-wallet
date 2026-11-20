/// Cover writes: while the app runs, the setup file is rewritten with its own
/// bytes at random times, the way a save writes it (a temporary file renamed
/// over it). The file's times — modified, changed, created — then tell when
/// the app last ran rather than when its owner last trained, and a single copy
/// shows nothing of which writes were saves
/// (next-steps/timing-concealment-onions-and-mock-flows.md). No key is needed:
/// the bytes are rewritten, not re-encrypted.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Rewrites a file at random times while started: the delays are exponential
/// (a memoryless rhythm, so no write is predictable from the last one) around
/// [mean], and never shorter than [min].
class CoverWrites {
  CoverWrites({
    required this.write,
    math.Random? random,
    this.mean = defaultMean,
    this.min = defaultMin,
  }) : _random = random ?? math.Random.secure();

  /// The mean delay between writes, and the shortest.
  static const Duration defaultMean = Duration(minutes: 30);
  static const Duration defaultMin = Duration(minutes: 1);

  /// The write itself (the caller serialises it with real saves).
  final Future<void> Function() write;
  final Duration mean;
  final Duration min;
  final math.Random _random;
  Timer? _timer;

  /// The delay before the next write.
  Duration nextDelay() {
    // 1 - u is in (0, 1], so its logarithm is finite.
    final double u = 1 - _random.nextDouble();
    final int us = (-math.log(u) * mean.inMicroseconds).round();
    return Duration(microseconds: math.max(us, min.inMicroseconds));
  }

  void start() {
    _timer?.cancel();
    _timer = Timer(nextDelay(), () async {
      await write();
      if (_timer != null) start();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Rewrite the file at [path] with its own bytes, as a save writes it: a
/// temporary file beside it, flushed, renamed over it. Nothing if there is no
/// such file; best effort otherwise (a failure leaves the file as it was).
Future<void> rewriteSame(String path) async {
  final File file = File(path);
  if (!file.existsSync()) return;
  final File tmp = File('$path.tmp');
  try {
    await tmp.writeAsBytes(await file.readAsBytes(), flush: true);
    await tmp.rename(path);
  } on FileSystemException {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } on FileSystemException {
      // Nothing more to do: the file itself is untouched.
    }
  }
}
