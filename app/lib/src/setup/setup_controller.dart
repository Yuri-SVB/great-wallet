import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/bip39.dart';
import '../core/encoding_constants.dart';
import '../core/entropy.dart';
import '../core/great_wall_core.dart';
import '../core/master_secret.dart';
import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';
import '../core/stage_params.dart';
import 'setup_crypto.dart';
import 'setup_vault.dart';

/// Phases of the Setup flow.
///
/// Setup is "a write-only operation on the user's memory" (ARCHITECTURE.md
/// §"Invariants"): generate a fresh root, encode it onto the chained fractals
/// (one 32-bit point per stage), let the user memorise the points, then destroy
/// the plaintext.
enum SetupPhase {
  idle,

  /// Encoding the current stage's single point onto its fractal (quick).
  encoding,

  /// Running the chained Argon2 derivation that forms the current stage's
  /// fractal from all preceding points (the wall-clock cost).
  deriving,

  /// The user studies the points stage by stage.
  memorise,
  complete,

  /// Every stage selected back; the seed has been reconstructed.
  recallComplete,
  error,
}

/// Outcome of the `E` canonical-leaf-area enumeration (drives the screen's
/// sound cue and status).
enum LeafScanOutcome {
  /// One or more canonical islands were highlighted.
  shown,

  /// Too many / too dense to enumerate here — the user should zoom in.
  tooMany,

  /// No leaf areas resolved in view (e.g. zoomed out / over a dead region).
  empty,
}

/// Outcome of a select-mode click. Selecting a point only **marks** it on the
/// displayed stage; deriving the next fractal is a separate step (selecting the
/// next stage — see [deriveNextStage]).
enum SelectionOutcome {
  /// The click did not land on an encodable leaf.
  invalid,

  /// The point was marked on the displayed stage. The chain does not advance —
  /// select the next stage to derive its fractal.
  marked,

  /// The final stage's point was marked; every stage is selected and the seed
  /// has been reconstructed.
  complete,

  /// A valid click that would overwrite a stage already selected **and** discard
  /// the later fractals derived from it. The caller must confirm with the user,
  /// then re-call with `confirmedReselect: true`.
  needsConfirm,

  /// A derivation is in progress, the stage is not a derived fractal, or the
  /// walk is already complete; ignored.
  busy,
}

/// Outcome of a [SetupController.deriveNextStage] request — triggered by
/// selecting the first not-yet-derived stage.
enum DeriveOutcome {
  /// The next fractal was derived; the canvas is now on it, ready for its point.
  derived,

  /// The previous stage has no selected point yet, so there is nothing to derive
  /// from — the caller surfaces an error to the user.
  noPriorPoint,

  /// There is no next stage to derive (every stage is already derived).
  none,

  /// A derivation is already in progress, or it was cancelled; ignored.
  busy,
}

/// Drives the Setup mode and owns the integration between great-wall-core
/// (encode / chained Argon2) and great-wall-ux (the canvas + overlays).
///
/// Implements the **chained protocol** with a text Stage 0. Stage 0 is a
/// salt/pepper *text* (no fractal, no point) that seeds the chain; the entropy
/// root is then split into one 32-bit chunk per fractal stage. Every fractal
/// `(o,p,q)` is the memory-hard hash of the Stage-0 text plus *all preceding
/// points* (`θ_k = SHA-256(Argon2^N(text ‖ points 1..k-1))`), so even the first
/// fractal is personalised — there is no app-canonical fractal. The text never
/// enters the entropy, so the BIP39 ↔ Great Wall conversion stays lossless. One
/// fractal = one haystack; one point = one needle.
///
/// SECURITY: the generated entropy and the encoded points are coercion-relevant.
/// They are held only for the duration of the memorisation phase and wiped by
/// [finish]/[dispose]. Nothing here is logged or persisted (SCOPE.md invariants).
class SetupController extends ChangeNotifier {
  SetupController(this._core);

  final GreatWallCore _core;

  SetupPhase _phase = SetupPhase.idle;
  SetupPhase get phase => _phase;

  /// True when the active session is a **cold-start recall** (the salt was
  /// entered and the points are being re-derived link by link), as opposed to
  /// a fresh/imported setup. Drives the recall-specific control copy.
  bool _isRecallSession = false;
  bool get isRecallSession => _isRecallSession;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// Configured number of fractal **point stages** for a fresh/recall session
  /// (1..[maxPointStages]). Each point stage is one 32-bit chunk, so this fixes
  /// the entropy width (`32 ×`) — every value 1..4 is a valid setup, not just the
  /// old mini/default/large presets. An imported seed phrase overrides it with
  /// its own word count. Used only as the pre-session fallback for [nStages].
  int _pointStages = 4;
  int get configuredPointStages => _pointStages;

  /// The largest number of point stages a setup may have: 4 (128-bit / 12-word
  /// BIP39). Stage 0 (text) sits on top, so the displayed stages run 0..4 at
  /// most — the upper (stage) slots of the orbit builder
  /// (next-steps/orbit-setup-tab-ui-pathway.md, P1: `0..4` not `0..8`).
  static const int maxPointStages = 4;

  /// Total number of displayed stages of the active session: the Stage-0 text
  /// stage plus one per 32-bit fractal point (`pointStageCount + 1`). For an
  /// imported seed phrase the point count may be any 3..24-word size. Falls back
  /// to the configured point-stage count before a session starts.
  int _stageCount = 0;
  int get nStages => _stageCount > 0 ? _stageCount : _pointStages + 1;

  /// Number of fractal point stages (`nStages - 1`): Stage 0 carries no point.
  int get pointStageCount => nStages - 1;

  /// Which stage the canvas is currently showing. Stage 0 is the salt/pepper
  /// text stage (no fractal, no point); stages 1..N are the chain-derived
  /// fractals, one 32-bit point each.
  int _displayStageIndex = 0;
  int get displayStageIndex => _displayStageIndex;

  /// True when the displayed stage is the Stage-0 text stage (no canvas).
  bool get isTextStage => _displayStageIndex == 0;

  /// The displayed fractal mapped onto great-wall-ux's render paths. Every
  /// chained fractal is a perturbation now (Stage 0 is text, not a fractal), so
  /// fractal stages always use the perturbed path; only matters for stages >= 1.
  Stage get displayStage =>
      _displayStageIndex == 0 ? Stage.stage1 : Stage.stage2;

  /// The Stage-0 salt/pepper text (held for the session so recall can re-derive
  /// the chain; wiped on reset/finish). Shown only behind a reveal toggle.
  String _chainText = '';
  String get saltPepper => _chainText;

  /// The fractal stage being derived/encoded right now, for progress labels
  /// (its 0-based display index, i.e. 1..N).
  int _workingStageIndex = 1;
  int get workingStageNumber => _workingStageIndex;

  int _argon2Done = 0;
  int _argon2Total = 1;
  int get argon2Done => _argon2Done;
  int get argon2Total => _argon2Total;

  /// The point stage (1..N) whose fractal is deriving right now — foreground
  /// (Stage 1 / a manual derive) or background generation — or null when nothing
  /// is deriving. Drives the stage tab's progress fill.
  int? get derivingStageIndex {
    if (_phase == SetupPhase.deriving || _phase == SetupPhase.encoding) {
      return _workingStageIndex;
    }
    if (_isGenerating) return _generatingStage;
    return null;
  }

  /// Fraction in [0, 1] of the deriving stage's Argon2 passes done (1.0 during
  /// the brief encode that follows, 0 when idle).
  double get stageProgress => _argon2Total > 0
      ? (_argon2Done / _argon2Total).clamp(0.0, 1.0)
      : 0.0;

  // Session-only secret material.
  List<int>? _entropyBits;

  /// One encoded point per stage; index 0 (the text stage) is always `null`,
  /// indices 1..N hold each fractal's point. `null` until that stage is encoded.
  List<EncodedPoint?> _points = const <EncodedPoint?>[];

  /// Each fractal's chain-derived reservoirs; index 0 (the text stage) is always
  /// `null`. Every later stage is derived from the text + all preceding points.
  List<StageReservoirs?> _reservoirs = const <StageReservoirs?>[];

  /// Each resolved stage's master-secret export record `(o, p, q, leaf-centre)`;
  /// index 0 (the text stage) is always `null`. A fractal stage's record exists
  /// once its **point** is known: at encode time for a fresh/imported setup
  /// (every stage up-front), or as each point is decoded during a recall walk
  /// (stages 1..k as they come back). Drives [canExportMasterAt] — see
  /// [exportMasterSecret] and MasterSecret.
  List<StageRecord?> _stageRecords = const <StageRecord?>[];

  /// Each resolved stage's leaf rectangle (the small region the point sits in),
  /// kept so the UI can zoom-to-fit a point ("focus"). Set at encode time for a
  /// generated/imported setup and as each point is decoded during a recall walk;
  /// index 0 is always null.
  List<FixedRect?> _leafRects = const <FixedRect?>[];

  /// The Argon2 GUI iteration count of the active session — part of the export
  /// transcript, so it is held for the session and must match across setup and
  /// recall (see DESIGN.md §"Master-Secret Export").
  int _iterations = 0;

  /// The displayed stage's perturbation as great-wall-ux's display surrogate
  /// (`null` for the Stage-0 text stage). The authoritative reservoirs live on
  /// [GreatWallCore.source]; see CoreEscapeCountSource.reservoirs.
  StageParameters? _displayParams;
  StageParameters? get displayStageParams => _displayParams;

  Argon2Job? _argon2Job;

  /// True between [halt] and the in-flight derivation unwinding, so the
  /// Argon2Cancelled handlers preserve progress (stash the checkpoint, keep the
  /// entropy) instead of treating the cancel as a full teardown.
  bool _halting = false;

  /// The working stage's latest completed intermediary digest, refreshed every
  /// Argon2 pass. On [halt] it becomes [_halted]; on completion/reset it is
  /// wiped. Coercion-relevant — held only while a derivation is live.
  _HaltCheckpoint? _inFlight;

  /// A halted stage's preserved progress (its last intermediary digest and the
  /// number of passes done), kept so a later resume can finish the stage without
  /// repeating that work. Null when nothing is halted.
  _HaltCheckpoint? _halted;

  /// Whether a stage is currently halted with preserved progress.
  bool get isHalted => _halted != null;

  /// Whether [resumeDerivation] can run: a halted generation (holding its
  /// entropy root) or a halted N/I expansion (holding its plan), and not a recall
  /// walk. A halted recall-walk derive is not resumable from the stash here —
  /// re-deriving that stage supersedes it.
  bool get canResume =>
      _halted != null &&
      !_isRecallSession &&
      (_entropyBits != null || _expandPlan != null);

  /// Whether the displayed stage can be truncated from (it and every stage above
  /// it deleted): a settled generated/imported setup (memorise, not deriving or
  /// generating) showing a point stage (≥ 1). Recall reconstructs a fixed setup,
  /// so it is not editable this way.
  bool get canTruncateFromDisplayed =>
      _phase == SetupPhase.memorise &&
      !_isGenerating &&
      !_isRecallSession &&
      _displayStageIndex >= 1 &&
      _displayStageIndex < nStages;

  /// Whether stage [k]'s point can be edited: a settled generated/imported setup
  /// (memorise, not deriving/generating, not a recall walk) on a derived point
  /// stage.
  bool _canEditPointAt(int k) =>
      _phase == SetupPhase.memorise &&
      !_isGenerating &&
      !_isRecallSession &&
      k >= 1 &&
      k < nStages &&
      k < _reservoirs.length &&
      _reservoirs[k] != null;

  /// Whether the displayed stage's point can be changed (see [_canEditPointAt]).
  bool get canEditCurrentPoint => _canEditPointAt(_displayStageIndex);

  /// The stage index a halt left paused (0 when none).
  int get haltedStage => _halted?.stage ?? 0;

  /// Passes completed / total for the halted stage (0 when none).
  int get haltedPass => _halted?.pass ?? 0;
  int get haltedTotal => _halted?.total ?? 0;

  /// The Argon2 memory profile of the active session, kept so the background
  /// generation of later stages uses the same profile as Stage 1.
  Argon2Profile _profile = Argon2Profile.basic;

  /// True while stages **after Stage 1** are still deriving in the background.
  /// The session is already interactive (phase `memorise`) by then; this only
  /// drives the subtle progress notice and (via the UI) holds select-mode
  /// practice off until the whole chain exists.
  bool _isGenerating = false;
  bool get isGenerating => _isGenerating;

  /// The stage (1..N) currently deriving in the background, or 0 when not
  /// generating. Drives the "Deriving stage k/N…" notice.
  int _generatingStage = 0;
  int get generatingStage => _generatingStage;

  /// Set if a background stage derivation failed; the already-derived stages
  /// stay usable, so this is surfaced as a non-fatal notice rather than the
  /// error phase.
  String? _generationError;
  String? get generationError => _generationError;

