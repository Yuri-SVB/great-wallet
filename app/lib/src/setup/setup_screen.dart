import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:great_wall_ux/great_wall_ux.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart' as qr;

import '../core/bip39.dart';
import '../core/encoding_constants.dart';
import '../core/entropy.dart';
import '../core/great_wall_core.dart';
import '../core/master_secret.dart';
import '../core/namtso_harvester.dart';
import '../core/orbit_protocol.dart';
import '../core/stage_params.dart';
import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';
import 'desktop_qr_scanner.dart';
import 'orbit_vault.dart';
import 'setup_controller.dart';
import 'setup_crypto.dart';
import 'setup_vault.dart';

/// Setup mode screen: encode a fresh seed onto the chained fractals (one
/// 32-bit point per stage) and let the user memorise the points.
///
/// This is the concrete `great-wall-core + great-wall-ux` integration the
/// architecture assigns to Setup (ARCHITECTURE.md §"7. great-wallet", mode 1):
/// great-wall-ux's [FractalCanvas] / palette / brightness drive the visuals,
/// while a [SetupController] runs the engine's encode/Argon2 pipeline and feeds
/// the canvas its [EscapeCountSource] and overlays.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final SetupController _setup = SetupController(widget.core);

  final PanZoomController _viewport =
      PanZoomController(initial: _initialViewport);
  final BrightnessController _brightness = BrightnessController();

  /// Deep render mode (Alt+L). When on, the canvas escape-count cap rises from
  /// [EncodingConstants.renderMaxIterFast] to the engine's encode cap, so the
  /// rendered boundary matches where the encoder lands leaves. Off by default
  /// and reset per stage — it is an exceptional escape hatch for the rare leaf
  /// sitting deep in a high-escape-count void, and it makes interior rendering
  /// laggy (hence the persistent on-canvas marker).
  bool _deepRender = false;

  /// The displayed stage last seen, so deep render can snap back to fast when
  /// the view moves to a new stage (mirrors the per-stage brightness reset).
  int _shownStage = 0;

  /// UI sound cues. The canvas plays the tap "click"; the selection-outcome
  /// cues (select / confirm / deny) are dispatched from [_onCanvasSelect],
  /// where the decode result is known.
  final SoundBoard _sounds = SoundBoard();

  /// Focus node for the canvas/hotkey handler, so we can return keyboard focus
  /// to it after the user has been typing in a text field.
  final FocusNode _hotkeys = FocusNode(debugLabel: 'setup-hotkeys');

  // Focus nodes for the input controls. N/I/R focus the stages slider / import
  // field; C focuses the colour wheel; the rest are reached with Tab. Each field
  // is wrapped in _track(_Field…) so focus also drives the console help.
  final FocusNode _stage0Focus = FocusNode(debugLabel: 'salt');
  final FocusNode _iterationsFocus = FocusNode(debugLabel: 'iterations');
  final FocusNode _stagesFocus = FocusNode(debugLabel: 'stages');
  final FocusNode _profileFocus = FocusNode(debugLabel: 'profile');
  final FocusNode _mnemonicFocus = FocusNode(debugLabel: 'import');
  final FocusNode _exportLabelFocus = FocusNode(debugLabel: 'export-label');
  final FocusNode _hueFocus = FocusNode(debugLabel: 'hue');

  /// Per-stage **master-secret export label** (e.g. `SIGNING-1`). Appended to
  /// the Argon2id transcript message at the exporting stage, versioning the
  /// derived secret — DESIGN.md §"Master-Secret Export". Same restricted
  /// `[A-Z0-9-]` widget as Stage 0; shown on every non-0 stage in all modes. A
  /// single field applies to whichever stage is on screen when Copy is pressed.
  final TextEditingController _exportLabel = TextEditingController();

  /// True when the last edit to [_exportLabel] had characters up-cased or
  /// dropped by the engine's canonicalisation (mirrors [_stage0Restricted]).
  bool _exportLabelRestricted = false;

  void _onExportLabelRestricted({required bool adjusted}) {
    if (_exportLabelRestricted == adjusted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _exportLabelRestricted == adjusted) return;
      setState(() => _exportLabelRestricted = adjusted);
      if (adjusted) {
        _warnOnConsole('Export salt adjusted to A–Z, 0–9 and "-" so it stays '
            'reproducible.');
      }
    });
  }

  /// An existing BIP39 phrase to import instead of generating a fresh root.
  /// Secret material: obscured by default, cleared once it has been encoded.
  final TextEditingController _mnemonic = TextEditingController();
  bool _mnemonicHidden = true;

  /// Stage 0 — the salt/pepper text that seeds the fractal chain. One field,
  /// one scheme: use it as a non-secret label ('MAIN-STASH') or a secret pepper
  /// (a blindly pasted high-entropy string) — the app treats it identically.
  /// Obscured by default with a reveal toggle; constrained to a safe ASCII
  /// subset (see [_SaltPepperFormatter]).
  final TextEditingController _stage0 = TextEditingController();
  bool _stage0Hidden = true;

  /// True when the last edit to [_stage0] had characters up-cased or dropped by
  /// the engine's canonicalisation. Tracks the state so the warning fires once
  /// per transition; the warning itself is surfaced on the console (DESIGN.md
  /// "Strong text restrictions": the divergence must be signalled to the user).
  bool _stage0Restricted = false;

  /// Called by [_SaltPepperFormatter] (during the edit pipeline) with whether
  /// the engine had to adjust the typed text. Defers the [setState] to a
  /// post-frame callback so it never runs mid-build, and fires even when the
  /// resolved text is unchanged (e.g. a lone disallowed char in an empty field,
  /// which would not trigger `onChanged`).
  void _onStage0Restricted({required bool adjusted}) {
    if (_stage0Restricted == adjusted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _stage0Restricted == adjusted) return;
      setState(() => _stage0Restricted = adjusted);
      if (adjusted) {
        _warnOnConsole('Salt / pepper adjusted to A–Z, 0–9 and "-" so it stays '
            'reproducible across devices.');
      }
    });
  }

  HueOffset _hue = HueOffset.red;
  Argon2Profile _profile = Argon2Profile.basic;
  /// N — the per-stage **Argon2 iteration count**, entered as a free number.
  /// Essentially unbounded (0..∞): a deliberately heavy setup may take hours,
  /// days, or weeks to derive, so N is a numeric field rather than a capped
  /// slider. [_iterations] holds the last in-range value; [_iterationsValid]
  /// gates the action buttons while the field is empty or malformed.
  int _iterations = 1;
  final TextEditingController _iterationsField =
      TextEditingController(text: '1');
  bool get _iterationsValid {
    final int? n = int.tryParse(_iterationsField.text.trim());
    return n != null && n >= 0;
  }

  /// Number of fractal **point stages** for a fresh/recall setup, chosen on a
  /// discrete slider with five positions, 0..[SetupController.maxPointStages].
  /// 0 is a Stage-0-text-only setup (no fractal points); each higher position
  /// adds one 32-bit fractal stage (`32 × count` bits / `3 × count` BIP39
  /// words). Every position is a valid setup, so the count needs no validity
  /// gate. (N is reserved for the Argon2 iteration count, below.)
  ///
  /// The stages slider that set this was removed with the deprecated legacy
  /// chain; the value is now fixed and only feeds the Argon2 calibration
  /// estimate.
  final int _pointStages = 4;

  final _ImportFormat _importFormat = _ImportFormat.words;

  /// Select mode: when on, tapping the canvas decodes the point under the
  /// cursor instead of panning. Toggled by the panel button or the `S` key.
  bool _selectMode = false;

  /// True while the user is picking a replacement point for the displayed stage
  /// (the `R` edit): the next canvas click sets the new point. Esc cancels.
  bool _editPointMode = false;

  /// The stage whose point is being replaced by import (the `I` edit), or null
  /// when the inline bit editor is closed.
  int? _pointImportStage;
  _ImportFormat _pointImportFmt = _ImportFormat.words;
  final TextEditingController _pointImport = TextEditingController();
  final FocusNode _pointImportFocus = FocusNode(debugLabel: 'point-import');

  /// The point-stage count a pending expansion would grow to, while the method
  /// picker (New / Import / Manual) is open in the console. Null otherwise.
  int? _expandTarget;

  /// The point-stage count an in-progress import expansion will reach, while its
  /// inline m-point bit editor is open. Reuses the [_pointImport] field/focus
  /// (the two import editors are mutually exclusive). Null otherwise.
  int? _expandImportTarget;

  /// True during a **manual** expansion (the R method): the new stages derive
  /// one at a time and the user clicks each point on its fresh fractal. Canvas
  /// selection is enabled while this is on; [_expandManualTarget] is the
  /// point-stage count the walk grows to.
  bool _expandManualActive = false;
  int? _expandManualTarget;

  /// Provisional-key save/load: the destination/source file path. The
  /// provisional key itself is never kept in a screen field — it is entered,
  /// shown, or copied only inside the Write/Open dialogs. [_vaultBusy] disables
  /// the controls while an encrypt/decrypt pass runs.
  final TextEditingController _vaultPath = TextEditingController();
  final FocusNode _vaultPathFocus = FocusNode(debugLabel: 'vault-path');
  bool _vaultBusy = false;

  /// True while a master-secret export's Argon2id pass is in flight, so a second
  /// tap on "Copy master secret" is ignored until it finishes.
  bool _exporting = false;

  /// True while the memory-hard orbit advance `o_{i+1} = H*(K_i)` is running in a
  /// worker isolate (a forward stage navigation). Folds into [_busy] so the
  /// progress scrim shows and other hotkeys/navigation are blocked meanwhile.
  bool _advancing = false;

  /// The stage the advance in flight is deriving *into*, or null. Screen-owned,
  /// because the orbit never goes through [SetupController] — which is exactly
  /// why the stage bar could not show this before: it reads the controller's
  /// `derivingStageIndex` / `stageProgress`, and an orbit advance sets neither.
  int? _advanceTarget;

  /// Completed / total memory-hard passes of the advance in flight, streamed
  /// per pass out of [GreatWallCore.startOrbitAdvance].
  int _advanceDone = 0;
  int _advanceTotal = 0;

  /// The advance in flight, so Halt can cancel it — killing the worker isolate
  /// costs at most the single pass currently running.
  OrbitAdvanceJob? _advanceJob;

  /// Fraction of the advance completed, for the stage tab's determinate bar.
  double get _advanceProgress => _advanceTotal <= 0
      ? 0
      : (_advanceDone / _advanceTotal).clamp(0.0, 1.0);

  /// A **halted** advance's preserved work: the stage it was deriving into, the
  /// passes completed, and the intermediary digest after them. Kept so Halt
  /// costs one pass rather than the whole stage, saved into the vault, and
  /// restored from it — the orbit peer of `SetupController`'s `_halted`.
  ///
  /// Dropped whenever it could no longer apply: a successful advance, a
  /// re-rooted prefix ([_invalidateDeeperThan] / [_clearOrbitPlacements]), or a
  /// change to `D` (the pass count it is relative to).
  ({int stage, int pass, Uint8List digest})? _advanceCheckpoint;

  /// Whether a halted advance can be resumed right now: its checkpoint is for
  /// the next stage to derive, its prefix is still settled, and `D` still agrees
  /// with the pass it stopped at.
  bool get _canResumeAdvance {
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    if (cp == null || _advancing) return false;
    return cp.stage == _orbitReachableCeiling + 1 &&
        cp.pass >= 1 &&
        cp.pass < _iterations &&
        _orbitK[cp.stage - 1] != null;
  }

  /// Drop a preserved checkpoint, wiping the digest. Must run inside a
  /// [setState] when it changes what is on screen.
  void _clearAdvanceCheckpoint() {
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    if (cp != null) Entropy.wipe(cp.digest);
    _advanceCheckpoint = null;
  }

  // --- Bottom console ---------------------------------------------------------
  // The console at the foot of the screen is the app's single message surface:
  // toasts, the help text of whatever control is under focus, and confirmation
  // prompts all land here instead of as SnackBars / modal dialogs.

  /// Recent console lines, most recent last (capped).
  final List<String> _consoleLog = <String>[];

  /// The input control currently under focus; the console renders its help
  /// (label + live value) so the panel itself can stay label-free.
  _Field? _focusedField;

  /// Whether the hotkey manual is shown in the console. On at launch.
  bool _manualVisible = true;

  /// Whether the console is collapsed to a thin status line (the `M` hotkey /
  /// the console's button). Independent of the stage-tab bar.
  bool _chromeMinimized = false;

  /// Whether the stage-tab bar is hidden (the `9` hotkey). Independent of the
  /// console so the user can dismiss either alone.
  bool _stageBarHidden = false;

  /// The selected **secondary slot** within the active stage (the orbit builder's
  /// lower tab row, `0..`[_maxSlot]). Slot `#0` is the salt; `#j≥1` are the
  /// fractals (their content is wired in later phases —
  /// next-steps/orbit-setup-tab-ui-pathway.md, P2+). Selected by a plain digit;
  /// stage selection moved to `Alt`+digit.
  int _slotIndex = 0;

  /// Highest secondary slot index — a fixed row of seven tabs (`0..6`).
  static const int _maxSlot = 6;

  /// The **orbit** stage cursor (`0..`[_maxStage]) — the screen-owned active
  /// stage while building the orbit pre-session. Stage 0 is rooted by σ; a deep
  /// stage is entered by the forward memory-hard advance `o_i = H*(K_{i-1})`.
  /// (During a legacy chain session the active stage instead follows the
  /// controller's `displayStageIndex`; see [_activeStage].)
  int _orbitStage = 0;

  // --- salt slot (`#0`) — Namtso σ harvest (stage 0) / retirement (stage i>0).
  // The salt slot's input; wiring σ → the orbit root o₀ into the derivation is a
  // later phase (P5). Ported from the orbit setup screen's harvest panel.
  bool _harvesting = false;
  String? _harvestNote;
  DateTime? _harvestedDate;
  HarvestSession? _harvestSession;
  final TextEditingController _sigmaCtrl = TextEditingController();
  final TextEditingController _explorerCtrl = TextEditingController();

  /// Required fractal count `r_i` per stage (index `0..`[SetupController.maxPointStages]).
  /// `r_0 = 2` by design (fixed); deep stages default to the 96-bit standard
  /// `r_i = 3` and offer the `{2,3}` slider. `r_i` is the **minimum** number of
  /// fractals the holder places; every slot is operationally equal, so any `r_i`
  /// of the `s_i` slots may be placed and the rest derive (slots beyond `r_i`
  /// are only *faded* as a hint, not disabled). The actual per-slot `θ_i_j`
  /// board render is wired with the orbit protocol (P5).
  final List<int> _requiredFractals = List<int>.generate(
      SetupController.maxPointStages + 1, (int i) => i == 0 ? 2 : 3);

  /// The stage whose slots/`r_i` the secondary row currently reflects. In a
  /// legacy chain session it follows the controller's `displayStageIndex`; while
  /// building the orbit (pre-session) it is the screen-owned [_orbitStage].
  int get _activeStage =>
      (_hasSession ? _setup.displayStageIndex : _orbitStage)
          .clamp(0, _maxStage);

  // --- P5: stage-0 orbit board render cache ---------------------------------
  // Stage 0's fractal slots (#j≥1) render the real board `θ_0_(j-1)` derived
  // from σ → o₀. The authoritative u64 reservoirs ride `widget.core.source`
  // (stage_params.dart); [_boardParams] is the display-proxy the canvas uses
  // only to trigger repaints. Both are cached, keyed by [_boardKey] = "σ#slot",
  // so panning/zooming (which rebuilds this screen) does not re-run the θ hash
  // or force a needless canvas repaint. Only ever populated at stage 0, where
  // the legacy controller leaves the render reservoirs free (stage 0 is its
  // text stage) — so there is no clash with the deep-stage `_applyReservoirs`.
  StageParameters? _boardParams;
  StageReservoirs? _boardReservoirs;
  String _boardKey = '';

  // --- P5: per-stage orbit board state --------------------------------------
  // Highest orbit stage index (mirrors the legacy stage ceiling).
  static const int _maxStage = SetupController.maxPointStages;

  // Per orbit stage i (0..[_maxStage]) and fractal slot (1..[_maxSlot]): the
  // placed 32-bit chunk and its encoded board point. Every slot is equal: the
  // holder places any r_i of them (each slot's abscissa is its index s), which
  // fixes Sh_i; the remaining slots are DERIVED — Sh_i evaluated at their slot
  // index (by the engine) — and locked. `_boardDerived` distinguishes the two.
  // Slot 0 (salt) is unused. Session-only; wiped when σ changes.
  // Indexed `[stage][slot]`.
  final List<List<List<int>?>> _boardChunks = List<List<List<int>?>>.generate(
      _maxStage + 1, (_) => List<List<int>?>.filled(_maxSlot + 1, null));
  final List<List<({int reRaw, int imRaw})?>> _boardPoints =
      List<List<({int reRaw, int imRaw})?>>.generate(_maxStage + 1,
          (_) => List<({int reRaw, int imRaw})?>.filled(_maxSlot + 1, null));
  final List<List<bool>> _boardDerived = List<List<bool>>.generate(
      _maxStage + 1, (_) => List<bool>.filled(_maxSlot + 1, false));

  // Monotonic per-stage token guarding the deferred, off-isolate encode of a
  // stage's forgetting-resistance share markers ([_encodeShareMarkers]). Any
  // change to the stage's shares — a re-placement, a deeper-stage re-root, or a
  // σ reset — bumps it so a late background result is discarded rather than
  // written over fresh state. Indexed `[stage]`.
  final List<int> _shareEncodeGen = List<int>.filled(_maxStage + 1, 0);

  /// Per-stage orbit point `o_i`. `o_0` is derived on the fly from σ (see
  /// [_stageOrbit]); `o_i` (`i≥1`) is the memory-hard advance `o_i = H*(K_{i-1})`,
  /// filled when the user advances forward (P5 deep stages). Null until derived.
  /// Coercion-relevant — wiped on any placement clear / dispose.
  final List<Uint8List?> _orbitO = List<Uint8List?>.filled(_maxStage + 1, null);

  /// Per-stage master secret `K_i = H(o_i ‖ Sh_i)`, recomputed by
  /// [_recomputeExtraShares] whenever stage `i` has `r_i` fractals placed (in any
  /// slots), and null otherwise. Coercion-relevant — wiped and nulled on any placement
  /// clear (and hence on dispose, via [_clearOrbitPlacements]). The board export
  /// (`K` / `Alt+K`) copies the active stage's `K_i` (optionally domain-separated
  /// by the export-salt label) through [_copyOrbitMaster].
  final List<Uint8List?> _orbitK = List<Uint8List?>.filled(_maxStage + 1, null);

  /// The active stage's master secret `K_i`, or null until `r_i` fractals are placed.
  Uint8List? get _activeK => _orbitK[_activeStage];

  /// The stage-0 slot whose point is being imported inline, or null. Reuses the
  /// legacy point-import editor ([_importEditorBody] / [_pointImport]) — one
  /// import surface, mutually exclusive with the chain import.
  int? _boardImportSlot;

  /// Canonical islands enumerated under the current view (the `E` reveal) on the
  /// active board's fractal — cleared on any slot / σ change.
  List<CanvasIsland> _boardIslands = const <CanvasIsland>[];

  /// The placed point's focus decoration (canonical island cells + bbox) per
  /// slot, cached until the point / σ changes. Drives the square frame and the
  /// cross↔square switch.
  final Map<int, _BoardDeco?> _boardDecoCache = <int, _BoardDeco?>{};

  /// Whether the active board's placed point is drawn as a **square** (frame +
  /// island cells) rather than a **cross**. Switches on the island's on-screen
  /// pixel span with a hysteresis band ([_kMarkerSquareEnterPx] /
  /// [_kMarkerSquareExitPx]) so it does not flicker at the threshold.
  bool _boardMarkerSquare = false;
  static const double _kMarkerSquareEnterPx = 64;
  static const double _kMarkerSquareExitPx = 40;

  /// Whether the board is currently showing the **canonical** view (island
  /// centred + zoomed + brightened) rather than the initial default view.
  /// Re-pressing the active slot's digit toggles between the two.
  bool _boardCanonicalView = false;

  /// Canonical-view zoom: the island's **smaller** edge targets this fraction of
  /// the shorter screen axis (zoom in to inspect)…
  static const double _kCanonicalSmallEdgeRatio = 0.4;

  /// …but never let the island's **larger** edge exceed this fraction, so an
  /// elongated island still fits fully on screen (overflow guard).
  static const double _kCanonicalLargeEdgeCap = 0.9;

  /// True at an orbit-board fractal slot (`#j≥1`). While building the orbit
  /// (pre-session) every stage's fractal slots are boards; during a legacy chain
  /// session only stage 0's are (deep session stages ride the chain canvas).
  bool get _isBoardSlot =>
      _slotIndex >= 1 && (!_hasSession || _activeStage == 0);

  /// True when the current board slot still takes a point — i.e. it is not a
  /// derived (auto-computed) share. All fractals at a stage are operationally
  /// equal: any slot may take a point until `r_i` are placed, after which the
  /// rest derive and lock. (The tab row fades slots beyond `r_i` as a "these are
  /// extras" hint, not a lock — the holder is free to use them.)
  bool get _placeableBoardSlot =>
      _isBoardSlot && !_boardDerived[_activeStage][_slotIndex];

  /// A confirmation awaiting an inline answer in the console (replaces modal
  /// dialogs). Resolved by the console's action buttons.
  _ConsolePrompt? _prompt;

  @override
  void initState() {
    super.initState();
    _setup.addListener(_onSetupChanged);
    // Drive the board's cross↔square switch as the view zooms (the screen does
    // not otherwise rebuild on pan/zoom).
    _viewport.addListener(_onBoardViewportChanged);
  }

  void _onSetupChanged() {
    if (!mounted) return;
    // Snap deep render back to fast when the view moves to a new stage — it is a
    // per-view escalation, not a sticky preference (mirrors the brightness
    // per-stage reset).
    if (_setup.displayStageIndex != _shownStage) {
      _shownStage = _setup.displayStageIndex;
      _deepRender = false;
      _editPointMode = false; // cancel an armed point edit if the view moved
      if (_pointImportStage != null) {
        _pointImport.clear();
        _pointImportStage = null;
      }
      // A moved view also dismisses an open expansion picker / import editor.
      _expandTarget = null;
      if (_expandImportTarget != null) {
        _pointImport.clear();
        _expandImportTarget = null;
      }
    }
    _updateEta();
    setState(() {});
  }

  // --- Derivation ETA estimate ------------------------------------------------
  // Timed off the controller's per-pass notifications: every point stage runs
  // the same N passes at ~the same cost, so a running average of completed-pass
  // durations projects both "this stage" and "to the last stage" honestly.

  final Stopwatch _passWatch = Stopwatch();
  int _etaStage = 0; // stage the watch is timing (0 = none)
  int _etaPass0 = 0; // argon2Done when the watch started
  int _etaLastDone = 0; // argon2Done at the last completed pass
  int _etaLastMs = 0; // watch elapsed at that pass (avg is over completed passes)

  /// Refresh the pass-timing watch from the controller's current state. Resets
  /// when the deriving stage changes; records a timestamp when a pass completes.
  void _updateEta() {
    final int? ds = _setup.derivingStageIndex;
    if (ds == null) {
      if (_passWatch.isRunning) _passWatch.stop();
      _passWatch.reset();
      _etaStage = 0;
      return;
    }
    if (ds != _etaStage) {
      _etaStage = ds;
      _etaPass0 = _setup.argon2Done;
      _etaLastDone = _setup.argon2Done;
      _etaLastMs = 0;
      _passWatch
        ..reset()
        ..start();
    } else if (_setup.argon2Done > _etaLastDone) {
      _etaLastDone = _setup.argon2Done;
      _etaLastMs = _passWatch.elapsedMilliseconds;
    }
  }

  /// Average completed-pass duration in ms, or null until a pass has completed
  /// since timing began ("estimating…").
  double? _avgPassMs() {
    final int passes = _etaLastDone - _etaPass0;
    if (passes <= 0 || _etaLastMs <= 0) return null;
    return _etaLastMs / passes;
  }

  /// Estimated time left on the deriving stage.
  Duration? _stageEta() {
    final double? avg = _avgPassMs();
    if (avg == null) return null;
    final int remaining =
        (_setup.argon2Total - _setup.argon2Done).clamp(0, _setup.argon2Total);
    return Duration(milliseconds: (remaining * avg).round());
  }

  /// Estimated time left until the batch's last stage finishes.
  Duration? _totalEta() {
    final double? avg = _avgPassMs();
    final Duration? stage = _stageEta();
    final int? ds = _setup.derivingStageIndex;
    if (avg == null || stage == null || ds == null) return null;
    final int last = _setup.nStages - 1;
    final int fullAfter = (last - ds).clamp(0, last);
    return stage +
        Duration(milliseconds: (fullAfter * _setup.argon2Total * avg).round());
  }

  /// Estimated time until stage [k] finishes (null if it is already done or
  /// not yet estimable).
  Duration? _etaToStage(int k) {
    final int? ds = _setup.derivingStageIndex;
    final double? avg = _avgPassMs();
    final Duration? stage = _stageEta();
    if (ds == null || avg == null || stage == null || k < ds) return null;
    final Duration fullStage =
        Duration(milliseconds: (_setup.argon2Total * avg).round());
    return stage + fullStage * (k - ds);
  }

  /// Compact duration: `4h 50m` / `33m 12s` / `45s`.
  String _fmtEta(Duration d) {
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  /// A stage tab's hover label: its name, plus its own ETA while deriving.
  String _tabTooltip(int i) {
    final String base = i == 0 ? 'Stage 0 — salt / pepper' : 'Stage $i';
    final Duration? eta = _etaToStage(i);
    return eta == null ? base : '$base — ETA ~${_fmtEta(eta)}';
  }

  /// One-line derivation status for the console, or null when nothing derives.
  String? _derivationStatus() {
    final int? ds = _setup.derivingStageIndex;
    if (ds == null) return null;
    final Duration? t = _totalEta();
    final String eta = t == null ? 'estimating…' : '~${_fmtEta(t)} left';
    final int last = _setup.nStages - 1;
    return 'Deriving Stage $ds/$last — pass ${_setup.argon2Done}/'
        '${_setup.argon2Total} · $eta';
  }

  /// The two-line derivation block for the expanded console: the live pass and
  /// the stage / batch ETAs.
  Widget _derivationBlock() {
    final int? ds = _setup.derivingStageIndex;
    final int last = _setup.nStages - 1;
    final Duration? s = _stageEta();
    final Duration? t = _totalEta();
    final String line2 = (s == null || t == null)
        ? 'estimating…'
        : '~${_fmtEta(s)} to this stage · ~${_fmtEta(t)} to Stage $last';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.hourglass_top, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Deriving Stage $ds/$last — pass ${_setup.argon2Done}/'
                '${_setup.argon2Total}',
                style: _termStyle.copyWith(
                    color: _kConsoleAccent, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Text(line2),
        ),
      ],
    );
  }

  @override
  void dispose() {
    // Release any awaiter blocked on an unanswered console prompt.
    if (_prompt != null && !_prompt!.completer.isCompleted) {
      _prompt!.completer.complete(false);
    }
    // Kill any in-flight Namtso harvest so it can't outlive the screen.
    _harvestSession?.cancel();
    // Drop any stage-0 orbit board reservoirs we pointed the shared render
    // source at, so no fractal state outlives this screen.
    widget.core.source.reservoirs = null;
    widget.core.leafSource.reservoirs = null;
    _boardReservoirs?.clear();
    // Wipe placed/derived board chunks (session-only point material).
    _clearOrbitPlacements();
    _sigmaCtrl.dispose();
    _explorerCtrl.dispose();
    _setup.removeListener(_onSetupChanged);
    _setup.dispose();
    _viewport.removeListener(_onBoardViewportChanged);
    _viewport.dispose();
    _brightness.dispose();
    _sounds.dispose();
    _iterationsField.dispose();
    _exportLabel.dispose();
    _mnemonic.dispose();
    _pointImport.dispose();
    _pointImportFocus.dispose();
    _vaultPath.dispose();
    _vaultPathFocus.dispose();
    _stage0.dispose();
    _hotkeys.dispose();
    _stage0Focus.dispose();
    _iterationsFocus.dispose();
    _stagesFocus.dispose();
    _profileFocus.dispose();
    _mnemonicFocus.dispose();
    _exportLabelFocus.dispose();
    _hueFocus.dispose();
    super.dispose();
  }

  bool get _busy =>
      _advancing ||
      _setup.phase == SetupPhase.encoding ||
      _setup.phase == SetupPhase.deriving;

  /// Whether in-app webcam QR scanning is available — only on the platforms
  /// `mobile_scanner` implements (Android / iOS / macOS). Linux/Windows hide the
  /// Scan button and fall back to typing the key.
  bool get _scanSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Whether the desktop (flutter_webrtc + zxing2) scan path applies — Linux and
  /// Windows, where `mobile_scanner` has no backend. Best-effort: the camera may
  /// fail to open on some setups, in which case the user falls back to hex-load.
  bool get _desktopScanSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// Whether a setup session is live (stages exist to navigate / focus): not the
  /// initial config screen, an error, or a finished/wiped session.
  bool get _hasSession =>
      _setup.phase == SetupPhase.encoding ||
      _setup.phase == SetupPhase.deriving ||
      _setup.phase == SetupPhase.memorise ||
      _setup.phase == SetupPhase.recallComplete;

  /// Move keyboard focus to an input field by its node. If the field is not on
  /// screen in the current mode (`context == null`), say so in the console
  /// instead of silently doing nothing.
  void _focusField(FocusNode node, String label) {
    if (node.context == null) {
      _toast('The $label field is not available in this mode.');
      return;
    }
    _sounds.play(UiSound.focus);
    node.requestFocus();
  }

  /// Global shortcuts that fire even while a text field has focus (text fields
  /// do not consume these keys, so they bubble up to here): Esc leaves a field
  /// for the viewer, F1 is the manual, and F2–F5 switch top-level mode.
  Map<ShortcutActivator, VoidCallback> get _globalShortcuts =>
      <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _focusViewer,
        const SingleActivator(LogicalKeyboardKey.f1): _toggleManual,
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            _gotoMode('Setup', here: true),
        const SingleActivator(LogicalKeyboardKey.f3): () =>
            _gotoMode('Train', here: false),
        const SingleActivator(LogicalKeyboardKey.f4): () =>
            _gotoMode('Accelerate', here: false),
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            _gotoMode('Inherit', here: false),
      };

  /// Switch top-level mode (F2 Setup · F3 Train · F4 Accelerate · F5 Inherit).
  /// Only Setup exists in this app today; the others announce themselves so the
  /// keys (and muscle memory) are correct from the start.
  void _gotoMode(String name, {required bool here}) {
    if (here) {
      _toast('$name (current mode).');
    } else {
      _sounds.play(UiSound.deny);
      _toast('$name mode is not available yet.');
    }
  }

  /// Return keyboard focus to the fractal viewer (and so out of any text field),
  /// re-enabling the single-key hotkeys. The non-directional counterpart to Tab.
  void _focusViewer() {
    // Esc also cancels an armed manual point edit and any open expansion picker
    // or import editor.
    if (_editPointMode) setState(() => _editPointMode = false);
    if (_boardImportSlot != null) {
      _pointImport.clear();
      setState(() => _boardImportSlot = null);
    }
    if (_expandTarget != null) setState(() => _expandTarget = null);
    if (_expandImportTarget != null) {
      _pointImport.clear();
      setState(() => _expandImportTarget = null);
    }
    if (_expandManualActive) _endManualExpand();
    _hotkeys.requestFocus();
  }

  /// Toggle the hotkey manual, restoring the console if it was minimized so the
  /// manual is actually visible. Bound to H and F1.
  void _toggleManual() {
    _sounds.play(UiSound.click);
    setState(() {
      _manualVisible = !_manualVisible;
      if (_manualVisible) _chromeMinimized = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool hasResult = _setup.phase == SetupPhase.memorise;
    return CallbackShortcuts(
      bindings: _globalShortcuts,
      child: Focus(
      focusNode: _hotkeys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  // Clicking anywhere on the canvas returns keyboard focus to the
                  // hotkey handler; the Listener is passive.
                  child: Listener(
                    onPointerDown: (_) => _hotkeys.requestFocus(),
                    child: Stack(
                      children: <Widget>[
                        // Slot #0 is the salt (Namtso σ at stage 0; retirement
                        // placeholder at stage i>0). Fractal slots (#j≥1) render
                        // the real orbit board θ_i_(j-1) whenever the board flow
                        // is active ([_isBoardSlot] — every stage pre-session,
                        // stage 0 during a legacy session); a legacy session's
                        // deep stages fall through to the chain canvas.
                        Positioned.fill(
                          child: _slotIndex == 0
                              ? _saltSlotPanel()
                              : (_isBoardSlot
                                  ? _orbitBoardPanel(_slotIndex)
                                  : (_setup.isTextStage
                                      ? _textStagePanel()
                                      : _canvas())),
                        ),
                        if (_busy) Positioned.fill(child: _progressOverlay()),
                        if (_selectMode && !_setup.isTextStage)
                          Positioned(
                            top: 56,
                            left: 12,
                            child: _Badge(_expandManualActive
                                ? 'Add stage — click your point'
                                : 'Recall — click your point'),
                          ),
                        if (_editPointMode && (!_setup.isTextStage || _isBoardSlot))
                          const Positioned(
                            top: 56,
                            left: 12,
                            child: _Badge('Click the new point · Esc to cancel'),
                          ),
                        // Deep render reminder: explains the lag while the high
                        // escape-count cap is active, and how to turn it off.
                        if (_deepRender && !_setup.isTextStage)
                          const Positioned(
                            top: 56,
                            right: 12,
                            child: _Badge('Deep render · Alt+L to exit'),
                          ),
                        // Stage tabs hover over the top of the viewer with a
                        // transparent background, so they never squeeze the
                        // canvas. Toggled independently of the console (key 9).
                        if (!_stageBarHidden)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            // Stage bar (Alt+digit) with the secondary slot bar
                            // (plain digit) stacked directly beneath it, plus the
                            // r_i control when a fractal slot is in focus.
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                _stageTabs(),
                                _slotTabs(),
                                if (_slotIndex >= 1) _riControl(),
                              ],
                            ),
                          ),
                        // The console always floats over the foot of the viewer
                        // (expanded or as a thin minimized bar) — it never takes
                        // a layout row, so the view is never squeezed.
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: _console(),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 260, child: _controlPanel(hasResult)),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// The upper-edge stage tabs: a **fixed** bar of five numbered tabs (0..4,
  /// the protocol ceiling) spanning the fractal-view width. Stage 0 is the
  /// salt/pepper text; 1..N-1 are the chain-derived fractals. The stage under
  /// focus is highlighted; tabs that are not currently reachable — outside this
  /// setup's stage count, not yet derived, or before any session — stay visible
  /// but greyed out and inert. Tapping a reachable tab focuses it (the same as
  /// pressing its number key).
  /// Select a **secondary slot** within the active stage (the lower tab row).
  /// Out-of-range digits give the usual blocked cue. Content per slot is wired
  /// in later phases; for now this just moves the selection.
  void _selectSlot(int i) {
    if (i < 0 || i > _maxSlot) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    if (i == _slotIndex) {
      // Re-pressing the active board slot toggles between the initial default
      // view and the canonical view (island centred, zoomed, brightened).
      if (_isBoardSlot) _toggleBoardView();
      return;
    }
    if (_boardImportSlot != null) _pointImport.clear();
    _sounds.play(UiSound.navStage);
    setState(() {
      _slotIndex = i;
      // Any point entry armed for the previous slot no longer applies, and the
      // revealed islands belonged to the previous board's fractal.
      _editPointMode = false;
      _boardImportSlot = null;
      _boardIslands = const <CanvasIsland>[];
      _boardCanonicalView = false; // arriving on a board starts at the default view
    });
    // Landing on a board resets the view, so each fractal opens centred at the
    // default zoom/brightness (the same recenter stage selection performs).
    if (_isBoardSlot) _recenter();
  }

  /// The **secondary slot tabs** — a fixed row of seven numbered tabs (`0..6`)
  /// directly beneath the stage bar. Slot `#0` is the salt; `#j≥1` are the
  /// fractals. Reuses [_StageTab] so it shares the stage bar's stable layout;
  /// per-slot content lands in P2+ (this row is navigation only for now).
  Widget _slotTabs() {
    final int r = _requiredFractals[_activeStage];
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i <= _maxSlot; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _StageTab(
                      index: i,
                      inSetup: true,
                      selected: i == _slotIndex,
                      // Every fractal at a stage is operationally equal — any
                      // slot may take a point until r_i are placed, after which
                      // the rest derive. The fade on slots beyond r_i is a hint
                      // ("r_i is the minimum; these are extras"), not a lock:
                      // salt (#0) + the first r_i are lit, the rest faded, all
                      // navigable and all placeable.
                      available: i == 0 || i <= r,
                      deriving: false,
                      progress: 0,
                      tooltip: i == 0
                          ? 'Slot 0 — salt (σ / retirement)'
                          : i <= r
                              ? 'Slot $i — fractal (rᵢ=$r is the minimum)'
                              : 'Slot $i — fractal (beyond rᵢ=$r — equally usable)',
                      onTap: () => _selectSlot(i),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact `r_i` control for the active stage: the **minimum** number of
  /// fractals to place, `2` or `3`. Grayed and fixed at `2` for stage 0
  /// (σ-public entry); a `{2,3}` slider for deep stages (2 = substandard 64-bit,
  /// 3 = standard 96-bit). The holder places any `r_i` of the `s_i` fractals;
  /// the rest derive as forgetting-forgiveness shares. The exact per-stage
  /// optionality will ultimately come from the engine's tier rules (open item);
  /// for now only stage 0 is fixed.
  Widget _riControl() {
    final ThemeData theme = Theme.of(context);
    final int stage = _activeStage;
    final int r = _requiredFractals[stage];
    final bool fixed = stage == 0; // r_0 = 2 by design
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: <Widget>[
            Text('rᵢ = $r', style: theme.textTheme.labelMedium),
            Expanded(
              child: Slider(
                value: r.toDouble(),
                min: 2,
                max: 3,
                divisions: 1,
                label: '$r',
                onChanged: fixed
                    ? null
                    : (double v) {
                        final int nv = v.round();
                        if (nv != _requiredFractals[stage]) {
                          setState(() {
                            _requiredFractals[stage] = nv;
                            // r_i is the live threshold over equal slots, so a
                            // change re-settles the stage: raising it un-settles
                            // (K_i clears until another point is placed), lowering
                            // it re-derives the now-extra slots. Either way Sh_i
                            // (hence K_i) changes, which re-roots deeper stages.
                            _recomputeExtraShares(stage);
                            _invalidateDeeperThan(stage);
                            _boardDecoCache.clear();
                            _boardCanonicalView = false;
                          });
                        }
                      },
              ),
            ),
            Text(
              fixed
                  ? 'fixed (stage 0)'
                  : r == 2
                      ? 'substandard · 64-bit'
                      : 'standard · 96-bit',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }

  // --- salt slot (`#0`) content ---------------------------------------------

  /// The salt slot's panel: Namtso σ harvest at stage 0, or the (future)
  /// stage-retirement placeholder at stage `i>0`.
  Widget _saltSlotPanel() {
    final int stage = _activeStage;
    return stage > 0 ? _retirementPlaceholder(stage) : _namtsoSaltPanel();
  }

  /// Pick a date and harvest σ from the Namtso CLI (desktop); fills the σ field.
  /// Ported from the orbit setup screen. Cancellable and timeout-bounded.
  Future<void> _harvestFromDate() async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _harvestedDate ?? today,
      firstDate: DateTime(2009, 1, 3), // Bitcoin genesis
      lastDate: today,
      helpText: 'Harvest σ from the timechain at a date',
    );
    if (picked == null) return;
    setState(() {
      _harvesting = true;
      _harvestNote = null;
    });
    final HarvestSession session = const NamtsoHarvester()
        .start(date: picked, explorer: _explorerCtrl.text.trim());
    _harvestSession = session;
    try {
      final String sigma = await session.result;
      if (!mounted) return;
      setState(() {
        _sigmaCtrl.text = sigma;
        _harvestedDate = picked;
        _harvestNote = 'σ harvested for ${_isoDate(picked)} '
            '(${sigma.length ~/ 2} bytes).';
      });
    } on NamtsoCancelled {
      if (mounted) setState(() => _harvestNote = 'Harvest cancelled.');
    } on NamtsoUnavailable catch (e) {
      if (mounted) {
        setState(() => _harvestNote = 'Namtso unavailable: ${e.message} — '
            'build it with app/native/build_namtso.sh, or paste σ below.');
      }
    } on NamtsoError catch (e) {
      if (mounted) setState(() => _harvestNote = e.message);
    } finally {
      _harvestSession = null;
      if (mounted) setState(() => _harvesting = false);
    }
  }

  void _cancelHarvest() => _harvestSession?.cancel();

  static String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Stage-0 salt slot: the Namtso σ harvest. σ → the orbit root `o₀`; the actual
  /// derivation wiring lands with the orbit protocol step (P5).
  Widget _namtsoSaltPanel() {
    final ThemeData theme = Theme.of(context);
    final String sigma = _sigmaCtrl.text.trim();
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.calendar_month, size: 32),
                const SizedBox(width: 12),
                Text('Stage 0 · slot 0 — salt (σ)',
                    style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The Namtso salt: a memorable date → σ (1024 bits derived from '
              'Bitcoin block headers) → the orbit root o₀. σ is public; its job '
              'is to rule out precomputation, not secrecy.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            if (NamtsoHarvester.isSupported)
              Row(
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: _harvesting ? null : _harvestFromDate,
                    icon: const Icon(Icons.calendar_month),
                    label: const Text('Harvest from date'),
                  ),
                  const SizedBox(width: 12),
                  if (_harvesting) ...<Widget>[
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text('Fetching headers…', style: theme.textTheme.bodySmall),
                    const SizedBox(width: 12),
                    TextButton(
                        onPressed: _cancelHarvest,
                        child: const Text('Cancel')),
                  ],
                ],
              )
            else
              Text('Namtso harvesting needs a desktop platform; paste σ below.',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: _explorerCtrl,
              enabled: !_harvesting,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                labelText: 'Esplora URLs (advanced, optional)',
                hintText: 'https://esplora.example/api, … — blank = defaults',
              ),
            ),
            if (_harvestNote != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_harvestNote!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Text('σ (hex)', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            TextField(
              controller: _sigmaCtrl,
              maxLines: 2,
              style: theme.textTheme.bodySmall,
              // A new σ re-roots every board, so any placed/derived points no
              // longer decode — drop them.
              onChanged: (_) => setState(_clearOrbitPlacements),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'harvest a date, or paste σ hex',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sigma.isEmpty
                  ? 'No σ yet.'
                  : 'σ set (${sigma.length ~/ 2} bytes) → orbit root o₀. The '
                      'fractal slots (1..) now render this stage’s boards θ₀,ⱼ; '
                      'point placement + Kᵢ completion land in the next P5 step.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }

  /// Stage `i>0` salt slot: the future retirement feature (bury `o_i` on-chain
  /// to retire the stages below). Disabled placeholder for now.
  Widget _retirementPlaceholder(int stage) {
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.lock_clock, size: 40, color: theme.disabledColor),
              const SizedBox(height: 12),
              Text('Stage $stage · slot 0 — retirement',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Retire the stages below this one by burying o_$stage on-chain '
                '(burial date + identifier as the substitute salt) — a future, '
                'irreversible action. Coming soon.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stageTabs() {
    const int maxTab = SetupController.maxPointStages; // 0..4 → five fixed tabs
    final bool session = _hasSession;
    // Orbit build (pre-session): the cursor is [_orbitStage]; a stage is
    // reachable up to the derived ceiling, and the next stage is tappable to
    // advance into it.
    final int ceiling = session ? 0 : _orbitReachableCeiling;
    final int current = session ? _setup.displayStageIndex : _orbitStage;
    // A legacy chain session reads its derivation state off the controller; an
    // orbit advance is screen-owned, so the stage bar takes it from
    // [_advanceTarget] / [_advanceProgress]. Only one can be live at a time.
    final int? deriving = _advanceTarget ?? _setup.derivingStageIndex;
    final double progress =
        _advanceTarget != null ? _advanceProgress : _setup.stageProgress;
    // Transparent so the tabs hover over the fractal (no opaque bar).
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i <= maxTab; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _StageTab(
                      index: i,
                      // In the (possibly slider-previewed) setup, so it shows as
                      // a real box rather than an out-of-setup ghost slot. In the
                      // orbit build the derived stages plus the next (advanceable)
                      // one are the setup so far.
                      inSetup:
                          session ? i < _setup.nStages : i <= ceiling + 1,
                      selected: i == current,
                      available: session
                          ? _setup.isStageAvailable(i)
                          : i <= ceiling,
                      deriving: deriving == i,
                      progress: progress,
                      tooltip: _tabTooltip(i),
                      // Tappable for a stage in the active setup; a ghost slot
                      // beyond it is tappable too when the setup can grow, to
                      // start an expansion up to that slot. In the orbit build the
                      // reachable stages and the next (advanceable) one are
                      // tappable via [_selectStage] → [_selectOrbitStage].
                      onTap: session
                          ? ((i < _setup.nStages)
                              ? () => _selectStage(i)
                              : (_setup.canExpand &&
                                      i >= _setup.nStages &&
                                      i <= SetupController.maxPointStages)
                                  ? () => _beginExpand(i)
                                  : null)
                          : (i <= ceiling + 1 ? () => _selectStage(i) : null),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // While a text field (salt, seed phrase, …) holds focus, let it consume the
    // keystroke — never fire canvas shortcuts. Press Esc to leave the field and
    // return to the viewer (handled globally below).
    if (_textInputHasFocus) return KeyEventResult.ignored;
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    // V + ↑/↓ — sound volume. A held-key chord (not a Scheme-A single key), so
    // it is handled before the key-down-only guard below and may auto-repeat
    // while the arrow is held, ramping the level. Level 0 is silence == muted.
    if (kb.isLogicalKeyPressed(LogicalKeyboardKey.keyV)) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _changeVolume(up: true);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _changeVolume(up: false);
        return KeyEventResult.handled;
      }
    }
    // Scheme A: all hotkeys are single, unmodified keys, active when the viewer
    // (not a text field) has focus, fired once per press. If a modifier is held,
    // bail so OS combos are left alone.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Alt hotkeys — exceptional actions that take Alt by design; handled before
    // the modifier bail just below. Each is the rare/advanced counterpart of a
    // plain key: Alt+L deep render (vs the fast default), Alt+K the full export
    // digest (vs K's conventional first 32 chars).
    if (kb.isAltPressed && !kb.isControlPressed && !kb.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyL) {
        _toggleDeepRender();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyK) {
        if (!_busy) _copyMasterSecret(full: true);
        return KeyEventResult.handled;
      }
      // Alt+I — the hex counterpart of plain I (BIP39 words): on an editable
      // point (a chain stage or an orbit board slot) it opens the point-import
      // editor in hex.
      if (event.logicalKey == LogicalKeyboardKey.keyI) {
        if (_expandTarget != null) {
          _expandImport(hex: true);
        } else if (_placeableBoardSlot) {
          _beginBoardImport(_slotIndex, hex: true);
        } else if (_setup.canEditCurrentPoint) {
          _changePointImport(hex: true);
        }
        return KeyEventResult.handled;
      }
      // Alt+V — reveal / hide the obscured sensitive text fields together (the
      // visibility counterpart of V's volume control).
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        _toggleSensitiveVisibility();
        return KeyEventResult.handled;
      }
      // Alt+D — open the spacious Argon2 calibration dialog (vs plain D, which
      // focuses the raw derivation-steps field).
      if (event.logicalKey == LogicalKeyboardKey.keyD) {
        _openCalibrationDialog();
        return KeyEventResult.handled;
      }
      // Alt+digit — select that **stage** (the upper/main tabs). Stage selection
      // moved to Alt so plain digits can drive the secondary slot tabs.
      final int? altStage = _digitKeys[event.logicalKey];
      if (altStage != null) {
        _selectStage(altStage);
        return KeyEventResult.handled;
      }
    }
    if (kb.isAltPressed || kb.isControlPressed || kb.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // H — halt an in-progress derivation, behind a console confirmation (keeps
    // the work done so far). The hotkey manual lives on F1 only now.
    if (event.logicalKey == LogicalKeyboardKey.keyH) {
      _abortDerivation();
      return KeyEventResult.handled;
    }
    // M — collapse / restore the console (independent of the stage bar).
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      final bool minimizing = !_chromeMinimized;
      _sounds.play(minimizing ? UiSound.chromeDown : UiSound.chromeUp);
      setState(() => _chromeMinimized = minimizing);
      return KeyEventResult.handled;
    }
    // 9 — show / hide the stage-tab bar (independent of the console).
    if (event.logicalKey == LogicalKeyboardKey.digit9 ||
        event.logicalKey == LogicalKeyboardKey.numpad9) {
      final bool hiding = !_stageBarHidden;
      _sounds.play(hiding ? UiSound.chromeDown : UiSound.chromeUp);
      setState(() => _stageBarHidden = hiding);
      return KeyEventResult.handled;
    }
    // X — exclude the displayed stage and every stage above it (truncate). In
    // the orbit build this drops the current orbit stage and every deeper one.
    if (event.logicalKey == LogicalKeyboardKey.keyX) {
      if (_hasSession) {
        _truncate();
      } else {
        _truncateOrbit();
      }
      return KeyEventResult.handled;
    }
    // E — enumerate the canonical leaf areas under the current view and
    // highlight each one's canonical island (flat white). Heavy one-shot
    // (memoized decode grid + per-leaf discovery); no-op while a derivation is
    // busy.
    if (event.logicalKey == LogicalKeyboardKey.keyE) {
      if (!_busy) {
        unawaited(_isBoardSlot ? _boardEnumerateIslands() : _enumerateIslands());
      }
      return KeyEventResult.handled;
    }
    // C — focus the colour wheel (then ← → cycle hues).
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _focusField(_hueFocus, 'colour wheel');
      return KeyEventResult.handled;
    }
    // N / I / R — on an editable point (a chain stage or an orbit board slot)
    // they change that point: N = new random, R = manual click, I = blind
    // import (which shares the inline bit editor).
    if (event.logicalKey == LogicalKeyboardKey.keyN) {
      if (_expandTarget != null) {
        _expandNew();
      } else if (_placeableBoardSlot) {
        _generatePrimary(_slotIndex);
      } else if (_setup.canEditCurrentPoint) {
        _changePointGenerated();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyI) {
      if (_expandTarget != null) {
        _expandImport(hex: false);
      } else if (_placeableBoardSlot) {
        _beginBoardImport(_slotIndex, hex: false);
      } else if (_setup.canEditCurrentPoint) {
        _changePointImport(hex: false);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyR) {
      if (_expandTarget != null) {
        _expandManual();
        return KeyEventResult.handled;
      }
      // At a placeable orbit board slot (any non-derived fractal), R arms a
      // manual point placement (the same click-to-place mechanism as a chain
      // point edit).
      if (_placeableBoardSlot) {
        _armBoardManual();
      } else if (_setup.canEditCurrentPoint) {
        _changePointManual();
      }
      return KeyEventResult.handled;
    }
    // Field focus (uniform coverage): S salt/export · P profile · D derivation
    // steps. The salt (config screen) and export-label (live setup) fields never
    // coexist, so pick by session state rather than a focus node's context
    // (which could be stale): a live setup means the export label.
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      // The export-salt field is shown either in a live setup or on a stage-0
      // board once K_i is derived; the config-screen salt/pepper otherwise.
      if (_hasSession || (_isBoardSlot && _activeK != null)) {
        _focusField(_exportLabelFocus, 'export salt');
      } else {
        _focusField(_stage0Focus, 'salt / pepper');
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyP) {
      _focusField(_profileFocus, 'Argon2 profile');
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyD) {
      _focusField(_iterationsFocus, 'derivation steps');
      return KeyEventResult.handled;
    }
    // (A is currently unbound — freed from its old "abort" duty, now on H.)
    // Z — reset, behind a console confirmation so a stray keypress cannot wipe a
    // setup.
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      _confirmReset();
      return KeyEventResult.handled;
    }
    // K — derive and copy the exported master secret ("the key") for the stage
    // under focus.
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      if (!_busy) _copyMasterSecret();
      return KeyEventResult.handled;
    }
    // Provisional-key panel (when shown): F focus file path · W write/save ·
    // O open setup file · T blank template. W/O/T no-op while a vault pass runs.
    if (_vaultPanelShown) {
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        _focusVaultPath();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyW) {
        if (!_vaultBusy) _writeSetup();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyO) {
        if (!_vaultBusy) _openSetup();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyT) {
        if (!_vaultBusy) _exportBlankTemplate();
        return KeyEventResult.handled;
      }
    }
    // 0–6 — select that **secondary slot** within the active stage. (Stage
    // selection is Alt+digit; the `9` bar toggle is handled above.)
    final int? digit = _digitKeys[event.logicalKey];
    if (digit != null) {
      _selectSlot(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Alt+V — reveal or hide the obscured sensitive text fields (the salt/pepper
  /// and the import phrase/hex) together: if any is hidden, reveal all; if all
  /// are shown, hide all. The counterpart of V's volume control.
  void _toggleSensitiveVisibility() {
    final bool reveal = _stage0Hidden || _mnemonicHidden;
    _sounds.play(UiSound.click);
    setState(() {
      _stage0Hidden = !reveal;
      _mnemonicHidden = !reveal;
    });
    _toast(reveal ? 'Sensitive text revealed.' : 'Sensitive text hidden.');
  }

  /// Step the UI sound-cue volume one level (bound to `V` + ↑/↓). Plays a cue at
  /// the new level as feedback — silent at level 0, which *is* the cue that the
  /// app is now muted — and notes the level in the console.
  void _changeVolume({required bool up}) {
    final int level = up ? _sounds.volumeUp() : _sounds.volumeDown();
    _sounds.play(up ? UiSound.adjustUp : UiSound.adjustDown);
    _toast(level == 0 ? 'Volume muted.' : 'Volume $level/$kMaxVolumeLevel.');
  }

  /// Current render escape-count cap: the fast default, or the engine's encode
  /// cap when deep render (Alt+L) is on.
  int get _renderMaxIter => _deepRender
      ? widget.core.encodeParams.maxIter
      : EncodingConstants.renderMaxIterFast;

  /// Toggle deep render mode (Alt+L). Raises/lowers the canvas escape-count cap
  /// so the rendered boundary matches the encoder in high escape-count voids;
  /// laggy while on (see the on-canvas marker).
  void _toggleDeepRender() {
    setState(() => _deepRender = !_deepRender);
    _sounds.play(_deepRender ? UiSound.modeOn : UiSound.modeOff);
    _toast(_deepRender
        ? 'Deep render ON — ${widget.core.encodeParams.maxIter} iterations '
            '(slower in voids).'
        : 'Deep render off — ${EncodingConstants.renderMaxIterFast} iterations.');
  }

  /// Select stage [index]: focus it if it is already available (Stage 0, or a
  /// fractal already derived), or — if it is the first not-yet-derived stage —
  /// trigger that stage's derivation. Anything else (out of range, or a gap
  /// beyond the next stage) sounds a deny cue and explains why.
  void _selectStage(int index) {
    if (_busy) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    // Building the orbit (no legacy session): the screen owns the stage cursor.
    if (!_hasSession) {
      _selectOrbitStage(index);
      return;
    }
    if (index == _setup.displayStageIndex) {
      // Re-selecting the current stage zooms to its point (if any).
      _focusPoint(index);
      return;
    }
    if (index < 0 || index >= _setup.nStages) {
      // A ghost slot beyond the setup starts an expansion up to it (if the setup
      // can grow); anything else is out of range.
      if (index >= _setup.nStages &&
          index <= SetupController.maxPointStages &&
          _setup.canExpand) {
        _beginExpand(index);
        return;
      }
      _sounds.play(UiSound.denyBlocked);
      _toast('This setup has ${_setup.nStages - 1} stage'
          '${_setup.nStages - 1 == 1 ? '' : 's'} (0–${_setup.nStages - 1}).');
      return;
    }
    // Already derived (or the Stage-0 text) — focus it and recenter the view.
    if (_setup.isStageAvailable(index)) {
      _sounds.play(UiSound.navStage);
      _setup.showStage(index);
      _recenter();
      return;
    }
    // Not derived yet because generation is still running in the background —
    // it will open on its own when ready.
    if (_setup.isGenerating) {
      _sounds.play(UiSound.denyPending);
      _toast('Stage $index is still deriving — it will open when ready.');
      return;
    }
    // Not derived. Only the very next stage can be derived, and only once the
    // previous stage carries a selected point.
    if (index != _setup.firstUnderivedStage) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Recall the earlier stages first.');
      return;
    }
    if (!_setup.hasSelectedPoint(index - 1)) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Select your point on Stage ${index - 1} first.');
      return;
    }
    _deriveNextStage();
  }

  /// Derive the next stage's fractal (the explicit chain-advance step). Shows the
  /// progress overlay while the Argon2 pass runs, then lands on the new fractal.
  Future<void> _deriveNextStage() async {
    final DeriveOutcome outcome = await _setup.deriveNextStage(
      argon2Iterations: _iterations,
      profile: _profile,
    );
    if (!mounted) return;
    switch (outcome) {
      case DeriveOutcome.derived:
        _sounds.play(UiSound.stageReady);
        _recenter(); // land centred on the fresh fractal
        _toast('Stage ${_setup.displayStageIndex} derived — recall your point.');
      case DeriveOutcome.noPriorPoint:
        _sounds.play(UiSound.denyBlocked);
        _toast('Select your point on the previous stage first.');
      case DeriveOutcome.none:
      case DeriveOutcome.busy:
        break;
    }
  }

  /// Highest **derived** orbit stage: stage 0 plus the contiguous run of deep
  /// stages whose `o_i` the forward advance has already produced. The next stage
  /// (`+1`) is the one a forward navigation would advance into.
  int get _orbitReachableCeiling {
    int c = 0;
    for (int i = 1; i <= _maxStage; i++) {
      if (_orbitO[i] != null) {
        c = i;
      } else {
        break;
      }
    }
    return c;
  }

  /// Navigate the orbit stage cursor (pre-session). Stage 0 is always reachable
  /// (rooted by σ); a deep stage is reachable once its `o_i` has been produced by
  /// the forward advance. Forward navigation into the next, not-yet-derived stage
  /// triggers that memory-hard advance ([_advanceOrbitInto]).
  void _selectOrbitStage(int index) {
    if (index < 0 || index > _maxStage) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    if (index == _orbitStage) {
      // Re-selecting the current stage recenters its board view.
      _recenter();
      return;
    }
    // Backward, or into an already-derived deep stage: just move the cursor.
    if (index < _orbitStage || _stageOrbit(index) != null) {
      _sounds.play(UiSound.navStage);
      _setOrbitStage(index);
      return;
    }
    // Forward into the immediate next stage: run the memory-hard advance
    // o_{index} = H*(K_{index-1}) from the (now complete) preceding stage.
    if (index == _orbitReachableCeiling + 1) {
      unawaited(_advanceOrbitInto(index));
      return;
    }
    _sounds.play(UiSound.denyBlocked);
    _toast('Reach the earlier stages first.');
  }

  /// Serialize stage [stage]'s Shamir polynomial `Sh_i` by re-interpolating it
  /// from the `r_i` points the holder placed — in whichever slots they chose,
  /// each at abscissa = slot index — or null if fewer than `r_i` are placed.
  /// This mirrors [_recomputeExtraShares]'s `chosen` set exactly, so `Sh_i` (and
  /// thus `K_i` and the advance) is identical however it is recomputed. `Sh_i`
  /// is coercion-relevant, so the interim coefficients are wiped before
  /// returning; the caller owns (and wipes) the returned bytes.
  Uint8List? _stageShBytes(int stage) {
    final int r = _requiredFractals[stage];
    final List<int> placed = <int>[];
    for (int s = 1; s <= _maxSlot; s++) {
      if (_boardChunks[stage][s] != null && !_boardDerived[stage][s]) {
        placed.add(s);
      }
    }
    if (placed.length < r) return null; // not enough points placed yet
    final List<int> chosen = placed.length > r ? placed.sublist(0, r) : placed;
    final List<int> xs = <int>[for (final int s in chosen) s];
    final List<int> ys = <int>[
      for (final int s in chosen) OrbitProtocol.bitsToU32(_boardChunks[stage][s]!),
    ];
    final List<int> sh = widget.core.shamirInterp(xs, ys);
    final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
    for (int i = 0; i < sh.length; i++) {
      sh[i] = 0; // wipe the interim polynomial
    }
    return shBytes;
  }

  /// Advance the orbit forward into stage [target]: run the memory-hard step
  /// `o_target = H*(K_{target-1})` (via [GreatWallCore.startOrbitAdvance] in a
  /// worker isolate, at the current `P`/`D` profile + derivation steps),
  /// streaming each completed pass to the stage bar and letting Halt cancel it;
  /// on success, store `o_target` and land on it. The preceding stage must be
  /// complete
  /// (`K_{target-1}` derived); otherwise this reports what is missing. Re-placing
  /// a point in an earlier stage cascade-invalidates the deeper `o_i`/`K_i` (see
  /// [_setPrimary]), so a forward advance always rebuilds from a settled prefix.
  Future<void> _advanceOrbitInto(int target) async {
    final int from = target - 1;
    final Uint8List? oFrom = _stageOrbit(from);
    if (oFrom == null || _orbitK[from] == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Place stage $from’s ${_requiredFractals[from]} required points '
          'first.');
      return;
    }
    final Uint8List? shBytes = _stageShBytes(from);
    if (shBytes == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Place stage $from’s ${_requiredFractals[from]} required points '
          'first.');
      return;
    }
    // D (`_iterations`) is the number of memory-hard passes per advance. D == 0
    // is the instant pass-through (o_{i+1} = K_i, non-memory-hard) — a dev/test
    // convenience, so it skips the "advancing" scrim; D >= 1 shows it.
    final int steps = _iterations;
    final bool memoryHard = steps >= 1;
    if (memoryHard) {
      setState(() {
        _advancing = true;
        _advanceTarget = target;
        _advanceDone = 0;
        _advanceTotal = steps;
      });
    }
    _sounds.play(UiSound.focus);
    ({Uint8List k, Uint8List next})? adv;
    bool cancelled = false;
    try {
      // Streamed rather than one opaque call, so each completed pass moves the
      // stage bar and Halt can stop it. `oFrom` is NOT wiped here — for stage 0
      // it is a fresh derivation from σ, but for a deep stage it *is*
      // `_orbitO[from]`, which the setup still needs.
      final OrbitAdvanceJob job = await widget.core.startOrbitAdvance(
        oFrom,
        shBytes,
        steps: steps,
        profile: _profile,
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _advanceDone = done;
            _advanceTotal = total;
          });
        },
        onCheckpoint: (int done, Uint8List digest) {
          // Keep the latest intermediary so a halt costs at most this pass. The
          // callback's buffer is wiped by the facade once it returns, so copy.
          final ({int stage, int pass, Uint8List digest})? old =
              _advanceCheckpoint;
          if (old != null) Entropy.wipe(old.digest);
          _advanceCheckpoint = (
            stage: target,
            pass: done,
            digest: Uint8List.fromList(digest),
          );
        },
      );
      _advanceJob = job;
      adv = await job.result;
    } on Argon2Cancelled {
      cancelled = true;
    } catch (_) {
      adv = null;
    } finally {
      Entropy.wipe(shBytes);
      _advanceJob = null;
      if (memoryHard && mounted) {
        setState(() {
          _advancing = false;
          _advanceTarget = null;
          _advanceDone = 0;
          _advanceTotal = 0;
        });
      }
    }
    if (!mounted) return;
    if (cancelled) {
      // The checkpoint survives the halt — that is the whole point of it.
      final int done = _advanceCheckpoint?.pass ?? 0;
      _sounds.play(UiSound.navStage);
      setState(() {});
      _toast(done > 0
          ? 'Advance halted after $done/$steps passes — kept. Save to keep it '
              'across sessions, or Resume to continue.'
          : 'Advance halted before the first pass finished — nothing to keep.');
      return;
    }
    if (adv == null) {
      _sounds.play(UiSound.warn);
      _toast('Orbit advance failed — try again.');
      return;
    }
    // adv.k == K_{from}; adv.next == o_{target}. Keep only o_target; the K copy
    // is redundant with _orbitK[from] and is wiped.
    Entropy.wipe(adv.k);
    final Uint8List? oldNext = _orbitO[target];
    if (oldNext != null) Entropy.wipe(oldNext);
    _orbitO[target] = adv.next;
    _clearAdvanceCheckpoint(); // the advance landed; the checkpoint is spent
    _setOrbitStage(target);
    _sounds.play(UiSound.stageReady);
    _toast('Advanced to stage $target — place its points.');
  }

  /// Continue a halted advance from its preserved checkpoint, running only the
  /// passes that remain. The orbit peer of [_resumeDerivation].
  ///
  /// `K_{stage-1}` is not stored anywhere — it is read back from [_orbitK],
  /// which the setup recomputes from the stage's placed points on restore. So a
  /// resume after reopening a file needs nothing from the file but the digest
  /// and the pass count.
  Future<void> _resumeOrbitAdvance() async {
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    if (cp == null || !_canResumeAdvance) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Nothing to resume.');
      return;
    }
    final int target = cp.stage;
    final Uint8List? k = _orbitK[target - 1];
    if (k == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Place stage ${target - 1}’s points first.');
      return;
    }
    final int steps = _iterations;
    setState(() {
      _advancing = true;
      _advanceTarget = target;
      _advanceDone = cp.pass;
      _advanceTotal = steps;
    });
    _sounds.play(UiSound.focus);
    ({Uint8List k, Uint8List next})? adv;
    bool cancelled = false;
    try {
      final OrbitAdvanceJob job = await widget.core.resumeOrbitAdvance(
        k,
        cp.digest,
        fromPass: cp.pass,
        steps: steps,
        profile: _profile,
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _advanceDone = done;
            _advanceTotal = total;
          });
        },
        onCheckpoint: (int done, Uint8List digest) {
          final ({int stage, int pass, Uint8List digest})? old =
              _advanceCheckpoint;
          if (old != null) Entropy.wipe(old.digest);
          _advanceCheckpoint = (
            stage: target,
            pass: done,
            digest: Uint8List.fromList(digest),
          );
        },
      );
      _advanceJob = job;
      adv = await job.result;
    } on Argon2Cancelled {
      cancelled = true;
    } catch (_) {
      adv = null;
    } finally {
      _advanceJob = null;
      if (mounted) {
        setState(() {
          _advancing = false;
          _advanceTarget = null;
          _advanceDone = 0;
          _advanceTotal = 0;
        });
      }
    }
    if (!mounted) return;
    if (cancelled) {
      final int done = _advanceCheckpoint?.pass ?? 0;
      _sounds.play(UiSound.navStage);
      setState(() {});
      _toast('Advance halted again after $done/$steps passes — kept.');
      return;
    }
    if (adv == null) {
      _sounds.play(UiSound.warn);
      _toast('Orbit advance failed — try again.');
      return;
    }
    Entropy.wipe(adv.k);
    final Uint8List? oldNext = _orbitO[target];
    if (oldNext != null) Entropy.wipe(oldNext);
    _orbitO[target] = adv.next;
    _clearAdvanceCheckpoint();
    _setOrbitStage(target);
    _sounds.play(UiSound.stageReady);
    _toast('Advanced to stage $target — place its points.');
  }

  /// Move the orbit cursor to [index] and reset the per-board transient state so
  /// the new stage's board opens clean (default view, no armed edit / import /
  /// island reveal, fresh render + decoration caches).
  void _setOrbitStage(int index) {
    setState(() {
      _orbitStage = index;
      _editPointMode = false;
      _boardImportSlot = null;
      _boardIslands = const <CanvasIsland>[];
      _boardDecoCache.clear();
      _boardCanonicalView = false;
      _boardKey = ''; // force the render cache to rebuild for the new stage
    });
    _recenter();
  }

  /// Whether the keyboard focus is currently inside an editable text field, so
  /// typed characters must not be interpreted as canvas shortcuts. Checks the
  /// active focus rather than specific fields, so any future input is covered.
  bool get _textInputHasFocus {
    final BuildContext? c = FocusManager.instance.primaryFocus?.context;
    if (c == null) return false;
    if (c.widget is EditableText) return true;
    return c.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Soft-coded target: a focused point's leaf should occupy this fraction of
  /// the view's (shorter-axis) span — half by default.
  static const double _kFocusLeafRatio = 0.5;

  /// Recenter the canvas to the default position/zoom and reset brightness,
  /// without touching the session. Triggered automatically on arriving at a
  /// stage (the old `R` behaviour, now folded into stage selection).
  void _recenter() {
    _viewport.viewport = _initialViewport;
    _brightness.reset();
    setState(() {});
  }

  /// Zoom-to-fit the point of [index] ("focus"): centre on its coordinates and
  /// set the zoom so the leaf's largest dimension is [_kFocusLeafRatio] of the
  /// view's shorter-axis span. No-op (deny) if that stage has no point.
  void _focusPoint(int index) {
    final ({double re, double im, double leafW, double leafH})? t =
        _setup.focusTargetAt(index);
    if (t == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('No point on Stage $index to focus yet.');
      return;
    }
    final double leafMax = math.max(t.leafW, t.leafH);
    final FractalViewport cur = _viewport.viewport;
    // half-extent is half the shorter-axis span; choose it so leafMax /
    // (2*halfExtent) == ratio. Fall back to the current zoom if the leaf size is
    // unknown.
    final double half =
        leafMax > 0 ? leafMax / (2 * _kFocusLeafRatio) : cur.halfExtent;
    _sounds.play(UiSound.navZoom);
    _viewport.viewport = cur.copyWith(
      centreRe: t.re,
      centreIm: t.im,
      halfExtent: half,
    );
    setState(() {});
  }

  Widget _canvas() {
    final Stage stage = _setup.displayStage;
    return FractalCanvas(
      source: widget.core.source,
      controller: _viewport,
      palette: Palette.forHue(_hue),
      brightness: _brightness,
      sounds: _sounds,
      stage: stage,
      stageParameters:
          stage == Stage.stage2 ? _setup.displayStageParams : null,
      maxIterations: _renderMaxIter,
      // Generated points (white, after Generate) plus selected points (green,
      // in select mode). Empty until there is something to show.
      overlays: _setup.overlaysForDisplayStage(),
      semanticLabel: 'Fractal canvas',
      // Selection is enabled only once points exist and the user turns on
      // select mode (button or `S`). Otherwise taps do nothing and the canvas
      // is pan/zoom only.
      onSelect: (_selectMode || _editPointMode)
          ? (FractalSelection sel) {
              _onCanvasSelect(sel);
            }
          : null,
    );
  }

  /// Stage-0 fractal slot (`#j≥1`): the real orbit board `θ_0_(j-1)` derived
  /// from σ → o₀. Any slot may carry a placed point (shown as a white cross)
  /// until `r_0` are placed; the rest then derive and lock. Point
  /// entry uses the *existing* mechanisms — `R` arms a manual click, exactly
  /// like editing a chain point (so the canvas takes a click only in select /
  /// edit mode). When σ is unset/invalid a "set σ first" panel is shown.
  Widget _orbitBoardPanel(int slot) {
    final StageParameters? bp = _boardRenderParams(slot);
    if (bp == null) return _boardNeedsSigmaPanel(slot);
    final CanvasOverlays overlays = _boardOverlays(slot);
    return FractalCanvas(
      source: widget.core.source,
      controller: _viewport,
      palette: Palette.forHue(_hue),
      brightness: _brightness,
      sounds: _sounds,
      stage: Stage.stage2,
      stageParameters: bp,
      maxIterations: _renderMaxIter,
      overlays: overlays,
      semanticLabel: 'Orbit fractal board (stage 0, slot $slot)',
      // Same gate as the chain canvas: a click lands only while select / edit
      // mode is armed (here, by `R`), and routes through [_onCanvasSelect].
      onSelect: (_selectMode || _editPointMode)
          ? (FractalSelection sel) => _onCanvasSelect(sel)
          : null,
    );
  }

  /// Overlays for the active board: any islands revealed by `E`, plus the placed
  /// point's marker. Shallow zoom (island small on screen) draws a fixed cross;
  /// once the island spans enough pixels it becomes a square frame around its
  /// cells (the switch has hysteresis — see [_updateBoardMarkerMode]).
  CanvasOverlays _boardOverlays(int slot) {
    final ({int reRaw, int imRaw})? pt = _boardPoints[_activeStage][slot];
    final _BoardDeco? deco = pt == null ? null : _boardDecoFor(slot);
    final bool square = _boardMarkerSquare && deco != null;
    final List<CrossMarker> crosses = <CrossMarker>[];
    if (pt != null && !square) {
      // The cross sits on the island's centre when it resolved, else the point.
      final double re = deco != null
          ? (deco.reMin + deco.reMax) / 2.0
          : fixedToDouble(pt.reRaw);
      final double im = deco != null
          ? (deco.imMin + deco.imMax) / 2.0
          : fixedToDouble(pt.imRaw);
      crosses.add(CrossMarker(re: re, im: im));
    }
    return CanvasOverlays(
      islands: <CanvasIsland>[
        ..._boardIslands,
        if (square && deco.cells.pointsReIm.isNotEmpty) deco.cells,
      ],
      frames: <SelectionFrame>[
        if (square)
          SelectionFrame(
            reMin: deco.reMin,
            reMax: deco.reMax,
            imMin: deco.imMin,
            imMax: deco.imMax,
          ),
      ],
      crosses: crosses,
    );
  }

  /// The orbit point `o_i` for [stage]. Stage 0 is `o_0 = H(σ)` (derived on the
  /// fly from slot 0's Namtso salt, so there is no separate `o_0` state to keep
  /// in sync); a deep stage's `o_i = H*(K_{i-1})` is read from [_orbitO], filled
  /// by the forward-navigation advance. Null when σ is unset/invalid (stage 0) or
  /// the stage has not been advanced into yet (deep stages).
  Uint8List? _stageOrbit(int stage) {
    if (stage == 0) {
      final Uint8List? sigma = _parseHex(_sigmaCtrl.text.trim());
      if (sigma == null || sigma.isEmpty) return null;
      return widget.core.orbitRoot(sigma);
    }
    return _orbitO[stage];
  }

  /// Board reservoirs `(o, p, q)` for the active stage's slot [slot] (board
  /// `θ_i_(slot-1)`), or null when the stage's `o_i` is unavailable. Cheap
  /// (`orbitRoot`/`theta`).
  ({int o, int p, int q})? _boardPrm(int slot) {
    final Uint8List? oi = _stageOrbit(_activeStage);
    if (oi == null) return null;
    return OrbitProtocol(widget.core).orbitParams(oi, slot - 1);
  }

  /// Discovery params for resolving a canonical island's *shape* — the engine's
  /// encode params with a larger flood cap so the island is a real shape, not a
  /// speck. Pure visualisation; never affects encoded bits. (Peer of
  /// SetupController's `_islandVizParams`.)
  CoreDiscoveryParams get _islandVizParams {
    final CoreDiscoveryParams b = widget.core.encodeParams;
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

  /// Build the canonical-island decoration (cells + bbox) for a known leaf on the
  /// board's `(o, p, q)`, or null if the island can't be resolved. (Peer of
  /// SetupController's `_islandDecoForLeaf`.)
  _BoardDeco? _boardIslandDecoForLeaf(
      FixedRect leafRect, String path, int o, int p, int q) {
    final CoreCanonicalIsland? isl = widget.core.bindings.canonicalIsland(
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
    return _BoardDeco(
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
      escapeCount: isl.escapeCount,
    );
  }

  /// `E` on a board: enumerate the canonical leaf areas under the current view on
  /// the active board's fractal and highlight each one's island (the board peer
  /// of [_enumerateIslands] / SetupController.enumerateCanonicalIslands).
  Future<void> _boardEnumerateIslands() async {
    final int slot = _slotIndex;
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    final StageParameters? bp = _boardParams;
    if (prm == null || bp == null) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    _sounds.play(UiSound.focus);
    // Point the leaf source at this board so the decode/enumerate run on the
    // same fractal that is on screen.
    widget.core.leafSource.reservoirs =
        StageReservoirs(o: prm.o, p: prm.p, q: prm.q);
    // Use the RAW enumeration (exact I4F60 rects). Passing the rect back to
    // canonicalIsland through a double round-trip changes which island the
    // discovery returns, so the E-revealed island would disagree with the one a
    // click on it resolves (which uses the exact rect from decodeFull).
    final CoreLeafAreasResult res = widget.core.leafSource.leafAreasRaw(
      LeafAreasRequest(
        viewport: _viewport.viewport,
        stage: Stage.stage2,
        stageParameters: bp,
        numBits: EncodingConstants.bitsPerPoint,
      ),
    );
    if (!mounted) return;
    if (res.tooMany) {
      _sounds.play(UiSound.warn);
      _toast('Too many / too dense to enumerate here — zoom in.');
      return;
    }
    final List<CanvasIsland> islands = <CanvasIsland>[];
    for (final CoreLeafArea leaf in res.leaves) {
      final _BoardDeco? deco = _boardIslandDecoForLeaf(
        leaf.rect, // exact rect — no Fixed→double→Fixed round-trip
        leaf.path,
        prm.o,
        prm.p,
        prm.q,
      );
      if (deco != null) islands.add(deco.cells);
    }
    setState(() => _boardIslands = islands);
    if (islands.isEmpty) {
      _sounds.play(UiSound.denyMiss);
      _toast('No canonical islands in view — zoom in.');
    } else {
      _sounds.play(UiSound.confirm);
      _toast('Highlighted ${islands.length} canonical island(s).');
    }
  }

  /// Focus decoration for a board's placed point: the canonical island (cells +
  /// bbox) when it resolves, else the whole leaf rect (no cells) so the point is
  /// always framed. Peer of SetupController's `_focusDecoForLeaf`.
  _BoardDeco _boardFocusDecoForLeaf(
      FixedRect leafRect, String path, int o, int p, int q) {
    final _BoardDeco? isl = _boardIslandDecoForLeaf(leafRect, path, o, p, q);
    if (isl != null) return isl;
    return _BoardDeco(
      cells: const CanvasIsland(cellSize: 0.0, pointsReIm: <double>[]),
      reMin: fixedToDouble(leafRect.reMin),
      reMax: fixedToDouble(leafRect.reMax),
      imMin: fixedToDouble(leafRect.imMin),
      imMax: fixedToDouble(leafRect.imMax),
      escapeCount: 0, // no island resolved — brightness stays at default
    );
  }

  /// The placed point's focus decoration for [slot] (island cells + bbox),
  /// computed by decoding the stored point on its board and cached until the
  /// point / σ changes. Null when the slot has no point.
  _BoardDeco? _boardDecoFor(int slot) {
    if (_boardDecoCache.containsKey(slot)) return _boardDecoCache[slot];
    final ({int reRaw, int imRaw})? pt = _boardPoints[_activeStage][slot];
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    _BoardDeco? deco;
    if (pt != null && prm != null) {
      final CoreDecodeResult d = widget.core.decodePoint(
          reRaw: pt.reRaw, imRaw: pt.imRaw, o: prm.o, p: prm.p, q: prm.q);
      if (d.valid) {
        deco = _boardFocusDecoForLeaf(d.leafRect, d.path, prm.o, prm.p, prm.q);
      }
    }
    _boardDecoCache[slot] = deco;
    return deco;
  }

  /// Recompute the cross↔square mode for the active board from the placed
  /// island's on-screen pixel span, applying the hysteresis band. Cheap: reads
  /// the cached [_boardDecoFor] and only rebuilds when the mode flips. Driven by
  /// the viewport listener (zoom) and after placement / slot changes.
  void _updateBoardMarkerMode() {
    if (!mounted || !_isBoardSlot) return;
    final _BoardDeco? deco = _boardDecoFor(_slotIndex);
    final bool next;
    if (deco == null) {
      next = false;
    } else {
      final ViewportMath m = ViewportMath(_viewport.viewport);
      final (double x0, double y0) = m.coordToPixel(deco.reMin, deco.imMin);
      final (double x1, double y1) = m.coordToPixel(deco.reMax, deco.imMax);
      final double spanPx = math.max((x1 - x0).abs(), (y1 - y0).abs());
      next = _boardMarkerSquare
          ? spanPx > _kMarkerSquareExitPx
          : spanPx >= _kMarkerSquareEnterPx;
    }
    if (next != _boardMarkerSquare) {
      setState(() => _boardMarkerSquare = next);
    }
  }

  void _onBoardViewportChanged() => _updateBoardMarkerMode();

  /// Re-pressing the active board slot's digit alternates between the initial
  /// default view and the canonical view. Falls back to the default view when
  /// there is no placed point to focus.
  void _toggleBoardView() {
    final bool canFocus = _boardDecoFor(_slotIndex) != null;
    if (_boardCanonicalView || !canFocus) {
      _boardCanonicalView = false;
      _sounds.play(UiSound.navZoom);
      _recenter(); // default position + zoom + brightness (its own setState)
    } else {
      _boardCanonicalView = true;
      _focusBoardCanonical();
    }
  }

  /// The **canonical view** of the active board's placed island: centre it,
  /// zoom so its smaller edge nears [_kCanonicalSmallEdgeRatio] of the shorter
  /// screen axis (without letting the larger edge overflow past
  /// [_kCanonicalLargeEdgeCap]), and raise the brightness offset just enough
  /// that the island reaches at least half brightness at that zoom.
  void _focusBoardCanonical() {
    final _BoardDeco? deco = _boardDecoFor(_slotIndex);
    if (deco == null) {
      _boardCanonicalView = false;
      _recenter();
      return;
    }
    final double w = deco.reMax - deco.reMin;
    final double h = deco.imMax - deco.imMin;
    final double small = math.min(w, h);
    final double large = math.max(w, h);
    final FractalViewport cur = _viewport.viewport;

    // half-extent = half the shorter-axis span. Zoom so the smaller edge hits
    // its target ratio, but back off if that would push the larger edge past
    // the overflow cap. Fall back to the current zoom if the island is degenerate.
    double half = cur.halfExtent;
    if (large > 0) {
      final double bySmall =
          small > 0 ? small / (2 * _kCanonicalSmallEdgeRatio) : 0;
      final double byLarge = large / (2 * _kCanonicalLargeEdgeCap);
      half = math.max(bySmall, byLarge);
    }
    _viewport.viewport = cur.copyWith(
      centreRe: (deco.reMin + deco.reMax) / 2.0,
      centreIm: (deco.imMin + deco.imMax) / 2.0,
      halfExtent: half,
    );

    // Brightness solve. The shader lights a cell by
    //   factor = B / (B + 2^(n - beo) / z^2),   z = kReferenceHalfExtent / half
    // so factor >= 0.5  <=>  beo >= n - log2(B) - 2*log2(z). Pick the smallest
    // beo that reaches half brightness, never dimmer than the session default.
    final double z = kReferenceHalfExtent / half;
    final double beoForHalf = deco.escapeCount.toDouble() -
        _log2(kBrightnessFalloffBase) -
        2 * _log2(z);
    final double beo = math.max(_brightness.defaultOffset, beoForHalf);
    _brightness.adjustBySteps((beo - _brightness.offset) / _brightness.step);

    _sounds.play(UiSound.navZoom);
    setState(() {});
  }

  static double _log2(double x) => math.log(x) / math.ln2;

  /// Arm a manual point placement for the current board slot — the board peer of
  /// [_changePointManual]: the next canvas click sets slot [_slotIndex]'s point.
  void _armBoardManual() {
    setState(() => _editPointMode = true);
    _sounds.play(UiSound.click);
    _toast('Click the point for slot $_slotIndex (Esc to cancel).');
  }

  /// Decode a tapped leaf as slot [slot]'s point (under the board's
  /// reservoirs) and record it. Returns true when a point was placed.
  bool _placePrimaryAt(int slot, FractalSelection sel) {
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (prm == null) return false;
    final int reRaw = fixedFromDouble(sel.re);
    final int imRaw = fixedFromDouble(sel.im);
    final CoreDecodeResult d = widget.core.decodePoint(
        reRaw: reRaw, imRaw: imRaw, o: prm.o, p: prm.p, q: prm.q);
    if (!d.valid) {
      _sounds.play(UiSound.denyMiss);
      _toast('No encodable leaf there — zoom in and click closer.');
      return false;
    }
    _setPrimary(slot, d.bits, (reRaw: reRaw, imRaw: imRaw));
    _sounds.play(UiSound.selectPoint);
    return true;
  }

  /// Generate a random 32-bit point for slot [slot] (the app picks the entropy),
  /// encoding it to a real board point — the board peer of
  /// [_changePointGenerated] (`N`).
  void _generatePrimary(int slot) {
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (prm == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Set σ in slot 0 first.');
      return;
    }
    final List<int> bits = Entropy.randomBits(32);
    final EncodedPoint pt = widget.core
        .encodeStage(List<int>.of(bits), o: prm.o, p: prm.p, q: prm.q)
        .first;
    _setPrimary(slot, bits, (reRaw: pt.reRaw, imRaw: pt.imRaw));
    Entropy.wipe(bits);
    _sounds.play(UiSound.selectPoint);
  }

  /// Open the shared inline import editor for slot [slot]'s point — the board
  /// peer of [_changePointImport] (`I` / `Alt+I`), reusing [_importEditorBody].
  void _beginBoardImport(int slot, {required bool hex}) {
    _pointImport.clear();
    setState(() {
      _pointImportFmt = hex ? _ImportFormat.hex : _ImportFormat.words;
      _boardImportSlot = slot;
    });
    _pointImportFocus.requestFocus();
  }

  /// Apply the inline import to the pending board slot: 8 hex or 3 words → 32
  /// bits, encoded to a board point.
  void _applyBoardImport() {
    final int slot = _boardImportSlot!;
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (prm == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Set σ in slot 0 first.');
      return;
    }
    List<int> bits;
    try {
      bits = _pointImportFmt == _ImportFormat.hex
          ? Entropy.hexToBits(_pointImport.text.trim().toUpperCase())
          : Bip39.mnemonicToEntropyBits(_pointImport.text.trim());
    } on FormatException catch (e) {
      _sounds.play(UiSound.denyInput);
      _toast(e.message);
      return;
    }
    if (bits.length != EncodingConstants.bitsPerPoint) {
      Entropy.wipe(bits);
      _sounds.play(UiSound.denyInput);
      _toast('A board point is 32 bits — 8 hex digits or 3 words.');
      return;
    }
    final EncodedPoint pt = widget.core
        .encodeStage(List<int>.of(bits), o: prm.o, p: prm.p, q: prm.q)
        .first;
    _setPrimary(slot, bits, (reRaw: pt.reRaw, imRaw: pt.imRaw));
    Entropy.wipe(bits);
    _cancelBoardImport();
    _sounds.play(UiSound.selectPoint);
  }

  void _cancelBoardImport() {
    _pointImport.clear();
    setState(() => _boardImportSlot = null);
    _focusViewer();
  }

  /// The inline import editor for a board point (reuses [_importEditorBody]).
  Widget _boardImportEditor() {
    final int slot = _boardImportSlot!;
    return _importEditorBody(
      title: 'Import slot $slot\'s point — 3 words or 8 hex (a 32-bit point).',
      words: 3,
      hexDigits: 8,
      onApply: _applyBoardImport,
      onCancel: _cancelBoardImport,
    );
  }

  /// Record slot [slot]'s placed chunk + point (copying [bits]) on the active
  /// stage and re-derive that stage's shares — the placed count may now have
  /// reached `r_i`, fixing `Sh_i`. Any slot may be the one placed here; all
  /// fractals at a stage are operationally equal.
  void _setPrimary(int slot, List<int> bits, ({int reRaw, int imRaw}) point) {
    final int stage = _activeStage;
    setState(() {
      final List<int>? old = _boardChunks[stage][slot];
      if (old != null) Entropy.wipe(old);
      _boardChunks[stage][slot] = List<int>.of(bits);
      _boardPoints[stage][slot] = point;
      _boardDerived[stage][slot] = false;
      _recomputeExtraShares(stage);
      // Changing a point in this stage re-roots every deeper stage
      // (o_{i+1}=H*(K_i)), so their advanced o_i / K_i and any placed points no
      // longer decode — drop them; the user re-advances from the settled prefix.
      _invalidateDeeperThan(stage);
      // Placing this point (and re-deriving the shares) invalidates the cached
      // island decorations; the canonical view (if any) referred to the old one.
      _boardDecoCache.clear();
      _boardCanonicalView = false;
    });
    // Pick the marker mode for the freshly placed point at the current zoom.
    _updateBoardMarkerMode();
  }

  /// Drop every stage deeper than [stage] (wiping its chunks, points, `o_i` and
  /// `K_i`). Called when an earlier stage's point changes, since a re-rooted
  /// prefix invalidates the whole memory-hard advance chain below it. Must run
  /// inside a [setState].
  void _invalidateDeeperThan(int stage) {
    // A halted advance into any deeper stage was derived from the prefix that
    // just changed, so its checkpoint no longer leads anywhere.
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    if (cp != null && cp.stage > stage) _clearAdvanceCheckpoint();
    for (int st = stage + 1; st <= _maxStage; st++) {
      _shareEncodeGen[st]++; // discard any in-flight share-marker encode for st
      for (int s = 1; s <= _maxSlot; s++) {
        final List<int>? c = _boardChunks[st][s];
        if (c != null) Entropy.wipe(c);
        _boardChunks[st][s] = null;
        _boardPoints[st][s] = null;
        _boardDerived[st][s] = false;
      }
      final Uint8List? k = _orbitK[st];
      if (k != null) {
        Entropy.wipe(k);
        _orbitK[st] = null;
      }
      final Uint8List? o = _orbitO[st];
      if (o != null) {
        Entropy.wipe(o);
        _orbitO[st] = null;
      }
    }
  }

  /// Derive [stage]'s non-placed fractal shares from the `r_i` points the holder
  /// placed (in whichever slots), and (re)compute `K_i = H(o_i ‖ Sh_i)` into
  /// [_orbitK]. `Sh_i = shamirInterp(placed, abscissa = slot index)`; the engine
  /// then evaluates it at each non-placed slot's index
  /// ([GreatWallCore.shamirEval]) and that value is encoded onto its board
  /// `θ_i_(s-1)` for display. Fewer than `r_i` placed (or a missing `o_i`) simply
  /// clears the derived slots and `K_i`. All fractals are equal, so any `r_i` of
  /// the `s_i` boards reconstruct the identical `Sh_i` (orbit_protocol_test).
  /// Must run inside a [setState].
  void _recomputeExtraShares(int stage) {
    final int r = _requiredFractals[stage];
    // Any recompute supersedes an in-flight background share-marker encode for
    // this stage (see [_encodeShareMarkers]); bump the token so a late result is
    // discarded rather than written over the freshly recomputed state.
    _shareEncodeGen[stage]++;
    // K_i is only valid while the primaries are complete; drop the previous one
    // up front so every incomplete early-return below leaves it null.
    final Uint8List? oldK = _orbitK[stage];
    if (oldK != null) {
      Entropy.wipe(oldK);
      _orbitK[stage] = null;
    }
    // All fractals at a stage are operationally equal: each slot's abscissa is
    // its index, so ANY r_i user-placed points fix the identical degree-(r_i-1)
    // polynomial Sh_i and the remaining slots derive on it (Shamir subset-
    // invariance). The placed set is whichever slots the holder chose — not
    // necessarily 1..r_i — which is what lets recovery use a *different* r_i of
    // the s_i points (forgetting-resistance).
    final List<int> placed = <int>[];
    for (int s = 1; s <= _maxSlot; s++) {
      if (_boardChunks[stage][s] != null && !_boardDerived[stage][s]) {
        placed.add(s);
      }
    }
    // Drop any previously-derived slots; they are recomputed below, or left
    // clear while the placed count is still under threshold.
    for (int s = 1; s <= _maxSlot; s++) {
      if (_boardDerived[stage][s]) {
        final List<int>? c = _boardChunks[stage][s];
        if (c != null) Entropy.wipe(c);
        _boardChunks[stage][s] = null;
        _boardPoints[stage][s] = null;
        _boardDerived[stage][s] = false;
      }
    }
    if (placed.length < r) return; // under threshold — Sh_i not yet determined
    // Exactly r_i points fix the polynomial. Placement never lets more than r_i
    // accumulate, but lowering r_i (the slider) can leave extra placed slots; the
    // lowest-indexed r_i then win and the surplus re-derive below.
    final List<int> chosen =
        placed.length > r ? placed.sublist(0, r) : placed;
    final Uint8List? oi = _stageOrbit(stage);
    if (oi == null) return;
    final OrbitProtocol orbit = OrbitProtocol(widget.core);
    // Interpolate Sh_i over the chosen slots at abscissa = slot index.
    final List<int> xs = <int>[for (final int s in chosen) s];
    final List<int> ys = <int>[
      for (final int s in chosen)
        OrbitProtocol.bitsToU32(_boardChunks[stage][s]!),
    ];
    final List<int> sh = widget.core.shamirInterp(xs, ys);
    // K_i = H(o_i ‖ Sh_i): the per-stage master secret, exported (optionally
    // domain-separated) by K / Alt+K. Computed here while Sh_i is in hand.
    final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
    _orbitK[stage] = widget.core.masterSecret(oi, shBytes);
    Entropy.wipe(shBytes);
    // Derive every NON-chosen slot at abscissa = slot index (display-only; K_i
    // above uses the chosen points alone). Encoding the fractal point is a
    // CPU-heavy island-discovery search that, on the degenerate share values a
    // corner-case stage produces (an all-ones stage → constant polynomial →
    // all-ones shares), can take tens of seconds per point at a sparse-island
    // reservoir — running it on the UI isolate froze the app — so it is deferred
    // off-isolate ([_encodeShareMarkers]); a null point renders no marker until
    // it lands.
    final Set<int> chosenSet = chosen.toSet();
    final List<List<int>> pendingBits = <List<int>>[];
    final List<List<int>> pendingRes = <List<int>>[];
    final List<int> pendingSlots = <int>[];
    for (int s = 1; s <= _maxSlot; s++) {
      if (chosenSet.contains(s)) continue;
      final List<int> bits =
          OrbitProtocol.u32ToBits(widget.core.shamirEval(sh, s));
      final ({int o, int p, int q}) prm = orbit.orbitParams(oi, s - 1);
      _boardChunks[stage][s] = bits; // owns it
      _boardPoints[stage][s] = null; // marker pending until the encode lands
      _boardDerived[stage][s] = true;
      pendingBits.add(List<int>.of(bits));
      pendingRes.add(<int>[prm.o, prm.p, prm.q]);
      pendingSlots.add(s);
    }
    for (int i = 0; i < sh.length; i++) {
      sh[i] = 0; // Sh_i is coercion-relevant — zero it once shares are made.
    }
    if (pendingSlots.isNotEmpty) {
      unawaited(_encodeShareMarkers(
          stage, _shareEncodeGen[stage], pendingSlots, pendingBits, pendingRes));
    }
  }

  /// Encode stage [stage]'s deferred forgetting-resistance share markers off the
  /// UI isolate (see [GreatWallCore.encodeSharePoints]) and, when they land,
  /// place them on their slots — unless a newer recompute, a deeper-stage
  /// re-root, or a σ reset has since bumped [_shareEncodeGen] past [gen], in
  /// which case the stale result is dropped. A failed encode leaves the markers
  /// pending: they are display-only, so `K_i` and the advance are unaffected.
  Future<void> _encodeShareMarkers(
    int stage,
    int gen,
    List<int> slots,
    List<List<int>> chunks,
    List<List<int>> reservoirs,
  ) async {
    List<({int reRaw, int imRaw})> pts;
    try {
      pts = await widget.core.encodeSharePoints(chunks, reservoirs);
    } catch (_) {
      return;
    }
    if (!mounted || gen != _shareEncodeGen[stage]) return;
    if (pts.length != slots.length) return; // engine returns one point per chunk
    setState(() {
      for (int i = 0; i < slots.length; i++) {
        final int s = slots[i];
        // Only apply while this is still the derived share we encoded.
        if (_boardDerived[stage][s]) {
          _boardPoints[stage][s] = (reRaw: pts[i].reRaw, imRaw: pts[i].imRaw);
        }
      }
      _boardDecoCache.clear();
    });
  }

  /// Drop every orbit placement across all stages (wiping chunks, `o_i` and
  /// `K_i`) — called when σ changes, since a new σ re-roots the whole orbit and
  /// old points no longer decode, and on dispose.
  void _clearOrbitPlacements() {
    _clearAdvanceCheckpoint(); // a re-rooted orbit invalidates a halted advance
    for (int st = 0; st <= _maxStage; st++) {
      _shareEncodeGen[st]++; // discard any in-flight share-marker encode
      for (int s = 1; s <= _maxSlot; s++) {
        final List<int>? c = _boardChunks[st][s];
        if (c != null) Entropy.wipe(c);
        _boardChunks[st][s] = null;
        _boardPoints[st][s] = null;
        _boardDerived[st][s] = false;
      }
      final Uint8List? k = _orbitK[st];
      if (k != null) {
        Entropy.wipe(k);
        _orbitK[st] = null;
      }
      // o_0 is derived on the fly (never stored); wipe the advanced deep points.
      final Uint8List? o = _orbitO[st];
      if (o != null) {
        Entropy.wipe(o);
        _orbitO[st] = null;
      }
    }
    _boardKey = '';
    _boardIslands = const <CanvasIsland>[];
    _boardDecoCache.clear();
    _boardCanonicalView = false;
  }

  /// Informational panel section for the active orbit board: the slot's role,
  /// its placed/derived state, the hotkeys that set the point (`R` manual click,
  /// `N` random, `I`/`Alt+I` import) — routed through the existing point-entry
  /// mechanisms, so there are no bespoke buttons — and the reset-view gesture.
  List<Widget> _boardStatus() {
    final int slot = _slotIndex;
    final int stage = _activeStage;
    final int r = _requiredFractals[stage];
    final bool derived = _boardDerived[stage][slot];
    final bool placed = _boardPoints[stage][slot] != null;
    final bool hasRoot = stage == 0
        ? _parseHex(_sigmaCtrl.text.trim()) != null
        : _orbitO[stage] != null;
    final ThemeData theme = Theme.of(context);
    final Widget body;
    if (derived) {
      body = Text(
        'Derived share (locked): the stage’s Shamir polynomial — fixed by the '
        '$r points you placed — extrapolated onto this fractal. It is a real, '
        'usable point: recovery accepts any $r of the stage’s fractals, not '
        'only the ones you placed here.',
        style: theme.textTheme.bodySmall,
      );
    } else if (!hasRoot) {
      body = Text(
        stage == 0
            ? 'Set σ in slot 0 first.'
            : 'Advance into this stage first.',
        style: theme.textTheme.bodySmall,
      );
    } else {
      body = Text(
        placed
            ? 'Point placed. R new click · N regenerate · I import (words/hex).'
            : 'R to place (click a leaf) · N random · I import (words/hex). '
                'rᵢ=$r is the minimum — place any $r fractals; the rest derive.',
        style: theme.textTheme.bodySmall,
      );
    }
    return <Widget>[
      Text(
          derived
              ? 'Slot $slot — derived share (locked)'
              : 'Slot $slot — fractal${slot > r ? ' (beyond rᵢ=$r)' : ''}',
          style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      body,
      const SizedBox(height: 6),
      Text(
        placed
            ? 'Press $slot again to toggle the canonical view — island centred, '
                'zoomed and brightened — and back.'
            : 'Press $slot again to reset the view (position · zoom · brightness).',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
      // Orbit-build stage navigation (pre-session): advance forward once this
      // stage is complete, and exclude this stage and below (deep stages only).
      if (!_hasSession) ...<Widget>[
        if (_orbitK[stage] != null && stage < _maxStage) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            stage == _orbitReachableCeiling
                ? 'Stage complete. Alt+${stage + 1} advances the orbit (memory-hard).'
                : 'Stage complete.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
        if (_orbitK[stage] != null && stage == _maxStage) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'Deepest stage — its K is the wallet master key (copy with K).',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
        if (stage >= 1) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'X excludes Stage $stage and every stage below it.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ],
    ];
  }

  /// Derive stage-0 board `θ_0_(slot-1)` from the current σ, point the render
  /// source at its authoritative u64 reservoirs, and return the display-proxy
  /// [StageParameters] the canvas repaints on. Returns null when σ is unset or
  /// not valid hex. Cheap `orbitRoot`/`theta` hashes only run when the (σ, slot)
  /// key changes; otherwise the cached reservoirs are re-pointed (a plain field
  /// write, in case a deep-stage visit overwrote them) and the cached params are
  /// returned unchanged so the canvas does not needlessly repaint.
  StageParameters? _boardRenderParams(int slot) {
    final int stage = _activeStage;
    // Cache key: stage 0 keys on the σ text (so no `orbitRoot` hash runs on a
    // pan/zoom rebuild); deep stages key on `stage#slot` alone, since their `o_i`
    // is stable until an advance / σ change — both of which reset [_boardKey].
    final String key =
        stage == 0 ? '0#$slot#${_sigmaCtrl.text.trim()}' : '$stage#$slot';
    if (key != _boardKey) {
      _boardKey = key;
      final Uint8List? oi = _stageOrbit(stage);
      if (oi == null) {
        _boardReservoirs = null;
        _boardParams = null;
      } else {
        final ({int o, int p, int q}) prm =
            OrbitProtocol(widget.core).orbitParams(oi, slot - 1);
        final StageReservoirs res =
            StageReservoirs(o: prm.o, p: prm.p, q: prm.q);
        final ({double o, double p, double q}) dk = res.displayKey;
        _boardReservoirs = res;
        _boardParams = StageParameters(o: dk.o, p: dk.p, q: dk.q);
      }
    }
    // Re-point the render source every build (cheap): a deep-stage visit or the
    // legacy chain may have set its own reservoirs since this board was last
    // shown, so reclaim the shared source for the board on screen.
    widget.core.source.reservoirs = _boardReservoirs;
    widget.core.leafSource.reservoirs = _boardReservoirs;
    return _boardParams;
  }

  /// Shown for a stage-0 fractal slot before σ exists: the board is `θ_0_(j-1)`,
  /// derived from σ → o₀, so it cannot render until σ is set in slot 0.
  Widget _boardNeedsSigmaPanel(int slot) {
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Align(
        alignment: const Alignment(0, -0.3),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.blur_on, size: 48),
              const SizedBox(height: 16),
              Text('Stage 0 · slot $slot — fractal board',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'This board is derived from σ → o₀. Set σ in slot 0 (the Namtso '
                'salt) first; the fractal appears here once σ is valid hex.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Parse an even-length hex string (whitespace ignored) to bytes; null on any
  /// malformed input. Ported from the orbit setup screen's σ parser.
  static Uint8List? _parseHex(String s) {
    final String h = s.replaceAll(RegExp(r'\s'), '');
    if (h.isEmpty || h.length.isOdd) return null;
    final Uint8List out = Uint8List(h.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      final int? b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  /// The left-pane panel shown for Stage 0 (the salt/pepper text): there is no
  /// fractal and no point to select here. Shows the text the chain was seeded
  /// with, behind a reveal toggle (it may be a secret pepper).
  Widget _textStagePanel() {
    final String text = _setup.saltPepper;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      // Sit a little above centre so the derivation progress overlay (which sits
      // a little below centre) never lands on top of this text.
      child: Align(
        alignment: const Alignment(0, -0.3),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.password, size: 48),
              const SizedBox(height: 16),
              Text('Stage 0 — salt / pepper',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'This text seeds every fractal in your chain — there is no '
                'shared "canonical" fractal, and no point to select here. '
                'You chose whether it is a public label or a secret pepper.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              if (text.isEmpty)
                Text('(no salt / pepper set)',
                    style: Theme.of(context).textTheme.bodySmall)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SelectableText(
                      _stage0Hidden ? '•' * text.length : text,
                      style: const TextStyle(
                        fontFamily: GreatWallTypography.fontFamily,
                        fontFamilyFallback: <String>['monospace'],
                        fontSize: 18,
                        letterSpacing: 1.5,
                      ),
                    ),
                    IconButton(
                      tooltip: _stage0Hidden ? 'Reveal' : 'Hide',
                      icon: Icon(_stage0Hidden
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () =>
                          setState(() => _stage0Hidden = !_stage0Hidden),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Run the `E` canonical-leaf-area enumeration: a start cue, then a result
  /// cue + toast/console log. See [SetupController.enumerateCanonicalIslands].
  Future<void> _enumerateIslands() async {
    _sounds.play(UiSound.focus);
    final LeafScanOutcome r =
        await _setup.enumerateCanonicalIslands(_viewport.viewport);
    if (!mounted) return;
    switch (r) {
      case LeafScanOutcome.shown:
        _sounds.play(UiSound.confirm);
        _toast('Highlighted ${_setup.islandCount} canonical island(s).');
      case LeafScanOutcome.tooMany:
        _sounds.play(UiSound.warn);
        _toast('Too many / too dense to enumerate here — zoom in.');
      case LeafScanOutcome.empty:
        _sounds.play(UiSound.denyMiss);
        _toast('No canonical islands in view — zoom in.');
    }
  }

  Future<void> _onCanvasSelect(FractalSelection sel) async {
    // Placing a stage-0 orbit board point (the `R` manual arm): the click sets
    // this slot's point. On an invalid leaf the mode stays armed to retry.
    if (_editPointMode && _placeableBoardSlot) {
      if (_placePrimaryAt(_slotIndex, sel)) {
        setState(() => _editPointMode = false);
      }
      return;
    }
    // Editing the displayed stage's point (the R edit): the click sets the new
    // point and the tail (if any) was already confirmed when arming the mode.
    if (_editPointMode) {
      final SelectionOutcome o = _setup.changeCurrentPointAt(sel);
      final int k = _setup.displayStageIndex;
      switch (o) {
        case SelectionOutcome.invalid:
          _sounds.play(UiSound.denyMiss);
          _toast('No encodable leaf there — zoom in and click closer.');
        case SelectionOutcome.marked:
          setState(() => _editPointMode = false);
          _sounds.play(UiSound.changePoint);
          _toast('Stage $k point changed.');
        default:
          setState(() => _editPointMode = false);
      }
      return;
    }
    // During a manual expansion, only the fresh (point-less) new stages accept a
    // click; an existing stage's point is never clobbered by a stray tap.
    if (_expandManualActive && _setup.hasPointAt(_setup.displayStageIndex)) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Stage ${_setup.displayStageIndex} already has its point.');
      return;
    }
    SelectionOutcome outcome = _setup.selectPoint(sel);
    // A valid click that would clobber a re-selected stage's later fractals asks
    // for confirmation before discarding them.
    if (outcome == SelectionOutcome.needsConfirm) {
      final bool ok = await _confirmReselect();
      if (!mounted || !ok) return;
      outcome = _setup.selectPoint(sel, confirmedReselect: true);
      if (!mounted) return;
    }
    final String? msg;
    switch (outcome) {
      case SelectionOutcome.invalid:
        _sounds.play(UiSound.denyMiss);
        msg = 'No encodable leaf there — zoom in and click closer.';
      case SelectionOutcome.marked:
        _sounds.play(UiSound.selectPoint);
        final int k = _setup.displayStageIndex;
        // Manual expansion: the click set this new stage's point; advance to the
        // next new stage (deriving it) until the target is reached.
        if (_expandManualActive) {
          final int g = _expandManualTarget ?? k;
          if (k < g) {
            _toast('Point set on Stage $k — deriving Stage ${k + 1}…');
            await _deriveNextStage();
          } else {
            _endManualExpand();
            _sounds.play(UiSound.finalReady);
            _toast('Expansion complete — Stage $g added.');
          }
          return;
        }
        msg = k < _setup.nStages - 1
            ? 'Point marked on Stage $k/${_setup.nStages - 1} — '
                'select Stage ${k + 1} to derive it.'
            : 'Point marked on Stage $k/${_setup.nStages - 1}.';
      case SelectionOutcome.complete:
        _sounds.play(UiSound.finalReady);
        msg = 'Recall complete — seed reconstructed.';
      case SelectionOutcome.needsConfirm:
      case SelectionOutcome.busy:
        msg = null;
    }
    if (msg == null) return;
    _toast(msg);
  }

  /// Show an inline console confirmation and complete with the user's choice
  /// when they press a button. Shared by every confirm flow (re-derive, abort,
  /// reset). Ensures the console is expanded so the prompt is visible.
  Future<bool> _consoleConfirm({
    required String message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
  }) {
    final Completer<bool> completer = Completer<bool>();
    _resolvePrompt(false); // decline any already-pending prompt first
    _sounds.play(UiSound.warn); // a destructive confirmation is being raised
    setState(() {
      _chromeMinimized = false; // make sure the prompt is visible
      _prompt = _ConsolePrompt(
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        completer: completer,
      );
    });
    return completer.future;
  }

  /// Confirm a point re-selection that will discard the later fractals already
  /// derived from this stage. The confirmation is shown **inline in the
  /// console** (not a modal dialog); the returned future completes when the user
  /// presses one of the console's action buttons.
  Future<bool> _confirmReselect() => _consoleConfirm(
        message: 'Re-derive later stages? This stage already has a point and '
            'later stages were derived from it. Choosing a new point discards '
            'those later stages — you will re-derive and re-select them.',
        confirmLabel: 'Discard & re-select',
      );

  Widget _progressOverlay() {
    final bool deriving = _setup.phase == SetupPhase.deriving;
    // The stage-tab strip (above this scrim) is the progress bar and the console
    // carries the live text + ETA, so the overlay avoids a third copy: while
    // deriving it shows only Halt; for the brief encode (no Halt) it shows a
    // short label so the dim is not blank.
    return ColoredBox(
      color: Colors.black54,
      // Sit a little below centre so it clears the Stage-0 text panel (which
      // sits a little above centre) during the foreground Stage-1 derivation.
      child: Align(
        alignment: const Alignment(0, 0.3),
        child: deriving
            ? TextButton(
                onPressed: _setup.halt,
                child: const Text('Halt'),
              )
            : _advancing
                // The orbit advance now streams pass by pass, so it gets the
                // same Halt the chain derivation has: cancelling kills the
                // worker isolate, costing at most the pass in flight. The stage
                // tab above carries the bar; this states the cost in passes.
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _advanceTotal > 0
                            ? 'Advancing the orbit (memory-hard) — pass '
                                '$_advanceDone/$_advanceTotal…'
                            : 'Advancing the orbit (memory-hard)…',
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _advanceJob == null
                            ? null
                            : () {
                                _sounds.play(UiSound.select);
                                _advanceJob?.cancel();
                              },
                        child: const Text('Halt'),
                      ),
                    ],
                  )
                : Text(
                    _setup.phase == SetupPhase.encoding
                        ? 'Encoding…'
                        : 'Working…',
                    style: const TextStyle(color: Colors.white),
                  ),
      ),
    );
  }

  // --- Console ----------------------------------------------------------------

  /// The hotkey manual, shown in the console (on by default at launch, toggled
  /// with `H`). Lists every shortcut the setup screen handles.
  static const List<String> _manualLines = <String>[
    'F1 manual · F2 Setup · F3 Train · F4 Accelerate · F5 Inherit',
    'Esc  return to the fractal (leave a text field) · Tab cycles fields',
    'M  console   9  stage bar   Z  reset (asks first)',
    'Alt+0–4  go to that stage (recenters); press again to zoom to its point',
    '0–6  select the secondary slot (0 = salt · 1–6 = fractals)',
    'Fractals are equal: rᵢ is the minimum — place any rᵢ, the rest derive',
    'Simplest: fill fractals in order & remember which ones you learn',
    'N / I / R  on a point: N new random · I import · R manual click',
    'I import = BIP39 words · Alt+I import = hex (config & point edit alike)',
    'Click/press a ghost slot past the last stage to grow the setup (N/I/R)',
    'S salt / export salt · P profile · D derivation steps · C colour',
    'Alt+D  calibrate derivation time (dialog: target time → steps N)',
    'K  copy the master secret ("the key")    H  halt derivation (keeps progress)',
    'X  exclude this stage & above (shorten the setup)',
    'E  highlight canonical islands in view (white) · zoom in if too many',
    'Vault: F file path · W write/save · O open file · T blank templates',
    'In Write: Q QR · Alt+Q copy · press again to switch 128/256-bit · I scan QR to reuse key · Alt+I own key',
    'In Open: Q scan QR · Alt+Q type key (32 or 64 hex) · Esc cancel',
    'V+↑/↓  sound volume (level 0 = muted) · Alt+V reveal/hide sensitive text',
    'Alt+K  copy the full export digest (not just the first 32 chars)',
    'Alt+L  deep render — reveal leaves in escape-count voids (slower)',
    'L+scroll brightness · scroll zoom · drag pan (over the canvas)',
  ];

  /// Console palette: "Gunmetal" — a cool, near-neutral blue-grey, translucent
  /// over the canvas so the fractal faintly bleeds through. The slight blue cast
  /// (channels offset a few levels from pure grey) reads as a *material* rather
  /// than an abstract flat grey; it stays unsaturated enough to sit neutrally
  /// against all six fractal hue schemes. See great-wall-ux/SCOPE.md
  /// §"Console palette" for the rationale.
  /// Memorise-mode guidance. Lives in the console (not the control panel) so the
  /// panel stays a stable, compact action surface.
  static const String _memoriseHelp =
      'Memorise your points. Stage 0 is the salt/pepper you entered; each later '
      'stage is its own fractal carrying one point. Study the marked location on '
      'every fractal until you can find it from memory, then finish — the seed '
      'is then held only in your recall.';

  /// Whether the user is studying a settled generated/imported setup (the state
  /// the [_memoriseHelp] guidance applies to).
  bool get _inMemoriseStudy =>
      _setup.phase == SetupPhase.memorise &&
      !_setup.isGenerating &&
      !_setup.isRecallSession;

  static const Color _kConsoleBg = Color(0xE6131519); // ~90% opaque gunmetal
  static const Color _kConsoleFg = Color(0xFFE9EDF2); // cool off-white
  static const Color _kConsoleAccent = Color(0xFFB8C2CC); // brighter, same cast

  static const TextStyle _termStyle = TextStyle(
    color: _kConsoleFg,
    fontFamily: GreatWallTypography.fontFamily,
    fontFamilyFallback: <String>['monospace'],
    fontSize: 13,
    height: 1.3,
  );

  /// The bottom console — the single surface for toasts, focus help, and inline
  /// confirmations. Collapses to a one-line status bar when minimized. Styled as
  /// a terminal: saturated green on black.
  Widget _console() {
    final String? focusHelp =
        _focusedField != null ? _fieldHelp(_focusedField!) : null;
    final String status = _prompt != null
        ? _prompt!.message
        : _expandTarget != null
            ? 'Add stages — N new · I import · Esc cancel.'
            : _derivationStatus() ??
            focusHelp ??
            (_inMemoriseStudy ? _memoriseHelp : null) ??
            (_consoleLog.isEmpty ? 'Ready.' : _consoleLog.last);
    return Material(
      color: _kConsoleBg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border:
              Border(top: BorderSide(color: _kConsoleAccent.withValues(alpha: 0.35))),
        ),
        child: SafeArea(
          top: false,
          child: DefaultTextStyle(
            style: _termStyle,
            child: IconTheme(
              data: const IconThemeData(color: _kConsoleFg, size: 16),
              child: _chromeMinimized
                  ? _consoleStatusBar(status)
                  : _consoleExpanded(),
            ),
          ),
        ),
      ),
    );
  }

  /// The collapsed console: one status line plus a restore button.
  Widget _consoleStatusBar(String status) {
    return Row(
      children: <Widget>[
        const SizedBox(width: 12),
        const Icon(Icons.terminal),
        const SizedBox(width: 8),
        Expanded(
          child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        IconButton(
          tooltip: 'Restore console (M)',
          color: _kConsoleFg,
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: () => setState(() => _chromeMinimized = false),
        ),
      ],
    );
  }

  /// The expanded console: header, optional inline prompt, focus help, the
  /// recent log, and the optional hotkey manual.
  Widget _consoleExpanded() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header.
        Row(
          children: <Widget>[
            const SizedBox(width: 12),
            const Icon(Icons.terminal),
            const SizedBox(width: 8),
            Text('Console',
                style: _termStyle.copyWith(
                    color: _kConsoleAccent, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              tooltip: _manualVisible ? 'Hide manual (F1)' : 'Show manual (F1)',
              color: _kConsoleFg,
              icon: Icon(_manualVisible ? Icons.help : Icons.help_outline),
              onPressed: () => setState(() => _manualVisible = !_manualVisible),
            ),
            IconButton(
              tooltip: 'Minimize console & tabs (M)',
              color: _kConsoleFg,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => setState(() => _chromeMinimized = true),
            ),
          ],
        ),
        Divider(height: 1, color: _kConsoleAccent.withValues(alpha: 0.25)),
        // Live region — pinned above the scroll so a confirmation prompt or the
        // focused-field help is always visible (never scrolled behind the
        // manual).
        if (_prompt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _consolePromptBlock(),
          ),
        if (_prompt == null && _expandTarget != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _expandPickerBlock(),
          ),
        if (_prompt == null &&
            _expandTarget == null &&
            _setup.derivingStageIndex != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _derivationBlock(),
          ),
        if (_prompt == null &&
            _expandTarget == null &&
            _setup.derivingStageIndex == null &&
            _focusedField != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.info_outline, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text(_fieldHelp(_focusedField!))),
              ],
            ),
          ),
        // Memorise guidance — relocated here from the control panel so the panel
        // stays stable. Shown only when nothing more urgent is.
        if (_prompt == null &&
            _expandTarget == null &&
            _setup.derivingStageIndex == null &&
            _focusedField == null &&
            _inMemoriseStudy)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.menu_book, size: 14),
                SizedBox(width: 6),
                Expanded(child: Text(_memoriseHelp)),
              ],
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final String line in _consoleLog) Text('› $line'),
                if (_manualVisible) ...<Widget>[
                  const SizedBox(height: 8),
                  Text('Hotkeys',
                      style: _termStyle.copyWith(
                          color: _kConsoleAccent, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  _manualColumns(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The hotkey manual laid out in two columns. The lines are short and the
  /// console is wide, so a single column wasted the horizontal space and ran
  /// tall enough to scroll; splitting in half roughly halves the height and
  /// fits comfortably without scrolling.
  Widget _manualColumns() {
    final int half = (_manualLines.length + 1) ~/ 2;
    Widget column(Iterable<String> lines) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(line),
              ),
          ],
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: column(_manualLines.take(half))),
        const SizedBox(width: 20),
        Expanded(child: column(_manualLines.skip(half))),
      ],
    );
  }

  /// The inline confirmation block (replaces modal dialogs): the prompt message
  /// plus Cancel / Confirm buttons that complete the pending future. Styled to
  /// match the terminal (green on black).
  Widget _consolePromptBlock() {
    final _ConsolePrompt p = _prompt!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _kConsoleFg.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _kConsoleFg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(p.message),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                style: TextButton.styleFrom(foregroundColor: _kConsoleFg),
                onPressed: () => _resolvePrompt(false),
                child: Text(p.cancelLabel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _kConsoleFg,
                  foregroundColor: _kConsoleBg,
                ),
                onPressed: () => _resolvePrompt(true),
                child: Text(p.confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlPanel(bool hasResult) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: <Widget>[

          // Orbit board status (role + placed/derived + the hotkeys that set the
          // point). Point entry reuses the existing mechanisms — there are no
          // bespoke buttons here.
          if (_isBoardSlot) ...<Widget>[
            ..._boardStatus(),
            // Master-secret (K_i) export — offered once the active stage has r_i
            // fractals placed (K_i derived). Reuses the export-salt field
            // + Copy button.
            if (_activeK != null) ...<Widget>[
              const Divider(height: 32),
              ..._masterExportControls(),
            ],
            const Divider(height: 32),
          ],

          if (_setup.phase == SetupPhase.recallComplete)
            ..._recallCompleteControls()
          else if (_setup.isRecallSession && hasResult)
            ..._recallControls()
          else if (!hasResult)
            ..._configControls()
          else
            ..._memoriseControls(),

          // (Stage navigation lives in the fixed 0–4 tab bar above the canvas;
          // the redundant "< Stage k / N >" row was dropped.)

          // Background generation progress: later stages are still deriving
          // while the user studies the ones already done.
          if (_setup.isGenerating || _setup.generationError != null) ...<Widget>[
            const Divider(height: 32),
            _generationNotice(),
          ],

          // A halted generation: its progress is preserved; offer to resume.
          if (_setup.canResume) ...<Widget>[
            const Divider(height: 32),
            _haltedNotice(),
          ],

          // A halted orbit advance: same deal, screen-owned.
          if (_canResumeAdvance) ...<Widget>[
            const Divider(height: 32),
            _haltedAdvanceNotice(),
          ],

          // Inline editor for importing a stage-0 orbit board's point.
          if (_boardImportSlot != null) ...<Widget>[
            const Divider(height: 32),
            _boardImportEditor(),
          ],

          // Inline editor for replacing the displayed stage's point by import.
          if (_pointImportStage != null) ...<Widget>[
            const Divider(height: 32),
            _pointImportEditor(),
          ],

          // Inline editor for importing the points of an expansion's new stages.
          if (_expandImportTarget != null) ...<Widget>[
            const Divider(height: 32),
            _expandImportEditor(),
          ],

          // Truncation: delete the displayed stage and every stage above it.
          if (_setup.canTruncateFromDisplayed) ...<Widget>[
            const Divider(height: 32),
            _truncateControl(),
          ],

          // The cold-start recall walk shows a per-stage hint while the user
          // clicks their points back. There is no select-mode toggle: a recall
          // session selects implicitly (the answer is hidden), and a
          // generated/imported setup displays its points, so there is nothing to
          // practise.
          if (_selectMode &&
              !_setup.isTextStage &&
              _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            const Divider(height: 32),
            Text(
              _expandManualActive
                  ? 'Adding Stage ${_setup.displayStageIndex}/'
                      '${_expandManualTarget ?? _setup.nStages - 1} — click your '
                      'point on this fractal; the next stage then derives '
                      'automatically.'
                  : 'Recalling Stage ${_setup.displayStageIndex}/'
                      '${_setup.nStages - 1} — click your point to mark it, then '
                      'select the next stage (tab or number key) to derive it.',
            ),
          ],

          // Master-secret export — offered at every non-0 stage in every mode
          // (generation, import, recall) the moment the stage is resolved, not
          // only at the end. Exports exactly the prefix fixed so far.
          if (_setup.canExportMasterAt(_setup.displayStageIndex) &&
              _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            const Divider(height: 32),
            ..._masterExportControls(),
          ],

          // Blind BIP39 export of the seed recalled so far — recall only (it
          // needs the decoded points). Available at every recall stage once a
          // point is back; before the final stage it is a partial,
          // shorter-than-standard seed.
          if (_setup.canExport &&
              _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            const Divider(height: 32),
            Text(
              'Blind copy — partial seed',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${_setup.recalledStageCount}/${_setup.nStages - 1} points '
              'recalled (${_setup.recalledBitCount} bits). Until the final '
              'stage this is a non-standard, shorter — therefore weaker — seed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _bip39CopyButton(),
          ],

          // Provisional-key save / load: an encrypted on-disk copy of the setup
          // for the consolidation window. Save needs a settled setup — an orbit
          // one, or a legacy chain one (halted chains save as resumable); Load
          // is offered on the config screen too (to restore one).
          if (_vaultPanelShown) ...<Widget>[
            const Divider(height: 32),
            _vaultControls(),
          ],

          const Divider(height: 32),

          OutlinedButton.icon(
            onPressed: _busy ? null : _reset,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
          ),

          const Divider(height: 32),
          // Colour wheel: focus with C, cycle hues with ← →. The scheme name is
          // shown in the console (focus _Field.hue), not labelled here. No rotate
          // buttons — the arrows replace them.
          Center(
            child: _track(
              _Field.hue,
              _HueWheelControl(
                value: _hue,
                focusNode: _hueFocus,
                onChanged: (HueOffset h) {
                  _sounds.play(UiSound.click);
                  setState(() => _hue = h);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'engine ${widget.core.engineVersion}',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  List<Widget> _configControls() {
    // The legacy 0.3.0 chain is deprecated (a single 32-bit point per stage is
    // too weak), so Setup is orbit-only: this panel shows just the shared
    // configuration — σ (Stage-0 salt/pepper), the Argon2 profile, calibration
    // and D. Points are placed on the boards (R / N / I); there is no chain
    // source selector or start button any more.
    return <Widget>[
      ..._stage0Input(),
      const SizedBox(height: 16),
      _argon2ProfileSlider(),
      const SizedBox(height: 16),
      _calibrateButton(),
      const SizedBox(height: 16),
      ..._iterationsInput(),
      if (_setup.phase == SetupPhase.error && _setup.errorMessage != null) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          _setup.errorMessage!,
          style: const TextStyle(color: Colors.redAccent),
        ),
      ],
      // Leaf-area / island enumeration feedback (the `E` action): "too many",
      // "no islands", or nothing while islands are shown.
      if (_setup.islandStatus != null) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          _setup.islandStatus!,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    ];
  }

  /// A fixed-width label placed to the left of a slider, so the label adds no
  /// vertical height (layout stays put) and never shifts horizontally.
  Widget _sliderLabel(String text) => SizedBox(
        width: 58,
        child: Text(text, style: Theme.of(context).textTheme.labelMedium),
      );

  /// Free numeric input for **N**, the per-stage Argon2 iteration count. The
  /// range is essentially 0..∞ — a deliberately heavy setup may take hours,
  /// days, or weeks to derive — so there is no upper cap, only a digit limit
  /// guarding the int parse. Larger N ⇒ proportionally longer derivation. (The
  /// time a given N takes drifts with hardware; N itself is exact and
  /// reproducible — see docs §"time is a perishable label on a durable
  /// parameter".)
  /// Open the spacious Argon2 calibration dialog (Alt+D). It benchmarks on this
  /// device, solves the iteration count N for a chosen target time, and — on
  /// Apply — returns N, which we write into the derivation-steps field. Exit is
  /// Esc + confirm (handled inside the dialog).
  Future<void> _openCalibrationDialog() async {
    if (_busy || _hasSession) return;
    final int profileIdx =
        _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
    final int? n = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => _CalibrationDialog(
        core: widget.core,
        sounds: _sounds,
        profile: _profile,
        profileLabel: _profileLabels[profileIdx],
        initialStages: _pointStages,
      ),
    );
    if (!mounted || n == null) return;
    setState(() {
      _iterations = n;
      _iterationsField.text = n.toString();
    });
    _sounds.play(UiSound.confirm);
  }

  /// Panel affordance that opens the calibration dialog (same as Alt+D).
  Widget _calibrateButton() {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: (_busy || _hasSession) ? null : _openCalibrationDialog,
        icon: const Icon(Icons.timer_outlined, size: 18),
        label: const Text('Calibrate derivation time…  (Alt+D)'),
      ),
    );
  }

  List<Widget> _iterationsInput() {
    final String raw = _iterationsField.text.trim();
    final bool invalid = raw.isNotEmpty && !_iterationsValid;
    // Label/help live in the console (focus _Field.iterations); keep only the
    // field (with its validation error) in the panel.
    return <Widget>[
      _track(
        _Field.iterations,
        TextField(
          controller: _iterationsField,
          focusNode: _iterationsFocus,
          enabled: !_busy,
          maxLines: 1,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(12),
          ],
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: 'Derivation steps / stage',
            hintText: 'e.g. 1',
            errorText: invalid ? 'Enter a whole number (0 or more).' : null,
          ),
          onChanged: (_) {
            _sounds.play(UiSound.tickSoft);
            final int? v = int.tryParse(_iterationsField.text.trim());
            if (v != null && v >= 0 && v != _iterations) {
              _iterations = v;
              // The checkpoint's `pass` is relative to D; a new D orphans it.
              _clearAdvanceCheckpoint();
            }
            setState(() {});
          },        ),
      ),
    ];
  }

  /// The three Argon2 memory profiles in ascending cost, paired with their
  /// slider labels (`Argon2Profile` order == ascending GiB).
  static const List<Argon2Profile> _profiles = <Argon2Profile>[
    Argon2Profile.basic,
    Argon2Profile.advanced,
    Argon2Profile.greatWall,
  ];
  static const List<String> _profileLabels = <String>[
    'Basic — 1 GiB',
    'Advanced — 32 GiB',
    'Great Wall — 128 GiB',
  ];

  /// The Argon2 memory profile, chosen on a three-stop slider rather than a
  /// dropdown so the memory cost reads as one escalating axis next to the
  /// iteration-count (N) field.
  Widget _argon2ProfileSlider() {
    final int idx = _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
    // Profile name lives in the console (focus _Field.profile); the slider thumb
    // label still shows it on drag.
    return _track(
      _Field.profile,
      Row(
        children: <Widget>[
          _sliderLabel('Memory'),
          Expanded(
            child: Slider(
              focusNode: _profileFocus,
              value: idx.toDouble(),
              min: 0,
              max: (_profiles.length - 1).toDouble(),
              divisions: _profiles.length - 1,
              label: _profileLabels[idx],
              onChanged: _busy
                  ? null
                  : (double v) {
                      final Argon2Profile next = _profiles[v.round()];
                      if (next == _profile) return;
                      _sounds.play(UiSound.tickSoft);
                      setState(() => _profile = next);
                    },
            ),
          ),
        ],
      ),
    );
  }


  /// The Stage-0 salt/pepper field: obscured by default with a reveal toggle,
  /// constrained to a safe ASCII subset (uppercase letters, digits, hyphen).
  /// One field, one scheme — the user decides whether it is a public label or a
  /// secret pepper. The restriction (and why it exists) is explained inline.
  List<Widget> _stage0Input() {
    // Label/help live in the console (focus _Field.salt). The reveal toggle and
    // the restriction warning stay on the field.
    return <Widget>[
      _track(
        _Field.salt,
        TextField(
          controller: _stage0,
          focusNode: _stage0Focus,
          obscureText: _stage0Hidden,
          enabled: !_busy,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: <TextInputFormatter>[
            _SaltPepperFormatter(widget.core, _onStage0Restricted),
          ],
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: 'Stage 0 — salt / pepper',
            hintText: 'e.g. MAIN-STASH',
            suffixIcon: IconButton(
              tooltip: _stage0Hidden ? 'Show text' : 'Hide text',
              icon: Icon(
                _stage0Hidden ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () => setState(() => _stage0Hidden = !_stage0Hidden),
            ),
          ),
          style: const TextStyle(
            fontFamily: GreatWallTypography.fontFamily,
            fontFamilyFallback: <String>['monospace'],
          ),
          onChanged: (_) {
            _sounds.play(UiSound.tickSoft);
            setState(() {});
          },        ),
      ),
      // The formatting warning (when the engine adjusts the text) is conveyed on
      // the console, which expands and pops to the foreground — see
      // _onStage0Restricted / _warnOnConsole.
    ];
  }

  /// Controls shown during a cold-start recall walk (select mode on). The
  /// select-mode switch, the per-stage recall hint, the blind-copy export and
  /// Reset all live in the always-shown section below.
  List<Widget> _recallControls() {
    return <Widget>[
      const Text('Recall your points'),
      const SizedBox(height: 8),
      Text(
        'Select mode is on. Click your memorised point to mark it, then select '
        'the next stage (its tab or number key) to derive that fractal (the '
        'same Argon2 cost as setup). Nothing is shown — the seed is rebuilt only '
        'from your clicks.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  List<Widget> _memoriseControls() {
    // The "what to do" guidance lives in the console now (see _memoriseHelp), so
    // the panel stays a stable, compact action surface.
    return <Widget>[
      FilledButton(
        onPressed: () {
          _sounds.play(UiSound.confirm);
          _setup.finish();
        },
        child: const Text('I have memorised them'),
      ),
    ];
  }

  List<Widget> _recallCompleteControls() {
    return <Widget>[
      Row(
        children: <Widget>[
          const Icon(Icons.verified, color: Color(0xFF00E676)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Recall complete',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        'Every stage was selected back and the seed was reconstructed from '
        'your points. It is never shown on screen — the buttons below copy it '
        'straight to the clipboard so you can paste it blind into another '
        "wallet's import wizard and continue without ever reading it.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      _bip39CopyButton(),
      const SizedBox(height: 24),
      ..._masterExportControls(),
      const SizedBox(height: 24),
      FilledButton(onPressed: _reset, child: const Text('Done')),
    ];
  }

  /// A subtle, non-blocking notice while later stages derive in the background
  /// (or a one-line warning if a background derivation failed). The stages
  /// already derived are fully navigable meanwhile; focus stays put.
  Widget _generationNotice() {
    final String? err = _setup.generationError;
    if (err != null) {
      return Text(err, style: const TextStyle(color: Colors.orangeAccent));
    }
    final int total = _setup.nStages - 1;
    // Progress now reads off the stage-tab strip (the deriving stage's box
    // fills), so this notice is just the explanatory line.
    return Text(
      'Deriving stage ${_setup.generatingStage}/$total in the background — '
      'the stages already done are ready to study now.'
      '${_setup.canExportResumable ? ' Write (W) snapshots the progress so far '
          'to resume in a later session.' : ''}',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  /// The halted-derivation notice: how much of the stalled stage was preserved,
  /// and a button to resume it (and the rest of the chain).
  Widget _haltedNotice() {
    final int k = _setup.haltedStage;
    final int last = _setup.nStages - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Halted at Stage $k/$last — pass ${_setup.haltedPass}/'
          '${_setup.haltedTotal} kept. Resume picks up where it stopped'
          '${_setup.canExportResumable ? ', or Write (W) saves it to resume in a '
              'later session (the file then holds the seed — guard it).' : '.'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _resumeDerivation,
          icon: const Icon(Icons.play_arrow),
          label: Text('Resume Stage $k'),
        ),
      ],
    );
  }

  void _resumeDerivation() {
    _sounds.play(UiSound.select);
    _setup.resumeDerivation();
  }

  /// The orbit peer of [_haltedNotice]: a halted advance's preserved passes, and
  /// the button that continues from them.
  Widget _haltedAdvanceNotice() {
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    if (cp == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Advance into Stage ${cp.stage} halted — pass ${cp.pass}/$_iterations '
          'kept. Resume continues from there; Write (W) saves it so a later '
          'session can (the file then holds the partial derivation — guard it). '
          'Changing D, or re-placing a point below Stage ${cp.stage}, discards it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () {
            _sounds.play(UiSound.select);
            unawaited(_resumeOrbitAdvance());
          },
          icon: const Icon(Icons.play_arrow),
          label: Text('Resume Stage ${cp.stage}'),
        ),
      ],
    );
  }

  // --- Orbit provisional key: capture / write / restore ----------------------
  // The orbit peer of SetupController's chain vault. It lives on the screen
  // because the orbit state does: σ, D, P, r_i, o_i and the placed points are
  // all screen-owned fields (none of them go through the controller), so an
  // orbit save/load that routed through SetupController would have to mirror
  // them first. See next-steps/orbit-save-load-and-cpnf-rederivation-plan.md §3.

  /// The single failure message every vault open reports. A wrong key, a corrupt
  /// file, a chain/orbit mix-up and a doctored payload MUST be indistinguishable
  /// — otherwise someone holding the file learns from probing it whether a
  /// candidate key was right. (GCM authentication already makes the first two
  /// identical; this keeps the parse failures from breaking that.)
  static const String _vaultOpaqueError =
      'Could not open — wrong key, or not a setup file.';

  /// The deepest orbit stage the forward advance has actually reached: stage 0
  /// (always rooted by σ) until an advance produces `o_1`, then the highest
  /// contiguous `o_i`. This is the last stage a save has to carry.
  int get _orbitDeepestStage => _orbitReachableCeiling;

  /// Whether the screen-owned orbit setup is **settled**, and so can be written
  /// as an [OrbitVault]: σ parses, and the deepest reached stage has its `r_i`
  /// fractals placed (`K_i` derived — which, since re-placing a point
  /// cascade-invalidates the deeper `o_i`, implies every shallower stage is
  /// settled too). Deliberately cheap: it parses σ but never runs `orbitRoot`,
  /// so it is safe in `build` and in the hotkey gate.
  ///
  /// Settled-only by design. A halted, mid-advance orbit needs a checkpointable
  /// engine advance and is deferred (Role 1 of
  /// `next-steps/orbit-persistence-and-provisional-key-roles.md`).
  bool get _orbitSettled {
    final Uint8List? sigma = _parseHex(_sigmaCtrl.text.trim());
    if (sigma == null || sigma.isEmpty) return false;
    return _orbitK[_orbitDeepestStage] != null;
  }

  /// Capture the settled orbit setup as an [OrbitVault] — pure, synchronous and
  /// read straight off the screen-owned state, with no [SetupController] call.
  ///
  /// Stage 0's `o₀` is omitted (it re-derives from σ) and the derived slots are
  /// omitted (they re-derive from the placed ones), so the file carries only
  /// what a restore cannot recompute cheaply: the `o_i` that would otherwise
  /// cost a memory-hard advance each, and the points only the holder knows.
  ///
  /// The result **is the secret** — the caller MUST [OrbitVault.wipe] it.
  OrbitVault _exportOrbitVault() {
    final int deepest = _orbitDeepestStage;
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    return OrbitVault(
      sigma: _sigmaCtrl.text.trim().replaceAll(RegExp(r'\s'), ''),
      iterations: _iterations,
      profile: _profile,
      // A halted advance rides along, so reopening the file continues from the
      // pass it reached instead of restarting the stage. Only carried while it
      // still applies (see [_canResumeAdvance]).
      resume: cp != null && _canResumeAdvance
          ? OrbitVaultResume(
              stage: cp.stage,
              pass: cp.pass,
              digest: List<int>.of(cp.digest),
            )
          : null,
      stages: <OrbitVaultStage>[
        for (int i = 0; i <= deepest; i++)
          OrbitVaultStage(
            required: _requiredFractals[i],
            orbit: i == 0 ? null : List<int>.of(_orbitO[i]!),
            points: <OrbitVaultPoint>[
              for (int s = 1; s <= _maxSlot; s++)
                if (_boardPoints[i][s] != null && !_boardDerived[i][s])
                  OrbitVaultPoint(
                    slot: s,
                    reRaw: _boardPoints[i][s]!.reRaw,
                    imRaw: _boardPoints[i][s]!.imRaw,
                  ),
            ],
          ),
      ],
    );
  }

  /// Write the settled orbit setup to [path], encrypted under the provisional
  /// key — the orbit peer of `SetupController.saveVaultToFile`, and the reason
  /// the screen does its own file I/O: it is the screen that owns the state.
  ///
  /// The write is **atomic** (temp file + rename). Phase 2 re-writes this same
  /// file on every graded card, and a half-written vault is an unopenable one.
  /// Uses [providedKey] (the user's own entropy) if given, else a fresh
  /// [genLenBytes]-byte key. The captured vault is wiped on every path.
  Future<({String? error, Uint8List? key})> _saveOrbitVaultToFile(
    String path, {
    Uint8List? providedKey,
    int genLenBytes = SetupCrypto.keyLenBytes,
  }) async {
    if (!_orbitSettled) {
      return (error: 'This setup cannot be saved yet.', key: null);
    }
    final OrbitVault vault = _exportOrbitVault();
    final File tmp = File('$path.tmp');
    try {
      final SealedVault sealed = await SetupCrypto.sealPayload(
        vault.toJson(),
        providedKey: providedKey,
        genLenBytes: genLenBytes,
      );
      await tmp.writeAsBytes(sealed.fileBytes, flush: true);
      await tmp.rename(path);
      return (error: null, key: sealed.key);
    } catch (e) {
      // Best effort: never leave the partial temp behind. It is ciphertext, but
      // a stale `.tmp` beside the vault is confusing at best.
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // Nothing more to do — the save has already failed.
      }
      return (error: 'Could not save the file (${e.runtimeType}).', key: null);
    } finally {
      vault.wipe();
    }
  }

  /// Restore a settled orbit setup from [vault] **into orbit mode** — never into
  /// the legacy chain `memorise` session, so no [SetupController] state is
  /// touched and the deprecated recall walk stays unreachable from a load.
  ///
  /// The mirror of [_exportOrbitVault]: each `o_i` comes straight out of the
  /// file (stage 0's from σ), each stored point is cheap-decoded back to its
  /// 32-bit chunk under `(o,p,q) = orbitParams(o_i, slot-1)`, and
  /// [_recomputeExtraShares] then re-interpolates `Sh_i`, recomputes
  /// `K_i = H(o_i ‖ Sh_i)` and re-derives the unplaced slots — exactly what a
  /// live placement does, so a restored setup and a freshly built one are the
  /// same state. **No Argon2 pass runs.**
  ///
  /// Integrity is the envelope's job, not re-derivation's: the AEAD tag
  /// authenticates the whole payload, so a stored `o_i` cannot have been
  /// tampered with independently of the points. There is deliberately **no**
  /// cheap `o_i == H*(K_{i-1})` check — that check *is* the memory-hard advance
  /// this file exists to skip. (Phase 2's re-derivation walk performs it as a
  /// side effect; that is where it becomes an error locator.)
  ///
  /// Returns null on success, else a message. Nothing is applied unless every
  /// stage validated and every stored point decoded, so a failed restore leaves
  /// the current setup untouched. The caller owns and wipes [vault].
  Future<String?> _restoreOrbitVault(OrbitVault vault) async {
    final Uint8List? sigma = _parseHex(vault.sigma);
    if (sigma == null || sigma.isEmpty) return _vaultOpaqueError;
    final int deepest = vault.stages.length - 1;
    if (deepest < 0 || deepest > _maxStage) return _vaultOpaqueError;

    // Validate the whole file and resolve every stage's o_i and board
    // reservoirs first — the decode below is the expensive part, and a partial
    // restore of a bad file must never reach the screen state.
    final List<Uint8List> orbits = <Uint8List>[];
    final List<List<int>> pointsRaw = <List<int>>[];
    final List<List<int>> reservoirs = <List<int>>[];
    final List<({int stage, int slot})> targets = <({int stage, int slot})>[];
    final OrbitProtocol protocol = OrbitProtocol(widget.core);
    for (int i = 0; i <= deepest; i++) {
      final OrbitVaultStage stage = vault.stages[i];
      if (stage.required < 1 || stage.required > _maxSlot) {
        return _vaultOpaqueError;
      }
      final List<int>? oI = stage.orbit;
      if (i == 0) {
        // σ is o₀'s only source; a file that also carries one disagrees with
        // itself about the root and is rejected rather than silently preferred.
        if (oI != null) return _vaultOpaqueError;
        orbits.add(widget.core.orbitRoot(sigma));
      } else {
        if (oI == null || oI.isEmpty) return _vaultOpaqueError;
        orbits.add(Uint8List.fromList(oI));
      }
      // Under r_i placed points Sh_i is not fixed, so the stage would restore
      // unsettled — and any deeper stage's o_i would then have no derivation.
      if (stage.points.length < stage.required) return _vaultOpaqueError;
      final Set<int> seenSlots = <int>{};
      for (final OrbitVaultPoint point in stage.points) {
        if (point.slot < 1 ||
            point.slot > _maxSlot ||
            !seenSlots.add(point.slot)) {
          return _vaultOpaqueError;
        }
        final ({int o, int p, int q}) prm =
            protocol.orbitParams(orbits[i], point.slot - 1);
        pointsRaw.add(<int>[point.reRaw, point.imRaw]);
        reservoirs.add(<int>[prm.o, prm.p, prm.q]);
        targets.add((stage: i, slot: point.slot));
      }
    }

    // One decodeFull per placed point, over every stage, is seconds of CPU — it
    // runs in a worker isolate behind the _vaultBusy spinner, or opening a file
    // freezes the app.
    List<List<int>?> decoded;
    try {
      decoded = await widget.core.decodePoints(pointsRaw, reservoirs);
    } catch (_) {
      return _vaultOpaqueError;
    }
    // A point that does not decode under its own stage's reservoirs means the
    // file and the engine disagree — a wrong-protocol or doctored file. Nothing
    // is applied then, and the chunks decoded so far are wiped rather than left
    // to the collector; the same holds if the screen went away mid-decode.
    if (!mounted ||
        decoded.length != targets.length ||
        decoded.contains(null)) {
      for (final List<int>? bits in decoded) {
        if (bits != null) Entropy.wipe(bits);
      }
      return _vaultOpaqueError;
    }

    setState(() {
      // Drop whatever is on the boards now: a restore replaces the orbit, and a
      // leftover placement from another σ would neither decode nor be visible.
      _clearOrbitPlacements();
      _sigmaCtrl.text = vault.sigma;
      _iterations = vault.iterations;
      _iterationsField.text = '${vault.iterations}';
      _profile = vault.profile;
      for (int i = 0; i <= deepest; i++) {
        _requiredFractals[i] = vault.stages[i].required;
        // o₀ is never stored: [_stageOrbit] re-derives it from σ on demand.
        if (i >= 1) _orbitO[i] = orbits[i];
      }
      for (int k = 0; k < targets.length; k++) {
        final ({int stage, int slot}) t = targets[k];
        _boardChunks[t.stage][t.slot] = decoded[k]!; // owns the bits
        _boardPoints[t.stage][t.slot] =
            (reRaw: pointsRaw[k][0], imRaw: pointsRaw[k][1]);
        _boardDerived[t.stage][t.slot] = false;
      }
      // Every o_i is in place above, so each stage can now re-interpolate its
      // own Sh_i, recompute K_i and kick off the derived slots' marker encode.
      for (int i = 0; i <= deepest; i++) {
        _recomputeExtraShares(i);
      }
      // A halted advance, if the file carried one. Accepted only when it still
      // fits the restored setup: deriving into the next stage, stopped
      // part-way through this file's own D. K_{stage-1} is not read from the
      // file — [_recomputeExtraShares] above has just rebuilt it from the
      // placed points, which is why the checkpoint need not carry a key.
      final OrbitVaultResume? r = vault.resume;
      if (r != null &&
          r.stage == deepest + 1 &&
          r.pass >= 1 &&
          r.pass < vault.iterations &&
          _orbitK[deepest] != null) {
        _advanceCheckpoint = (
          stage: r.stage,
          pass: r.pass,
          digest: Uint8List.fromList(r.digest),
        );
      }
    });
    _setOrbitStage(deepest);
    return null;
  }

  /// Provisional-key save / load: an encrypted on-disk copy of the setup, kept
  /// only across the memorisation window and destroyed at graduation.
  Widget _vaultControls() {
    final bool canSave =
        _orbitSettled || _setup.canExportVault || _setup.canExportResumable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Heading + explanation live in the console (focus _Field.vault); the
        // panel keeps only the inputs and actions for a stable layout.
        _track(
          _Field.vault,
          TextField(
            controller: _vaultPath,
            focusNode: _vaultPathFocus,
            enabled: !_vaultBusy,
            maxLines: 1,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'File path  (F)',
              hintText: '/path/to/setup.gwvault',
            ),
          ),
        ),
        const SizedBox(height: 8),
        // The provisional key is entered / shown / copied only inside the
        // Write and Open dialogs — never in a panel field — so it is never an
        // idle on-screen artifact. F focuses the path; W writes; O opens; T
        // prints a blank template.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            // Always present (greyed out when there is nothing to save yet) so
            // the panel layout stays stable.
            FilledButton.icon(
              onPressed: (_vaultBusy || !canSave) ? null : _writeSetup,
              icon: const Icon(Icons.save_alt),
              label: const Text('Write (save)  (W)'),
            ),
            OutlinedButton.icon(
              onPressed: _vaultBusy ? null : _openSetup,
              icon: const Icon(Icons.lock_open),
              label: const Text('Open setup file  (O)'),
            ),
            OutlinedButton.icon(
              onPressed: _vaultBusy ? null : _exportBlankTemplate,
              icon: const Icon(Icons.print),
              label: const Text('Blank templates  (T)'),
            ),
            if (_vaultBusy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ],
    );
  }

  /// Move keyboard focus to the vault file-path field (F).
  void _focusVaultPath() => _focusField(_vaultPathFocus, 'vault file path');

  /// Whether the provisional-key panel is on screen — the config screen (to open
  /// a saved setup) or a settled setup, orbit or legacy chain (to write one).
  /// Gates the F/W/O/T keys.
  bool get _vaultPanelShown =>
      _orbitSettled ||
      _setup.phase == SetupPhase.idle ||
      _setup.canExportVault ||
      _setup.canExportResumable;

  /// Write (save) the settled setup to the file path, encrypted under a fresh
  /// app-generated 128-bit key, then open the key dialog (W). The key can be
  /// overridden with the user's own entropy from inside that dialog.
  ///
  /// A settled **orbit** setup writes an [OrbitVault] off the screen state; the
  /// legacy chain path stays on [SetupController] while it survives as the
  /// porting reference. The orbit takes precedence — the two cannot both be
  /// settled, since orbit placement never enters a chain session.
  Future<void> _writeSetup() async {
    final bool orbit = _orbitSettled;
    if (!orbit && !_setup.canExportVault && !_setup.canExportResumable) {
      _sounds.play(UiSound.denyInput);
      _toast('Finish a setup first — there is nothing to write yet.');
      return;
    }
    final String path = _vaultPath.text.trim();
    if (path.isEmpty) {
      _sounds.play(UiSound.denyInput);
      _toast('Enter a file path.');
      return;
    }
    setState(() => _vaultBusy = true);
    final ({String? error, Uint8List? key}) result = orbit
        ? await _saveOrbitVaultToFile(path)
        : await _setup.saveVaultToFile(path);
    if (!mounted) return;
    setState(() => _vaultBusy = false);
    if (result.error != null || result.key == null) {
      _sounds.play(UiSound.denyInput);
      _toast(result.error ?? 'Could not save.');
      return;
    }
    _sounds.play(UiSound.exportOk);
    await _showKeyDialog(path, result.key!, orbit: orbit);
  }

  /// Open (load) a saved setup from the file path (O): scan the QR (Q) or type
  /// the 32- or 64-hex key (Alt+Q focuses the field, Enter loads), Esc to
  /// cancel. The key is never displayed.
  Future<void> _openSetup() async {
    final String path = _vaultPath.text.trim();
    if (path.isEmpty) {
      _sounds.play(UiSound.denyInput);
      _toast('Enter a file path.');
      return;
    }
    final bool canScan = _scanSupported || _desktopScanSupported;
    final TextEditingController hexInput = TextEditingController();
    final FocusNode hexFocus = FocusNode(debugLabel: 'open-hex');
    Uint8List? keyBytes;

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        void loadHex() {
          try {
            keyBytes = SetupCrypto.hexToKey(hexInput.text);
          } on FormatException catch (e) {
            _sounds.play(UiSound.denyInput);
            _toast(e.message);
            return;
          }
          Navigator.of(ctx).pop();
        }

        Future<void> scan() async {
          final Uint8List? k = await _scanKey();
          if (k == null) return;
          keyBytes = k;
          if (ctx.mounted) Navigator.of(ctx).pop();
        }

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            if (canScan) const SingleActivator(LogicalKeyboardKey.keyQ): scan,
            const SingleActivator(LogicalKeyboardKey.keyQ, alt: true): () =>
                hexFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(ctx).pop(),
          },
          child: Focus(
            autofocus: true,
            child: AlertDialog(
              title: const Text('Open setup file'),
              content: SizedBox(
                width: 340,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      canScan
                          ? 'Q — scan the QR with the camera.  Alt+Q — type the '
                              '32- or 64-hex key instead.  Esc — cancel.'
                          : 'Alt+Q — type the 32- or 64-hex key (live scanning '
                              'needs a camera this platform does not expose).  '
                              'Esc — cancel.',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: hexInput,
                      focusNode: hexFocus,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLines: 1,
                      onSubmitted: (_) => loadHex(),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        labelText: 'Key — 32 or 64 hex digits',
                        hintText: 'paste from your manager, then Enter',
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                if (canScan)
                  TextButton.icon(
                    onPressed: scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan (Q)'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: loadHex,
                  child: const Text('Load'),
                ),
              ],
            ),
          ),
        );
      },
    );
    hexInput.dispose();
    hexFocus.dispose();
    if (!mounted || keyBytes == null) return;
    await _loadWithBytes(path, keyBytes!);
  }

  /// Scan the provisional-key QR, returning the 16 raw key bytes or null. Uses
  /// `mobile_scanner` where it has a backend, else the flutter_webrtc + zxing2
  /// desktop scanner.
  Future<Uint8List?> _scanKey() => _desktopScanSupported
      ? DesktopKeyScanner.show(context)
      : _scanWithMobileScanner();

  /// The `mobile_scanner` dialog (Android / iOS / macOS): returns the 16 raw key
  /// bytes from the QR's byte segment, or null if cancelled.
  Future<Uint8List?> _scanWithMobileScanner() async {
    Uint8List? keyBytes;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Scan provisional key'),
        content: SizedBox(
          width: 320,
          height: 320,
          child: MobileScanner(
            onDetect: (BarcodeCapture capture) {
              if (keyBytes != null || capture.barcodes.isEmpty) return;
              final Uint8List? raw = capture.barcodes.first.rawBytes;
              if (raw == null || !SetupCrypto.isValidKeyLen(raw.length)) return;
              keyBytes = Uint8List.fromList(raw);
              Navigator.of(ctx).pop();
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    return keyBytes;
  }

  /// Shared decrypt+restore from a file path and 16- or 32-byte key, wiping the
  /// key. The heavy part (the Argon2 key derivation, and an orbit restore's
  /// per-point decode) runs behind the [_vaultBusy] spinner.
  Future<void> _loadWithBytes(String path, Uint8List keyBytes) async {
    setState(() => _vaultBusy = true);
    final String? err = await _openVaultFile(path, keyBytes);
    _wipeBytes(keyBytes);
    if (!mounted) return;
    setState(() => _vaultBusy = false);
    if (err != null) {
      _sounds.play(UiSound.denyInput);
      _toast(err);
      return;
    }
    _sounds.play(UiSound.confirm);
    _toast('Setup loaded.');
  }

  /// Decrypt the file at [path] with [keyBytes] and restore whichever setup it
  /// holds, returning null on success or a message on failure.
  ///
  /// The payload's `kind` picks the branch: `'orbit'` restores the screen-owned
  /// orbit setup ([_restoreOrbitVault]); an absent `kind` is a legacy 0.3.0
  /// chain [SetupVault] and takes the unchanged [SetupController] path. Every
  /// failure after the file is read reports the same [_vaultOpaqueError], so a
  /// wrong key, a corrupt file and a chain/orbit mix-up are indistinguishable.
  /// The caller owns and wipes [keyBytes].
  Future<String?> _openVaultFile(String path, Uint8List keyBytes) async {
    if (!SetupCrypto.isValidKeyLen(keyBytes.length)) return _vaultOpaqueError;
    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      // Not a secret-bearing distinction: whether the path exists is knowable
      // without the key, and saying so is the difference between a typo the user
      // can fix and one they cannot.
      return 'Could not read that file.';
    }
    Map<String, dynamic> payload;
    try {
      payload = await SetupCrypto.openPayload(bytes, keyBytes);
    } catch (_) {
      return _vaultOpaqueError;
    }
    if (payload[OrbitVault.kindKey] == OrbitVault.kind) {
      OrbitVault vault;
      try {
        vault = OrbitVault.fromJson(payload);
      } catch (_) {
        return _vaultOpaqueError;
      }
      try {
        return await _restoreOrbitVault(vault);
      } finally {
        vault.wipe();
      }
    }
    SetupVault chain;
    try {
      chain = SetupVault.fromJson(payload);
    } catch (_) {
      return _vaultOpaqueError;
    }
    try {
      if (chain.resume != null) {
        _setup.restoreResumableVault(chain); // halted — restore + offer Resume
      } else {
        _setup.restoreVault(chain);
      }
      return null;
    } catch (_) {
      return _vaultOpaqueError;
    } finally {
      chain.wipe();
    }
  }

  /// After a write, present the provisional [keyBytes] for the file at [path]:
  /// reveal the byte-mode v1 QR to hand-copy (Q), copy the 32-hex key blind to
  /// the clipboard for a password manager (Alt+Q), or overwrite the key with the
  /// user's own 32-hex entropy (I focuses the field, Enter applies). Esc closes.
  /// The key is never shown as text — only as a QR or copied blind — and the
  /// in-memory copy is wiped when the dialog closes.
  ///
  /// [orbit] says which writer the dialog's re-seals go back through, so the
  /// 128↔256 toggle and the own-key/scanned-key paths rewrite the same kind of
  /// vault the initial write produced.
  Future<void> _showKeyDialog(String path, Uint8List keyBytes,
      {required bool orbit}) async {
    Uint8List key = keyBytes;
    int keyLen = key.length; // 16 (128-bit) or 32 (256-bit)
    qr.QrImage matrix = _keyMatrix(key);
    final bool canScan = _scanSupported || _desktopScanSupported;
    bool showQr = false;
    bool copiedOnce = false;
    bool busy = false;
    final TextEditingController hexInput = TextEditingController();
    final FocusNode hexFocus = FocusNode(debugLabel: 'write-hex');

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setLocal) {
          void copyHex() {
            Clipboard.setData(ClipboardData(text: SetupCrypto.keyToHex(key)));
            _toast('${keyLen * 8}-bit key copied. The clipboard is not '
                'air-gapped — clear it after pasting into your manager.');
          }

          // Re-seal the file with either the user's own key or a fresh
          // [newLen]-byte generated key, overwriting the previous key + file,
          // and redraw. Shared by the 128↔256 toggle and the own-key path.
          Future<bool> reseal({Uint8List? ownKey, required int newLen}) async {
            setLocal(() => busy = true);
            final ({String? error, Uint8List? key}) r = orbit
                ? await _saveOrbitVaultToFile(path,
                    providedKey: ownKey, genLenBytes: newLen)
                : await _setup.saveVaultToFile(path,
                    providedKey: ownKey, genLenBytes: newLen);
            if (ownKey != null) _wipeBytes(ownKey);
            if (!ctx.mounted) return false;
            if (r.error != null || r.key == null) {
              setLocal(() => busy = false);
              _sounds.play(UiSound.denyInput);
              _toast(r.error ?? 'Could not save.');
              return false;
            }
            _wipeBytes(key); // drop the superseded key
            _sounds.play(UiSound.exportOk);
            setLocal(() {
              key = r.key!;
              keyLen = key.length;
              matrix = _keyMatrix(key);
              busy = false;
            });
            return true;
          }

          int otherLen() => keyLen == SetupCrypto.keyLenBytes
              ? SetupCrypto.keyLenBytes256
              : SetupCrypto.keyLenBytes;

          Future<void> applyOwnKey() async {
            Uint8List ownKey;
            try {
              ownKey = SetupCrypto.hexToKey(hexInput.text);
            } on FormatException catch (e) {
              _sounds.play(UiSound.denyInput);
              _toast(e.message);
              return;
            }
            if (await reseal(ownKey: ownKey, newLen: ownKey.length)) {
              setLocal(hexInput.clear);
              _toast('Re-saved with your own ${keyLen * 8}-bit key.');
            }
          }

          // Scan an existing provisional-key QR and re-seal the file under it,
          // so saving the same setup again reuses the QR you already
          // hand-coloured instead of producing a fresh code to copy. The scanned
          // bytes are validated as a key length before use, and wiped by reseal.
          Future<void> scanOwnKey() async {
            if (busy) return;
            final Uint8List? scanned = await _scanKey();
            if (scanned == null) return;
            if (!SetupCrypto.isValidKeyLen(scanned.length)) {
              _wipeBytes(scanned);
              _sounds.play(UiSound.denyInput);
              _toast('That QR is not a valid provisional key.');
              return;
            }
            if (await reseal(ownKey: scanned, newLen: scanned.length)) {
              _toast('Re-saved with the scanned key — your existing QR still '
                  'opens this file.');
            }
          }

          // Q reveals the QR; pressing it again switches 128↔256 (a fresh key,
          // overwriting the file). Alt+Q copies; pressing it again switches too.
          void onShowQr() {
            if (busy) return;
            if (!showQr) {
              setLocal(() => showQr = true);
            } else {
              reseal(newLen: otherLen());
            }
          }

          void onCopy() {
            if (busy) return;
            if (!copiedOnce) {
              copyHex();
              setLocal(() => copiedOnce = true);
            } else {
              reseal(newLen: otherLen()).then((bool ok) {
                if (ok && ctx.mounted) copyHex();
              });
            }
          }

          final int version = keyLen > SetupCrypto.keyLenBytes ? 2 : 1;
          return CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.keyQ): onShowQr,
              const SingleActivator(LogicalKeyboardKey.keyQ, alt: true): onCopy,
              // I — scan an existing QR to reuse its key; Alt+I — type your own
              // hex key. (I is a no-op where no camera backend exists.)
              if (canScan)
                const SingleActivator(LogicalKeyboardKey.keyI): scanOwnKey,
              const SingleActivator(LogicalKeyboardKey.keyI, alt: true): () =>
                  hexFocus.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(ctx).pop(),
            },
            child: Focus(
              autofocus: true,
              child: AlertDialog(
                title: Text('Provisional key — ${keyLen * 8}-bit'),
                content: SizedBox(
                  width: 340,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Text(
                          'Saved. Keep the key OFFLINE and destroy it at '
                          'graduation (shred / burn). Lose it and the file is '
                          'unrecoverable — that is the point.',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Q — show the QR to hand-copy onto a printed blank '
                          'template (T).  Alt+Q — copy the key for a password '
                          'manager (blind).  Press Q or Alt+Q again to switch to '
                          '${otherLen() * 8}-bit (a fresh key, overwriting the '
                          'file).  '
                          '${canScan ? 'I — scan an existing QR to reuse its key '
                              '(re-seals this setup under it).  ' : ''}'
                          'Alt+I — type your own 32- or 64-hex key (Enter).  '
                          'Esc — close.',
                          style: const TextStyle(fontSize: 11),
                        ),
                        if (showQr) ...<Widget>[
                          const SizedBox(height: 12),
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(12),
                              child: CustomPaint(
                                size: const Size(252, 252),
                                painter: _QrPainter(matrix, _QrView.scan),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${keyLen * 8}-bit · QR v$version. Do this alone, no '
                            'cameras. At EC-L the code still scans with up to ~2 '
                            'stray mis-coloured cells, so work carefully.',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: hexInput,
                          focusNode: hexFocus,
                          enabled: !busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLines: 1,
                          onSubmitted: (_) => applyOwnKey(),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            labelText:
                                'Your own key — 32 or 64 hex digits (optional)',
                            hintText: 'from dice etc., then Enter to apply',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: <Widget>[
                  TextButton.icon(
                    onPressed: busy ? null : onShowQr,
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(showQr ? 'Switch bits (Q)' : 'Show QR (Q)'),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : onCopy,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy key (Alt+Q)'),
                  ),
                  if (canScan)
                    TextButton.icon(
                      onPressed: busy ? null : scanOwnKey,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan to reuse (I)'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    hexInput.dispose();
    hexFocus.dispose();
    _wipeBytes(key); // recorded or abandoned — drop our copy
  }

  /// Byte-mode QR matrix for a provisional key: v1 (21×21) for the 16-byte
  /// key, v2 (25×25) for the 32-byte 256-bit key, both at EC level L.
  qr.QrImage _keyMatrix(Uint8List key) {
    final int version = key.length > SetupCrypto.keyLenBytes ? 2 : 1;
    return qr.QrImage(
      qr.QrCode(version, qr.QrErrorCorrectLevel.L)
        ..addByteData(ByteData.sublistView(key)),
    );
  }

  static void _wipeBytes(Uint8List b) {
    for (int i = 0; i < b.length; i++) {
      b[i] = 0;
    }
  }

  /// Export both reusable **blank** hand-fill templates (the key-independent
  /// skeleton: finders, timing, dark module, the v2 alignment pattern, over a
  /// highlighted module grid) as PNGs in the vault path's folder — one per key
  /// size, named `128-bit-…` / `256-bit-provisional-key-qr-template.png` so the
  /// size leads the file name. They hold no secret; print and hand-colour.
  Future<void> _exportBlankTemplate() async {
    final String base = _vaultPath.text.trim();
    if (base.isEmpty) {
      _sounds.play(UiSound.denyInput);
      _toast('Enter a file path first; the templates save in its folder.');
      return;
    }
    final String dir = File(base).parent.path;
    final String sep = Platform.pathSeparator;
    try {
      final List<String> saved = <String>[];
      for (final int lenBytes in <int>[
        SetupCrypto.keyLenBytes,
        SetupCrypto.keyLenBytes256,
      ]) {
        final Uint8List png = await _renderBlankTemplatePng(lenBytes);
        final String name =
            '${lenBytes * 8}-bit-provisional-key-qr-template.png';
        await File('$dir$sep$name').writeAsBytes(png, flush: true);
        saved.add(name);
      }
      if (!mounted) return;
      _sounds.play(UiSound.exportOk);
      _toast('Blank templates saved in $dir: ${saved.join(', ')}');
    } catch (e) {
      if (mounted) _toast('Could not save the templates (${e.runtimeType}).');
    }
  }

  /// Render the blank hand-fill skeleton PNG for a [lenBytes]-byte key (v1 for
  /// 16, v2 for 32). A dummy all-zero key yields only the module geometry; only
  /// the key-independent cells are drawn, so it leaks nothing.
  Future<Uint8List> _renderBlankTemplatePng(int lenBytes) async {
    final qr.QrImage matrix = _keyMatrix(Uint8List(lenBytes));
    // 24 px per module, including the painter's 4-module quiet zone each side.
    final int px = (matrix.moduleCount + 2 * _QrPainter.quiet) * 24;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    _QrPainter(matrix, _QrView.blank)
        .paint(canvas, Size(px.toDouble(), px.toDouble()));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(px, px);
    final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (png == null) throw StateError('template render failed');
    return png.buffer.asUint8List();
  }

  /// Common message tail for a point edit: what gets discarded above stage [k].
  String _editTail(int k) {
    final int last = _setup.nStages - 1;
    return k < last ? ' and discard Stages ${k + 1}–$last' : '';
  }

  /// Change the displayed stage's point to fresh random entropy (the `N` edit).
  Future<void> _changePointGenerated() async {
    final int k = _setup.displayStageIndex;
    final bool ok = await _consoleConfirm(
      message: 'Replace Stage $k\'s point with new random entropy'
          '${_editTail(k)}? This cannot be undone.',
      confirmLabel: 'Replace',
    );
    if (!ok || !mounted || !_setup.canEditCurrentPoint) return;
    _setup.changeCurrentPointGenerated();
    _sounds.play(UiSound.changePoint);
    _toast('Stage $k point regenerated.');
  }

  /// Arm the manual point edit (the `R` edit): the next canvas click sets the
  /// new point for the displayed stage.
  Future<void> _changePointManual() async {
    final int k = _setup.displayStageIndex;
    final bool ok = await _consoleConfirm(
      message: 'Click a new point for Stage $k${_editTail(k)}? '
          'This cannot be undone.',
      confirmLabel: 'Pick new point',
    );
    if (!ok || !mounted || !_setup.canEditCurrentPoint) return;
    setState(() => _editPointMode = true);
    _sounds.play(UiSound.click);
    _toast('Click the new point on Stage $k (Esc to cancel).');
  }

  /// Open the inline bit editor to replace the displayed stage's point by import
  /// (the `I` edit): 3 words → 32 bits (plain I) or 8 hex digits (Alt+I). The
  /// format toggle in the editor still lets the user switch after opening.
  Future<void> _changePointImport({required bool hex}) async {
    final int k = _setup.displayStageIndex;
    final bool ok = await _consoleConfirm(
      message: 'Replace Stage $k\'s point by import${_editTail(k)}? '
          'This cannot be undone.',
      confirmLabel: 'Import',
    );
    if (!ok || !mounted || !_setup.canEditCurrentPoint) return;
    _pointImport.clear();
    setState(() {
      _pointImportFmt = hex ? _ImportFormat.hex : _ImportFormat.words;
      _pointImportStage = k;
    });
    _pointImportFocus.requestFocus();
  }

  void _applyPointImport() {
    final String text = _pointImport.text;
    final String? err = _pointImportFmt == _ImportFormat.hex
        ? _setup.changeCurrentPointHex(text)
        : _setup.changeCurrentPointWords(text);
    if (err != null) {
      _sounds.play(UiSound.denyInput);
      _toast(err);
      return;
    }
    final int k = _setup.displayStageIndex;
    _cancelPointImport();
    _sounds.play(UiSound.changePoint);
    _toast('Stage $k point changed.');
  }

  void _cancelPointImport() {
    _pointImport.clear();
    setState(() => _pointImportStage = null);
    _focusViewer();
  }

  /// The inline editor shown while replacing a stage's point by import.
  Widget _pointImportEditor() {
    final int k = _pointImportStage!;
    return _importEditorBody(
      title: 'Import a new point for Stage $k${_editTail(k)}.',
      words: 3,
      hexDigits: 8,
      onApply: _applyPointImport,
      onCancel: _cancelPointImport,
    );
  }

  /// The inline editor shown while importing the points for an expansion's new
  /// stages: one point per added stage ([m] points → 3·m words / 8·m hex).
  Widget _expandImportEditor() {
    final int g = _expandImportTarget!;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    return _importEditorBody(
      title: 'Import $m point${m == 1 ? '' : 's'} for new '
          'Stage${m == 1 ? ' $g' : 's $firstNew–$g'}.',
      words: 3 * m,
      hexDigits: 8 * m,
      onApply: _applyExpandImport,
      onCancel: _cancelExpandImport,
    );
  }

  /// Shared inline import editor: a Words/Hex toggle, a masked field, and
  /// Apply/Cancel. [words]/[hexDigits] size the labels for the expected bit
  /// count (one point = 3 words / 8 hex; m points scale both). Reused by the
  /// single-point I edit and the multi-point import expansion (mutually
  /// exclusive, so they share [_pointImport] / [_pointImportFocus]).
  Widget _importEditorBody({
    required String title,
    required int words,
    required int hexDigits,
    required VoidCallback onApply,
    required VoidCallback onCancel,
  }) {
    final bool hex = _pointImportFmt == _ImportFormat.hex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        SegmentedButton<_ImportFormat>(
          segments: <ButtonSegment<_ImportFormat>>[
            ButtonSegment<_ImportFormat>(
                value: _ImportFormat.words, label: Text('$words words')),
            ButtonSegment<_ImportFormat>(
                value: _ImportFormat.hex, label: Text('$hexDigits hex')),
          ],
          selected: <_ImportFormat>{_pointImportFmt},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (Set<_ImportFormat> s) {
            setState(() {
              _pointImportFmt = s.first;
              _pointImport.clear();
            });
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pointImport,
          focusNode: _pointImportFocus,
          obscureText: _mnemonicHidden,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: hex
              ? <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                  TextInputFormatter.withFunction(
                    (TextEditingValue o, TextEditingValue n) =>
                        n.copyWith(text: n.text.toUpperCase()),
                  ),
                ]
              : null,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: hex ? '$hexDigits hex digits' : '$words words',
            hintText: hex ? 'A1B2C3D4' : 'word word word',
            suffixIcon: IconButton(
              tooltip: _mnemonicHidden ? 'Show' : 'Hide',
              icon: Icon(
                _mnemonicHidden ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () =>
                  setState(() => _mnemonicHidden = !_mnemonicHidden),
            ),
          ),
          onChanged: (_) {
            _sounds.play(UiSound.tickSoft);
            setState(() {});
          },
          onSubmitted: (_) => onApply(),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            FilledButton(onPressed: onApply, child: const Text('Apply')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }

  // --- Expansion (grow the setup with more point stages) ---------------------

  /// Open the method picker (in the console) to grow the setup to [g] point
  /// stages: New (random), Import, or Manual. No-op unless the setup can grow.
  void _beginExpand(int g) {
    if (!_setup.canExpand ||
        g < _setup.firstExpansionStage ||
        g > SetupController.maxPointStages) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    // The expansion editors are mutually exclusive with the point-edit one.
    if (_pointImportStage != null) _cancelPointImport();
    setState(() {
      _expandImportTarget = null;
      _expandTarget = g;
    });
    _sounds.play(UiSound.navStage);
  }

  /// Expand with fresh random points for every new stage (the N method), behind
  /// a console confirmation (each new stage costs a full derivation).
  Future<void> _expandNew() async {
    final int? g = _expandTarget;
    if (g == null) return;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    setState(() => _expandTarget = null);
    final bool ok = await _consoleConfirm(
      message: 'Add $m new stage${m == 1 ? '' : 's'} '
          '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'}) with fresh random '
          'points? Each derives in turn (~the usual per-stage time).',
      confirmLabel: 'Add',
    );
    if (!ok || !mounted || !_setup.canExpand) return;
    _setup.expandGenerated(g);
    _sounds.play(UiSound.confirm);
    _toast('Deriving $m new stage${m == 1 ? '' : 's'} '
        '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'})…');
  }

  /// Switch from the picker to the inline import editor (the I method), in
  /// [hex] or words.
  void _expandImport({required bool hex}) {
    final int? g = _expandTarget;
    if (g == null) return;
    _pointImport.clear();
    setState(() {
      _pointImportFmt = hex ? _ImportFormat.hex : _ImportFormat.words;
      _expandTarget = null;
      _expandImportTarget = g;
    });
    _pointImportFocus.requestFocus();
  }

  void _applyExpandImport() {
    final int g = _expandImportTarget!;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    final String text = _pointImport.text;
    final String? err = _pointImportFmt == _ImportFormat.hex
        ? _setup.expandImportedHex(g, text)
        : _setup.expandImportedWords(g, text);
    if (err != null) {
      _sounds.play(UiSound.denyInput);
      _toast(err);
      return;
    }
    _cancelExpandImport();
    _sounds.play(UiSound.confirm);
    _toast('Deriving $m new stage${m == 1 ? '' : 's'} '
        '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'})…');
  }

  void _cancelExpandImport() {
    _pointImport.clear();
    setState(() => _expandImportTarget = null);
    _focusViewer();
  }

  /// The console method picker shown while an expansion target is chosen.
  Widget _expandPickerBlock() {
    final int g = _expandTarget!;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Add $m new stage${m == 1 ? '' : 's'} '
            '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'}) — choose how to fill '
            'the new point${m == 1 ? '' : 's'}:'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            _expandPickButton('New (N)', _expandNew),
            _expandPickButton('Import (I)', () => _expandImport(hex: false)),
            _expandPickButton('Manual (R)', _expandManual),
            _expandPickButton('Cancel (Esc)', _cancelExpand),
          ],
        ),
      ],
    );
  }

  Widget _expandPickButton(String label, VoidCallback onTap) => TextButton(
        style: TextButton.styleFrom(foregroundColor: _kConsoleFg),
        onPressed: onTap,
        child: Text(label),
      );

  void _cancelExpand() {
    setState(() => _expandTarget = null);
    _focusViewer();
  }

  /// Grow the setup by hand (the R method): derive each new stage in turn and
  /// click its point on the fresh fractal. Confirms first, grows empty stages,
  /// enables canvas selection, and derives the first new stage; each click then
  /// advances to the next ([_onCanvasSelect]).
  Future<void> _expandManual() async {
    final int? g = _expandTarget;
    if (g == null) return;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    setState(() => _expandTarget = null);
    final bool ok = await _consoleConfirm(
      message: 'Add $m new stage${m == 1 ? '' : 's'} '
          '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'}) by hand? Each derives in '
          'turn; click your chosen point on every new fractal.',
      confirmLabel: 'Add',
    );
    if (!ok || !mounted || !_setup.canExpand) return;
    _setup.beginManualExpansion(g);
    setState(() {
      _expandManualActive = true;
      _expandManualTarget = g;
      _selectMode = true; // enable canvas point selection on the new stages
    });
    _sounds.play(UiSound.confirm);
    await _deriveNextStage(); // derive Stage firstNew; the user clicks its point
  }

  /// Leave manual-expansion mode (completed or cancelled), disabling selection.
  void _endManualExpand() {
    setState(() {
      _expandManualActive = false;
      _expandManualTarget = null;
      _selectMode = false;
    });
  }

  /// Truncation control: exclude the displayed stage and every stage above it.
  /// The explanation lives in the console (focus _Field.truncate); the panel
  /// keeps only the action button for a stable, compact layout.
  Widget _truncateControl() {
    final int k = _setup.displayStageIndex;
    return Align(
      alignment: Alignment.centerLeft,
      child: _track(
        _Field.truncate,
        OutlinedButton.icon(
          onPressed: _truncate,
          icon: const Icon(Icons.content_cut),
          label: Text('Exclude Stage $k & above (X)'),
        ),
      ),
    );
  }

  /// Exclude the displayed stage and every stage above it. Bound to the `X`
  /// hotkey and the truncate button; denies when the displayed stage cannot be
  /// truncated (Stage 0, or a not-yet-settled / recall setup).
  Future<void> _truncate() async {
    if (!_setup.canTruncateFromDisplayed) {
      _sounds.play(UiSound.deny);
      return;
    }
    final int k = _setup.displayStageIndex;
    final int last = _setup.nStages - 1;
    final String kept =
        k == 1 ? 'only the salt/pepper text' : 'Stages 0–${k - 1}';
    final bool ok = await _consoleConfirm(
      message: k == last
          ? 'Exclude Stage $k? The setup keeps $kept. This cannot be undone.'
          : 'Exclude Stages $k–$last? The setup keeps $kept. '
              'This cannot be undone.',
      confirmLabel: 'Exclude',
    );
    if (!ok || !mounted) return;
    _setup.truncateFrom(k);
    _sounds.play(UiSound.undo);
    _toast(k - 1 >= 1
        ? 'Excluded — setup now has ${k - 1} stage${k - 1 == 1 ? '' : 's'}.'
        : 'Excluded down to the salt/pepper text (no point stages).');
  }

  /// Exclude the current orbit stage and every deeper one (the `X` hotkey while
  /// building the orbit). Keeps Stages 0..k-1 and lands on the new terminal
  /// (k-1); Stage 0 (the σ root) cannot be excluded. The deeper `o_i`/`K_i` and
  /// their placed points are wiped ([_invalidateDeeperThan]).
  Future<void> _truncateOrbit() async {
    final int k = _orbitStage;
    if (k < 1) {
      _sounds.play(UiSound.deny);
      _toast('Stage 0 is the orbit root — it cannot be excluded.');
      return;
    }
    final bool ok = await _consoleConfirm(
      message: 'Exclude Stage $k and every stage below it? The orbit keeps '
          'Stages 0–${k - 1}, whose K becomes the wallet key. This cannot be '
          'undone.',
      confirmLabel: 'Exclude',
    );
    if (!ok || !mounted) return;
    setState(() {
      _invalidateDeeperThan(k - 1); // wipe stage k and every deeper stage
      _orbitStage = k - 1;
      _editPointMode = false;
      _boardImportSlot = null;
      _boardIslands = const <CanvasIsland>[];
      _boardDecoCache.clear();
      _boardCanonicalView = false;
      _boardKey = '';
    });
    _recenter();
    _sounds.play(UiSound.undo);
    _toast('Excluded — the orbit now ends at Stage ${k - 1}.');
  }

  /// The blind BIP39 seed-phrase copy. Operates on whatever has been recalled so
  /// far via [SetupController.exportMnemonic]; shown only where a decoded seed
  /// exists (the recall partial export and the recall-complete panel).
  Widget _bip39CopyButton() {
    return OutlinedButton.icon(
      onPressed: _copyMnemonic,
      icon: const Icon(Icons.content_copy),
      label: const Text('Copy seed phrase (BIP39)'),
    );
  }

  /// The master-secret export affordances for the **currently displayed** stage:
  /// an explanation, the optional per-stage export-label field (restricted
  /// `[A-Z0-9-]`, versioning the key), and the blind copy. The Argon2id pass
  /// covers stages `1..displayStageIndex` (DESIGN.md §"Master-Secret Export").
  List<Widget> _masterExportControls() {
    // Heading + explanation live in the console (focus _Field.exportLabel).
    return <Widget>[
      _track(
        _Field.exportLabel,
        TextField(
          controller: _exportLabel,
          focusNode: _exportLabelFocus,
          enabled: !_busy,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: <TextInputFormatter>[
            _SaltPepperFormatter(widget.core, _onExportLabelRestricted),
          ],
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            labelText: 'Export salt (optional)',
            hintText: 'e.g. SIGNING-1',
          ),
          style: const TextStyle(
            fontFamily: GreatWallTypography.fontFamily,
            fontFamilyFallback: <String>['monospace'],
          ),
          onChanged: (_) {
            _sounds.play(UiSound.tickSoft);
            setState(() {});
          },
        ),
      ),
      // Formatting warning is conveyed on the console (see
      // _onExportLabelRestricted / _warnOnConsole).
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: (_busy || _exporting) ? null : _copyMasterSecret,
        icon: _exporting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.content_copy),
        label: Text(_exporting ? 'Deriving…' : 'Copy key (K)'),
      ),
    ];
  }

  Future<void> _copyMnemonic() async {
    final String? mnemonic = _setup.exportMnemonic();
    if (mnemonic == null) {
      _sounds.play(UiSound.deny);
      return;
    }
    await Clipboard.setData(ClipboardData(text: mnemonic));
    if (!mounted) return;
    _sounds.play(UiSound.exportOk);
    // Confirmation never echoes the secret itself.
    _toast('Seed phrase copied — paste it into your wallet, then clear the '
        'clipboard.');
  }

  /// Export and copy the master secret for the focused stage. `K` copies the
  /// conventional first-32-chars view; `Alt+K` ([full]) copies the entire digest
  /// (all [MasterSecret.outputBytes] as hex).
  Future<void> _copyMasterSecret({bool full = false}) async {
    if (_exporting) return;
    // On an orbit board the "master secret" is the cheap per-stage `K_i`
    // (no Argon2id transcript pass); route to the orbit export.
    if (_isBoardSlot) {
      await _copyOrbitMaster(full: full);
      return;
    }
    final int idx = _setup.displayStageIndex;
    setState(() => _exporting = true);
    // The Argon2id pass runs off the UI isolate, so this awaits; the finally
    // clears the in-flight flag even if it fails, and we re-check `mounted`
    // after the await before touching the clipboard or UI.
    String? secret;
    try {
      secret = await _setup.exportMasterSecret(
        stageIndex: idx,
        label: _exportLabel.text,
        full: full,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    if (!mounted) return;
    if (secret == null) {
      _sounds.play(UiSound.deny);
      return;
    }
    final int chars = secret.length;
    await Clipboard.setData(ClipboardData(text: secret));
    if (!mounted) return;
    _sounds.play(UiSound.exportOk);
    // Confirmation never echoes the secret itself.
    _toast(full
        ? 'Full key copied ($chars chars) — paste it, then clear the clipboard.'
        : 'Key copied — paste it, then clear the clipboard.');
  }

  /// Copy the active orbit stage's master secret `K_i` to the clipboard, reusing
  /// the same field, hotkeys and button as the legacy export. An empty export-salt
  /// label copies `K_i` itself; a non-empty one copies the domain-separated
  /// `H(K_i ‖ label)` (the demoted `[A-Z0-9-]` pepper — one setup, many keys).
  /// `K` copies the conventional first-32-hex view; `Alt+K` ([full]) the whole
  /// digest. Cheap `H` throughout — no Argon2id pass, so no deriving spinner.
  /// Entropy actually behind the exported key at [stage]: the placed points,
  /// `Σ r_j × 32` bits over stages `0..stage`. This is what an attacker must
  /// guess; the 512-bit state and the copied view can each *cap* what is
  /// carried, never raise it.
  int _placedEntropyBits(int stage) {
    int bits = 0;
    for (int i = 0; i <= stage && i <= _maxStage; i++) {
      bits += _requiredFractals[i] * EncodingConstants.bitsPerPoint;
    }
    return bits;
  }

  /// One-line entropy readout for the export surfaces: how much is usable, and
  /// which of the three limits is binding. [viewBits] is what the copied form
  /// actually carries (4 bits per hex digit).
  ///
  /// Stated because the conventional 32-digit view is a *display* convention
  /// inherited from the 1024-byte Argon2id export, not a statement about the
  /// key — so the figure a holder is relying on is not otherwise visible.
  String _exportEntropyNote(int stage, int viewBits) {
    final int placed = _placedEntropyBits(stage);
    const int stateBits = kOrbitPointLen * 8;
    final int usable = math.min(placed, math.min(viewBits, stateBits));
    final String limit = usable == placed
        ? 'your placed points'
        : usable == viewBits
            ? 'this view — Alt+K copies all $stateBits bits'
            : 'the orbit state';
    return '$usable bits usable at stage $stage '
        '($placed placed, $viewBits in this view; limited by $limit)';
  }

  Future<void> _copyOrbitMaster({bool full = false}) async {
    final Uint8List? ki = _activeK;
    if (ki == null) {
      _sounds.play(UiSound.deny);
      return;
    }
    final String label = widget.core.canonicalizeSaltPepper(_exportLabel.text);
    // Canonical `[A-Z0-9-]` is pure ASCII, so the code units are the bytes.
    // The export derivation is applied for EVERY label including the empty one,
    // so K_i itself is never handed out — `K_i^L = TH(export-label, K_i ‖ L)`.
    final Uint8List key =
        widget.core.exportKey(ki, Uint8List.fromList(label.codeUnits));
    final String secret =
        full ? MasterSecret.fullHex(key) : MasterSecret.displayHex(key);
    // Wipe the derived key (never K_i, which is state).
    Entropy.wipe(key);
    final int chars = secret.length;
    await Clipboard.setData(ClipboardData(text: secret));
    if (!mounted) return;
    _sounds.play(UiSound.exportOk);
    // Confirmation never echoes the secret itself — only how much of it there is.
    _toast('${full ? 'Full key' : 'Key'} copied ($chars chars) — '
        '${_exportEntropyNote(_activeStage, chars * 4)}.'
        '${_activeStage == 0 ? ' Stage 0 is σ-public and its points are assumed'
            ' seizable, so this key carries no coercion resistance.' : ''}'
        ' Paste it, then clear the clipboard.');
  }

  /// Append a line to the console log (the app's toast surface).
  void _toast(String msg) {
    if (!mounted) return;
    setState(() {
      _consoleLog.add(msg);
      if (_consoleLog.length > 50) _consoleLog.removeRange(0, _consoleLog.length - 50);
    });
  }

  /// Surface a warning on the console and make sure it is seen: expand the
  /// console and hide the hotkey manual so the message leads, then log it.
  void _warnOnConsole(String message) {
    if (!mounted) return;
    setState(() {
      _chromeMinimized = false; // expand the console
      _manualVisible = false; // hide the hotkeys menu so the warning leads
    });
    _toast(message);
  }

  /// Set the focus-help line when a control gains focus. Deferred to a
  /// post-frame callback so it never runs mid-build (focus changes fire during
  /// layout).
  void _gainFocus(_Field f) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusedField == f) return;
      setState(() => _focusedField = f);
    });
  }

  /// Clear the focused-field marker when a control loses focus — but only if it
  /// is still this control (so the gain of the next control wins regardless of
  /// callback order).
  void _loseFocus(_Field f) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusedField != f) return;
      setState(() => _focusedField = null);
    });
  }

  /// Wrap [child] so that, while it (or a descendant text field/slider) holds
  /// focus, the console shows field [f]'s help. The wrapper is not a tab stop.
  Widget _track(_Field f, Widget child) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool has) => has ? _gainFocus(f) : _loseFocus(f),
      child: child,
    );
  }

  /// The console help for an input field: its label plus the current value, so
  /// the panel itself can omit both. Computed live, so it tracks edits while the
  /// field stays focused.
  String _fieldHelp(_Field f) {
    switch (f) {
      case _Field.stages:
        return 'Number of stages: $_pointStages (0–4). 0 = Stage-0 text only; '
            '4 = 12 words / 128 bits. ← → or drag to change.';
      case _Field.iterations:
        final String n = _iterationsField.text.trim();
        return 'Derivation steps per stage (D) = ${n.isEmpty ? '—' : n} (0…∞): '
            'the memory-hard passes each stage runs — the orbit advance '
            'oᵢ₊₁ = H*(Kᵢ), and the legacy chain alike. Higher = longer, '
            'stronger (hours to weeks); 0 = instant pass-through (dev only, not '
            'memory-hard).';
      case _Field.profile:
        final int idx =
            _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
        return 'Argon2 profile: ${_profileLabels[idx]} — memory per pass. '
            '← → or drag to change.';
      case _Field.salt:
        return 'Stage 0 salt/pepper: seeds the fractal chain. A public label or '
            'a secret pasted pepper (uppercase letters, digits, hyphen).';
      case _Field.mnemonic:
        if (_importFormat == _ImportFormat.hex) {
          final int digits = _mnemonic.text.replaceAll(RegExp(r'\s'), '').length;
          if (digits == 0) {
            return 'Import hex: paste uppercase 0–9 A–F from a randomness source '
                'you trust over the device (kept hidden). 8 digits = one stage.';
          }
          if (digits % 8 != 0) {
            return 'Import hex: $digits digits — must be a multiple of 8 '
                '(8 = 32 bits = one stage).';
          }
          return 'Import hex: $digits digits → ${digits ~/ 8} stages.';
        }
        final int wc = _mnemonic.text
            .trim()
            .split(RegExp(r'\s+'))
            .where((String w) => w.isNotEmpty)
            .length;
        if (wc == 0) {
          return 'Import phrase: type or paste your existing BIP39 seed phrase '
              '(kept hidden). 3 words = one stage.';
        }
        if (wc % 3 != 0 || wc > 24) {
          return 'Import phrase: $wc words — must be a multiple of 3 (3–24).';
        }
        final bool standard = <int>{12, 15, 18, 21, 24}.contains(wc);
        return 'Import phrase: $wc words → ${wc ~/ 3} stages'
            '${standard ? '' : ' (sub-standard length)'}.';
      case _Field.exportLabel:
        if (_isBoardSlot) {
          return 'Key (master-secret export): this stage’s orbit key '
              'Kᵢ = TH(tag, oᵢ ‖ Shᵢ), fixed once rᵢ fractals are placed and '
              'domain-separated from the orbit advance — leaking it does not '
              'expose the stages above. What you copy is Kᵢ salted by the label '
              'below. '
              '${_exportEntropyNote(_activeStage, MasterSecret.displayChars * 4)}. '
              'Paste into another wallet or use as a downstream pepper. The '
              'optional salt versions the key (e.g. SIGNING-1, '
              'uppercase/digits/hyphen). Press K to copy — blind, never shown.';
        }
        final int idx = _setup.displayStageIndex;
        return 'Key (master-secret export): Argon2id over your setup so far '
            '(stages 1–$idx). Paste into another wallet or use as a downstream '
            'pepper. This optional salt versions the key (e.g. SIGNING-1, '
            'uppercase/digits/hyphen). Press K to derive and copy — blind, '
            'never shown.';
      case _Field.hue:
        return 'Colour scheme: ${_hue.name}. ← → to cycle through the six hues.';
      case _Field.vault:
        return 'Provisional key: encrypt this setup to a file (AES-256-GCM) for '
            'the memorisation window — a transient crutch, not a backup; delete '
            'it at graduation. Protect it with your own password (managed/deleted '
            'in a password manager) or an app-generated key shown as a small QR '
            'to print and keep OFFLINE. The file is useless without its secret.';
      case _Field.truncate:
        final int k = _setup.displayStageIndex;
        final int last = _setup.nStages - 1;
        return k == last
            ? 'Shorten the setup by excluding this last stage (Stage $k), '
                'keeping Stages 0–${k - 1}. Cannot be undone.'
            : 'Shorten the setup: exclude Stage $k and every stage above it '
                '(Stages $k–$last), keeping Stages 0–${k - 1}. Cannot be undone.';
    }
  }

  /// Answer the pending console confirmation, completing its future.
  void _resolvePrompt(bool ok) {
    final _ConsolePrompt? p = _prompt;
    if (p == null) return;
    setState(() => _prompt = null);
    if (!p.completer.isCompleted) p.completer.complete(ok);
  }

  /// Reset behind an inline console confirmation, so the Z hotkey (or a stray
  /// keypress) cannot discard a setup by accident.
  Future<void> _confirmReset() async {
    final bool ok = await _consoleConfirm(
      message: 'Reset and discard the current setup? Un-memorised points and '
          'any entered text will be lost.',
      confirmLabel: 'Reset',
    );
    if (ok && mounted) _reset();
  }

  /// Halt a running derivation behind a console confirmation (the A hotkey).
  /// Kills only the current Argon2 pass; every completed intermediary digest of
  /// the working stage is kept, as are the stages already derived. No-op with a
  /// deny cue when nothing is deriving.
  Future<void> _abortDerivation() async {
    if (!_busy && !_setup.isGenerating) {
      _sounds.play(UiSound.deny);
      return;
    }
    final bool ok = await _consoleConfirm(
      message: 'Halt the running derivation? Only the current pass (~1 min) is '
          'dropped — every digest completed so far on this stage is kept, and '
          'the stages already derived stay usable.',
      confirmLabel: 'Halt',
    );
    if (ok && mounted && (_busy || _setup.isGenerating)) {
      _setup.halt();
      _toast('Halted — progress kept.');
    }
  }

  void _reset() {
    _sounds.play(UiSound.click);
    _resolvePrompt(false); // drop any pending console confirmation
    _setup.reset();
    _brightness.reset();
    _viewport.viewport = _initialViewport;
    _mnemonic.clear();
    _stage0.clear();
    _exportLabel.clear();
    setState(() {
      _selectMode = false;
      _stage0Hidden = true;
      _exportLabelRestricted = false;
    });
    _focusViewer(); // back on the config screen; hotkeys act on the viewer
  }
}


