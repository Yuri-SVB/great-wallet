import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Harvests the orbit salt σ from the **Namtso** CLI (the flat submodule
/// `namtso-the-sacred-salt`), which derives a 1024-bit σ from the Bitcoin
/// timechain's block headers at a target date (SHAKE256 over a header window).
///
/// This is the sole seam between the app and Namtso on desktop: the app shells
/// out to the built `namtso` binary — `namtso harvest --date YYYY-MM-DD
/// --explorer ""` — which prints the σ hex on its first stdout line, then the
/// receipt JSON. great-wall-core never depends on Namtso; it only consumes the
/// pre-harvested σ (ARCHITECTURE.md §"Submodule Rules").
///
/// Desktop-only: it spawns a process and reaches the network. On mobile/web (no
/// `Process`, no bundled binary) callers fall back to manual σ entry.
class NamtsoHarvester {
  const NamtsoHarvester();

  /// Whether harvesting is even possible on this platform (needs `Process`).
  static bool get isSupported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Backstop cap on how long a harvest may run before the app kills it. The
  /// namtso CLI now self-bounds every phase (connect / read timeouts + a DNS
  /// bound) and batches its fetches, so it fails fast on a dead network on its
  /// own; this is only a last-resort guard for a genuinely stuck process, kept
  /// generous so it never clips a legitimately-progressing harvest.
  static const Duration defaultTimeout = Duration(seconds: 90);

  /// Start a **cancellable, timeout-bounded** harvest and return a
  /// [HarvestSession]. This is the safe entry point for UI: the process is
  /// spawned via `Process.start` (never blocking the UI isolate), killed on
  /// [HarvestSession.cancel] or after [timeout], so the app can never hang on a
  /// slow or unreachable network.
  ///
  /// [session.result] completes with the σ hex (lowercase, 256 chars), or errors
  /// with [NamtsoUnavailable] (binary missing / this platform), [NamtsoCancelled]
  /// (user cancel), or [NamtsoError] (timeout, non-zero exit, unparseable out).
  HarvestSession start({
    required DateTime date,
    String network = 'mainnet',
    int window = 32,
    String explorer = '',
    Duration timeout = defaultTimeout,
  }) {
    return _session(
      args: <String>[
        'harvest',
        '--date',
        _isoDate(date),
        '--network',
        network,
        '--window',
        '$window',
        '--explorer',
        explorer,
      ],
      verb: 'harvest',
      timeout: timeout,
      what: 'a σ hex line',
    );
  }

  /// Start a cancellable, timeout-bounded **unbury** (Namtso spec §15): the 64
  /// bytes buried under [label] on [date]. [HarvestSession.result] completes
  /// with them as hex — or fails with [NamtsoUnavailable], [NamtsoCancelled],
  /// or [NamtsoError] (a Namtso build that cannot unbury yet says so).
  HarvestSession unbury({
    required String label,
    required DateTime date,
    String explorer = '',
    Duration timeout = defaultTimeout,
  }) {
    return _session(
      args: <String>[
        'unbury',
        '--label',
        label,
        '--date',
        _isoDate(date),
        '--explorer',
        explorer,
      ],
      verb: 'unbury',
      timeout: timeout,
      what: 'a data hex line',
    );
  }

  /// Run `namtso` with [args] ([verb] names it in messages) and take the hex
  /// on its first stdout line ([what] describes it). Cancellable and bounded
  /// by [timeout].
  HarvestSession _session({
    required List<String> args,
    required String verb,
    required Duration timeout,
    required String what,
  }) {
    final Completer<String> completer = Completer<String>();
    Process? proc;
    bool cancelled = false;

    void cancel() {
      cancelled = true;
      proc?.kill(ProcessSignal.sigkill);
      if (!completer.isCompleted) {
        completer.completeError(const NamtsoCancelled());
      }
    }

    Future<void> run() async {
      if (!isSupported) {
        completer.completeError(NamtsoUnavailable(
            'Namtso $verb needs a desktop build (Process support).'));
        return;
      }
      final String bin = _locateBinary();
      try {
        proc = await Process.start(bin, args);
      } on ProcessException catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(
              NamtsoUnavailable('could not run namtso ($bin): ${e.message}'));
        }
        return;
      }
      if (cancelled) {
        proc?.kill(ProcessSignal.sigkill);
        return;
      }
      // Drain both pipes so the child can't block on a full stdout buffer.
      final Future<String> outF =
          proc!.stdout.transform(utf8.decoder).join();
      final Future<String> errF =
          proc!.stderr.transform(utf8.decoder).join();

      bool timedOut = false;
      final int code;
      try {
        code = await proc!.exitCode.timeout(timeout, onTimeout: () {
          timedOut = true;
          proc?.kill(ProcessSignal.sigkill);
          return -1;
        });
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(NamtsoError('namtso failed to run: $e'));
        }
        return;
      }
      final String out = await outF;
      final String err = (await errF).trim();

      if (cancelled) return; // cancel() already errored the completer
      if (timedOut) {
        if (!completer.isCompleted) {
          completer.completeError(NamtsoError(
              'namtso $verb timed out after ${timeout.inSeconds}s '
              '(network unreachable?).'));
        }
        return;
      }
      if (code != 0) {
        if (!completer.isCompleted) {
          // An older namtso does not know the subcommand at all.
          final bool unknown = err.contains(verb) &&
              (err.contains('unrecognized') || err.contains('invalid'));
          final String reason = _extractError(err);
          completer.completeError(NamtsoError(unknown
              ? 'This Namtso build cannot $verb yet.'
              : 'namtso $verb failed (exit $code)'
                  '${reason.isEmpty ? '' : ': $reason'}'));
        }
        return;
      }
      final String first = out
          .split('\n')
          .firstWhere((String l) => l.trim().isNotEmpty, orElse: () => '');
      final String hex = first.trim().toLowerCase();
      if (!_looksLikeSigmaHex(hex)) {
        if (!completer.isCompleted) {
          completer.completeError(NamtsoError('namtso output did not start '
              'with $what (got "${_ellipsis(first)}").'));
        }
        return;
      }
      if (!completer.isCompleted) completer.complete(hex);
    }

    // Fire-and-forget: run() drives the process; failures land on the future.
    unawaited(run());
    return HarvestSession(completer.future, cancel);
  }

  /// Convenience: await a one-shot harvest (used by tests / non-UI callers).
  /// Prefer [start] in the UI so the run can be cancelled.
  Future<String> harvest({
    required DateTime date,
    String network = 'mainnet',
    int window = 32,
    String explorer = '',
    Duration timeout = defaultTimeout,
  }) {
    return start(
      date: date,
      network: network,
      window: window,
      explorer: explorer,
      timeout: timeout,
    ).result;
  }

  /// Probe order for the `namtso` binary: an explicit env override, the flat
  /// submodule's cargo output (dev builds), then whatever is on `PATH`.
  String _locateBinary() {
    final String exe = Platform.isWindows ? 'namtso.exe' : 'namtso';
    final String? override = Platform.environment['NAMTSO_BIN'];
    final String sep = Platform.pathSeparator;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      // app/ is a sibling of the namtso submodule inside great-wallet.
      <String>['..', 'namtso-the-sacred-salt', 'target', 'release', exe].join(sep),
      // Packaged builds bundle the binary next to the executable.
      <String>[exeDir, exe].join(sep),
    ];
    for (final String path in candidates) {
      if (File(path).existsSync()) return path;
    }
    // Last resort: let the OS resolve it on PATH.
    return exe;
  }

  static String _isoDate(DateTime d) {
    final String y = d.year.toString().padLeft(4, '0');
    final String m = d.month.toString().padLeft(2, '0');
    final String day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static bool _looksLikeSigmaHex(String s) =>
      s.length >= 2 && s.length.isEven && RegExp(r'^[0-9a-f]+$').hasMatch(s);

  /// namtso prints failures as a JSON object on stderr
  /// (`{"error":CODE,"message":...,"reason":...}`). Pull out the human reason;
  /// fall back to the raw text if it isn't the expected JSON.
  static String _extractError(String stderr) {
    final String t = stderr.trim();
    if (t.isEmpty) return '';
    try {
      final Object? j = jsonDecode(t);
      if (j is Map) {
        final Object? r = j['reason'] ?? j['message'] ?? j['error'];
        if (r != null && r.toString().trim().isNotEmpty) return r.toString();
      }
    } catch (_) {
      // not JSON — fall through to the raw text
    }
    return t;
  }

  static String _ellipsis(String s) =>
      s.length <= 24 ? s : '${s.substring(0, 24)}…';
}

/// A running, cancellable harvest. [result] completes with the σ hex or errors;
/// [cancel] kills the process and fails [result] with [NamtsoCancelled].
class HarvestSession {
  HarvestSession(this.result, this._cancel);

  final Future<String> result;
  final void Function() _cancel;

  void cancel() => _cancel();
}

/// The user cancelled the harvest.
class NamtsoCancelled implements Exception {
  const NamtsoCancelled();
  @override
  String toString() => 'NamtsoCancelled';
}

/// The Namtso binary could not be located or executed (build it with
/// `app/native/build_namtso.sh`, or this platform can't shell out).
class NamtsoUnavailable implements Exception {
  const NamtsoUnavailable(this.message);
  final String message;
  @override
  String toString() => 'NamtsoUnavailable: $message';
}

/// The Namtso CLI ran but reported an error (bad date, no connectivity, …).
class NamtsoError implements Exception {
  const NamtsoError(this.message);
  final String message;
  @override
  String toString() => 'NamtsoError: $message';
}