  // --- Select-mode recall state ---
  // One per stage (index 0 — the text stage — is always null; 1..N hold each
  // fractal's selection). A stage's point is **marked** by a click and the next
  // fractal is derived as a separate step; navigating the chain is therefore
  // decoupled from deriving it. Coercion-relevant; held only for the session.

  /// The green marker the user placed on each stage (the recalled point), or
  /// null where no point has been selected yet.
  List<({double re, double im})?> _selectedMarks =
      const <({double re, double im})?>[];

  /// The decoded 32-bit chunk selected on each stage, or null. The recalled seed
  /// is the concatenation of the contiguous run from stage 1.
  List<List<int>?> _selectedChunks = const <List<int>?>[];

  /// The reconstructed entropy root, set once every stage carries a point.
  List<int>? _recalledEntropyBits;

  /// The imported entropy buffer (m × 32 bits) feeding an in-progress I-mode
  /// expansion; owned by the controller and wiped when that expansion ends.
  /// Null outside an import expansion.
  List<int>? _expandImportBits;

  /// The active N/I expansion plan (fill mode + target), kept while the
  /// expansion runs **and** across a halt so [resumeDerivation] can finish it.
  /// Null when no N/I expansion is in flight or halted.
  _ExpandPlan? _expandPlan;

  /// The lowest point stage (1..N) whose fractal is **not** yet derived — the one
  /// a "select the next stage" action would derive. Equals [nStages] (a sentinel
  /// past the last stage) when every fractal is already derived.
  int get firstUnderivedStage {
    for (int k = 1; k < nStages; k++) {
      if (k >= _reservoirs.length || _reservoirs[k] == null) return k;
    }
    return nStages;
  }

  /// Whether stage [k] (1..N) has a selected point.
  bool hasSelectedPoint(int k) =>
      k >= 1 && k < _selectedChunks.length && _selectedChunks[k] != null;

  /// Whether stage [k] carries a point at all — selected during a recall walk,
  /// or already encoded in a generated/imported setup. This is the chain-forward
  /// precondition: a stage can only be derived once every prior point exists.
  bool _hasPointAt(int k) =>
      hasSelectedPoint(k) ||
      (k >= 1 && k < _points.length && _points[k] != null);

  /// Public view of [_hasPointAt]: whether stage [k] carries a point (selected
  /// or encoded). Lets the screen gate "derive the next stage" on the prior
  /// point existing in any setup — recall, generated, or an in-progress
  /// expansion (where the prior point may be encoded, not selected).
  bool hasPointAt(int k) => _hasPointAt(k);

  /// Stage [k]'s 32-bit point chunk — the recall selection if present, otherwise
  /// decoded on demand from the stored encoded point. No extra secret is kept in
  /// memory: the displayed marker already *is* this chunk (a placed point
  /// decodes back to it), so decoding when needed avoids a redundant stored copy
  /// while keeping chain-extension setup-agnostic.
  List<int> _pointChunk(int k) {
    final List<int>? sel = _selectedChunks[k];
    if (sel != null) return sel;
    final EncodedPoint? pt = (k >= 1 && k < _points.length) ? _points[k] : null;
    final StageReservoirs? res =
        (k >= 1 && k < _reservoirs.length) ? _reservoirs[k] : null;
    if (pt == null || res == null) {
      throw StateError('stage $k has no point to chain from');
    }
    final CoreDecodeResult d = _core.decodePoint(
      reRaw: pt.reRaw,
      imRaw: pt.imRaw,
      o: res.o,
      p: res.p,
      q: res.q,
    );
    return d.bits;
  }

  /// The green marker selected on stage [index], if any (for the canvas overlay).
  ({double re, double im})? selectedMarkAt(int index) =>
      (index >= 0 && index < _selectedMarks.length)
          ? _selectedMarks[index]
          : null;

  /// Points selected on the stage currently displayed (0 or 1).
  int get selectedCount => selectedMarkAt(_displayStageIndex) == null ? 0 : 1;

  /// The point + leaf geometry to zoom-to ("focus") for stage [index], or null
  /// if that stage has no point yet. Uses the encoded point of a generated /
  /// imported setup, or the recalled mark of a recall walk; the leaf width/height
  /// are in fractal units (0 if the leaf rect is unknown). Stage 0 has no point.
  ({double re, double im, double leafW, double leafH})? focusTargetAt(
      int index) {
    if (index < 1) return null;
    double? re;
    double? im;
    if (index < _points.length && _points[index] != null) {
      re = fixedToDouble(_points[index]!.reRaw);
      im = fixedToDouble(_points[index]!.imRaw);
    } else {
      final ({double re, double im})? mark = selectedMarkAt(index);
      if (mark != null) {
        re = mark.re;
        im = mark.im;
      }
    }
    if (re == null || im == null) return null;
    final FixedRect? rect =
        (index < _leafRects.length) ? _leafRects[index] : null;
    double leafW = 0;
    double leafH = 0;
    if (rect != null) {
      leafW = (fixedToDouble(rect.reMax) - fixedToDouble(rect.reMin)).abs();
      leafH = (fixedToDouble(rect.imMax) - fixedToDouble(rect.imMin)).abs();
    }
    return (re: re, im: im, leafW: leafW, leafH: leafH);
  }

  /// Points required to complete a stage — always one under the chained
  /// protocol (one point = one stage).
  int get requiredPerStage => 1;

  /// True once every stage has been selected back and the seed reconstructed.
  bool get isRecallComplete => _recalledEntropyBits != null;

  /// The contiguous run of selected chunks from stage 1 — the seed recalled so
  /// far. Stops at the first stage without a point.
  List<List<int>> _orderedSelectedChunks() {
    final List<List<int>> out = <List<int>>[];
    for (int k = 1; k < _selectedChunks.length; k++) {
      final List<int>? chunk = _selectedChunks[k];
      if (chunk == null) break;
      out.add(chunk);
    }
    return out;
  }

  /// Stages recalled (points selected back) so far — equivalently, the number of
  /// 32-bit points making up the seed available for blind export right now.
  int get recalledStageCount => _orderedSelectedChunks().length;

  /// Bits available for blind export so far (`32 ×` [recalledStageCount]).
  int get recalledBitCount =>
      recalledStageCount * EncodingConstants.bitsPerPoint;

  /// Whether any seed material has been recalled (so a blind export is
  /// possible). Below the final stage this is a partial, shorter-than-standard
  /// seed; at completion it is the full entropy root.
  bool get canExport => recalledStageCount > 0;

  /// The seed recalled **so far** as a BIP39 mnemonic, for an explicit
  /// user-initiated **blind** export (copy → paste into another wallet's
  /// import wizard without reading it). Available at every stage once at least
  /// one point has been recalled: before the final stage it encodes only the
  /// points decoded so far (`32 ×` stages bits — a non-standard, weaker seed);
  /// at completion it is the full entropy root. Returns null before any point
  /// is recalled.
  ///
  /// "The user never sees the seed" holds in the blind-copy sense: this string
  /// is handed to the clipboard, never rendered on screen (ARCHITECTURE.md
  /// §"Stage 0" / §"Invariants"). It is computed on demand and not retained.
  String? exportMnemonic() {
    final List<List<int>> chunks = _orderedSelectedChunks();
    if (chunks.isEmpty) return null;
    final List<int> bits = <int>[
      for (final List<int> chunk in chunks) ...chunk,
    ];
    final String mnemonic = Bip39.entropyBitsToMnemonic(bits);
    Entropy.wipe(bits);
    return mnemonic;
  }

  /// Whether the **master-secret export** is available at stage [stageIndex].
  ///
  /// True for any non-0 stage whose point is resolved (so its export record
  /// exists) and whose every preceding stage is resolved too — i.e. the prefix
  /// `1..stageIndex` is complete. For a fresh/imported setup that holds for all
  /// stages once encoded; during a recall walk it holds for each stage as its
  /// point is decoded. The export at stage `k` covers exactly that prefix and is
  /// **not** contingent on later stages (DESIGN.md §"Master-Secret Export":
  /// available at every non-0 stage).
  bool canExportMasterAt(int stageIndex) {
    if (stageIndex < 1 || stageIndex >= _stageRecords.length) return false;
    for (int k = 1; k <= stageIndex; k++) {
      if (_stageRecords[k] == null) return false;
    }
    return true;
  }

  /// Run the **master-secret export** at stage [stageIndex] (protocol 0.3.0):
  /// one Argon2id pass over the reproducible setup transcript of stages
  /// `1..stageIndex`, with the exporting stage's own [label] appended to the
  /// message. Returns the conventional 32-hex-char display string — or, when
  /// [full] is set, the entire digest as hex ([MasterSecret.fullHex], `Alt+K`) —
  /// or null if the stage is not exportable ([canExportMasterAt]).
  ///
  /// This **replaces** the `0.2.0` `SHA512(seed-phrase + salt)` export: the
  /// transcript (stage-0 text, iteration count, and each stage's params +
  /// leaf-centre) is an order-preserving function of the setup, so it tolerates
  /// large peppers/outputs without entropy collapse and reproduces bit-for-bit
  /// on recovery. It needs only the per-stage params and points the app already
  /// holds to render the fractals — **not** the plaintext seed — so it honours
  /// "the master secret is never shown" (the digest goes straight to the
  /// clipboard, never to the screen).
  ///
  /// The heavy Argon2id pass runs off the UI isolate ([GreatWallCore
  /// .argon2idMaster]). Coercion-relevant intermediates (the transcript message
  /// and raw output) are wiped before returning.
  Future<String?> exportMasterSecret({
    required int stageIndex,
    required String label,
    bool full = false,
  }) async {
    if (!canExportMasterAt(stageIndex)) return null;
    final List<StageRecord> records = <StageRecord>[
      for (int k = 1; k <= stageIndex; k++) _stageRecords[k]!,
    ];
    // Canonicalise the label through the engine — the same [A-Z0-9-] rule the
    // input field enforces — so the transcript byte layout matches the protocol.
    final Uint8List message = MasterSecret.buildExportTranscript(
      stage0Text: _chainText,
      iterations: _iterations,
      records: records,
      exportLabel: _core.canonicalizeSaltPepper(label),
    );
    final Uint8List raw = await _core.argon2idMaster(
      message,
      outLen: MasterSecret.outputBytes,
    );
    final String out =
        full ? MasterSecret.fullHex(raw) : MasterSecret.displayHex(raw);
    // Wipe the coercion-relevant transcript and raw output.
    message.fillRange(0, message.length, 0);
    raw.fillRange(0, raw.length, 0);
    return out;
  }

  /// The point markers to overlay for the currently displayed stage: the single
  /// location the user must learn to recognise (white), plus the point selected
  /// on this stage in select mode (green).
  // -- Canonical-island highlights (the `E` action) -------------------------

  List<CanvasIsland> _islandHighlights = const <CanvasIsland>[];
  String? _islandStatus;

  /// Transient status for the leaf-area / island enumeration ("too many leaf
  /// areas", "no islands"), or null when islands are shown or nothing was run.
  String? get islandStatus => _islandStatus;

  /// Enumerate the canonical leaf areas under [viewport] and highlight each
  /// one's canonical island (flat white). Aborts with a "zoom in" status when
  /// there are too many leaf areas. Triggered by the Setup screen's `E` action.
  ///
  /// Heavy: the enumeration decodes a grid of sample points and runs a fresh
  /// discovery per leaf, all through blocking FFI on the UI isolate. It is a
  /// one-shot on key-press (not per frame); moving it off the UI isolate is a
  /// follow-up if the freeze on a busy view becomes noticeable.
  /// Number of canonical islands currently highlighted by the `E` enumeration.
  int get islandCount => _islandHighlights.length;

  Future<LeafScanOutcome> enumerateCanonicalIslands(
      FractalViewport viewport) async {
    debugPrint('E: enumerating canonical leaf areas in the current view…');
    final LeafAreasResult res = await _core.leafSource.leafAreas(
      LeafAreasRequest(
        viewport: viewport,
        stage: displayStage,
        stageParameters: _displayParams,
        numBits: EncodingConstants.bitsPerPoint,
      ),
    );
    if (res.tooMany) {
      _islandHighlights = const <CanvasIsland>[];
      // Covers both "more than maxLeaves distinct areas" and the decode-budget
      // (zoom-out) guard — the action is the same.
      _islandStatus = 'Too many / too dense to enumerate here — zoom in.';
      debugPrint('E: too many / too dense to enumerate here — zoom in.');
      notifyListeners();
      return LeafScanOutcome.tooMany;
    }

    // (o, p, q): the canonical stage decodes on (0,0,0), a chain stage on its
    // reservoirs — the same surface the leaf was decoded on.
    final StageReservoirs? r =
        _displayStageIndex == 0 || _displayStageIndex >= _reservoirs.length
            ? null
            : _reservoirs[_displayStageIndex];
    final int o = r?.o ?? 0;
    final int p = r?.p ?? 0;
    final int q = r?.q ?? 0;

    final List<CanvasIsland> islands = <CanvasIsland>[];
    for (final LeafArea leaf in res.leaves) {
      final _IslandDeco? deco = _islandDecoForLeaf(
        FixedRect.fromDoubles(leaf.reMin, leaf.reMax, leaf.imMin, leaf.imMax),
        leaf.path,
        o,
        p,
        q,
      );
      if (deco != null) islands.add(deco.cells);
    }

    _islandHighlights = islands;
    _islandStatus = islands.isEmpty ? 'No islands found in view.' : null;
    debugPrint('E: ${res.leaves.length} leaf area(s) in view, '
        '${islands.length} canonical island(s) highlighted.');
    notifyListeners();
    return islands.isEmpty ? LeafScanOutcome.empty : LeafScanOutcome.shown;
  }