/// A stage-0 board's canonical-island decoration: the island cells plus its
/// bounding box (fractal coords), used to draw the square frame and to size the
/// cross↔square switch. The orbit peer of SetupController's `_IslandDeco`.
class _BoardDeco {
  const _BoardDeco({
    required this.cells,
    required this.reMin,
    required this.reMax,
    required this.imMin,
    required this.imMax,
    required this.escapeCount,
  });

  final CanvasIsland cells;
  final double reMin;
  final double reMax;
  final double imMin;
  final double imMax;

  /// The island's (uniform) escape count — every cell of a canonical island
  /// shares one escape count. Used to compute the brightness offset that lifts
  /// the island to at least half brightness in the canonical view.
  final int escapeCount;
}

/// How imported entropy is entered: BIP39 words, or blind uppercase hex (for
/// users who trust an external randomness source over the device RNG).
enum _ImportFormat { words, hex }

/// The input controls whose label + live value are conveyed in the console while
/// focused (so the panel itself can stay label-free).
enum _Field {
  stages,
  iterations,
  profile,
  salt,
  mnemonic,
  exportLabel,
  hue,
  vault,
  truncate,
}

/// A compact, focusable colour wheel: six hue sectors, no rotate buttons (←/→
/// cycle while focused) and no inline name (it is shown in the console). Tapping
/// a sector selects it and focuses the wheel.
class _HueWheelControl extends StatelessWidget {
  const _HueWheelControl({
    required this.value,
    required this.onChanged,
    required this.focusNode,
  });

