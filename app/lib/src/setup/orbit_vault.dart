import '../ffi/core_bindings.dart' show Argon2Profile;

/// The serializable **orbit provisional key** — everything needed to restore a
/// *settled* orbit setup **without re-running the memory-hard advance**: the
/// public salt `σ` (`o₀ = H(σ)`), the derivation profile (`D` passes, `P`
/// memory), and, per stage, its `r_i`, the memory-hard orbit point `o_i` (for
/// `i ≥ 1`; stage 0's is re-derived from `σ`), and the leaf coordinates of every
/// **placed** fractal point. On load the engine's cheap decode turns each
/// `(reRaw, imRaw)` back into the slot's 32-bit chunk (under `(o, p, q)`
/// recomputed from `o_i`), then `Sh_i` and `K_i` are recomputed on the screen;
/// the expensive Argon2 advance `o_i = H*(K_{i-1})` is skipped entirely.
///
/// This is the orbit peer of the legacy chain [SetupVault]. It captures the
/// **screen-owned** orbit state (`σ` / `_orbitO` / `_boardPoints`), not a
/// [SetupController] chain session, so restoring it does **not** enter the
/// legacy `memorise` phase.
///
/// A settled orbit is the common case; a halted, mid-advance one also rides
/// here, via the optional [resume] checkpoint (Role 1 of
/// `next-steps/orbit-persistence-and-provisional-key-roles.md`).
///
/// SECURITY — this object **is the secret**. `o_i` (`i ≥ 1`) reconstructs the
/// wallet from stage `i` onward, and the placed point coordinates are
/// coercion-relevant. It is the transient provisional key
/// (`next-steps/provisional-key-bootstrapping.md`): held externally only across
/// the memory-consolidation window and destroyed at graduation. It must **only
/// ever be persisted encrypted** ([SetupCrypto]); never write an [OrbitVault] to
/// disk, a log, a clipboard, or any sink in plaintext. `σ` alone is public (the
/// Namtso salt); everything else here is not. [toString] is redacted and [wipe]
/// zeroes the secret integers when done.
class OrbitVault {
  OrbitVault({
    required this.sigma,
    required this.iterations,
    required this.profile,
    required this.stages,
    this.resume,
  });

  /// On-disk format version written by this build.
  ///
  /// - **v1** — settled orbit, protocol 0.4.0 (256-bit `o_i`).
  /// - **v2** — adds optional sections: [resume], and the CPNF deck when it
  ///   lands. Still 0.4.0 widths.
  /// - **v3** — protocol 0.5.0: `o_i` and the resume digest are 512-bit.
  ///
  /// The file stores `o_i`, so its version must move whenever the orbit's width
  /// or derivation moves. Optional *sections* remain additive within a version —
  /// the deck can join v3 without another bump — but a width change cannot.
  static const int formatVersion = 3;

  /// Oldest version still readable. v1 and v2 are 0.4.0 files whose `o_i` are
  /// 256-bit; the 0.5.0 orbit cannot be rebuilt from them at all, so they are
  /// **rejected** rather than half-read. There is no migration: a 0.4.0 setup
  /// must be rebuilt and re-memorised.
  static const int minSupportedVersion = 3;

  /// Payload discriminator so an orbit open of a legacy *chain* vault (or vice
  /// versa) fails cleanly on parse rather than misreading fields. Chain
  /// [SetupVault] payloads carry no `kind`.
  static const String kind = 'orbit';

  /// The JSON key [kind] rides under — named so the load path can branch on the
  /// discriminator before committing to a payload type, without re-spelling the
  /// literal.
  static const String kindKey = 'kind';

  /// The canonical Stage-0 salt `σ` as hex (`o₀ = H(σ)`). Public — the Namtso
  /// salt — so it is not wiped.
  final String sigma;

  /// `D` — memory-hard advance passes per stage.
  final int iterations;

  /// `P` — the Argon2 memory profile.
  final Argon2Profile profile;