  /// Clear any canonical-island highlights and status (e.g. on stage change or
  /// session teardown).
  void _clearIslandHighlights() {
    _islandHighlights = const <CanvasIsland>[];
    _islandStatus = null;
  }

  // --- Selected-leaf decoration --------------------------------------------
  //
  // The displayed stage's selected leaf is shown as its canonical island (white
  // cells) framed by a white rectangle. Computed when the selection is made
  // (reusing that decode) and cached per stage; recomputed lazily on navigation.

  _IslandDeco? _selDeco;
  final Map<int, _IslandDeco?> _selDecoCache = <int, _IslandDeco?>{};
  _IslandDeco? _genDeco;
  final Map<int, _IslandDeco?> _genDecoCache = <int, _IslandDeco?>{};

  /// Discovery params for resolving a canonical island's *shape* — the engine's
  /// encode params with a larger flood cap so the island is a real shape, not a
  /// speck. Pure visualisation; never affects encoded bits.
  CoreDiscoveryParams get _islandVizParams {
    final CoreDiscoveryParams b = _core.encodeParams;
    return CoreDiscoveryParams(
      maxIter: b.maxIter,
      targetGood: b.targetGood,
      maxFloodPoints: EncodingConstants.canonicalIslandMaxFloodPoints,
      minGridCells: b.minGridCells,
      pMaxShift: b.pMaxShift,
      exclusionThresholdNum: b.exclusionThresholdNum,
      rngSeed: b.rngSeed,
    );
  }

  /// Build the canonical-island decoration for a known leaf (rect + path).
  _IslandDeco? _islandDecoForLeaf(
      FixedRect leafRect, String path, int o, int p, int q) {
    final CoreCanonicalIsland? isl = _core.bindings.canonicalIsland(
      leafRect: leafRect,
      params: _islandVizParams,
      o: o,
      p: p,
      q: q,
      path: path,
    );
    if (isl == null || isl.pointsRaw.isEmpty) return null;
    final List<double> pts = List<double>.filled(isl.pointsRaw.length, 0);
    for (int i = 0; i < isl.pointsRaw.length; i++) {
      pts[i] = fixedToDouble(isl.pointsRaw[i]);
    }
    return _IslandDeco(
      cells: CanvasIsland(
        cellSize: fixedToDouble(isl.pixelDeltaRaw),
        pointsReIm: pts,
        // The level set the canvas re-floods to draw this island at whatever
        // resolution is on screen; the points are its seeds, the cells only a
        // fallback. See great-wall-ux `island_fill.dart`.
        escapeCount: isl.escapeCount,
      ),
      reMin: fixedToDouble(isl.bbox.reMin),
      reMax: fixedToDouble(isl.bbox.reMax),
      imMin: fixedToDouble(isl.bbox.imMin),
      imMax: fixedToDouble(isl.bbox.imMax),
    );
  }

  /// The decoration for a focus leaf (the generated point or a selection) —
  /// always framed. Frames the canonical island (with its cells) when it
  /// resolves; otherwise frames the whole leaf rectangle (no cells), so the
  /// focus point is never unmarked.
  _IslandDeco _focusDecoForLeaf(FixedRect leafRect, String path, int o, int p, int q) {
    final _IslandDeco? isl = _islandDecoForLeaf(leafRect, path, o, p, q);
    if (isl != null) return isl;
    return _IslandDeco(
      cells: const CanvasIsland(cellSize: 0.0, pointsReIm: <double>[]),
      reMin: fixedToDouble(leafRect.reMin),
      reMax: fixedToDouble(leafRect.reMax),
      imMin: fixedToDouble(leafRect.imMin),
      imMax: fixedToDouble(leafRect.imMax),
    );
  }

  /// Decode the leaf at (reRaw, imRaw) on stage k's fractal and build its
  /// (always-framed) decoration, or null if the point doesn't decode.
  _IslandDeco? _focusDecoAt(int reRaw, int imRaw, int o, int p, int q) {
    final CoreDecodeResult d =
        _core.decodePoint(reRaw: reRaw, imRaw: imRaw, o: o, p: p, q: q);
    if (!d.valid) return null;
    return _focusDecoForLeaf(d.leafRect, d.path, o, p, q);
  }

  /// Recompute the displayed stage's focus decorations (cached per stage).
  void _refreshFocusDecos() {
    _selDeco = _selectedDecoForDisplay();
    _genDeco = _generatedDecoForDisplay();
  }

  _IslandDeco? _selectedDecoForDisplay() {
    final int k = _displayStageIndex;
    final ({double re, double im})? m = selectedMarkAt(k);
    if (k < 1 || m == null) return null;
    if (_selDecoCache.containsKey(k)) return _selDecoCache[k];
    final StageReservoirs? r = (k < _reservoirs.length) ? _reservoirs[k] : null;
    _IslandDeco? deco;
    if (r != null) {
      final CoreDecodeResult d = _core.decodePoint(
        reRaw: fixedFromDouble(m.re),
        imRaw: fixedFromDouble(m.im),
        o: r.o,
        p: r.p,
        q: r.q,
      );
      deco = d.valid ? _focusDecoForLeaf(d.leafRect, d.path, r.o, r.p, r.q) : null;
    }
    _selDecoCache[k] = deco;
    return deco;
  }

  _IslandDeco? _generatedDecoForDisplay() {
    final int k = _displayStageIndex;
    final EncodedPoint? pt = (k >= 1 && k < _points.length) ? _points[k] : null;
    if (pt == null) return null;
    if (_genDecoCache.containsKey(k)) return _genDecoCache[k];
    final StageReservoirs? r = (k < _reservoirs.length) ? _reservoirs[k] : null;
    final _IslandDeco? deco =
        (r == null) ? null : _focusDecoAt(pt.reRaw, pt.imRaw, r.o, r.p, r.q);
    _genDecoCache[k] = deco;
    return deco;
  }

  CanvasOverlays overlaysForDisplayStage() {
    final EncodedPoint? pt = _displayStageIndex < _points.length
        ? _points[_displayStageIndex]
        : null;
    // The generated point is marked by a fixed-size white cross placed on its
    // canonical island (falling back to the leaf centre if the island couldn't
    // be resolved), so the marker is always visible and the island grows into
    // view around it on deep zoom.
    final ({double re, double im})? crossAt = pt == null
        ? null
        : (_genDeco != null
            ? (
                re: (_genDeco!.reMin + _genDeco!.reMax) / 2.0,
                im: (_genDeco!.imMin + _genDeco!.imMax) / 2.0,
              )
            : (re: fixedToDouble(pt.reRaw), im: fixedToDouble(pt.imRaw)));
    return CanvasOverlays(
      crosshairs: false,
      // Enumerated (E) islands plus the generated and selected leaves' islands.
      islands: <CanvasIsland>[
        ..._islandHighlights,
        if (_genDeco != null) _genDeco!.cells,
        if (_selDeco != null) _selDeco!.cells,
      ],
      // The generated and selected leaves each framed by a white rectangle.
      frames: <SelectionFrame>[
        if (_genDeco != null)
          SelectionFrame(
            reMin: _genDeco!.reMin,
            reMax: _genDeco!.reMax,
            imMin: _genDeco!.imMin,
            imMax: _genDeco!.imMax,
          ),
        if (_selDeco != null)
          SelectionFrame(
            reMin: _selDeco!.reMin,
            reMax: _selDeco!.reMax,
            imMin: _selDeco!.imMin,
            imMax: _selDeco!.imMax,
          ),
      ],
      // The generated point's cross.
      crosses: <CrossMarker>[
        if (crossAt != null) CrossMarker(re: crossAt.re, im: crossAt.im),
      ],
    );
  }