  final HueOffset value;
  final ValueChanged<HueOffset> onChanged;
  final FocusNode focusNode;
  final double diameter = 84;

  void _step(int dir) {
    const List<HueOffset> order = HueOffset.values;
    final int i = (value.index + dir) % order.length;
    onChanged(order[i < 0 ? i + order.length : i]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Let the V + ↑/↓ volume chord bubble up to the screen handler instead of
    // cycling the hue, so volume works the same while the wheel holds focus.
    if (HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.keyV)) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowDown) {
      _step(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTapDown(TapDownDetails details) {
    final double r = diameter / 2;
    final Offset v = details.localPosition - Offset(r, r);
    if (v.distance < r * 0.25) return; // ignore the hub
    double angle = math.atan2(v.dx, -v.dy);
    if (angle < 0) angle += 2 * math.pi;
    final int n = HueOffset.values.length;
    final int sector = (angle / (2 * math.pi) * n).floor() % n;
    onChanged(HueOffset.values[sector]);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: _onKey,
      child: Semantics(
        label: 'Colour wheel: ${value.name}',
        button: true,
        child: GestureDetector(
          onTapDown: (TapDownDetails d) {
            focusNode.requestFocus();
            _handleTapDown(d);
          },
          child: CustomPaint(
            size: Size.square(diameter),
            painter: _HuePainter(value, focusNode.hasFocus),
          ),
        ),
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter(this.selected, this.focused);

  final HueOffset selected;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final Offset c = Offset(r, r);
    final int n = HueOffset.values.length;
    final double sweep = 2 * math.pi / n;
    for (int i = 0; i < n; i++) {
      final double start = -math.pi / 2 + i * sweep;
      final Paint fill = Paint()
        ..style = PaintingStyle.fill
        ..color = HSVColor.fromAHSV(
          1.0,
          HueOffset.values[i].degrees.toDouble() % 360.0,
          1.0,
          1.0,
        ).toColor();
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: r), start, sweep, true, fill);
      if (HueOffset.values[i] == selected) {
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r - 2),
          start,
          sweep,
          true,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4.0
            ..color = Colors.white,
        );
      }
    }
    if (focused) {
      canvas.drawCircle(
        c,
        r - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = Colors.white70,
      );
    }
    canvas.drawCircle(c, r * 0.22, Paint()..color = Colors.black87);
  }

  @override
  bool shouldRepaint(_HuePainter old) =>
      old.selected != selected || old.focused != focused;
}