  /// One entry per orbit stage, in stage order (index `0..N`).
  final List<OrbitVaultStage> stages;

  /// A **halted** memory-hard advance's checkpoint, or null for a fully settled
  /// setup. Lets a reopened file continue the advance from the pass it reached
  /// instead of restarting it — the orbit peer of [SetupVault]'s `resume`.
  OrbitVaultResume? resume;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': formatVersion,
        kindKey: kind,
        'sigma': sigma,
        'iterations': iterations,
        'profile': profile.value,
        'stages': <Map<String, dynamic>>[
          for (final OrbitVaultStage s in stages) s.toJson()
        ],
        if (resume != null) 'resume': resume!.toJson(),
      };

  /// Rebuild a vault from decoded JSON. Throws a generic [FormatException] on any
  /// missing/ill-typed field, unknown version, or wrong [kind] — the message
  /// never echoes values (a wrong-key decrypt that yields garbage, or a chain
  /// vault opened as orbit, must fail opaquely).
  factory OrbitVault.fromJson(Map<String, dynamic> json) {
    final int version = _int(json, 'v');
    if (version < minSupportedVersion ||
        version > formatVersion ||
        json[kindKey] != kind) {
      throw const FormatException('unsupported vault version');
    }
    final Object? sigma = json['sigma'];
    if (sigma is! String) throw const FormatException('bad vault');
    final int profileCode = _int(json, 'profile');
    final Argon2Profile profile = Argon2Profile.values.firstWhere(
      (Argon2Profile p) => p.value == profileCode,
      orElse: () => throw const FormatException('bad vault'),
    );
    final Object? rawStages = json['stages'];
    if (rawStages is! List || rawStages.isEmpty) {
      throw const FormatException('bad vault');
    }
    final Object? rawResume = json['resume'];
    return OrbitVault(
      sigma: sigma,
      iterations: _int(json, 'iterations'),
      profile: profile,
      stages: <OrbitVaultStage>[
        for (final Object? s in rawStages)
          OrbitVaultStage.fromJson(s is Map<String, dynamic>
              ? s
              : throw const FormatException('bad vault')),
      ],
      resume: rawResume == null
          ? null
          : OrbitVaultResume.fromJson(rawResume is Map<String, dynamic>
              ? rawResume
              : throw const FormatException('bad vault')),
    );
  }

  /// Zero every stage's secret integers (the `o_i` bytes and placed point
  /// coordinates). [sigma] is public and an immutable String, so it is dropped
  /// by reference rather than overwritten.
  void wipe() {
    for (final OrbitVaultStage s in stages) {
      s.wipe();
    }
    resume?.wipe();
  }

  @override
  String toString() =>
      'OrbitVault(<redacted>, ${stages.length} stages)';
}

/// A halted memory-hard advance, captured mid-flight: the stage being derived
/// **into**, how many of the `D` passes finished, and the intermediary digest
/// after that many passes.
///
/// `K_{stage-1}` is deliberately **not** stored — it is recomputed on restore
/// from the stage's placed points (the same tagged derivation the setup already
/// does), so the file carries no key it does not have to.
///
/// SECURITY — [digest] is an intermediary of `H*(K_{stage-1})`. Continuing the
/// remaining passes from it yields `o_stage`, so it is exactly as
/// coercion-relevant as a stored `o_i`, and lives under the same encryption.
class OrbitVaultResume {
  OrbitVaultResume({
    required this.stage,
    required this.pass,
    required this.digest,
  });

  /// The stage the advance is deriving into (`i+1`, never 0).
  final int stage;

  /// Passes completed so far — `1 .. D-1`. Zero would carry no work, and `D`
  /// would mean the advance had finished.
  final int pass;