  /// Run the full chained Setup pipeline on a **freshly generated** entropy root
  /// of [pointStages] fractal stages (each one 32-bit point, so `32 × pointStages`
  /// bits). [text] is the Stage-0 salt/pepper that seeds the fractal chain.
  Future<void> begin({
    required int pointStages,
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) {
    _pointStages = pointStages;
    return _encodeRoot(
      Entropy.randomBits(pointStages * EncodingConstants.bitsPerPoint),
      text: text,
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// Run the chained Setup pipeline on an **imported BIP39 seed phrase** instead
  /// of fresh entropy. The phrase may be sub-standard (any 3..24 words → a
  /// matching number of point stages). [text] is the Stage-0 salt/pepper. On an
  /// invalid phrase the controller enters the error phase with a generic message
  /// (the seed content is never echoed).
  Future<void> beginFromMnemonic(
    String mnemonic, {
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) {
    final List<int> bits;
    try {
      bits = Bip39.mnemonicToEntropyBits(mnemonic);
    } on FormatException catch (e) {
      _errorMessage = e.message; // generic by construction; no seed content
      _setPhase(SetupPhase.error);
      return Future<void>.value();
    }
    return _encodeRoot(
      bits,
      text: text,
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// Run the chained Setup pipeline on **blind hex entropy input** (8 hex digits
  /// per 32-bit stage) — for users who trust an external randomness source over
  /// the device RNG. [text] is the Stage-0 salt/pepper. Invalid or non-whole-
  /// stage input enters the error phase with a generic message (no content).
  Future<void> beginFromHex(
    String hex, {
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) {
    final List<int> bits;
    try {
      bits = Entropy.hexToBits(hex);
    } on FormatException {
      _errorMessage = 'Invalid hex — use uppercase 0–9 A–F.';
      _setPhase(SetupPhase.error);
      return Future<void>.value();
    }
    if (bits.length % EncodingConstants.bitsPerPoint != 0) {
      Entropy.wipe(bits);
      _errorMessage =
          'Hex must be a whole number of stages (8 digits = 32 bits each).';
      _setPhase(SetupPhase.error);
      return Future<void>.value();
    }
    return _encodeRoot(
      bits,
      text: text,
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// The shared chained-encode pipeline over a ready entropy [bits] root.
  ///
  /// Stage 0 is the salt/pepper [text] — it carries no point; it seeds the
  /// chain. Each fractal stage `k` (1..N) derives its `(o,p,q)` from the text
  /// plus all preceding points and encodes that stage's single 32-bit entropy
  /// chunk (chunk `k-1`). There is no canonical fractal: even the first fractal
  /// is personalised by the text. The text never enters the entropy, so the
  /// recalled seed equals [bits] exactly (lossless BIP39 round-trip). Takes
  /// ownership of [bits] and wipes it.
  Future<void> _encodeRoot(
    List<int> bits, {
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase != SetupPhase.idle &&
        _phase != SetupPhase.complete &&
        _phase != SetupPhase.error) {
      Entropy.wipe(bits);
      return; // a run is already in progress
    }
    _errorMessage = null;
    _generationError = null;
    _clearRecall();
    _isRecallSession = false;
    final int pointStages = bits.length ~/ EncodingConstants.bitsPerPoint;
    _stageCount = pointStages + 1; // + the Stage-0 text stage
    // Canonicalise through the engine so the stored/displayed text is exactly
    // what gets hashed (the protocol rule lives in core, not here).
    _chainText = _core.canonicalizeSaltPepper(text);
    _iterations = argon2Iterations;
    _profile = profile;
    try {
      _entropyBits = bits;
      _selDecoCache.clear();
      _genDecoCache.clear();
      _points = List<EncodedPoint?>.filled(pointStages + 1, null);
      _reservoirs = List<StageReservoirs?>.filled(pointStages + 1, null);
      _stageRecords = List<StageRecord?>.filled(pointStages + 1, null);
      _leafRects = List<FixedRect?>.filled(pointStages + 1, null);
      // Sized for the in-session practice recall (clicking your points back on
      // the already-derived fractals); empty until a point is marked.
      _selectedChunks = List<List<int>?>.filled(pointStages + 1, null);
      _selectedMarks =
          List<({double re, double im})?>.filled(pointStages + 1, null);

      // A text-only setup (0 point stages) has nothing to derive — land on the
      // Stage-0 view straight away.
      if (pointStages < 1) {
        Entropy.wipe(bits);
        _entropyBits = null;
        _applyDisplayStage(0);
        _setPhase(SetupPhase.memorise);
        return;
      }

      // Derive Stage 1 in the foreground (full-screen progress): there is
      // nothing to study until the first fractal exists. Hand control back the
      // moment it is ready so the user can begin memorising it…
      final bool ok = await _deriveAndEncodeStage(1, bits, foreground: true);
      if (!ok) return; // aborted mid-derivation (session torn down)
      _applyDisplayStage(1);
      _setPhase(SetupPhase.memorise);

      if (pointStages == 1) {
        Entropy.wipe(bits);
        _entropyBits = null;
        return;
      }

      // …while the remaining stages derive in the background. Each becomes
      // navigable the moment it is encoded ([isStageAvailable]); the entropy
      // root is kept alive until the last one is done, then wiped. The UI holds
      // select-mode practice off until [isGenerating] clears.
      _isGenerating = true;
      _generatingStage = 2;
      notifyListeners();
      unawaited(_generateRemaining(bits, pointStages));
    } on Argon2Cancelled {
      if (_halting) {
        // Halted during the foreground Stage-1 derivation: keep the partial
        // progress + entropy and land on the (text-only) prefix, rather than
        // tearing the session down.
        _enterHalted();
      } else {
        _resetSecrets();
        _setPhase(SetupPhase.idle);
      }
    } catch (e) {
      _resetSecrets();
      // Error text is deliberately generic — never include coordinates/bits.
      _errorMessage = 'Setup failed: ${e.runtimeType}';
      _setPhase(SetupPhase.error);
    }
  }

  /// Derive and encode a single fractal stage [k] over the entropy [bits].
  ///
  /// [foreground] drives the full-screen progress overlay (phase deriving →
  /// encoding) for the blocking Stage-1 derivation; background stages leave the
  /// phase at `memorise` and report progress only through [generatingStage] and
  /// the Argon2 counters, so the canvas stays interactive. The reservoirs and
  /// the encoded point are stored as soon as they exist, so the stage is
  /// navigable immediately after this returns. Returns `false` if the session
  /// was torn down (Reset/abort) while the derivation was in flight, in which
  /// case nothing was stored.
  Future<bool> _deriveAndEncodeStage(
    int k,
    List<int> bits, {
    required bool foreground,
  }) async {
    const int bpp = EncodingConstants.bitsPerPoint;
    _workingStageIndex = k;
    // Stage k's fractal derives from the text + every preceding point
    // (chunks 0..k-2) — one link of the memory-hard chain. Stage 1 derives
    // from the text alone.
    final List<int> priorPointBits = bits.sublist(0, (k - 1) * bpp);
    final Uint8List input = _core.chainInput(_chainText, priorPointBits);
    if (foreground) _setPhase(SetupPhase.deriving);
    _argon2Total = _iterations < 1 ? 1 : _iterations;
    _argon2Done = 0;
    notifyListeners();
    final Argon2Job job = await _core.startStageDerivation(
      input,
      iterations: _iterations,
      profile: _profile,
      onProgress: (int done, int total) {
        _argon2Done = done;
        _argon2Total = total;
        notifyListeners();
      },
      onCheckpoint: (int completed, Uint8List digest) =>
          _setInFlight(k, completed, _argon2Total, digest),
    );
    _argon2Job = job;
    final StageReservoirs reservoirs = await job.result;
    _argon2Job = null;
    _clearInFlight(); // stage's chain finished — its digest is no longer a checkpoint
    Entropy.wipe(priorPointBits);
    return _storeAndEncode(k, bits, reservoirs, foreground: foreground);
  }

  /// Store stage [k]'s [reservoirs], encode its 32-bit point (entropy chunk
  /// k-1), and record its master-secret transcript contribution. Returns `false`
  /// (after wiping [reservoirs]) if the session was torn down mid-flight, so
  /// nothing is written into the cleared arrays. Shared by fresh and resumed
  /// stage derivations.
  bool _storeAndEncode(
    int k,
    List<int> bits,
    StageReservoirs reservoirs, {
    required bool foreground,
  }) {
    if (_entropyBits == null || k >= _reservoirs.length) {
      reservoirs.clear();
      return false;
    }
    const int bpp = EncodingConstants.bitsPerPoint;
    _reservoirs[k] = reservoirs;

    // Encode this stage's single 32-bit point (entropy chunk k-1).
    if (foreground) _setPhase(SetupPhase.encoding);
    final List<int> chunk = bits.sublist((k - 1) * bpp, k * bpp);
    final List<EncodedPoint> pts = _core.encodeStage(
      chunk,
      o: reservoirs.o,
      p: reservoirs.p,
      q: reservoirs.q,
    );
    _points[k] = pts.first;
    _leafRects[k] = pts.first.leafRect;
    _genDecoCache.remove(k);
    // Record this stage's export contribution: its params and the centre of
    // the encoded point's leaf rectangle (DESIGN.md §"Master-Secret Export").
    final ({int re, int im}) leaf =
        MasterSecret.leafCentreRaw(pts.first.leafRect);
    _stageRecords[k] = StageRecord(
      o: reservoirs.o,
      p: reservoirs.p,
      q: reservoirs.q,
      leafReRaw: leaf.re,
      leafImRaw: leaf.im,
    );
    Entropy.wipe(chunk);
    // Refresh the displayed stage's cross/island now that its point exists, so
    // the marker appears immediately (not only after the next navigation).
    _refreshFocusDecos();
    notifyListeners();
    return true;
  }

  /// Finish a **halted** stage [k] by resuming its Argon2 chain from the
  /// preserved [fromDigest] (its result after [fromPass] passes), then store and
  /// encode it like a fresh stage. Mirrors [_deriveAndEncodeStage] but continues
  /// the work the halt kept instead of restarting from the chain input.
  Future<bool> _resumeAndEncodeStage(
    int k,
    List<int> bits,
    Uint8List fromDigest,
    int fromPass,
  ) async {
    _workingStageIndex = k;
    _argon2Total = _iterations < 1 ? 1 : _iterations;
    _argon2Done = fromPass; // progress / ETA continue from where the halt left off
    notifyListeners();
    final Argon2Job job = await _core.resumeStageDerivation(
      fromDigest,
      fromPass: fromPass,
      iterations: _iterations,
      profile: _profile,
      onProgress: (int done, int total) {
        _argon2Done = done;
        _argon2Total = total;
        notifyListeners();
      },
      onCheckpoint: (int completed, Uint8List digest) =>
          _setInFlight(k, completed, _argon2Total, digest),
    );
    // The isolate has its own copy now; wipe the stash digest we passed in.
    fromDigest.fillRange(0, fromDigest.length, 0);
    _argon2Job = job;
    final StageReservoirs reservoirs = await job.result;
    _argon2Job = null;
    _clearInFlight();
    // Resume always runs in the background (the prefix is already studyable), so
    // foreground: false — no full-screen encode phase.
    return _storeAndEncode(k, bits, reservoirs, foreground: false);
  }

  /// Derive the stages after Stage 1 in the background, one at a time, while the
  /// user studies the stages already done. Owns [bits] for the duration and
  /// wipes the entropy root once the last stage is encoded (or on abort). A
  /// failure leaves the stages derived so far intact and surfaces
  /// [generationError].
  Future<void> _generateRemaining(List<int> bits, int pointStages) async {
    try {
      for (int k = 2; k <= pointStages; k++) {
        _generatingStage = k;
        notifyListeners();
        final bool ok = await _deriveAndEncodeStage(k, bits, foreground: false);
        if (!ok) return; // session torn down — finally cleans up
      }
    } on Argon2Cancelled {
      // Cancelled. On a halt, the in-flight stage's progress is stashed and the
      // entropy is kept for resume (handled in the finally + _enterHalted). On a
      // reset, _resetSecrets has already wiped the session. Either way the
      // stages already derived stay valid; the rest simply never appear.
      return;
    } catch (e) {
      _generationError =
          'Stage $_generatingStage failed to derive (${e.runtimeType}); '
          'the earlier stages are still usable.';
    } finally {
      if (_halting) {
        // Halt: keep the entropy root (resume needs it) and promote the stash.
        _enterHalted();
      } else {
        _isGenerating = false;
        _generatingStage = 0;
        // The entropy root is no longer needed once every stage carries its
        // point (skip if a reset already wiped it).
        if (_entropyBits != null) {
          Entropy.wipe(bits);
          _entropyBits = null;
        }
        notifyListeners();
      }
    }
  }

  /// Resume a halted derivation: finish the halted stage from its preserved
  /// progress ([_halted]), then derive the rest of the chain in the background —
  /// exactly the tail of the original generation. No-op if nothing is halted,
  /// the entropy root is gone, or a derivation is already running.
  void resumeDerivation() {
    final _HaltCheckpoint? cp = _halted;
    if (!canResume ||
        cp == null ||
        _isGenerating ||
        _phase == SetupPhase.deriving ||
        _phase == SetupPhase.encoding) {
      return;
    }
    // An expansion halt resumes through its own (entropy-root-free) path.
    final _ExpandPlan? plan = _expandPlan;
    if (plan != null) {
      _resumeExpansion(cp, plan);
      return;
    }
    // Seed the in-flight stash with the resume's starting checkpoint (an owned
    // copy). The first *new* checkpoint only lands once a full resumed pass
    // completes — possibly a very long wait — so without this seed a re-halt in
    // that window would find _inFlight null, leaving _enterHalted nothing to
    // promote and the setup unresumable (the second-halt bug).
    _setInFlight(cp.stage, cp.pass, cp.total, cp.digest);
    _halted = null; // ownership of cp moves into the resume flow
    final List<int> bits = _entropyBits!;
    final int pointStages = nStages - 1;
    _isGenerating = true;
    _generatingStage = cp.stage;
    _generationError = null;
    notifyListeners();
    unawaited(_resumeRemaining(bits, cp, pointStages));
  }

  /// Finish the halted [cp] stage from its preserved digest, then derive stages
  /// after it (full chains) in the background. Mirrors [_generateRemaining]'s
  /// halt/teardown handling so a re-halt during resume preserves progress again.
  Future<void> _resumeRemaining(
    List<int> bits,
    _HaltCheckpoint cp,
    int pointStages,
  ) async {
    try {
      final bool ok = await _resumeAndEncodeStage(cp.stage, bits, cp.digest, cp.pass);
      if (!ok) return; // session torn down — finally cleans up
      for (int k = cp.stage + 1; k <= pointStages; k++) {
        _generatingStage = k;
        notifyListeners();
        final bool ok2 = await _deriveAndEncodeStage(k, bits, foreground: false);
        if (!ok2) return;
      }
    } on Argon2Cancelled {
      return; // re-halted mid-resume — the finally promotes the new stash
    } catch (e) {
      _generationError =
          'Stage $_generatingStage failed to derive (${e.runtimeType}); '
          'the earlier stages are still usable.';
    } finally {
      if (_halting) {
        _enterHalted();
      } else {
        _isGenerating = false;
        _generatingStage = 0;
        if (_entropyBits != null) {
          Entropy.wipe(bits);
          _entropyBits = null;
        }
        notifyListeners();
      }
    }
  }

  /// Halt an in-flight derivation: kill only the current Argon2 pass, keeping
  /// every completed intermediary digest of the working stage (stashed in
  /// [_halted] for a later resume) and the stages already derived. The entropy
  /// root is kept alive (a resume needs it); use [reset] to discard everything.
  ///
  /// No-op when nothing is deriving. The kill costs at most the single in-flight
  /// pass (~1 minute); all earlier passes survive because the worker streams
  /// each one's digest and [_inFlight] holds the latest.
  void halt() {
    if (_argon2Job == null) return;
    _halting = true;
    _argon2Job!.cancel();
    _argon2Job = null;
  }

  /// Record the working stage's latest intermediary digest (one per pass),
  /// wiping the previous one. Keeps an owned copy so the engine can wipe its.
  void _setInFlight(int stage, int completed, int total, Uint8List digest) {
    _inFlight?.wipe();
    _inFlight = _HaltCheckpoint(stage, completed, total, Uint8List.fromList(digest));
  }

  /// Drop the in-flight checkpoint (a stage finished, so its digest is no longer
  /// a resume point).
  void _clearInFlight() {
    _inFlight?.wipe();
    _inFlight = null;
  }

  /// Promote the in-flight checkpoint to the halted stash and land on the
  /// already-usable prefix. Called from the Argon2Cancelled handlers when a
  /// [halt] (not a reset) triggered the cancel.
  void _enterHalted() {
    _isGenerating = false;
    _generatingStage = 0;
    if (_inFlight != null) {
      _halted?.wipe();
      _halted = _inFlight;
      _inFlight = null;
    }
    _halting = false;
    _setPhase(SetupPhase.memorise);
    notifyListeners();
  }

  /// Discard the current session and return to the configuration screen,
  /// wiping any in-memory secrets. Safe to call at any time.
  void reset() {
    _argon2Job?.cancel();
    _argon2Job = null;
    _resetSecrets();
    _errorMessage = null;
    _displayStageIndex = 0;
    _argon2Done = 0;
    _setPhase(SetupPhase.idle);
  }

  /// Begin a **cold-start recall**: no setup ran this session. Derives the
  /// Stage-1 fractal from the salt/pepper [text] alone (the first chain link,
  /// `chainInput(text, [])`), then enters the select walk so the user clicks
  /// their memorised point on each stage in turn — exactly as [selectPoint]
  /// continues the chain.
  ///
  /// [pointStages] fixes how many point stages the seed has (so the walk knows
  /// when it is complete); [argon2Iterations] and [profile] MUST match the
  /// original setup or every derived fractal will differ and no point will
  /// decode. Nothing is encoded and no target markers are shown — recall
  /// reconstructs the seed purely from the user's clicks. Secrets stay
  /// in-session and are never logged (SCOPE.md invariants).
  Future<void> beginRecall({
    required int pointStages,
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase == SetupPhase.deriving ||
        _phase == SetupPhase.recallComplete) {
      return;
    }
    // Start from a clean session; no encoded points exist in a recall.
    _resetSecrets();
    _errorMessage = null;
    _pointStages = pointStages;
    _stageCount = pointStages + 1; // Stage-0 text + one per point stage
    _chainText = _core.canonicalizeSaltPepper(text);
    _iterations = argon2Iterations;
    _selDecoCache.clear();
    _genDecoCache.clear();
    _points = List<EncodedPoint?>.filled(_stageCount, null);
    _reservoirs = List<StageReservoirs?>.filled(_stageCount, null);
    _stageRecords = List<StageRecord?>.filled(_stageCount, null);
    _leafRects = List<FixedRect?>.filled(_stageCount, null);
    _selectedChunks = List<List<int>?>.filled(_stageCount, null);
    _selectedMarks = List<({double re, double im})?>.filled(_stageCount, null);
    try {
      _workingStageIndex = 1;
      _setPhase(SetupPhase.deriving);
      _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
      _argon2Done = 0;
      final Uint8List input = _core.chainInput(_chainText, const <int>[]);
      final Argon2Job job = await _core.startStageDerivation(
        input,
        iterations: argon2Iterations,
        profile: profile,
        onProgress: (int done, int total) {
          _argon2Done = done;
          _argon2Total = total;
          notifyListeners();
        },
        onCheckpoint: (int completed, Uint8List digest) =>
            _setInFlight(1, completed, _argon2Total, digest),
      );
      _argon2Job = job;
      final StageReservoirs reservoirs = await job.result;
      _argon2Job = null;
      _clearInFlight();
      // Land on Stage 1, the first fractal, ready for its point. Only Stage 1 is
      // derived (it needs no prior point); the rest derive one at a time as the
      // user selects each next stage.
      _reservoirs[1] = reservoirs;
      _applyReservoirs(1, reservoirs);
      _isRecallSession = true;
      _setPhase(SetupPhase.memorise);
    } on Argon2Cancelled {
      if (_halting) {
        _enterHalted();
      } else {
        _resetSecrets();
        _setPhase(SetupPhase.idle);
      }
    } catch (e) {
      _resetSecrets();
      _errorMessage = 'Recall failed: ${e.runtimeType}';
      _setPhase(SetupPhase.error);
    }
  }

  /// Snap the canvas to the first stage still awaiting a point — where a
  /// select-mode click should land. Called when the user enters select mode. The
  /// first such stage is the lowest derived fractal without a selected point;
  /// if every derived fractal already has a point, it snaps to the first
  /// not-yet-derived stage (so selecting it derives the next link). No-op once
  /// recall is complete or before a session exists.
  void showRecallStage() {
    if (isRecallComplete || _stageCount == 0) return;
    final int target = _focusStageForRecall();
    if (target >= 1 && target < nStages) {
      _applyDisplayStage(target);
      notifyListeners();
    }
  }

  /// The stage the recall walk should focus: the lowest derived fractal without
  /// a point, else the first not-yet-derived stage (capped at the last stage).
  int _focusStageForRecall() {
    for (int k = 1; k < nStages; k++) {
      final bool derived = k < _reservoirs.length && _reservoirs[k] != null;
      if (derived && !hasSelectedPoint(k)) return k;
    }
    final int next = firstUnderivedStage;
    return next < nStages ? next : nStages - 1;
  }

  /// Handle a select-mode click: decode the point under the cursor on the
  /// fractal currently shown and **mark** it as this stage's recalled point. The
  /// chain does **not** advance here — deriving the next fractal is a separate,
  /// explicit step ([deriveNextStage]), triggered by selecting the next stage.
  ///
  /// Marking is synchronous (no Argon2). Decoding mirrors encoding (protocol.py
  /// `decode_entropy`): the point is decoded under this stage's reservoirs into
  /// its 32-bit chunk. When the marked point belongs to a stage that already had
  /// one **and** later fractals were derived from it, those later fractals are
  /// now stale; the caller must confirm (the click returns [SelectionOutcome
  /// .needsConfirm]) and re-call with [confirmedReselect] to discard them.
  ///
  /// Decoded bits and coordinates stay inside the session and are never logged
  /// (SCOPE.md invariants).
  SelectionOutcome selectPoint(
    FractalSelection selection, {
    bool confirmedReselect = false,
  }) {
    if (_phase == SetupPhase.deriving ||
        _phase == SetupPhase.recallComplete) {
      return SelectionOutcome.busy;
    }

    final int k = _displayStageIndex;
    // Only a derived fractal stage can carry a point. Stage 0 (text) cannot.
    if (k < 1 || k >= _reservoirs.length) return SelectionOutcome.busy;
    final StageReservoirs? r = _reservoirs[k];
    if (r == null) return SelectionOutcome.busy;

    final CoreDecodeResult result = _core.decodePoint(
      reRaw: fixedFromDouble(selection.re),
      imRaw: fixedFromDouble(selection.im),
      o: r.o,
      p: r.p,
      q: r.q,
    );
    if (!result.valid) return SelectionOutcome.invalid;

    // Re-selecting a stage whose later fractals were derived **from its point**
    // discards them — confirm first. Only in a recall walk are later fractals a
    // function of this point; in a generated setup every fractal already exists
    // (from the real entropy), so re-clicking is just a practice correction.
    final bool discardsDownstream =
        _isRecallSession && hasSelectedPoint(k) && _hasDerivedAfter(k);
    if (discardsDownstream && !confirmedReselect) {
      return SelectionOutcome.needsConfirm;
    }

    // Record this stage's point and its master-secret export record (its
    // reservoirs + the centre of the decoded point's leaf rectangle).
    _selectedMarks[k] = (re: selection.re, im: selection.im);
    if (k < _leafRects.length) _leafRects[k] = result.leafRect;
    _setSelectedChunk(k, result.bits);
    final ({int re, int im}) leaf = MasterSecret.leafCentreRaw(result.leafRect);
    _stageRecords[k] = StageRecord(
      o: r.o,
      p: r.p,
      q: r.q,
      leafReRaw: leaf.re,
      leafImRaw: leaf.im,
    );

    // The selected leaf's decoration (always framed), reusing this decode.
    _selDecoCache[k] = _focusDecoForLeaf(result.leafRect, result.path, r.o, r.p, r.q);
    _refreshFocusDecos();
    debugPrint('select: stage=$k marked; '
        'selDeco=${_selDeco == null ? "NULL" : (_selDeco!.cells.pointsReIm.isEmpty ? "leaf-frame (no island cells)" : "island-frame (${_selDeco!.cells.pointsReIm.length ~/ 2} cells)")}; '
        'displayStage=$_displayStageIndex');

    // Any later fractals were derived from this stage's previous point; they are
    // now invalid. Discard them so the chain stays consistent.
    if (discardsDownstream) _discardAfter(k);

    // Reaching a full set of points reconstructs the seed.
    if (_allPointsSelected()) {
      _recalledEntropyBits = <int>[
        for (int j = 1; j < nStages; j++) ..._selectedChunks[j]!,
      ];
      _setPhase(SetupPhase.recallComplete);
      return SelectionOutcome.complete;
    }
    notifyListeners();
    return SelectionOutcome.marked;
  }

  /// Replace stage [k]'s point with [chunk] (one 32-bit point), re-encoding it on
  /// k's existing fractal. The stages above k were hashed from the old point, so
  /// they are dropped and the setup shrinks to k stages (their slots become
  /// ghosts to re-expand). Caller owns [chunk]; this copies what it keeps.
  void _setStagePoint(int k, List<int> chunk) {
    final StageReservoirs res = _reservoirs[k]!;
    final List<EncodedPoint> pts =
        _core.encodeStage(chunk, o: res.o, p: res.p, q: res.q);
    _points[k] = pts.first;
    _leafRects[k] = pts.first.leafRect;
    final ({int re, int im}) leaf =
        MasterSecret.leafCentreRaw(pts.first.leafRect);
    _stageRecords[k] = StageRecord(
      o: res.o,
      p: res.p,
      q: res.q,
      leafReRaw: leaf.re,
      leafImRaw: leaf.im,
    );
    // The encoded point now defines this stage; drop any recall-style selection.
    _selectedMarks[k] = null;
    _selDecoCache.remove(k);
    _genDecoCache.remove(k);
    final List<int>? oldSel = _selectedChunks[k];
    if (oldSel != null) {
      Entropy.wipe(oldSel);
      _selectedChunks[k] = null;
    }
    // Drop the now-stale tail. truncateFrom no-ops when k is the last stage.
    if (k < nStages - 1) {
      truncateFrom(k + 1);
    } else {
      _applyDisplayStage(k);
      notifyListeners();
    }
  }

  /// Change the displayed stage's point to fresh random entropy (the `N` edit).
  void changeCurrentPointGenerated() {
    final int k = _displayStageIndex;
    if (!_canEditPointAt(k)) return;
    final List<int> chunk =
        Entropy.randomBits(EncodingConstants.bitsPerPoint);
    _setStagePoint(k, chunk);
    Entropy.wipe(chunk);
  }

  /// Change the displayed stage's point to the leaf under a canvas click (the
  /// `R` edit). Returns [SelectionOutcome.invalid] if no encodable leaf is there,
  /// [SelectionOutcome.busy] if the stage cannot be edited, else `marked`.
  SelectionOutcome changeCurrentPointAt(FractalSelection sel) {
    final int k = _displayStageIndex;
    if (!_canEditPointAt(k)) return SelectionOutcome.busy;
    final StageReservoirs res = _reservoirs[k]!;
    final CoreDecodeResult d = _core.decodePoint(
      reRaw: fixedFromDouble(sel.re),
      imRaw: fixedFromDouble(sel.im),
      o: res.o,
      p: res.p,
      q: res.q,
    );
    if (!d.valid) return SelectionOutcome.invalid;
    _setStagePoint(k, d.bits);
    return SelectionOutcome.marked;
  }

  /// Change the displayed stage's point from blind uppercase hex (the `I` edit):
  /// exactly 8 digits = 32 bits. Returns an error message on invalid input (no
  /// content echoed), else null on success.
  String? changeCurrentPointHex(String hex) {
    final int k = _displayStageIndex;
    if (!_canEditPointAt(k)) return 'This stage cannot be edited.';
    List<int> bits;
    try {
      bits = Entropy.hexToBits(hex);
    } on FormatException {
      return 'Invalid hex — use uppercase 0–9 A–F.';
    }
    if (bits.length != EncodingConstants.bitsPerPoint) {
      Entropy.wipe(bits);
      return 'A point is 32 bits — exactly 8 hex digits.';
    }
    _setStagePoint(k, bits);
    Entropy.wipe(bits);
    return null;
  }

  /// Change the displayed stage's point from 3 BIP39 words (32 bits + checksum).
  /// Returns an error message on invalid input, else null on success.
  String? changeCurrentPointWords(String words) {
    final int k = _displayStageIndex;
    if (!_canEditPointAt(k)) return 'This stage cannot be edited.';
    List<int> bits;
    try {
      bits = Bip39.mnemonicToEntropyBits(words);
    } on FormatException catch (e) {
      return e.message;
    }
    if (bits.length != EncodingConstants.bitsPerPoint) {
      Entropy.wipe(bits);
      return 'A point is one stage — exactly 3 words.';
    }
    _setStagePoint(k, bits);
    Entropy.wipe(bits);
    return null;
  }

  /// Derive the **first not-yet-derived** stage's fractal — the explicit step
  /// that advances the chain, triggered by selecting that stage. The fractal is
  /// the memory-hard hash of the Stage-0 text plus every preceding point
  /// (protocol.py `decode_entropy`), so the previous stage MUST already carry a
  /// selected point ([DeriveOutcome.noPriorPoint] otherwise). On success the
  /// canvas lands on the new fractal, ready for its point.
  Future<DeriveOutcome> deriveNextStage({
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase == SetupPhase.deriving) return DeriveOutcome.busy;
    final int target = firstUnderivedStage;
    if (target >= nStages) return DeriveOutcome.none; // all derived
    // The next fractal hashes the points of every prior stage; they must exist
    // (selected during recall, or already encoded in a generated/imported setup).
    for (int k = 1; k < target; k++) {
      if (!_hasPointAt(k)) return DeriveOutcome.noPriorPoint;
    }

    final List<int> priorPointBits = <int>[
      for (int k = 1; k < target; k++) ..._pointChunk(k),
    ];
    final Uint8List input = _core.chainInput(_chainText, priorPointBits);
    try {
      _workingStageIndex = target;
      _setPhase(SetupPhase.deriving);
      _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
      _argon2Done = 0;
      final Argon2Job job = await _core.startStageDerivation(
        input,
        iterations: argon2Iterations,
        profile: profile,
        onProgress: (int done, int total) {
          _argon2Done = done;
          _argon2Total = total;
          notifyListeners();
        },
        onCheckpoint: (int completed, Uint8List digest) =>
            _setInFlight(target, completed, _argon2Total, digest),
      );
      _argon2Job = job;
      final StageReservoirs reservoirs = await job.result;
      _argon2Job = null;
      _clearInFlight();
      Entropy.wipe(priorPointBits);

      _reservoirs[target] = reservoirs;
      _applyDisplayStage(target);
      _setPhase(SetupPhase.memorise);
      return DeriveOutcome.derived;
    } on Argon2Cancelled {
      Entropy.wipe(priorPointBits);
      _argon2Job = null;
      if (_halting) {
        _enterHalted();
      } else {
        _setPhase(SetupPhase.memorise);
      }
      return DeriveOutcome.busy;
    }
  }

  /// Whether any stage after [k] currently holds a derived fractal.
  bool _hasDerivedAfter(int k) {
    for (int j = k + 1; j < nStages; j++) {
      if (j < _reservoirs.length && _reservoirs[j] != null) return true;
    }
    return false;
  }

  /// Store stage [k]'s selected chunk, wiping any previous one.
  void _setSelectedChunk(int k, List<int> bits) {
    final List<int>? old = _selectedChunks[k];
    if (old != null) Entropy.wipe(old);
    _selectedChunks[k] = bits;
  }

  /// Discard every stage after [k] — their derived fractals and any selected
  /// points (now stale because stage [k]'s point changed).
  void _discardAfter(int k) {
    for (int j = k + 1; j < nStages; j++) {
      _reservoirs[j]?.clear();
      _reservoirs[j] = null;
      final List<int>? chunk = _selectedChunks[j];
      if (chunk != null) Entropy.wipe(chunk);
      _selectedChunks[j] = null;
      _selectedMarks[j] = null;
      _stageRecords[j] = null;
      _leafRects[j] = null;
    }
    final List<int>? rec = _recalledEntropyBits;
    if (rec != null) Entropy.wipe(rec);
    _recalledEntropyBits = null;
  }

  /// Truncate the setup: delete stage [k] and every stage above it, leaving a
  /// setup of stages `0..k-1`. The kept prefix is fully derived, so the entropy
  /// root and any halt stash (which belong to the removed tail) are wiped. The
  /// display lands on the new last stage. No-op unless
  /// [canTruncateFromDisplayed] applies (so `k >= 1`).
  void truncateFrom(int k) {
    if (_phase != SetupPhase.memorise ||
        _isGenerating ||
        _isRecallSession ||
        k < 1 ||
        k >= nStages) {
      return;
    }
    // Wipe the secret material of every removed stage.
    for (int j = k; j < nStages; j++) {
      _reservoirs[j]?.clear();
      final List<int>? chunk = _selectedChunks[j];
      if (chunk != null) Entropy.wipe(chunk);
    }
    // The entropy root, any halt stash, and any halted-expansion plan describe
    // the (now-deleted) tail; the kept prefix is already derived, so none are
    // needed.
    if (_halted != null) {
      _halted!.wipe();
      _halted = null;
    }
    _wipeExpandImport();
    _expandPlan = null;
    if (_entropyBits != null) {
      Entropy.wipe(_entropyBits!);
      _entropyBits = null;
    }
    final List<int>? rec = _recalledEntropyBits;
    if (rec != null) Entropy.wipe(rec);
    _recalledEntropyBits = null;

    // Shrink to k stages (k-1 point stages) and trim every per-stage array.
    final int n = k;
    _points = _points.sublist(0, n);
    _reservoirs = _reservoirs.sublist(0, n);
    _stageRecords = _stageRecords.sublist(0, n);
    _leafRects = _leafRects.sublist(0, n);
    _selectedChunks = _selectedChunks.sublist(0, n);
    _selectedMarks = _selectedMarks.sublist(0, n);
    _stageCount = n;
    _pointStages = n - 1;
    _generationError = null;

    // Land on the new last stage (Stage 0 if truncated to text-only).
    _applyDisplayStage(n - 1);
    notifyListeners();
  }

  // --- Expansion: grow the setup with more point stages ----------------------

  /// Whether the displayed setup can grow more stages — the counterpart to
  /// [canTruncateFromDisplayed]'s shrink: a settled generated/imported setup
  /// (memorise, not deriving/generating, not a recall walk) still below the
  /// protocol ceiling of [maxPointStages]. A recall walk reconstructs a fixed
  /// setup, so it is never expandable.
  bool get canExpand =>
      _phase == SetupPhase.memorise &&
      !_isGenerating &&
      !_isRecallSession &&
      _stageCount > 0 &&
      pointStageCount < maxPointStages;

  /// The first point-stage index a new expansion would add (one past the current
  /// last point stage).
  int get firstExpansionStage => pointStageCount + 1;

  /// Grow every per-stage array to a setup of [n] stages (Stage 0 + n-1 point
  /// stages), appending empty slots. The appended stages carry no fractal or
  /// point yet — callers derive and fill them.
  void _growStagesTo(int n) {
    final int add = n - _stageCount;
    if (add <= 0) return;
    _points = <EncodedPoint?>[..._points, ...List<EncodedPoint?>.filled(add, null)];
    _reservoirs = <StageReservoirs?>[
      ..._reservoirs,
      ...List<StageReservoirs?>.filled(add, null),
    ];
    _stageRecords = <StageRecord?>[
      ..._stageRecords,
      ...List<StageRecord?>.filled(add, null),
    ];
    _leafRects = <FixedRect?>[..._leafRects, ...List<FixedRect?>.filled(add, null)];
    _selectedChunks = <List<int>?>[
      ..._selectedChunks,
      ...List<List<int>?>.filled(add, null),
    ];
    _selectedMarks = <({double re, double im})?>[
      ..._selectedMarks,
      ...List<({double re, double im})?>.filled(add, null),
    ];
    _stageCount = n;
    _pointStages = n - 1;
  }

  /// Shrink the per-stage arrays back to [n] stages, dropping the tail. Used to
  /// undo the slots an expansion grew but never managed to fill (a halt or a
  /// failure part-way). The dropped stages are expansion-fresh — underived and
  /// point-less — so there is nothing secret to wipe.
  void _shrinkStagesTo(int n) {
    if (n >= _stageCount) return;
    _points = _points.sublist(0, n);
    _reservoirs = _reservoirs.sublist(0, n);
    _stageRecords = _stageRecords.sublist(0, n);
    _leafRects = _leafRects.sublist(0, n);
    _selectedChunks = _selectedChunks.sublist(0, n);
    _selectedMarks = _selectedMarks.sublist(0, n);
    _stageCount = n;
    _pointStages = n - 1;
  }

  /// Start an N/I expansion to [targetPointStages]: grow the new stages, record
  /// the [mode] + target as the resumable plan, and derive/encode the new stages
  /// in the background like the tail of generation (the studyable prefix stays
  /// interactive). No-op unless [canExpand].
  ///
  /// The plan is mode-based (not a one-shot closure) so a halt can resume it:
  /// each new stage's chunk is reproduced by [_chunkForStage] from the mode and
  /// the kept import buffer. The manual R edit instead grows empty stages
  /// ([beginManualExpansion]) and fills them through the interactive walk.
  void _startExpansion(_ExpandMode mode, int targetPointStages) {
    if (!canExpand) return;
    final int target =
        targetPointStages > maxPointStages ? maxPointStages : targetPointStages;
    final int firstNew = firstExpansionStage;
    if (target < firstNew) return; // nothing to add
    _growStagesTo(target + 1);
    _expandPlan = _ExpandPlan(mode, target, firstNew);
    _isGenerating = true;
    _generatingStage = firstNew;
    _generationError = null;
    notifyListeners();
    unawaited(_expandRemaining(firstNew, target));
  }

  /// A fresh 32-bit chunk for new stage [k] under the active expansion plan:
  /// random (N) or the k-th slice of the kept import buffer (I). Caller owns and
  /// wipes the result.
  List<int> _chunkForStage(int k) {
    final _ExpandPlan plan = _expandPlan!;
    switch (plan.mode) {
      case _ExpandMode.generated:
        return Entropy.randomBits(EncodingConstants.bitsPerPoint);
      case _ExpandMode.imported:
        const int bpp = EncodingConstants.bitsPerPoint;
        final int off = (k - plan.firstNew) * bpp;
        return _expandImportBits!.sublist(off, off + bpp);
    }
  }

  /// Expand to [targetPointStages] with fresh random points for every new stage
  /// (the N edit).
  void expandGenerated(int targetPointStages) {
    _startExpansion(_ExpandMode.generated, targetPointStages);
  }

  /// Expand to [targetPointStages] from [importedBits] — `32 ·
  /// (targetPointStages - firstExpansionStage + 1)` bits, one 32-bit point per
  /// new stage (the I edit). Ownership of [importedBits] transfers here; it is
  /// kept (for a possible resume) and wiped when the expansion ends.
  void expandImported(int targetPointStages, List<int> importedBits) {
    if (!canExpand) {
      Entropy.wipe(importedBits);
      return;
    }
    _wipeExpandImport(); // drop any stale buffer before taking this one
    _expandImportBits = importedBits;
    _startExpansion(_ExpandMode.imported, targetPointStages);
  }

  /// Expand to [targetPointStages] from blind uppercase hex (the I edit): `8·m`
  /// digits for the `m` new stages. Returns an error message on invalid input
  /// (no content echoed), else null (the background expansion has started).
  String? expandImportedHex(int targetPointStages, String hex) {
    if (!canExpand) return 'This setup cannot be expanded.';
    final int m = targetPointStages - firstExpansionStage + 1;
    if (m < 1) return 'Nothing to add.';
    List<int> bits;
    try {
      bits = Entropy.hexToBits(hex);
    } on FormatException {
      return 'Invalid hex — use uppercase 0–9 A–F.';
    }
    if (bits.length != m * EncodingConstants.bitsPerPoint) {
      Entropy.wipe(bits);
      return '$m new stage${m == 1 ? '' : 's'} need ${8 * m} hex digits.';
    }
    expandImported(targetPointStages, bits);
    return null;
  }

  /// Expand to [targetPointStages] from `3·m` BIP39 words for the `m` new stages
  /// (the I edit). Returns an error message on invalid input, else null.
  String? expandImportedWords(int targetPointStages, String words) {
    if (!canExpand) return 'This setup cannot be expanded.';
    final int m = targetPointStages - firstExpansionStage + 1;
    if (m < 1) return 'Nothing to add.';
    List<int> bits;
    try {
      bits = Bip39.mnemonicToEntropyBits(words);
    } on FormatException catch (e) {
      return e.message;
    }
    if (bits.length != m * EncodingConstants.bitsPerPoint) {
      Entropy.wipe(bits);
      return '$m new stage${m == 1 ? '' : 's'} need ${3 * m} words.';
    }
    expandImported(targetPointStages, bits);
    return null;
  }

  /// Begin a **manual** expansion to [targetPointStages]: grow the setup with
  /// empty (underived, point-less) stages. The new stages then derive one at a
  /// time through the ordinary interactive walk — select the next stage to derive
  /// its fractal ([deriveNextStage]), click its point ([selectPoint]) — until the
  /// target count is reached. No-op unless [canExpand].
  void beginManualExpansion(int targetPointStages) {
    if (!canExpand) return;
    final int target =
        targetPointStages > maxPointStages ? maxPointStages : targetPointStages;
    if (target < firstExpansionStage) return;
    _growStagesTo(target + 1);
    notifyListeners();
  }

  /// Background loop for an N/I expansion: derive and encode stages
  /// [firstNew]..[target] in chain order. A halt preserves the in-flight stage's
  /// digest, the plan, and (for I) the import buffer so [resumeDerivation] can
  /// finish the rest; a failure or normal finish drops the plan and any
  /// grown-but-unfilled tail.
  Future<void> _expandRemaining(int firstNew, int target) async {
    int done = firstNew - 1; // last fully-encoded stage
    try {
      for (int k = firstNew; k <= target; k++) {
        _generatingStage = k;
        notifyListeners();
        final bool ok = await _deriveAndEncodeExpandStage(k);
        if (!ok) return; // torn down (reset) — arrays already wiped there
        done = k;
      }
    } on Argon2Cancelled {
      return; // halt/reset cancelled the in-flight stage; finally settles
    } catch (e) {
      _generationError =
          'Stage $_generatingStage failed to derive (${e.runtimeType}); '
          'the earlier stages are still usable.';
    } finally {
      _settleExpansion(done);
    }
  }

  /// Shared teardown for an N/I expansion loop (fresh or resumed). On a halt,
  /// preserve the in-flight digest + plan + import buffer (resume finishes them)
  /// and keep the grown tail. Otherwise drop the plan, wipe the import buffer,
  /// trim any unfilled tail, and settle on the studyable prefix.
  void _settleExpansion(int done) {
    // Resumable halt: a stage was in flight with at least one preserved pass.
    if (_halting && _inFlight != null) {
      _enterHalted(); // promotes the in-flight digest; plan + import kept
      return;
    }
    // Otherwise a clean stop — normal finish, failure, reset, or a halt before
    // the stage's first checkpoint (nothing to resume). Drop the plan, the
    // import buffer, and any grown-but-unfilled tail.
    _halting = false;
    _wipeExpandImport();
    _expandPlan = null;
    _clearInFlight();
    // Skip if a reset tore the session down (it cleared the arrays already).
    if (_phase == SetupPhase.memorise && _stageCount > 0) {
      if (done + 1 < _stageCount) _shrinkStagesTo(done + 1);
      _isGenerating = false;
      _generatingStage = 0;
      // Keep the user where they were studying; only re-land if the shrink left
      // the view past the new last stage.
      if (_displayStageIndex >= _stageCount) _applyDisplayStage(pointStageCount);
      notifyListeners();
    }
  }

  /// Derive and encode one **expansion** stage [k]: hash the chain (text + every
  /// existing point, decoded on demand) into stage k's fractal, then encode its
  /// point ([_chunkForStage], produced only after the fractal succeeds, so a
  /// cancelled derivation creates no chunk to leak). Background only. Returns
  /// false if the session was torn down mid-flight (reset).
  Future<bool> _deriveAndEncodeExpandStage(int k) async {
    _workingStageIndex = k;
    // Prior points (1..k-1) all already carry a point — decode them on demand.
    final List<int> priorPointBits = <int>[
      for (int j = 1; j < k; j++) ..._pointChunk(j),
    ];
    final Uint8List input = _core.chainInput(_chainText, priorPointBits);
    _argon2Total = _iterations < 1 ? 1 : _iterations;
    _argon2Done = 0;
    notifyListeners();
    final Argon2Job job = await _core.startStageDerivation(
      input,
      iterations: _iterations,
      profile: _profile,
      onProgress: (int done, int total) {
        _argon2Done = done;
        _argon2Total = total;
        notifyListeners();
      },
      onCheckpoint: (int completed, Uint8List digest) =>
          _setInFlight(k, completed, _argon2Total, digest),
    );
    _argon2Job = job;
    final StageReservoirs reservoirs = await job.result;
    _argon2Job = null;
    _clearInFlight();
    Entropy.wipe(priorPointBits);
    // Torn down (reset) while deriving? Drop the result untouched.
    if (k >= _reservoirs.length || _phase != SetupPhase.memorise) {
      reservoirs.clear();
      return false;
    }
    _encodePointOnReservoirs(k, _chunkForStage(k), reservoirs);
    return true;
  }

  /// Resume a halted N/I expansion: finish the halted stage from its preserved
  /// [cp] digest, then derive the remaining new stages. Mirrors
  /// [_resumeRemaining] for generation; called by [resumeDerivation] when the
  /// halted work is an expansion.
  void _resumeExpansion(_HaltCheckpoint cp, _ExpandPlan plan) {
    // See resumeDerivation: seed the in-flight stash so a re-halt before the
    // first resumed pass completes still leaves a resumable checkpoint.
    _setInFlight(cp.stage, cp.pass, cp.total, cp.digest);
    _halted = null; // ownership of cp moves into the resume flow
    _isGenerating = true;
    _generatingStage = cp.stage;
    _generationError = null;
    notifyListeners();
    unawaited(_resumeExpandRemaining(cp, plan));
  }

  Future<void> _resumeExpandRemaining(
    _HaltCheckpoint cp,
    _ExpandPlan plan,
  ) async {
    int done = cp.stage - 1;
    try {
      final bool ok =
          await _resumeAndEncodeExpandStage(cp.stage, cp.digest, cp.pass);
      if (!ok) return;
      done = cp.stage;
      for (int k = cp.stage + 1; k <= plan.target; k++) {
        _generatingStage = k;
        notifyListeners();
        final bool ok2 = await _deriveAndEncodeExpandStage(k);
        if (!ok2) return;
        done = k;
      }
    } on Argon2Cancelled {
      return; // re-halted mid-resume — the finally promotes the new stash
    } catch (e) {
      _generationError =
          'Stage $_generatingStage failed to derive (${e.runtimeType}); '
          'the earlier stages are still usable.';
    } finally {
      _settleExpansion(done);
    }
  }

  /// Finish a halted expansion stage [k] by resuming its Argon2 chain from the
  /// preserved [fromDigest] (after [fromPass] passes), then encode its point.
  /// Mirrors [_resumeAndEncodeStage]. Returns false if torn down mid-flight.
  Future<bool> _resumeAndEncodeExpandStage(
    int k,
    Uint8List fromDigest,
    int fromPass,
  ) async {
    _workingStageIndex = k;
    _argon2Total = _iterations < 1 ? 1 : _iterations;
    _argon2Done = fromPass;
    notifyListeners();
    final Argon2Job job = await _core.resumeStageDerivation(
      fromDigest,
      fromPass: fromPass,
      iterations: _iterations,
      profile: _profile,
      onProgress: (int done, int total) {
        _argon2Done = done;
        _argon2Total = total;
        notifyListeners();
      },
      onCheckpoint: (int completed, Uint8List digest) =>
          _setInFlight(k, completed, _argon2Total, digest),
    );
    fromDigest.fillRange(0, fromDigest.length, 0);
    _argon2Job = job;
    final StageReservoirs reservoirs = await job.result;
    _argon2Job = null;
    _clearInFlight();
    if (k >= _reservoirs.length || _phase != SetupPhase.memorise) {
      reservoirs.clear();
      return false;
    }
    _encodePointOnReservoirs(k, _chunkForStage(k), reservoirs);
    return true;
  }

  /// Store [reservoirs] for stage [k], encode [chunk] as its point on them, and
  /// record the master-secret contribution. Wipes [chunk]. The encode half of
  /// [_storeAndEncode], shared by expansion.
  void _encodePointOnReservoirs(
    int k,
    List<int> chunk,
    StageReservoirs reservoirs,
  ) {
    _reservoirs[k] = reservoirs;
    final List<EncodedPoint> pts = _core.encodeStage(
      chunk,
      o: reservoirs.o,
      p: reservoirs.p,
      q: reservoirs.q,
    );
    _points[k] = pts.first;
    _leafRects[k] = pts.first.leafRect;
    final ({int re, int im}) leaf =
        MasterSecret.leafCentreRaw(pts.first.leafRect);
    _stageRecords[k] = StageRecord(
      o: reservoirs.o,
      p: reservoirs.p,
      q: reservoirs.q,
      leafReRaw: leaf.re,
      leafImRaw: leaf.im,
    );
    _genDecoCache.remove(k);
    _refreshFocusDecos();
    Entropy.wipe(chunk);
    notifyListeners();
  }

  /// Wipe and drop the I-mode expansion's imported entropy buffer, if any.
  void _wipeExpandImport() {
    final List<int>? bits = _expandImportBits;
    if (bits != null) Entropy.wipe(bits);
    _expandImportBits = null;
  }

  // --- Provisional-key vault: export / restore the setup ---------------------

  /// Whether the current setup can be exported as a [SetupVault]: a settled
  /// setup (not mid-derivation) where every point stage carries a point. The
  /// recall-complete state qualifies too (its points are reconstructed).
  bool get canExportVault {
    if (_isGenerating || _stageCount <= 1) return false;
    for (int k = 1; k < nStages; k++) {
      if (k >= _stageRecords.length || _stageRecords[k] == null) return false;
    }
    return true;
  }

  /// Whether the current setup is a **mid-derivation** plain generation that can
  /// be saved as a *resumable* vault — either halted (preserved [_halted]
  /// progress) or still deriving in the foreground/background (a live [_inFlight]
  /// checkpoint of the working stage). It must hold the entropy root and be
  /// neither a recall walk nor an N/I expansion (whose resume state is not
  /// persisted). A save snapshots the current checkpoint without disturbing a
  /// derivation in progress. Such a save carries the seed root, so it is the
  /// strongest secret the app writes — see [VaultResume]'s security note.
  ///
  /// Briefly false between stages (after one stage is stored and before the next
  /// stage's first pass completes), when there is no checkpoint to snapshot yet.
  bool get canExportResumable =>
      (_halted != null || _inFlight != null) &&
      _entropyBits != null &&
      _expandPlan == null &&
      !_isRecallSession;

  /// Capture the current setup as a [SetupVault] (the provisional key). Each
  /// stage contributes its `(o, p, q)` and the centre of its point's leaf — one
  /// coordinate inside the leaf, which decodes back to the same point and bits.
  /// Encoded and manually-selected points are captured identically (both
  /// populate [StageRecord]). The caller owns the returned vault and MUST wipe
  /// it; it must only be persisted encrypted (never in plaintext).
  SetupVault exportVault() {
    final List<VaultStage> stages = <VaultStage>[];
    for (int k = 1; k < nStages; k++) {
      final StageRecord r = _stageRecords[k]!;
      stages.add(VaultStage(
        o: r.o,
        p: r.p,
        q: r.q,
        reRaw: r.leafReRaw,
        imRaw: r.leafImRaw,
      ));
    }
    return SetupVault(
      text: _chainText,
      iterations: _iterations,
      profile: _profile,
      stages: stages,
    );
  }

  /// Rebuild a full, settled (memorise) setup from a [SetupVault] — no Argon2:
  /// each stage's `(o, p, q)` + leaf coordinate is decoded back into its fractal
  /// reservoirs and encoded point. Every stage is validated before the current
  /// session is torn down, so a corrupt vault (e.g. a wrong-password decrypt)
  /// throws a generic [FormatException] and leaves the live session untouched.
  void restoreVault(SetupVault vault) {
    final int n = vault.stages.length + 1; // + the Stage-0 text stage
    // Decode + validate every stage first, into locals.
    final List<StageReservoirs?> reservoirs = <StageReservoirs?>[null];
    final List<EncodedPoint?> points = <EncodedPoint?>[null];
    final List<StageRecord?> records = <StageRecord?>[null];
    final List<FixedRect?> leafRects = <FixedRect?>[null];
    for (final VaultStage s in vault.stages) {
      final CoreDecodeResult d = _core.decodePoint(
        reRaw: s.reRaw,
        imRaw: s.imRaw,
        o: s.o,
        p: s.p,
        q: s.q,
      );
      if (!d.valid) throw const FormatException('bad vault');
      reservoirs.add(StageReservoirs(o: s.o, p: s.p, q: s.q));
      points.add(EncodedPoint(reRaw: s.reRaw, imRaw: s.imRaw, leafRect: d.leafRect));
      leafRects.add(d.leafRect);
      final ({int re, int im}) leaf = MasterSecret.leafCentreRaw(d.leafRect);
      records.add(StageRecord(
        o: s.o,
        p: s.p,
        q: s.q,
        leafReRaw: leaf.re,
        leafImRaw: leaf.im,
      ));
    }

    // All stages decoded — safe to replace the current session.
    _resetSecrets();
    _chainText = vault.text;
    _iterations = vault.iterations;
    _profile = vault.profile;
    _stageCount = n;
    _pointStages = n - 1;
    _points = points;
    _reservoirs = reservoirs;
    _stageRecords = records;
    _leafRects = leafRects;
    _selectedChunks = List<List<int>?>.filled(n, null);
    _selectedMarks = List<({double re, double im})?>.filled(n, null);
    _isRecallSession = false;
    _applyDisplayStage(1); // land on the first point stage
    _setPhase(SetupPhase.memorise);
  }

  /// Capture a mid-derivation generation as a **resumable** [SetupVault]: the
  /// derived prefix stages (stages 1..working-1, each a cheap-to-decode
  /// [VaultStage]) plus the [VaultResume] state — the entropy root, the working
  /// stage's checkpoint, and the stage geometry — needed to finish the chain in
  /// a later session. The checkpoint is the halted stash when paused, else the
  /// live in-flight checkpoint (its digest is copied, so an ongoing derivation
  /// that wipes/replaces the live buffer on the next pass is unaffected). Caller
  /// owns/wipes the vault and MUST persist it encrypted only (it holds the seed
  /// root).
  SetupVault exportResumableVault() {
    final _HaltCheckpoint cp = _halted ?? _inFlight!;
    final List<int> bits = _entropyBits!;
    final List<VaultStage> stages = <VaultStage>[];
    for (int k = 1; k < cp.stage; k++) {
      final StageRecord r = _stageRecords[k]!;
      stages.add(VaultStage(
        o: r.o,
        p: r.p,
        q: r.q,
        reRaw: r.leafReRaw,
        imRaw: r.leafImRaw,
      ));
    }
    return SetupVault(
      text: _chainText,
      iterations: _iterations,
      profile: _profile,
      stages: stages,
      resume: VaultResume(
        stage: cp.stage,
        pass: cp.pass,
        total: cp.total,
        pointStages: nStages - 1,
        digest: List<int>.from(cp.digest),
        entropy: List<int>.from(bits),
      ),
    );
  }

  /// Restore a halted generation from a **resumable** [vault] (see
  /// [exportResumableVault]): decode the derived prefix cheaply, re-seat the
  /// entropy root and halt checkpoint, and land in `memorise` with [canResume]
  /// true so the user can continue the derivation. Everything is validated into
  /// locals first, so a corrupt vault (e.g. a wrong-key decrypt) throws a
  /// generic [FormatException] and leaves the live session untouched.
  void restoreResumableVault(SetupVault vault) {
    final VaultResume? r = vault.resume;
    if (r == null) throw const FormatException('bad vault');
    const int bpp = EncodingConstants.bitsPerPoint;
    final int s = r.pointStages;
    if (s < 1 ||
        r.stage < 1 ||
        r.stage > s ||
        r.pass < 0 ||
        r.pass > r.total ||
        r.entropy.length != s * bpp ||
        r.digest.isEmpty ||
        vault.stages.length != r.stage - 1) {
      throw const FormatException('bad vault');
    }
    final int n = s + 1; // + the Stage-0 text stage
    final List<StageReservoirs?> reservoirs = List<StageReservoirs?>.filled(n, null);
    final List<EncodedPoint?> points = List<EncodedPoint?>.filled(n, null);
    final List<StageRecord?> records = List<StageRecord?>.filled(n, null);
    final List<FixedRect?> leafRects = List<FixedRect?>.filled(n, null);
    for (int i = 0; i < vault.stages.length; i++) {
      final VaultStage st = vault.stages[i];
      final CoreDecodeResult d = _core.decodePoint(
        reRaw: st.reRaw,
        imRaw: st.imRaw,
        o: st.o,
        p: st.p,
        q: st.q,
      );
      if (!d.valid) throw const FormatException('bad vault');
      final int k = i + 1;
      reservoirs[k] = StageReservoirs(o: st.o, p: st.p, q: st.q);
      points[k] =
          EncodedPoint(reRaw: st.reRaw, imRaw: st.imRaw, leafRect: d.leafRect);
      leafRects[k] = d.leafRect;
      final ({int re, int im}) leaf = MasterSecret.leafCentreRaw(d.leafRect);
      records[k] = StageRecord(
        o: st.o,
        p: st.p,
        q: st.q,
        leafReRaw: leaf.re,
        leafImRaw: leaf.im,
      );
    }

    // All prefix stages decoded — safe to replace the current session.
    _resetSecrets();
    _chainText = vault.text;
    _iterations = vault.iterations;
    _profile = vault.profile;
    _stageCount = n;
    _pointStages = s;
    _points = points;
    _reservoirs = reservoirs;
    _stageRecords = records;
    _leafRects = leafRects;
    _selectedChunks = List<List<int>?>.filled(n, null);
    _selectedMarks = List<({double re, double im})?>.filled(n, null);
    _isRecallSession = false;
    _entropyBits = List<int>.from(r.entropy);
    _halted = _HaltCheckpoint(
      r.stage,
      r.pass,
      r.total,
      Uint8List.fromList(r.digest),
    );
    _isGenerating = false;
    _generatingStage = 0;
    _generationError = null;
    // Land on the last derived prefix stage, or the Stage-0 text when the halt
    // landed on Stage 1 (no derived fractal yet).
    _applyDisplayStage(r.stage > 1 ? r.stage - 1 : 0);
    _setPhase(SetupPhase.memorise);
    notifyListeners();
  }

  /// Save the current setup, encrypted, to [path]. Uses [providedKey] (the
  /// user's own 16- or 32-byte entropy) if given, else generates a fresh key of
  /// [genLenBytes] bytes (128-bit by default, 32 for the 256-bit mode). On
  /// success returns the key (the caller renders it as a QR / hex and wipes it),
  /// else an [error]. The file holds only ciphertext; the key is never in it.
  Future<({String? error, Uint8List? key})> saveVaultToFile(
    String path, {
    Uint8List? providedKey,
    int genLenBytes = SetupCrypto.keyLenBytes,
  }) async {
    // A settled setup saves as a provisional key; a mid-derivation one (halted
    // or still deriving) snapshots its resume-state (the seed root + working
    // checkpoint) so the derivation can continue in a later session.
    final bool resumable = !canExportVault && canExportResumable;
    if (!canExportVault && !resumable) {
      return (error: 'This setup cannot be saved yet.', key: null);
    }
    final SetupVault vault = resumable ? exportResumableVault() : exportVault();
    try {
      final SealedVault sealed = await SetupCrypto.sealVault(vault,
          providedKey: providedKey, genLenBytes: genLenBytes);
      await File(path).writeAsBytes(sealed.fileBytes, flush: true);
      return (error: null, key: sealed.key);
    } catch (e) {
      return (error: 'Could not save the file (${e.runtimeType}).', key: null);
    } finally {
      vault.wipe();
    }
  }

  /// Decrypt + restore a setup from the encrypted file at [path] using the
  /// 16-byte provisional [keyBytes] (from a scanned QR or parsed hex). The live
  /// session is replaced only once decryption and validation succeed. Returns
  /// null on success, else a generic error message. The caller owns/wipes
  /// [keyBytes].
  Future<String?> loadVaultFromFile(String path, Uint8List keyBytes) async {
    if (!SetupCrypto.isValidKeyLen(keyBytes.length)) {
      return 'That is not a valid provisional key.';
    }
    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      return 'Could not read that file.';
    }
    SetupVault vault;
    try {
      vault = await SetupCrypto.openVault(bytes, keyBytes);
    } on FormatException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not load (${e.runtimeType}).';
    }
    try {
      if (vault.resume != null) {
        restoreResumableVault(vault); // a halted setup — restore + offer Resume
      } else {
        restoreVault(vault);
      }
      return null;
    } on FormatException catch (e) {
      return e.message;
    } finally {
      vault.wipe();
    }
  }

  /// True once every point stage (1..N) carries a selected point.
  bool _allPointsSelected() {
    for (int k = 1; k < nStages; k++) {
      if (!hasSelectedPoint(k)) return false;
    }
    return nStages > 1;
  }

  /// Point the canvas + render source at [index] using explicit [res] reservoirs
  /// (used by the recall walk, which carries its own re-derived reservoirs).
  void _applyReservoirs(int index, StageReservoirs? res) {
    _displayStageIndex = index;
    _core.source.reservoirs = res;
    _core.leafSource.reservoirs = res;
    _clearIslandHighlights();
    if (res == null) {
      _displayParams = null;
    } else {
      final ({double o, double p, double q}) key = res.displayKey;
      _displayParams = StageParameters(o: key.o, p: key.p, q: key.q);
    }
    _refreshFocusDecos();
  }

  /// Clear the displayed stage's selected point (mark, chunk and export record).
  void clearSelection() {
    final int k = _displayStageIndex;
    if (selectedMarkAt(k) == null) return;
    _selectedMarks[k] = null;
    final List<int>? old = _selectedChunks[k];
    if (old != null) Entropy.wipe(old);
    _selectedChunks[k] = null;
    _stageRecords[k] = null;
    _selDecoCache.remove(k);
    _refreshFocusDecos();
    notifyListeners();
  }

  /// Whether stage [index] can currently be shown: the Stage-0 text stage, or a
  /// fractal already derived this session. In generation / import every stage is
  /// available once the setup is encoded; during a recall walk it becomes
  /// available as its fractal is reached. Drives the stage-navigation arrows.
  bool isStageAvailable(int index) {
    if (index < 0 || index >= nStages) return false;
    if (index == 0) return true;
    return index < _reservoirs.length && _reservoirs[index] != null;
  }

  /// Switch the displayed stage during memorisation. Only stages that can be
  /// shown — the Stage-0 text stage, or a fractal already derived — are allowed.
  void showStage(int index) {
    if (index == _displayStageIndex) return;
    if (index < 0 || index >= nStages) return;
    if (index != 0 &&
        (index >= _reservoirs.length || _reservoirs[index] == null)) {
      return;
    }
    _applyDisplayStage(index);
    notifyListeners();
  }

  /// Advance the displayed stage to the next available one, wrapping around —
  /// the `T` hotkey. "Available" means the Stage-0 text stage or a fractal
  /// already derived, so during a partial recall it only visits stages reached
  /// so far. No-op until a session exists.
  void cycleStage() {
    if (_stageCount <= 1) return;
    for (int step = 1; step <= nStages; step++) {
      final int next = (_displayStageIndex + step) % nStages;
      final bool available = next == 0 ||
          (next < _reservoirs.length && _reservoirs[next] != null);
      if (available) {
        if (next != _displayStageIndex) {
          _applyDisplayStage(next);
          notifyListeners();
        }
        return;
      }
    }
  }

  /// Point the canvas (and the render source) at [index]: nothing for the
  /// Stage-0 text stage, otherwise that fractal's stored chain-derived
  /// reservoirs. Does not notify; callers do.
  void _applyDisplayStage(int index) {
    _displayStageIndex = index;
    final StageReservoirs? res =
        index == 0 || index >= _reservoirs.length ? null : _reservoirs[index];
    _core.source.reservoirs = res;
    _core.leafSource.reservoirs = res;
    _clearIslandHighlights();
    if (res == null) {
      _displayParams = null;
    } else {
      final ({double o, double p, double q}) key = res.displayKey;
      _displayParams = StageParameters(o: key.o, p: key.p, q: key.q);
    }
    _refreshFocusDecos();
  }

  /// Finish Setup and wipe all session secrets. Call when leaving the flow
  /// (the user has committed the points to memory).
  void finish() {
    _resetSecrets();
    _setPhase(SetupPhase.complete);
  }

  void _clearRecall() {
    for (final List<int>? chunk in _selectedChunks) {
      if (chunk != null) Entropy.wipe(chunk);
    }
    _selectedChunks = const <List<int>?>[];
    _selectedMarks = const <({double re, double im})?>[];
    final List<int>? rec = _recalledEntropyBits;
    if (rec != null) Entropy.wipe(rec);
    _recalledEntropyBits = null;
  }

  void _resetSecrets() {
    final List<int>? bits = _entropyBits;
    if (bits != null) Entropy.wipe(bits);
    _entropyBits = null;
    _wipeExpandImport(); // drop any in-progress import-expansion buffer
    _expandPlan = null;
    // Discard any halted-stage progress and live checkpoint.
    _halting = false;
    _clearInFlight();
    _halted?.wipe();
    _halted = null;
    _points = const <EncodedPoint?>[];
    for (final StageReservoirs? r in _reservoirs) {
      r?.clear();
    }
    _reservoirs = const <StageReservoirs?>[];
    _stageRecords = const <StageRecord?>[];
    _leafRects = const <FixedRect?>[];
    _iterations = 0;
    _displayParams = null;
    _stageCount = 0;
    _chainText = '';
    _isRecallSession = false;
    _isGenerating = false;
    _generatingStage = 0;
    _generationError = null;
    _core.source.reservoirs?.clear();
    _core.source.reservoirs = null;
    // leafSource holds the same reservoirs reference (cleared above); drop it.
    _core.leafSource.reservoirs = null;
    _clearIslandHighlights();
    _selDecoCache.clear();
    _genDecoCache.clear();
    _selDeco = null;
    _genDeco = null;
    _clearRecall();
  }

  void _setPhase(SetupPhase p) {
    _phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _resetSecrets();
    super.dispose();
  }
}

/// A halted stage's preserved progress: the last completed intermediary Argon2
/// [digest] of stage [stage] and how many passes were done ([pass] of [total]).
/// The [digest] is coercion-relevant and owned by the holder — call [wipe] when
/// discarding it. A later "resume" continues the chain from [digest] for the
/// remaining `total - pass` passes.
class _HaltCheckpoint {
  _HaltCheckpoint(this.stage, this.pass, this.total, this.digest);

  final int stage;
  final int pass;
  final int total;
  final Uint8List digest;

  void wipe() => digest.fillRange(0, digest.length, 0);
}

/// How an N/I expansion fills its new stages' points — fresh random (N) or
/// sliced from the kept import buffer (I).
enum _ExpandMode { generated, imported }

/// A resumable N/I expansion plan: the fill [mode], the point-stage count to
/// reach ([target]), and the index of the first new stage ([firstNew], used to
/// offset into the import buffer). Holds no secret itself — the import bits live
/// in [SetupController._expandImportBits].
class _ExpandPlan {
  _ExpandPlan(this.mode, this.target, this.firstNew);

  final _ExpandMode mode;
  final int target;
  final int firstNew;
}

/// A computed canonical-island decoration for the displayed stage: the island's
/// flat-white [cells] plus its bounding box (fractal coordinates) for framing
/// (the selected leaf) or centring a cross (the generated point).
class _IslandDeco {
  _IslandDeco({
    required this.cells,
    required this.reMin,
    required this.reMax,
    required this.imMin,
    required this.imMax,
  });

  final CanvasIsland cells;
  final double reMin;
  final double reMax;
  final double imMin;
  final double imMax;
}