/// A confirmation rendered inline in the console (instead of a modal dialog).
/// The console's action buttons complete [completer] with the user's choice.
class _ConsolePrompt {
  _ConsolePrompt({
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.completer,
  });

  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final Completer<bool> completer;
}

/// Maps the number-row and numpad digit keys to a stage index, so pressing a
/// number focuses that stage (when no text field holds the keystroke). Valid
/// stages are 0..4 ([SetupController.maxPointStages]); 5..9 are included so they
/// produce the usual out-of-range cue rather than nothing.
///
/// Not `const`: [LogicalKeyboardKey] has no primitive `==`, so it cannot be a
/// constant map key — a lazily-initialised `final` map is the idiomatic form.
final Map<LogicalKeyboardKey, int> _digitKeys = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.digit0: 0,
  LogicalKeyboardKey.digit1: 1,
  LogicalKeyboardKey.digit2: 2,
  LogicalKeyboardKey.digit3: 3,
  LogicalKeyboardKey.digit4: 4,
  LogicalKeyboardKey.digit5: 5,
  LogicalKeyboardKey.digit6: 6,
  LogicalKeyboardKey.digit7: 7,
  LogicalKeyboardKey.digit8: 8,
  LogicalKeyboardKey.digit9: 9,
  LogicalKeyboardKey.numpad0: 0,
  LogicalKeyboardKey.numpad1: 1,
  LogicalKeyboardKey.numpad2: 2,
  LogicalKeyboardKey.numpad3: 3,
  LogicalKeyboardKey.numpad4: 4,
  LogicalKeyboardKey.numpad5: 5,
  LogicalKeyboardKey.numpad6: 6,
  LogicalKeyboardKey.numpad7: 7,
  LogicalKeyboardKey.numpad8: 8,
  LogicalKeyboardKey.numpad9: 9,
};