  /// The intermediary digest after [pass] passes. Coercion-relevant.
  final List<int> digest;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stage': stage,
        'pass': pass,
        'digest': digest,
      };

  factory OrbitVaultResume.fromJson(Map<String, dynamic> json) {
    final List<int> digest = _intList(json, 'digest');
    if (digest.isEmpty) throw const FormatException('bad vault');
    return OrbitVaultResume(
      stage: _int(json, 'stage'),
      pass: _int(json, 'pass'),
      digest: digest,
    );
  }

  void wipe() {
    for (int i = 0; i < digest.length; i++) {
      digest[i] = 0;
    }
  }

  @override
  String toString() => 'OrbitVaultResume(<redacted>)';
}

/// One orbit stage's reconstruction data: its `r_i`, the memory-hard orbit point
/// `o_i` (null for stage 0, which re-derives from `σ`), and the placed slots'
/// leaf coordinates. All the integers are coercion-relevant — see [OrbitVault].
class OrbitVaultStage {
  OrbitVaultStage({
    required this.required,
    required this.orbit,
    required this.points,
  });

  /// `r_i` — the number of placed fractals that fix `Sh_i` (the minimum; the
  /// remaining slots derive on load).
  final int required;

  /// The memory-hard orbit point `o_i` as raw bytes, or null for stage 0 (its
  /// `o₀ = H(σ)` is re-derived from [OrbitVault.sigma], so storing it is
  /// redundant). Present for `i ≥ 1` so restore skips the Argon2 advance.
  List<int>? orbit;

  /// The placed fractal points — one per slot the holder actually placed (not
  /// the derived slots, which are recomputed on load).
  final List<OrbitVaultPoint> points;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'r': required,
        if (orbit != null) 'o': orbit,
        'points': <Map<String, dynamic>>[
          for (final OrbitVaultPoint p in points) p.toJson()
        ],
      };

  factory OrbitVaultStage.fromJson(Map<String, dynamic> json) {
    final Object? rawPoints = json['points'];
    if (rawPoints is! List) throw const FormatException('bad vault');
    return OrbitVaultStage(
      required: _int(json, 'r'),
      orbit: json.containsKey('o') ? _intList(json, 'o') : null,
      points: <OrbitVaultPoint>[
        for (final Object? p in rawPoints)
          OrbitVaultPoint.fromJson(p is Map<String, dynamic>
              ? p
              : throw const FormatException('bad vault')),
      ],
    );
  }

  void wipe() {
    final List<int>? o = orbit;
    if (o != null) {
      for (int i = 0; i < o.length; i++) {
        o[i] = 0;
      }
    }
    for (final OrbitVaultPoint p in points) {
      p.wipe();
    }
  }

  @override
  String toString() => 'OrbitVaultStage(<redacted>)';
}

/// A single placed point: the slot index (`1..s_i`) it occupies and a raw leaf
/// coordinate `(reRaw, imRaw)` inside its encoded point. Coercion-relevant.
class OrbitVaultPoint {
  OrbitVaultPoint({
    required this.slot,
    required this.reRaw,
    required this.imRaw,
  });

  final int slot;
  int reRaw;
  int imRaw;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'slot': slot,
        're': reRaw,
        'im': imRaw,
      };

  factory OrbitVaultPoint.fromJson(Map<String, dynamic> json) => OrbitVaultPoint(
        slot: _int(json, 'slot'),
        reRaw: _int(json, 're'),
        imRaw: _int(json, 'im'),
      );

  void wipe() {
    reRaw = 0;
    imRaw = 0;
  }

  @override
  String toString() => 'OrbitVaultPoint(<redacted>)';
}

/// Read an int field, throwing a generic [FormatException] (no value echoed) if
/// it is missing or the wrong type.
int _int(Map<String, dynamic> json, String key) {
  final Object? v = json[key];
  if (v is int) return v;
  throw const FormatException('bad vault');
}

/// Read a `List<int>` field (a decoded JSON array of ints), throwing a generic
/// [FormatException] (no value echoed) if it is missing or ill-typed.
List<int> _intList(Map<String, dynamic> json, String key) {
  final Object? v = json[key];
  if (v is! List) throw const FormatException('bad vault');
  return <int>[
    for (final Object? e in v) e is int ? e : throw const FormatException('bad vault'),
  ];
}