/// One numbered stage tab on the upper edge. Highlighted when it is the stage
/// under focus, dimmed and non-interactive when not yet reachable.
/// One stage's box in the top strip. The strip doubles as the derivation
/// progress bar: each box is a stage-sized segment, so filled boxes are elapsed
/// work and empty ones are still to come.
///
/// States: **available/selected** (lit) · **deriving** (filling left→right) ·
/// **pending** — requested but not derived (grey) · **ghost** — a slot outside
/// the current setup (a hollow frame the chain can still grow into).
class _StageTab extends StatelessWidget {
  const _StageTab({
    required this.index,
    required this.inSetup,
    required this.selected,
    required this.available,
    required this.deriving,
    required this.progress,
    required this.tooltip,
    required this.onTap,
  });

  final int index;

  /// Hover label — the stage name, plus its ETA while a chain is deriving.
  final String tooltip;

  /// Whether this stage belongs to the current (or slider-previewed) setup
  /// (`index < nStages`). Out-of-setup slots render as empty ghost frames.
  final bool inSetup;

  final bool selected;
  final bool available;

  /// This stage's fractal is deriving right now: the box fills as [progress].
  final bool deriving;

  /// Fill fraction in [0, 1] while [deriving].
  final double progress;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: deriving ? _derivingFace(scheme) : _restingFace(scheme),
      ),
    );
  }

  /// A non-deriving box: ghost (out of setup), pending (grey), or lit
  /// (available / selected).
  Widget _restingFace(ColorScheme scheme) {
    if (!inSetup) {
      // Ghost: a faint hollow slot — an open quest the chain can grow into.
      return _box(
        bg: Colors.transparent,
        border: scheme.outlineVariant.withValues(alpha: 0.25),
        fg: scheme.onSurface.withValues(alpha: 0.15),
        bold: false,
      );
    }
    final Color fg = selected
        ? scheme.onPrimary
        : available
            ? scheme.onSurface
            : scheme.onSurface.withValues(alpha: 0.35); // pending (requested) grey
    return _box(
      bg: selected ? scheme.primary : Colors.transparent,
      border: selected ? scheme.primary : scheme.outlineVariant,
      fg: fg,
      bold: selected,
    );
  }

  /// The deriving wipe: the left [progress] fraction shows the lit face (dark
  /// digit on the light-blue fill); the rest shows the unlit face (light digit
  /// on transparent). Painting the digit on both faces and clipping at the fill
  /// edge keeps it readable across the boundary — a late-90s scan-line reveal.
  Widget _derivingFace(ColorScheme scheme) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _box(
          bg: Colors.transparent,
          border: scheme.primary,
          fg: scheme.onSurface,
          bold: false,
        ),
        ClipRect(
          clipper: _LeftFractionClipper(progress),
          child: _box(
            bg: scheme.primary,
            border: scheme.primary,
            fg: scheme.onPrimary,
            bold: false,
          ),
        ),
      ],
    );
  }

  Widget _box({
    required Color bg,
    required Color border,
    required Color fg,
    required bool bold,
  }) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          color: fg,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontFamily: GreatWallTypography.fontFamily,
          fontFamilyFallback: const <String>['monospace'],
        ),
      ),
    );
  }
}

/// Clips a child to its left [fraction] of width — the moving edge of a stage
/// tab's derivation fill.
class _LeftFractionClipper extends CustomClipper<Rect> {
  const _LeftFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction.clamp(0.0, 1.0), size.height);

  @override
  bool shouldReclip(_LeftFractionClipper oldClipper) =>
      oldClipper.fraction != fraction;
}

/// Constrains the Stage-0 salt/pepper to a safe, reproducible ASCII subset:
/// uppercase letters, digits and hyphens. Lowercase is upper-cased; anything
/// else (spaces, underscores, punctuation, non-ASCII) is dropped as typed.
///
/// Rather than reimplement the rule, this delegates to the shared engine
/// ([GreatWallCore.canonicalizeSaltPepper], backed by
/// `bs_salt_pepper_canonicalize`) — the *same* canonicalisation that builds the
/// chain seed, so the field shows exactly the bytes that will be hashed. The
/// `[A-Z0-9-]` restriction (DESIGN.md "Strong text restrictions") exists so the
/// text reproduces identically across devices; a stray case/accent/look-alike
/// would silently fork the chain into an unrecoverable result.
///
/// [onResult] is called with whether the engine had to adjust the text, so the
/// field can flag the user — the divergence is never silent.
class _SaltPepperFormatter extends TextInputFormatter {
  _SaltPepperFormatter(this._core, this._onResult);

  final GreatWallCore _core;
  final void Function({required bool adjusted}) _onResult;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String canonical = _core.canonicalizeSaltPepper(newValue.text);
    if (canonical == newValue.text) {
      _onResult(adjusted: false);
      return newValue;
    }
    _onResult(adjusted: true);
    return TextEditingValue(
      text: canonical,
      selection: TextSelection.collapsed(offset: canonical.length),
    );
  }
}

/// Canonical default viewport (constants.py: DEFAULT_CENTER_*, VIEWPORT_BASE_SPAN
/// = 4.0 -> halfExtent 2.0).
const FractalViewport _initialViewport = FractalViewport(
  centreRe: -0.5,
  centreIm: -0.5,
  halfExtent: 2.0,
  widthPx: 1,
  heightPx: 1,
  devicePixelRatio: 1.0,
);

/// Small translucent label shown over the canvas (e.g. the select-mode hint).
class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

/// Paints the provisional-key QR. In **scan** mode it draws the plain scannable
/// code (solid black/white modules) — what the user reveals to hand-copy or to
/// scan back. In **blank** mode it draws the reusable hand-fill skeleton: only
/// the key-independent cells (the three finder patterns + separators, the timing
/// patterns, and the dark module) are inked, every cell sits in a clearly drawn
/// grid so the user can see exactly which squares to colour, and the data/EC
/// cells are left empty to fill in by reading the scan code. (Byte-mode v1 has
/// no alignment patterns.) Both views include the spec's 4-module quiet zone.
class _QrPainter extends CustomPainter {
  _QrPainter(this.image, this.view);

  final qr.QrImage image;
  final _QrView view;

  /// QR spec mandates a clear margin of at least 4 modules around the symbol;
  /// without it decoders often fail to lock onto the finder patterns.
  static const int quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = image.moduleCount; // 21 for version 1
    final double cell = size.width / (n + 2 * quiet);
    final double off = quiet * cell; // top-left offset of the symbol proper
    final Paint inked = Paint()..color = Colors.black;
    // A visible grid so the hand-filler can tell the module divisions apart.
    final Paint grid = Paint()
      ..color = const Color(0xFF9E9E9E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        final Rect rect = Rect.fromLTWH(off + c * cell, off + r * cell, cell, cell);
        final bool dark = image.isDark(r, c);
        switch (view) {
          case _QrView.scan:
            if (dark) canvas.drawRect(rect, inked);
          case _QrView.blank:
            // Key-independent skeleton only — the user inks the rest by hand,
            // reading the scan code, guided by the highlighted module grid.
            if (dark && _isFixed(r, c, n)) canvas.drawRect(rect, inked);
            canvas.drawRect(rect, grid);
        }
      }
    }
  }

  /// Key-independent modules: the three 8×8 finder+separator corners, the timing
  /// rows/cols, the dark module, and (at v2, n == 25) the single 5×5 alignment
  /// pattern centred at (n-7, n-7). v1 has no alignment pattern.
  bool _isFixed(int r, int c, int n) {
    bool corner(int r0, int c0) =>
        r >= r0 && r < r0 + 8 && c >= c0 && c < c0 + 8;
    if (corner(0, 0) || corner(0, n - 8) || corner(n - 8, 0)) return true;
    if (r == 6 || c == 6) return true; // timing patterns
    if (r == n - 8 && c == 8) return true; // dark module
    if (n >= 25) {
      final int a = n - 7; // alignment-pattern centre (18 at v2)
      if ((r - a).abs() <= 2 && (c - a).abs() <= 2) return true; // 5×5 ring
    }
    return false;
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.view != view;
}

/// How [_QrPainter] renders: the plain scannable code, or the reusable blank
/// skeleton (only the key-independent cells, over a highlighted module grid,
/// printed for hand-colouring).
enum _QrView { scan, blank }

/// Calibration target presets: a human duration label paired with the
/// wall-clock the derivation should take. Grounded in THREAT_MODEL.md — hours
/// defeat robbery / flash-kidnap, ~a week defeats the flashiest wrench attacks.
const List<({String label, Duration target})> _kCalibTargets =
    <({String label, Duration target})>[
  (label: '~1 hour', target: Duration(hours: 1)),
  (label: '~6 hours', target: Duration(hours: 6)),
  (label: '~1 day', target: Duration(days: 1)),
  (label: '~1 week', target: Duration(days: 7)),
];
/// Whether a calibration target time means one **inter-stage** derivation or
/// the **whole setup** (all stages). All-stages divides the target by the stage
/// count to get the per-stage time the iteration count N must hit.
enum _CalibScope { perStage, allStages }

/// The spacious Argon2 calibration dialog (opened by Alt+D / the panel button).
///
/// Flow: benchmark this device **once** at [profile] (seconds per derivation
/// step), then pick a target time, a scope (one stage vs all stages) and the
/// stage count; N recomputes arithmetically from the single benchmark — no
/// re-benchmark when those change. Apply returns N via [Navigator.pop]. Exit is
/// Esc / Cancel / ✕ with confirmation. "Time is a perishable label on a durable
/// parameter": N is exact and reproducible; only the absolute delay drifts.
class _CalibrationDialog extends StatefulWidget {
  const _CalibrationDialog({
    required this.core,
    required this.sounds,
    required this.profile,
    required this.profileLabel,
    required this.initialStages,
  });

  final GreatWallCore core;
  final SoundBoard sounds;
  final Argon2Profile profile;
  final String profileLabel;
  final int initialStages;

  @override
  State<_CalibrationDialog> createState() => _CalibrationDialogState();
}

class _CalibrationDialogState extends State<_CalibrationDialog> {
  bool _benching = false;
  String? _benchError;
  // Single on-device measurement; target/scope/stages all derive N from this.
  double? _secPerPass;
  Argon2BenchJob? _benchJob; // live benchmark, so it can be cancelled

  Duration? _target;
  _CalibScope _scope = _CalibScope.perStage;
  late int _stages;
  int? _computedN;

  // Advanced (sane defaults; "leave unchanged if unsure"):
  // - conservative safety margin baked into N (typical user overshoots ~2×),
  // - benchmark passes (median of these).
  double _margin = 2.0;
  int _passes = 3;

  // Determinate progress over (1 warm-up + _passes) benchmark passes, with a
  // wall-clock ETA projected from the passes completed so far.
  int _progressDone = 0;
  int _progressTotal = 0;
  final Stopwatch _benchClock = Stopwatch();
  double? _etaSeconds;

  @override
  void initState() {
    super.initState();
    _stages = widget.initialStages.clamp(1, SetupController.maxPointStages);
  }

  /// Recompute N from the single benchmark + the current target / scope / stages
  /// / margin. N is per stage; "all stages" splits the target across the stages
  /// so the whole setup ≈ target. The safety margin lengthens N (err to caution).
  void _recompute() {
    final double? s = _secPerPass;
    final Duration? t = _target;
    if (s == null || t == null) {
      _computedN = null;
      return;
    }
    final double perStageSeconds = _scope == _CalibScope.allStages
        ? t.inSeconds / _stages
        : t.inSeconds.toDouble();
    _computedN = (perStageSeconds * _margin / s).ceil().clamp(1, 1 << 30);
  }

  Future<void> _bench() async {
    _benchClock
      ..reset()
      ..start();
    setState(() {
      _benching = true;
      _benchError = null;
      _progressDone = 0;
      _progressTotal = 1 + _passes;
      _etaSeconds = null;
    });
    widget.sounds.play(UiSound.focus);
    try {
      _benchJob = await widget.core.startBenchArgon2(
        profile: widget.profile,
        passes: _passes,
        onProgress: (int done, int total) {
          if (!mounted) return;
          // Project remaining time from the passes done so far (the warm-up is
          // included, so the ETA is mildly conservative — fine).
          final double elapsed = _benchClock.elapsedMicroseconds / 1e6;
          setState(() {
            _progressDone = done;
            _progressTotal = total;
            _etaSeconds = done > 0 ? (total - done) * (elapsed / done) : null;
          });
        },
      );
      final double s = await _benchJob!.result;
      if (!mounted) return;
      setState(() {
        _secPerPass = s;
        _recompute();
      });
      widget.sounds.play(UiSound.confirm);
      debugPrint('calibrate: profile=${widget.profile} secPerStep=$s');
    } on Argon2Cancelled {
      if (!mounted) return;
      setState(() {
        _secPerPass = null;
        _computedN = null;
        _benchError = 'Benchmark cancelled.';
      });
      widget.sounds.play(UiSound.undo);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _secPerPass = null;
        _computedN = null;
        _benchError = 'Benchmark failed (${e.runtimeType}) — the chosen memory '
            'profile may not fit on this device.';
      });
      widget.sounds.play(UiSound.warn);
    } finally {
      _benchClock.stop();
      _benchJob = null;
      if (mounted) setState(() => _benching = false);
    }
  }

  /// Stop an in-progress benchmark (kills the worker isolate).
  void _cancelBench() => _benchJob?.cancel();

  Future<bool> _confirmClose() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Close calibration?'),
        content: const Text(
            'The benchmark result is discarded unless you Apply it first.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Close')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Esc / Cancel / ✕: while a benchmark runs this stops it (stay in the
  /// dialog); otherwise it closes the dialog after confirming.
  Future<void> _attemptClose() async {
    if (_benching) {
      _cancelBench();
      return;
    }
    if (await _confirmClose() && mounted) Navigator.of(context).pop();
  }

  String _fmtDuration(double seconds) {
    if (seconds < 90) return '${seconds.toStringAsFixed(0)} s';
    if (seconds < 5400) return '${(seconds / 60).toStringAsFixed(1)} min';
    if (seconds < 172800) return '${(seconds / 3600).toStringAsFixed(1)} h';
    return '${(seconds / 86400).toStringAsFixed(1)} d';
  }

  String _fmtMargin() => _margin == _margin.roundToDouble()
      ? _margin.toStringAsFixed(0)
      : _margin.toStringAsFixed(1);

  /// Determinate-progress label: warm-up, then "Measuring k / passes…", with a
  /// projected "~X left" ETA once the first pass has completed.
  String _progressLabel() {
    final String eta = _etaSeconds != null
        ? '   ·   ~${_fmtDuration(_etaSeconds!)} left'
        : '';
    if (_progressDone <= 0) return 'Warming up…$eta';
    return 'Measuring ${_progressDone.clamp(1, _passes)} / $_passes…$eta';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? s = _secPerPass;
    final int? n = _computedN;

    // Override the dialog route's default Escape→pop so Esc asks first.
    return Actions(
      actions: <Type, Action<Intent>>{
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (Intent _) {
            _attemptClose();
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text('Calibrate derivation steps / stage (D)',
                              style: theme.textTheme.titleLarge),
                        ),
                        IconButton(
                          tooltip: _benching ? 'Stop (Esc)' : 'Close (Esc)',
                          onPressed: _attemptClose,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 1 — benchmark this device (once).
                    Text('1 · Benchmark this device',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        // Run ↔ Stop: a benchmark in progress is cancellable.
                        OutlinedButton.icon(
                          onPressed: _benching ? _cancelBench : _bench,
                          icon: Icon(_benching ? Icons.stop : Icons.speed,
                              size: 18),
                          label: Text(_benching
                              ? 'Stop'
                              : (s == null ? 'Run benchmark' : 'Re-run')),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _benching
                                ? _progressLabel()
                                : (_benchError ??
                                    (s == null
                                        ? 'Profile: ${widget.profileLabel}'
                                        : '≈ ${s.toStringAsFixed(s < 10 ? 2 : 1)} s/step  ·  ${widget.profileLabel}')),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    // Determinate progress: one notch per (warm-up + timed) pass.
                    if (_benching) ...<Widget>[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: _progressTotal > 0
                            ? _progressDone / _progressTotal
                            : null,
                      ),
                    ],
                    const SizedBox(height: 20),

                    // 2 — target time.
                    Text('2 · Target time', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final ({String label, Duration target}) t
                            in _kCalibTargets)
                          ChoiceChip(
                            label: Text(t.label),
                            selected: _target == t.target,
                            onSelected: (_) => setState(() {
                              _target = t.target;
                              widget.sounds.play(UiSound.tickSoft);
                              _recompute();
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 3 — scope + stage count (disambiguates per-stage vs total).
                    Text('3 · Target applies to',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    SegmentedButton<_CalibScope>(
                      segments: const <ButtonSegment<_CalibScope>>[
                        ButtonSegment<_CalibScope>(
                            value: _CalibScope.perStage,
                            label: Text('One stage')),
                        ButtonSegment<_CalibScope>(
                            value: _CalibScope.allStages,
                            label: Text('All stages')),
                      ],
                      selected: <_CalibScope>{_scope},
                      onSelectionChanged: (Set<_CalibScope> sel) => setState(() {
                        _scope = sel.first;
                        widget.sounds.play(UiSound.tickSoft);
                        _recompute();
                      }),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Text('Stages: ', style: theme.textTheme.bodyMedium),
                        IconButton(
                          onPressed: _stages > 1
                              ? () => setState(() {
                                    _stages--;
                                    _recompute();
                                  })
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text('$_stages', style: theme.textTheme.titleMedium),
                        IconButton(
                          onPressed: _stages < SetupController.maxPointStages
                              ? () => setState(() {
                                    _stages++;
                                    _recompute();
                                  })
                              : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Advanced — sane defaults; leave unchanged if unsure.
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      title:
                          Text('Advanced', style: theme.textTheme.labelLarge),
                      children: <Widget>[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'If you don’t know what these mean, leave them '
                            'unchanged.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: <Widget>[
                            SizedBox(
                                width: 120,
                                child: Text('Safety margin',
                                    style: theme.textTheme.bodyMedium)),
                            Expanded(
                              child: SegmentedButton<double>(
                                showSelectedIcon: false,
                                segments: const <ButtonSegment<double>>[
                                  ButtonSegment<double>(
                                      value: 1.0, label: Text('×1')),
                                  ButtonSegment<double>(
                                      value: 1.5, label: Text('×1.5')),
                                  ButtonSegment<double>(
                                      value: 2.0, label: Text('×2')),
                                  ButtonSegment<double>(
                                      value: 3.0, label: Text('×3')),
                                ],
                                selected: <double>{_margin},
                                onSelectionChanged: (Set<double> sel) =>
                                    setState(() {
                                  _margin = sel.first;
                                  widget.sounds.play(UiSound.tickSoft);
                                  _recompute();
                                }),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            SizedBox(
                                width: 120,
                                child: Text('Benchmark passes',
                                    style: theme.textTheme.bodyMedium)),
                            IconButton(
                              onPressed: (_benching || _passes <= 1)
                                  ? null
                                  : () => setState(() => _passes--),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            Text('$_passes',
                                style: theme.textTheme.titleMedium),
                            IconButton(
                              onPressed: (_benching || _passes >= 7)
                                  ? null
                                  : () => setState(() => _passes++),
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Result.
                    if (n != null && s != null)
                      Text(
                        'N = $n   ·   one stage ≈ ${_fmtDuration(n * s)}   ·   '
                        'all $_stages ≈ ${_fmtDuration(n * s * _stages)}'
                        '${_margin == 1.0 ? '' : '   (×${_fmtMargin()} safety)'}',
                        style: theme.textTheme.bodyMedium,
                      )
                    else
                      Text(
                        s == null
                            ? 'Run the benchmark, then pick a target.'
                            : 'Pick a target time.',
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 24),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: _attemptClose,
                          child: Text(_benching ? 'Stop' : 'Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: (_benching || n == null)
                              ? null
                              : () => Navigator.of(context).pop(n),
                          child: const Text('Apply N'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
