import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:dragon_dice_ui/dragon_dice_ui.dart'
    show DiceCue, DiceRolls, DragonDiceWizard, digestBits;
import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show CardKind, Cues, Deck, MemCard, buildDeck;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:great_wall_ux/great_wall_ux.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart' as qr;

import '../app/sound_cue_folder.dart';
import '../command/command_board.dart';
import '../command/keyboard_layout.dart';
import '../command/zoom_flight.dart';
import '../core/encoding_constants.dart';
import '../core/entropy.dart';
import '../core/great_wall_core.dart';
import '../core/landmark_path.dart';
import '../core/master_secret.dart';
import '../core/namtso_harvester.dart';
import '../core/orbit_protocol.dart';
import '../core/stage_params.dart';
import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';
import 'desktop_qr_scanner.dart';
import 'orbit_vault.dart';
import 'setup_crypto.dart';

/// Setup mode screen: build an orbit setup — place points on each stage's
/// maps, advance between stages, and memorise them.
///
/// This is the concrete `great-wall-core + great-wall-ux` integration the
/// architecture assigns to Setup (ARCHITECTURE.md §"7. great-wallet", mode 1):
/// great-wall-ux's [FractalCanvas] / palette / brightness drive the visuals of
/// the orbit's maps, the engine encodes their points, and a worker isolate runs
/// the memory-hard advance between stages.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen>
    with TickerProviderStateMixin {
  final PanZoomController _viewport =
      PanZoomController(initial: _initialViewport);
  final BrightnessController _brightness = BrightnessController();
  bool _autoExposureWasOn = false;

  /// Deep render mode (Alt+L). When on, the canvas escape-count cap rises from
  /// [EncodingConstants.renderMaxIterFast] to the engine's encode cap, so the
  /// rendered boundary matches where the encoder lands leaves. Off by default
  /// and reset per stage — it is an exceptional escape hatch for the rare leaf
  /// sitting deep in a high-escape-count void, and it makes interior rendering
  /// laggy (hence the persistent on-canvas marker).
  bool _deepRender = false;

  /// UI sound cues. The canvas plays the tap "click"; the selection-outcome
  /// cues (select / confirm / deny) are dispatched where the result is known.
  final SoundBoard _sounds = SoundBoard();

  /// Focus node for the canvas/hotkey handler, so we can return keyboard focus
  /// to it after the user has been typing in a text field.
  final FocusNode _hotkeys = FocusNode(debugLabel: 'setup-hotkeys');

  // Focus nodes for the input controls, brought up from the board. Each field
  // is wrapped in _track(_Field…) so focus also drives the console help.
  final FocusNode _iterationsFocus = FocusNode(debugLabel: 'iterations');
  final FocusNode _profileFocus = FocusNode(debugLabel: 'profile');
  final FocusNode _exportLabelFocus = FocusNode(debugLabel: 'export-label');
  final FocusNode _hueFocus = FocusNode(debugLabel: 'hue');

  /// Per-stage **master-secret export label** (e.g. `SIGNING-1`). Appended to
  /// the Argon2id transcript message at the exporting stage, versioning the
  /// derived secret — DESIGN.md §"Master-Secret Export". Same restricted
  /// `[A-Z0-9-]` widget as Stage 0; shown on every non-0 stage in all modes. A
  /// single field applies to whichever stage is on screen when Copy is pressed.
  final TextEditingController _exportLabel = TextEditingController();

  /// True when the last edit to [_exportLabel] had characters up-cased or
  /// dropped by the engine's canonicalisation.
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

  /// Whether the point import field (dice rolls or hex) is obscured: secret
  /// material, hidden by default.
  bool _importHidden = true;

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

  /// The number of deep stages the Argon2 calibration estimates for: all of
  /// them, [OrbitProtocol.maxStage].
  final int _pointStages = OrbitProtocol.maxStage;

  /// True while the user is picking a replacement point for the displayed stage
  /// (the `R` edit): the next canvas click sets the new point. Esc cancels.
  bool _editPointMode = false;

  final TextEditingController _pointImport = TextEditingController();
  final FocusNode _pointImportFocus = FocusNode(debugLabel: 'point-import');

  /// Provisional-key save/load: the destination/source file path. The
  /// provisional key itself is never kept in a screen field — it is entered,
  /// shown, or copied only inside the Write/Open dialogs. [_vaultBusy] disables
  /// the controls while an encrypt/decrypt pass runs.
  final TextEditingController _vaultPath = TextEditingController();
  final FocusNode _vaultPathFocus = FocusNode(debugLabel: 'vault-path');
  bool _vaultBusy = false;

  /// True while the memory-hard orbit advance `o_{i+1} = H*(u_i)` is running in a
  /// worker isolate (a forward stage navigation). Folds into [_busy] so the
  /// progress scrim shows and other hotkeys/navigation are blocked meanwhile.
  bool _advancing = false;

  /// The stage the advance in flight is deriving *into*, or null: its stage
  /// tab fills as the passes complete.
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
  /// restored from it.
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

  /// The command board's keyboard layout: the build's default
  /// ([KeyboardLayout.buildDefault]), switchable for the session.
  KeyboardLayout _layout = KeyboardLayout.buildDefault;

  /// The command board's context (Alt + a top-row board key).
  CommandContext _context = CommandContext.main;

  /// The explanation of the board button or tab under the pointer or focus,
  /// shown in the log in place of its text; null when none is.
  String? _explaining;

  /// Whether the landmark path's numbered markers and its line are drawn
  /// (Path board).
  bool _showNumbers = true;
  bool _showLines = true;

  /// The stop last flown to (Path board's previous / next): its index among
  /// the shown stops of that map's path, as then shown. Stale once the map,
  /// the path or its visible stops change, and then the cycle starts over.
  ({(int, int) key, LandmarkPath path, int? visible, int index})? _stopAt;

  /// The running flight between views, if any.
  Ticker? _flight;

  /// Whether the panels are collapsed (F1): the bottom panel to a thin status
  /// line, and the stage and slot tabs hidden.
  bool _chromeMinimized = false;

  /// The input field each pane shows: the last one its board brought up
  /// (key label, profile or steps D on Setup; file path on Main). It stays
  /// until another replaces it; Esc only leaves it for the map.
  final Map<CommandContext, _Field> _paneField = <CommandContext, _Field>{};

  /// The selected **secondary slot** within the active stage (the orbit builder's
  /// lower tab row, `0..`[_maxSlot]). Slot `#0` is the salt; `#j≥1` are the
  /// fractals (their content is wired in later phases —
  /// next-steps/orbit-setup-tab-ui-pathway.md, P2+). Selected by a plain digit;
  /// stage selection moved to `Alt`+digit.
  int _slotIndex = 0;

  /// Highest secondary slot index — a fixed row of ten tabs (`0..9`), one per
  /// digit key.
  static const int _maxSlot = 9;

  /// The **orbit** stage cursor (`0..`[_maxStage]). Stage 0 is rooted by σ; a
  /// deep stage is entered by the forward memory-hard advance
  /// `o_i = H*(u_{i-1})`.
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

  /// Required fractal count `r_i` at stage 0 (σ-rooted) and at every deep
  /// stage (the 96-bit standard). Fixed: only standard setups exist.
  static const int _rootRequired = 2;
  static const int _deepRequired = 3;

  /// `r_i`, the number of fractals the holder places at [stage]. Every slot is
  /// operationally equal, so any `r_i` of the slots may be placed and the rest
  /// derive (slots beyond `r_i` are only *faded* as a hint, not disabled).
  static int _requiredOf(int stage) =>
      stage == 0 ? _rootRequired : _deepRequired;

  /// The stage whose slots/`r_i` the secondary row reflects: the orbit
  /// stage cursor.
  int get _activeStage => _orbitStage.clamp(0, _maxStage);

  // --- P5: stage-0 orbit board render cache ---------------------------------
  // Stage 0's fractal slots (#j≥1) render the real board `θ_0_(j-1)` derived
  // from σ → o₀. The authoritative u64 reservoirs ride `widget.core.source`
  // (stage_params.dart); [_boardParams] is the display-proxy the canvas uses
  // only to trigger repaints. Both are cached, keyed by [_boardKey] = "σ#slot",
  // so panning/zooming (which rebuilds this screen) does not re-run the θ hash
  // or force a needless canvas repaint.
  StageParameters? _boardParams;
  StageReservoirs? _boardReservoirs;
  String _boardKey = '';

  // --- P5: per-stage orbit board state --------------------------------------
  // Highest orbit stage index.
  static const int _maxStage = OrbitProtocol.maxStage;

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
  /// [_stageOrbit]); `o_i` (`i≥1`) is the memory-hard advance `o_i = H*(u_{i-1})`,
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

  /// The slot whose point is being imported inline ([_importEditorBody] /
  /// [_pointImport]), or null.
  int? _boardImportSlot;

  /// Canonical islands enumerated under the current view (the `E` reveal) on the
  /// active board's fractal — cleared on any slot / σ change.
  List<CanvasIsland> _boardIslands = const <CanvasIsland>[];

  /// The placed point's focus decoration (canonical island cells + bbox) per
  /// slot, cached until the point / σ changes. Drives the square frame and the
  /// cross↔square switch.
  final Map<int, _BoardDeco?> _boardDecoCache = <int, _BoardDeco?>{};

  /// Whether the active board shows its point's landmark path (Alt+E).
  bool _showPath = false;

  /// Landmark candidates per (stage, slot), scanned once per point off the
  /// UI isolate; null for a point with none. Freed wherever the board's
  /// points change.
  final Map<(int, int), LandmarkCandidates?> _candidates =
      <(int, int), LandmarkCandidates?>{};

  /// The route per (stage, slot), set in the route panel. Saved as the cues of
  /// the map's card in [_deck] when the setup is saved, and read back when it
  /// is opened.
  final Map<(int, int), _Route> _routes = <(int, int), _Route>{};

  /// The CPNF deck saved with this setup (celestial-peace-nf-core): a card per
  /// memorised map with its cues and SM-2 state, plus the fact cards. Null
  /// until the setup is first saved or opened with one. Kept in step with the
  /// boards: a map whose point changes restarts its card ([_mapsChanged]).
  Deck? _deck;

  /// Landmark paths per (stage, slot), searched off the UI isolate, each with
  /// the route it was searched for and the overlay it is drawn as; null for a
  /// point with no path. Dropped, and wiped, wherever the board's points
  /// change.
  final Map<(int, int), _ShownPath?> _paths = <(int, int), _ShownPath?>{};

  /// (stage, slot) pairs whose path is being computed.
  final Set<(int, int)> _pathsPending = <(int, int)>{};

  /// Bumped by every drop, so a computation started before it is discarded.
  int _pathGeneration = 0;

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

  /// True at an orbit-board fractal slot (`#j≥1`).
  bool get _isBoardSlot => _slotIndex >= 1;

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
    // Drive the board's cross↔square switch as the view zooms (the screen does
    // not otherwise rebuild on pan/zoom).
    _viewport.addListener(_onBoardViewportChanged);
    _autoExposureWasOn = _brightness.autoExposure;
    _brightness.addListener(_onBrightnessChanged);
    unawaited(_cueFolder.start());
  }

  /// The folder the sound cues are swapped in at run time.
  late final SoundCueFolder _cueFolder = SoundCueFolder(
    apply: (SoundCueMap map, Map<String, String> files) =>
        _sounds.applyCues(map, localFiles: files),
    appDefaults: _kCueDefaults,
    catalogue: _cueCatalogue(),
    onLog: (String m) {
      if (mounted) _toast(m);
    },
  );

  /// This screen's own cue defaults, over the built-in ones: controls that
  /// voiced a sound of their own before press cues keep it.
  static const String _kCueDefaults = """
# --- This app's defaults ----------------------------------------------------
press.advance.halt        select.wav
press.calibrate.scope     tick_soft.wav
press.calibrate.target    tick_soft.wav
""";

  /// Every cue name this screen plays beyond the built-in families: each
  /// board command's press and hover, the tabs', and [_Cue.all].
  static List<String> _cueCatalogue() => <String>[
        for (final _Cmd c in _Cmd.values) ...<String>[
          '$kCuePress.${c.cue}',
          '$kCueHover.${c.cue}',
        ],
        for (final CommandContext c in CommandContext.values) ...<String>[
          '$kCuePress.${contextTabCue(c)}',
          '$kCueHover.${contextTabCue(c)}',
        ],
        for (final String tab in <String>[_Cue.stageTab, _Cue.slotTab])
          ...<String>['$kCuePress.$tab', '$kCueHover.$tab'],
        ..._Cue.all,
        ...DiceCue.all,
      ];

  /// Play cue [name] (see [SoundCueMap]).
  void _cue(String name) => _sounds.cue(name);

  /// Show a dialog through [show], voicing its opening and closing as dialog
  /// [id].
  Future<T?> _dialog<T>(String id, Future<T?> Function() show) async {
    _cue('${_Cue.dialogOpen}.$id');
    try {
      return await show();
    } finally {
      _cue('${_Cue.dialogClose}.$id');
    }
  }

  /// [f], voicing the press of control [id] first; null stays null (a
  /// disabled control).
  VoidCallback? _press(String id, VoidCallback? f) => f == null
      ? null
      : () {
          _cue('$kCuePress.$id');
          f();
        };

  /// Announce auto brightness switching on or off — by the View board, or off
  /// by a manual brightness or shade step. The mode is announced; the values
  /// never are.
  void _onBrightnessChanged() {
    final bool on = _brightness.autoExposure;
    if (on == _autoExposureWasOn || !mounted) return;
    _autoExposureWasOn = on;
    _sounds.play(on ? UiSound.modeOn : UiSound.modeOff);
    _toast(on
        ? 'Auto brightness ON — follows the view; brighter / darker take '
            'back control.'
        : 'Auto brightness off.');
  }

  /// Show [text] in the log in place of its lines (a board button or a tab
  /// under the pointer or focus), or restore them (null).
  void _explain(String? text) {
    if (text != _explaining) setState(() => _explaining = text);
  }

  /// A stage tab's explanation: what the stage holds and how far it is.
  String _stageExplanation(int i) {
    final String head = 'Stage $i (Alt+$i).';
    final String state;
    if (_advanceTarget == i) {
      state = 'Advancing into it (memory-hard).';
    } else if (_orbitK[i] != null) {
      state = 'Complete: its ${_requiredOf(i)} points are placed.';
    } else if (i == 0 || _orbitO[i] != null) {
      state = i == 0
          ? 'Rooted by σ (slot 0); place ${_requiredOf(i)} points.'
          : 'Reached; place ${_requiredOf(i)} points.';
    } else if (i == _orbitReachableCeiling + 1) {
      state = 'Not reached: Alt+$i advances into it (memory-hard) once '
          'Stage ${i - 1} is complete.';
    } else {
      state = 'Not reached.';
    }
    return '$head $state';
  }

  /// A slot tab's explanation at the active stage: the slot's role, its
  /// point, the keys that set it, and what pressing its number does.
  String _slotExplanation(int slot) {
    final int stage = _activeStage;
    if (slot == 0) {
      return stage == 0
          ? 'Slot 0 — salt: σ, the orbit’s root. Harvest it with Namtso or '
              'paste it.'
          : 'Slot 0 — retirement: burying o_$stage on-chain retires the '
              'shallower stages. Coming soon.';
    }
    final int r = _requiredOf(stage);
    final bool derived = _boardDerived[stage][slot];
    final bool placed = _boardPoints[stage][slot] != null;
    final bool hasRoot = stage == 0
        ? _parseHex(_sigmaCtrl.text.trim()) != null
        : _orbitO[stage] != null;
    final String keys =
        _keys(<_Cmd>[_Cmd.placeByClick, _Cmd.newPoint, _Cmd.dice]);
    final String head = derived
        ? 'Slot $slot — derived share (locked).'
        : 'Slot $slot — fractal${slot > r ? ' (beyond rᵢ=$r)' : ''}.';
    final String body = derived
        ? 'The stage’s Shamir polynomial — fixed by the $r points you placed '
            '— extrapolated onto this fractal. It is a real, usable point: '
            'recovery accepts any $r of the stage’s fractals, not only the '
            'ones you placed.'
        : !hasRoot
            ? (stage == 0
                ? 'Set σ in slot 0 first.'
                : 'Advance into this stage first.')
            : placed
                ? 'Point placed. $keys.'
                : '$keys. rᵢ=$r is the minimum — place any $r fractals; the '
                    'rest derive.';
    final String press = slot != _slotIndex
        ? 'Press $slot to show it.'
        : placed
            ? 'Press $slot again to toggle the canonical view — island '
                'centred, zoomed and brightened — and back.'
            : 'Press $slot again to reset the view (position · zoom · '
                'brightness).';
    final String complete = _orbitK[stage] == null
        ? ''
        : stage == _maxStage
            ? ' Deepest stage — its K is the wallet master key (copy: '
                '${_hint(_Cmd.copyKey)}).'
            : stage == _orbitReachableCeiling
                ? ' Stage complete. Alt+${stage + 1} advances the orbit '
                    '(memory-hard).'
                : ' Stage complete.';
    return '$head $body $press$complete';
  }

  @override
  void dispose() {
    _stopFlight();
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
    _viewport.removeListener(_onBoardViewportChanged);
    _viewport.dispose();
    _brightness.removeListener(_onBrightnessChanged);
    _brightness.dispose();
    unawaited(_cueFolder.dispose());
    _sounds.dispose();
    _iterationsField.dispose();
    _exportLabel.dispose();
    _pointImport.dispose();
    _pointImportFocus.dispose();
    _vaultPath.dispose();
    _vaultPathFocus.dispose();
    _hotkeys.dispose();
    _iterationsFocus.dispose();
    _profileFocus.dispose();
    _exportLabelFocus.dispose();
    _hueFocus.dispose();
    super.dispose();
  }

  bool get _busy => _advancing;

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

  /// Bring up input field [f] in the current context's pane and focus it by
  /// its [node]. If the field is not shown in the current mode, say so in the
  /// console instead of silently doing nothing.
  void _showField(_Field f, FocusNode node, String label) {
    setState(() {
      _paneField[_context] = f;
      _chromeMinimized = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (node.context == null) {
        _toast('The $label field is not available in this mode.');
        return;
      }
      _sounds.play(UiSound.focus);
      node.requestFocus();
    });
  }

  /// Global shortcuts that fire even while a text field has focus (text fields
  /// do not consume these keys, so they bubble up to here): Esc leaves a field
  /// for the viewer, F1 collapses or restores the bottom panel, and F2–F5
  /// switch top-level mode.
  Map<ShortcutActivator, VoidCallback> get _globalShortcuts =>
      <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _focusViewer,
        const SingleActivator(LogicalKeyboardKey.f1): () =>
            _togglePanel(byKey: true),
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            _gotoMode('Setup', _Cue.f2, here: true),
        const SingleActivator(LogicalKeyboardKey.f3): () =>
            _gotoMode('Train', _Cue.f3, here: false),
        const SingleActivator(LogicalKeyboardKey.f4): () =>
            _gotoMode('Accelerate', _Cue.f4, here: false),
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            _gotoMode('Inherit', _Cue.f5, here: false),
      };

  /// Switch top-level mode (F2 Setup · F3 Train · F4 Accelerate · F5 Inherit).
  /// Only Setup exists in this app today; the others announce themselves so the
  /// keys (and muscle memory) are correct from the start.
  void _gotoMode(String name, String cue, {required bool here}) {
    _cue(cue);
    _toast(here
        ? '$name (current mode).'
        : '$name mode is not available yet.');
  }

  /// Return keyboard focus to the fractal viewer (and so out of any text field),
  /// re-enabling the single-key hotkeys. The non-directional counterpart to Tab.
  void _focusViewer() {
    // Esc also cancels an armed manual point edit and an open import editor.
    if (_editPointMode) setState(() => _editPointMode = false);
    if (_boardImportSlot != null) {
      _pointImport.clear();
      setState(() => _boardImportSlot = null);
    }
    _hotkeys.requestFocus();
  }

  /// Collapse or restore the panels — the command board and the log, and the
  /// stage and slot tabs (F1).
  void _togglePanel({bool byKey = false}) {
    final bool collapsing = !_chromeMinimized;
    if (byKey) {
      _cue(collapsing ? _Cue.f1Collapse : _Cue.f1Restore);
    } else {
      _sounds.play(collapsing ? UiSound.chromeDown : UiSound.chromeUp);
    }
    setState(() => _chromeMinimized = collapsing);
  }

  /// Show the board's [c] context (Alt + its top-row key), restoring the panel
  /// if it was collapsed.
  void _setContext(CommandContext c) {
    _cue('$kCuePress.${contextTabCue(c)}');
    setState(() {
      _context = c;
      _chromeMinimized = false;
      _explaining = null;
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    onPointerDown: (_) {
                      _stopFlight();
                      _hotkeys.requestFocus();
                    },
                    onPointerSignal: (_) => _stopFlight(),
                    child: Stack(
                      children: <Widget>[
                        // Slot #0 is the salt (Namtso σ at stage 0; retirement
                        // placeholder at stage i>0). Fractal slots (#j≥1) render
                        // the real orbit board θ_i_(j-1).
                        Positioned.fill(
                          child: _slotIndex == 0
                              ? _saltSlotPanel()
                              : _orbitBoardPanel(_slotIndex),
                        ),
                        if (_busy) Positioned.fill(child: _progressOverlay()),
                        if (_editPointMode && _isBoardSlot)
                          const Positioned(
                            top: 56,
                            left: 12,
                            child: _Badge('Click the new point · Esc to cancel'),
                          ),
                        // Deep render reminder: explains the lag while the high
                        // escape-count cap is active, and how to turn it off.
                        if (_deepRender && _isBoardSlot)
                          Positioned(
                            top: 56,
                            right: 12,
                            child: _Badge(
                                'Deep render · ${_hint(_Cmd.deepRender)} to exit'),
                          ),
                        // Stage tabs hover over the top of the viewer with a
                        // transparent background, so they never squeeze the
                        // canvas. Hidden with the bottom panel (F1).
                        if (!_chromeMinimized)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            // Stage bar (Alt+digit) with the secondary slot bar
                            // (plain digit) stacked directly beneath it.
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                _stageTabs(),
                                _slotTabs(),
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
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

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

  /// The **secondary slot tabs** — a fixed row of ten numbered tabs (`0..9`)
  /// directly beneath the stage bar. Slot `#0` is the salt; `#j≥1` are the
  /// fractals. Reuses [_StageTab] so it shares the stage bar's stable layout;
  /// per-slot content lands in P2+ (this row is navigation only for now).
  Widget _slotTabs() {
    final int r = _requiredOf(_activeStage);
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
                      explanation: _slotExplanation(i),
                      onExplain: _explain,
                      cue: '${_Cue.slotTab}.$i',
                      onCue: _cue,
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
    final DateTime? picked = await _dialog(_Cue.harvestDate, () => showDatePicker(
      context: context,
      initialDate: _harvestedDate ?? today,
      firstDate: DateTime(2009, 1, 3), // Bitcoin genesis
      lastDate: today,
      helpText: 'Harvest σ from the timechain at a date',
    ));
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
                    onPressed:
                        _press(_Cue.harvest, _harvesting ? null : _harvestFromDate),
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
                        onPressed: _press(_Cue.harvestCancel, _cancelHarvest),
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
  /// to retire the shallower stages). Disabled placeholder for now.
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
                'Retire the shallower stages by burying o_$stage on-chain '
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

  /// The upper-edge stage tabs: a **fixed** bar of five numbered tabs
  /// (0..[_maxStage]) spanning the view's width. Stage 0 is rooted by σ; the
  /// deeper ones are entered by the memory-hard advance. The stage under focus
  /// is lit; stages not reached yet stay visible as ghosts.
  Widget _stageTabs() {
    // The cursor is [_orbitStage]; a stage is reachable up to the derived
    // ceiling, and the next stage is tappable to advance into it. The advance
    // in flight fills its tab ([_advanceTarget] / [_advanceProgress]).
    final int ceiling = _orbitReachableCeiling;
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
              for (int i = 0; i <= _maxStage; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _StageTab(
                      index: i,
                      // The derived stages plus the next (advanceable) one are
                      // the setup so far; the rest show as ghost slots.
                      inSetup: i <= ceiling + 1,
                      selected: i == _orbitStage,
                      available: i <= ceiling,
                      deriving: _advanceTarget == i,
                      progress: _advanceProgress,
                      explanation: _stageExplanation(i),
                      onExplain: _explain,
                      cue: '${_Cue.stageTab}.$i',
                      onCue: _cue,
                      onTap: i <= ceiling + 1 ? () => _selectStage(i) : null,
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
    if (kb.isControlPressed || kb.isMetaPressed) return KeyEventResult.ignored;
    // The board's keys, by position (kBoardKeys): the same on every layout.
    final int board = kBoardKeys.indexOf(event.physicalKey);
    if (kb.isAltPressed) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      // Alt + a top-row board key: switch the board's context.
      for (final CommandContext c in CommandContext.values) {
        if (board == c.key) {
          _setContext(c);
          return KeyEventResult.handled;
        }
      }
      // Alt + digit: select that stage (the upper tabs).
      final int? altStage = _digitKeys[event.logicalKey];
      if (altStage != null) {
        _selectStage(altStage);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // A board key runs the context's command at that position; holding it
    // repeats only the commands that step a value.
    if (board >= 0) {
      final BoardCommand? c = _board()[board];
      if (c == null || (event is KeyRepeatEvent && !c.repeats)) {
        return KeyEventResult.handled;
      }
      if (!c.enabled) {
        if (event is KeyDownEvent) _sounds.play(UiSound.denyBlocked);
        return KeyEventResult.handled;
      }
      if (c.cue != null) _cue('$kCuePress.${c.cue}');
      c.run();
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 0–6 — select that secondary slot within the active stage.
    final int? digit = _digitKeys[event.logicalKey];
    if (digit != null) {
      _selectSlot(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Command board ----------------------------------------------------------

  /// The current context's board: each command at its position, null where
  /// a position is empty.
  List<BoardCommand?> _board() {
    final List<BoardCommand?> out =
        List<BoardCommand?>.filled(kBoardKeys.length, null);
    for (final _Cmd c in _Cmd.values) {
      if (c.context == _context) out[c.slot] = _command(c).withCue(c.cue);
    }
    return out;
  }

  /// The keys of [cmds] (all of one context) with their names, for a hint
  /// line: e.g. `Setup board (Alt+W): F place by click · A new random point`.
  String _keys(List<_Cmd> cmds) {
    final CommandContext ctx = cmds.first.context;
    return '${ctx.label} board (Alt+${_layout.keys[ctx.key]}): '
        '${cmds.map((_Cmd c) => '${_layout.keys[c.slot]} ${_command(c).name.toLowerCase()}').join(' · ')}';
  }

  /// How to reach [c]: its context's Alt key, then its key, on this layout.
  String _hint(_Cmd c) =>
      '${c.context.label} board (Alt+${_layout.keys[c.context.key]}) › '
      '${_layout.keys[c.slot]}';

  /// The landmark route of the active map can be adjusted: its path is shown.
  bool get _routeReady =>
      _showPath &&
      _isBoardSlot &&
      _slotIndex >= 1 &&
      _paths[(_activeStage, _slotIndex)] != null;

  /// Step the active map's route: ρ and the exponent by index into the
  /// engine's choices, the visible stops by one, each within its range.
  void _stepRoute({int rho = 0, int exponent = 0, int visible = 0}) {
    final (int, int) key = (_activeStage, _slotIndex);
    final _ShownPath? shown = _paths[key];
    if (shown == null) return;
    final _Route r = _routeOf(key);
    final int before = shown.path.stops.length - 1;
    final int nextRho = (r.rho + rho)
        .clamp(0, widget.core.landmarkRhoChoices.length - 1);
    final int nextExponent = (r.exponent + exponent)
        .clamp(0, widget.core.landmarkExponentChoices.length - 1);
    final int nextVisible = ((r.visible ?? before) + visible).clamp(0, before);
    if (nextRho == r.rho &&
        nextExponent == r.exponent &&
        nextVisible == (r.visible ?? before)) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    _setRoute(key, (
      rho: nextRho,
      exponent: nextExponent,
      visible: nextVisible == before ? null : nextVisible,
    ));
  }

  /// Step the colour scheme through the six hues.
  void _stepHue(int dir) {
    const List<HueOffset> order = HueOffset.values;
    setState(() => _hue = order[(_hue.index + dir) % order.length]);
  }

  /// The command [c]: what it shows, whether it is available now, and what it
  /// does — the actions of the former letter hotkeys, by board.
  BoardCommand _command(_Cmd c) {
    switch (c) {
      case _Cmd.layout:
        return BoardCommand(
          name: 'Keyboard layout: ${_layout.label}',
          help: 'Switches the letters printed on the board '
              '(${KeyboardLayout.values.map((KeyboardLayout l) => l.label).join(', ')}). '
              'The keys stay where they are; only their letters change. The '
              'build sets the default; a change lasts this session.',
          icon: Icons.keyboard,
          run: () {
            setState(() => _layout = _layout.next);
            _toast('Keyboard layout: ${_layout.label}.');
          },
        );
      case _Cmd.save:
        return BoardCommand(
          name: 'Save setup',
          help: 'Encrypts this setup to the file path under a provisional key '
              '(a QR, a password manager or your own key): a crutch for the '
              'memorisation window, deleted at graduation.',
          icon: Icons.save,
          enabled: !_vaultBusy,
          run: _writeSetup,
        );
      case _Cmd.open:
        return BoardCommand(
          name: 'Open setup',
          help: 'Opens an encrypted setup file with its provisional key (scan '
              'the QR or type the key).',
          icon: Icons.folder_open,
          enabled: !_vaultBusy,
          run: _openSetup,
        );
      case _Cmd.templates:
        return BoardCommand(
          name: 'Blank QR templates',
          help: 'Saves the 128- and 256-bit QR skeletons, to print and colour '
              'in by hand with the key.',
          icon: Icons.qr_code_2,
          enabled: !_vaultBusy,
          run: _exportBlankTemplate,
        );
      case _Cmd.volumeDown:
      case _Cmd.volumeUp:
        final bool up = c == _Cmd.volumeUp;
        return BoardCommand(
          name: up ? 'Volume up' : 'Volume down',
          help: 'Steps the sound cues ${up ? 'up' : 'down'} a level; level 0 '
              'is silence. Hold to keep stepping.',
          icon: up ? Icons.volume_up : Icons.volume_down,
          repeats: true,
          run: () => _changeVolume(up: up),
        );
      case _Cmd.secrets:
        return BoardCommand(
          name: 'Show or hide secrets',
          help: 'Reveals or hides the imported dice rolls or hex.',
          icon: Icons.visibility,
          active: !_importHidden,
          run: _toggleSensitiveVisibility,
        );
      case _Cmd.filePath:
        return BoardCommand(
          name: 'File path',
          help: 'Shows the setup file path, where save and open look.',
          icon: Icons.description,
          run: _focusVaultPath,
        );
      case _Cmd.reset:
        return BoardCommand(
          name: 'Reset',
          help: 'Clears the setup — σ, every point and stage — after asking. '
              'Not while an advance runs: halt it first.',
          icon: Icons.restart_alt,
          enabled: !_busy,
          run: _confirmReset,
        );
      case _Cmd.label:
        return BoardCommand(
          name: 'Key label',
          help: 'Shows the key’s label: an optional salt that versions the '
              'exported key (e.g. SIGNING-1).',
          icon: Icons.label_outline,
          run: () =>
              _showField(_Field.exportLabel, _exportLabelFocus, 'key label'),
        );
      case _Cmd.profile:
        return BoardCommand(
          name: 'Profile',
          help: 'Shows the Argon2 memory profile (← → to change).',
          icon: Icons.memory,
          run: () => _showField(_Field.profile, _profileFocus, 'Argon2 profile'),
        );
      case _Cmd.steps:
        return BoardCommand(
          name: 'Steps D',
          help: 'Shows the derivation steps per stage: the memory-hard passes '
              'each stage runs.',
          icon: Icons.repeat,
          run: () =>
              _showField(_Field.iterations, _iterationsFocus, 'derivation steps'),
        );
      case _Cmd.calibrate:
        return BoardCommand(
          name: 'Calibrate',
          help: 'Opens the calibration: pick a target time, get the steps D for '
              'this device.',
          icon: Icons.speed,
          run: _openCalibrationDialog,
        );
      case _Cmd.newPoint:
      case _Cmd.dice:
      case _Cmd.importHex:
      case _Cmd.placeByClick:
        final bool editable = _placeableBoardSlot;
        return switch (c) {
          _Cmd.newPoint => BoardCommand(
              name: 'System random',
              help: 'Places a point from this device’s random generator, after '
                  'a warning: it is only as good as the system’s randomness. '
                  'Dragon Dice is the safer entropy.',
              icon: Icons.computer,
              enabled: editable,
              run: _systemRandom,
            ),
          _Cmd.dice || _Cmd.importHex => BoardCommand(
              name: c == _Cmd.importHex ? 'Import hex' : 'Dragon Dice',
              help: c == _Cmd.importHex
                  ? 'Imports this map’s point from hex '
                      '($_kHexDigitsPerPoint digits a point).'
                  : 'Opens the Dragon Dice wizard: roll real dice until they '
                      'carry this map’s ${EncodingConstants.bitsPerPoint} '
                      'bits: entropy you make and can check, not the '
                      'device’s. Its advanced mode estimates how likely biased '
                      'dice fall short.',
              icon: c == _Cmd.importHex ? Icons.tag : null,
              glyph: c == _Cmd.importHex
                  ? null
                  : (Color colour) => D20Glyph(colour: colour),
              enabled: editable,
              run: c == _Cmd.importHex
                  ? () => _beginBoardImport(_slotIndex)
                  : () => unawaited(_rollDice()),
            ),
          _ => BoardCommand(
              name: 'Place by click',
              help: 'Arms a click: your next click on the map places its point.',
              icon: Icons.ads_click,
              enabled: editable,
              run: _armBoardManual,
            ),
        };
      case _Cmd.exclude:
        return BoardCommand(
          name: 'Exclude stage',
          help: 'Drops this stage and every deeper one, after asking.',
          icon: Icons.content_cut,
          run: _truncateOrbit,
        );
      case _Cmd.halt:
        // Halt while something derives; Resume while an advance is halted.
        final bool resume = !_busy && _canResumeAdvance;
        return BoardCommand(
          name: resume ? 'Resume' : 'Halt',
          help: resume
              ? 'Resumes the halted advance into Stage '
                  '${_advanceCheckpoint?.stage}: only its remaining passes run.'
              : 'Halts the running derivation, after asking; the passes done '
                  'are kept, and this key then resumes.',
          icon: resume ? Icons.play_arrow : Icons.pause,
          enabled: resume || _busy,
          run: resume
              ? () {
                  _sounds.play(UiSound.select);
                  unawaited(_resumeOrbitAdvance());
                }
              : _abortDerivation,
        );
      case _Cmd.copyKey:
      case _Cmd.copyDigest:
        final bool full = c == _Cmd.copyDigest;
        return BoardCommand(
          name: full ? 'Copy full digest' : 'Copy key',
          help: full
              ? 'Copies the full export digest, not just its first 32 '
                  'characters.'
              : 'Derives and copies this stage’s key, blind: never shown.',
          icon: full ? Icons.fingerprint : Icons.key,
          enabled: !_busy,
          run: () => _copyMasterSecret(full: full),
        );
      case _Cmd.prevStop:
      case _Cmd.nextStop:
        final bool next = c == _Cmd.nextStop;
        return BoardCommand(
          name: next ? 'Next stop' : 'Previous stop',
          help: 'Flies to the ${next ? 'next' : 'previous'} stop shown, '
              'wrapping around: zooming out, across and back in along the '
              'shortest way, the way the path’s hops are measured.',
          icon: next ? Icons.skip_next : Icons.skip_previous,
          enabled: _routeReady,
          run: () => _cycleStop(next ? 1 : -1),
        );
      case _Cmd.numbers:
        return BoardCommand(
          name: 'Stop numbers',
          help: 'Shows or hides the stops’ numbered markers.',
          icon: Icons.format_list_numbered,
          active: _showNumbers,
          run: () {
            _sounds.play(_showNumbers ? UiSound.modeOff : UiSound.modeOn);
            setState(() => _showNumbers = !_showNumbers);
          },
        );
      case _Cmd.lines:
        return BoardCommand(
          name: 'Stop lines',
          help: 'Shows or hides the line from stop to stop.',
          icon: Icons.timeline,
          active: _showLines,
          run: () {
            _sounds.play(_showLines ? UiSound.modeOff : UiSound.modeOn);
            setState(() => _showLines = !_showLines);
          },
        );
      case _Cmd.framePath:
        return BoardCommand(
          name: 'Frame the path',
          help: 'Flies to the view holding every stop shown.',
          icon: Icons.fit_screen,
          enabled: _routeReady,
          run: () {
            final (int, int) key = (_activeStage, _slotIndex);
            final _ShownPath? shown = _paths[key];
            if (shown == null) return;
            _sounds.play(UiSound.navZoom);
            _frame(_visibleOf(shown.path, _routeOf(key).visible));
          },
        );
      case _Cmd.rhoZoom:
      case _Cmd.rhoPan:
        final bool zoom = c == _Cmd.rhoZoom;
        return BoardCommand(
          name: zoom ? 'ρ toward zoom' : 'ρ toward pan',
          help: zoom
              ? 'Makes zooming cheaper than panning: a route with fewer stops.'
              : 'Makes panning cheaper than zooming: a route with more stops.',
          icon: zoom ? Icons.zoom_in : Icons.pan_tool,
          enabled: _routeReady,
          run: () => _stepRoute(rho: zoom ? 1 : -1),
        );
      case _Cmd.exponentDown:
      case _Cmd.exponentUp:
        final bool up = c == _Cmd.exponentUp;
        return BoardCommand(
          name: up ? 'Exponent up' : 'Exponent down',
          help: up
              ? 'Penalises long hops more: shorter hops, more stops.'
              : 'Tolerates longer hops: fewer stops.',
          glyph: (Color colour) => HopGlyph(spread: !up, colour: colour),
          enabled: _routeReady,
          run: () => _stepRoute(exponent: up ? 1 : -1),
        );
      case _Cmd.path:
        return BoardCommand(
          name: 'Landmark path',
          help: 'Shows or hides the landmark path of this map’s point: its '
              'features outlined, joined by a line, numbered.',
          icon: Icons.route,
          active: _showPath,
          run: _toggleLandmarkPath,
        );
      case _Cmd.stopsDown:
      case _Cmd.stopsUp:
        final bool up = c == _Cmd.stopsUp;
        return BoardCommand(
          name: up ? 'More stops shown' : 'Fewer stops shown',
          help: up
              ? 'Shows one more stop before the leaf.'
              : 'Hides the shallowest stop shown. With none left the map is '
                  'unaided, and its review is graded.',
          icon: up ? Icons.layers : Icons.layers_clear,
          enabled: _routeReady,
          repeats: true,
          run: () => _stepRoute(visible: up ? 1 : -1),
        );
      case _Cmd.islands:
        return BoardCommand(
          name: 'Reveal islands',
          help: 'Highlights the canonical islands in view (zoom in if there are '
              'too many).',
          icon: Icons.diamond,
          enabled: !_busy && _isBoardSlot,
          run: () => unawaited(_boardEnumerateIslands()),
        );
      case _Cmd.deepRender:
        return BoardCommand(
          name: 'Deep render',
          help: 'Renders up to the encoder’s escape cap, revealing leaves in '
              'escape-count voids (slower).',
          icon: Icons.blur_on,
          active: _deepRender,
          run: _toggleDeepRender,
        );
      case _Cmd.autoBrightness:
        return BoardCommand(
          name: 'Auto brightness',
          help: 'Brightness and slope follow each view; a manual step turns it '
              'off.',
          icon: Icons.brightness_auto,
          active: _brightness.autoExposure,
          run: _brightness.toggleAutoExposure,
        );
      case _Cmd.brightnessDown:
      case _Cmd.brightnessUp:
        final bool up = c == _Cmd.brightnessUp;
        return BoardCommand(
          name: up ? 'Brighter' : 'Darker',
          help: 'Moves the lit band ${up ? 'up' : 'down'}. Hold to keep '
              'stepping.',
          icon: up ? Icons.brightness_high : Icons.brightness_low,
          repeats: true,
          run: () => _brightness.adjustBySteps(up ? 1.0 : -1.0),
        );
      case _Cmd.slopeDown:
      case _Cmd.slopeUp:
        final bool up = c == _Cmd.slopeUp;
        return BoardCommand(
          name: up ? 'More shades' : 'Fewer shades',
          help: 'Spreads the brightness falloff over ${up ? 'more' : 'fewer'} '
              'escape counts. Hold to keep stepping.',
          icon: up ? Icons.gradient : Icons.contrast,
          repeats: true,
          run: () => _brightness.adjustSlopeBySteps(up ? 1.0 : -1.0),
        );
      case _Cmd.hueDown:
      case _Cmd.hueUp:
        final bool up = c == _Cmd.hueUp;
        return BoardCommand(
          name: up ? 'Next hue' : 'Previous hue',
          help: 'Cycles the colour scheme through its six hues (now: '
              '${_hue.name}).',
          icon: up ? Icons.rotate_right : Icons.rotate_left,
          repeats: true,
          run: () => _stepHue(up ? 1 : -1),
        );
    }
  }

  /// Reveal or hide the imported dice rolls or hex (Main board).
  void _toggleSensitiveVisibility() {
    final bool reveal = _importHidden;
    setState(() => _importHidden = !reveal);
    _toast(reveal ? 'Sensitive text revealed.' : 'Sensitive text hidden.');
  }

  /// Step the UI sound-cue volume one level (Main board). Plays a cue at
  /// the new level as feedback — silent at level 0, which *is* the cue that the
  /// app is now muted — and notes the level in the console.
  void _changeVolume({required bool up}) {
    final int level = up ? _sounds.volumeUp() : _sounds.volumeDown();
    _sounds.play(up ? UiSound.adjustUp : UiSound.adjustDown);
    _toast(level == 0 ? 'Volume muted.' : 'Volume $level/$kMaxVolumeLevel.');
  }

  /// Current render escape-count cap: the fast default, or the engine's encode
  /// cap when deep render (View board) is on.
  int get _renderMaxIter => _deepRender
      ? widget.core.encodeParams.maxIter
      : EncodingConstants.renderMaxIterFast;

  /// Toggle deep render mode (View board). Raises/lowers the canvas escape-count cap
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

  /// Toggle the landmark path on the active map (Path board). The mode is
  /// announced; the path never is.
  void _toggleLandmarkPath() {
    setState(() => _showPath = !_showPath);
    _sounds.play(_showPath ? UiSound.modeOn : UiSound.modeOff);
    final bool computing = _showPath &&
        _isBoardSlot &&
        _boardPoints[_activeStage][_slotIndex] != null &&
        !_paths.containsKey((_activeStage, _slotIndex));
    _toast(!_showPath
        ? 'Landmark path off.'
        : computing
            ? 'Landmark path on — computing (a few seconds)…'
            : 'Landmark path on.');
  }

  /// Drop (and wipe) every landmark path and free every candidate set: the
  /// points they lead to changed, or may have. Routes are kept; the maps whose
  /// points did change are reset by [_mapsChanged].
  void _dropPaths() {
    for (final _ShownPath? p in _paths.values) {
      p?.path.wipe();
    }
    _paths.clear();
    for (final LandmarkCandidates? c in _candidates.values) {
      c?.dispose();
    }
    _candidates.clear();
    _pathsPending.clear();
    _pathGeneration++;
  }

  /// The engine's default route: its ρ and exponent among the choices, every
  /// stop visible.
  _Route get _defaultRoute {
    final LandmarkParams p = widget.core.landmarkParams;
    return (
      rho: widget.core.landmarkRhoChoices.indexWhere(
          (LandmarkRho r) => r.num * p.rhoDen == p.rhoNum * r.den),
      exponent:
          widget.core.landmarkExponentChoices.indexOf(p.badnessExponent),
      visible: null,
    );
  }

  _Route _routeOf((int, int) key) => _routes[key] ?? _defaultRoute;

  /// A route as a card's cues: the engine's values, not the panel's indices.
  Cues _cuesOf(_Route r) {
    final LandmarkRho rho = widget.core.landmarkRhoChoices[r.rho];
    return Cues(
      rhoNum: rho.num,
      rhoDen: rho.den,
      exponent: widget.core.landmarkExponentChoices[r.exponent],
      visible: r.visible,
    );
  }

  /// A card's cues as a route, or null if its ρ or exponent is not among this
  /// engine's choices (the map then shows the default route).
  _Route? _routeOfCues(Cues c) {
    final int rho = widget.core.landmarkRhoChoices
        .indexWhere((LandmarkRho r) => r.num * c.rhoDen == c.rhoNum * r.den);
    final int exponent =
        widget.core.landmarkExponentChoices.indexOf(c.exponent);
    if (rho < 0 || exponent < 0) return null;
    return (rho: rho, exponent: exponent, visible: c.visible);
  }

  /// The maps matching [changed] hold new points, or none ([drop]: their stage
  /// is gone). Their routes keep ρ and the exponent with every stop shown
  /// again; their deck cards restart — the schedule was for another point —
  /// or, with [drop], leave the deck.
  void _mapsChanged(
    bool Function(int stage, int slot) changed, {
    bool drop = false,
  }) {
    for (final (int, int) key in _routes.keys.toList()) {
      if (!changed(key.$1, key.$2)) continue;
      final _Route r = _routes[key]!;
      _routes[key] = (rho: r.rho, exponent: r.exponent, visible: null);
    }
    final Deck? deck = _deck;
    if (deck == null) return;
    Deck next = deck;
    for (final MemCard c in deck.cards) {
      if (c.kind != CardKind.point || !changed(c.stageIndex, c.slot)) continue;
      next = drop
          ? next.removeMap(c.stageIndex, c.slot)
          : next.withCard(MemCard.map(c.stageIndex, c.slot,
              (c.cues ?? _cuesOf(_defaultRoute)).withVisible(null)));
    }
    _deck = next;
  }

  /// Whether stage [stage]'s slot [slot] holds a point the holder placed (not
  /// a derived share).
  bool _placed(int stage, int slot) =>
      _boardPoints[stage][slot] != null && !_boardDerived[stage][slot];

  /// The deck to save: the current one (or a fresh one, a card per placed
  /// map), every placed map in it, and the session's routes as its cues.
  Deck _deckForSave(int deepest) {
    final Cues start = _cuesOf(_defaultRoute);
    final List<List<int>> placed = <List<int>>[
      for (int i = 0; i <= deepest; i++)
        <int>[
          for (int s = 1; s <= _maxSlot; s++)
            if (_placed(i, s)) s,
        ],
    ];
    Deck deck = _deck ?? buildDeck(maps: placed, cues: start);
    for (int i = 0; i <= deepest; i++) {
      for (final int s in placed[i]) {
        deck = deck.addMap(i, s, start);
      }
    }
    _routes.forEach(((int, int) key, _Route r) {
      final MemCard? card = deck.map(key.$1, key.$2);
      if (card != null) deck = deck.withCard(card.copyWith(cues: _cuesOf(r)));
    });
    return deck;
  }

  /// Set [key]'s route. A new ρ or exponent searches again, with every stop
  /// visible; the current path stays drawn until the new one is found.
  void _setRoute((int, int) key, _Route route) {
    final _Route old = _routeOf(key);
    final bool reroute = route.rho != old.rho || route.exponent != old.exponent;
    final _Route next = reroute
        ? (rho: route.rho, exponent: route.exponent, visible: null)
        : route;
    setState(() {
      _routes[key] = next;
      final _ShownPath? p = _paths[key];
      if (!reroute && p != null) {
        _paths[key] = (
          path: p.path,
          rho: p.rho,
          exponent: p.exponent,
          overlay: _canvasPathOf(p.path, next.visible),
        );
      }
    });
  }

  /// The landmark-path overlay of [slot]'s point on the active stage, or null
  /// while it is first computed (which this starts) or if the point has none.
  /// A path searched for another route stays drawn while this searches again.
  CanvasPath? _pathOverlay(int slot) {
    final (int, int) key = (_activeStage, slot);
    final _Route route = _routeOf(key);
    final _ShownPath? shown = _paths[key];
    final bool current = _paths.containsKey(key) &&
        (shown == null ||
            (shown.rho == route.rho && shown.exponent == route.exponent));
    if (!current && !_pathsPending.contains(key)) {
      unawaited(_computePath(key, slot));
    }
    final CanvasPath? overlay = shown?.overlay;
    if (overlay == null) return null;
    // The same stops (so their traced outlines are kept), drawn as set.
    return CanvasPath(
      stops: overlay.stops,
      showNumbers: _showNumbers,
      showLine: _showLines,
    );
  }

  /// The stops of [path] drawn with [visible] stops before the leaf (null:
  /// all), the shallowest hidden first.
  static List<LandmarkFeature> _visibleOf(LandmarkPath path, int? visible) {
    final int before = path.stops.length - 1;
    final int shown = visible == null ? before : visible.clamp(0, before);
    return path.stops.skip(before - shown).toList();
  }

  /// How much larger than the framed stops a frame is, and the fewest cells
  /// of a stop it spans: a stop fills about a third of the view.
  static const double _kFrameMargin = 3.0;
  static const double _kFrameMinCells = 8.0;

  /// Fly to the view framing [stops] (their bounding boxes together).
  void _frame(List<LandmarkFeature> stops) {
    double reMin = double.infinity, reMax = -double.infinity;
    double imMin = double.infinity, imMax = -double.infinity;
    double cell = 0;
    for (final LandmarkFeature f in stops) {
      reMin = math.min(reMin, fixedToDouble(f.bboxReMin));
      reMax = math.max(reMax, fixedToDouble(f.bboxReMax));
      imMin = math.min(imMin, fixedToDouble(f.bboxImMin));
      imMax = math.max(imMax, fixedToDouble(f.bboxImMax));
      cell = math.max(cell, fixedToDouble(f.cellRaw));
    }
    final double span = math.max(reMax - reMin, imMax - imMin);
    final double half =
        math.max(span * _kFrameMargin, cell * _kFrameMinCells) / 2;
    _flyTo((reMin + reMax) / 2, (imMin + imMax) / 2, half);
  }

  /// Fly the view smoothly to centre `(re, im)` at half-extent [half]
  /// ([ZoomFlight]). Any pointer input on the map stops it.
  void _flyTo(double re, double im, double half) {
    _stopFlight();
    final FractalViewport from = _viewport.viewport;
    final ZoomFlight f = ZoomFlight(
      re0: from.centreRe,
      im0: from.centreIm,
      w0: 2 * from.halfExtent,
      re1: re,
      im1: im,
      w1: 2 * half,
    );
    final int total = f.duration.inMicroseconds;
    final Ticker t = createTicker((Duration elapsed) {
      final double progress = elapsed.inMicroseconds / total;
      final ({double re, double im, double w}) v = f.at(progress);
      _viewport.viewport = _viewport.viewport
          .copyWith(centreRe: v.re, centreIm: v.im, halfExtent: v.w / 2);
      if (progress >= 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _stopFlight());
      }
    });
    _flight = t;
    t.start();
  }

  void _stopFlight() {
    _flight?.dispose();
    _flight = null;
  }

  /// Fly to the next (or, with [dir] -1, the previous) stop shown on the
  /// active map's path, wrapping around; the first press goes to the first
  /// stop (or the last).
  void _cycleStop(int dir) {
    final (int, int) key = (_activeStage, _slotIndex);
    final _ShownPath? shown = _paths[key];
    if (shown == null) return;
    final int? visible = _routeOf(key).visible;
    final List<LandmarkFeature> stops = _visibleOf(shown.path, visible);
    final int n = stops.length;
    final ({(int, int) key, LandmarkPath path, int? visible, int index})? at =
        _stopAt;
    final bool fresh = at == null ||
        at.key != key ||
        !identical(at.path, shown.path) ||
        at.visible != visible;
    final int index =
        fresh ? (dir > 0 ? 0 : n - 1) : (at.index + dir) % n;
    _stopAt = (key: key, path: shown.path, visible: visible, index: index);
    _sounds.play(UiSound.navZoom);
    _frame(<LandmarkFeature>[stops[index]]);
  }

  /// Search [slot]'s landmark path for [key]'s route off the UI isolate,
  /// scanning its candidates first if needed (seconds; a search alone is
  /// fast), and cache it under [key].
  Future<void> _computePath((int, int) key, int slot) async {
    final ({int reRaw, int imRaw})? pt = _boardPoints[key.$1][slot];
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (pt == null || prm == null) return;
    _pathsPending.add(key);
    final int generation = _pathGeneration;
    LandmarkCandidates? candidates = _candidates[key];
    if (!_candidates.containsKey(key)) {
      final CoreDecodeResult d = widget.core.decodePoint(
          reRaw: pt.reRaw, imRaw: pt.imRaw, o: prm.o, p: prm.p, q: prm.q);
      if (d.valid) {
        try {
          candidates = await widget.core.landmarkCandidates(
              leafRect: d.leafRect, path: d.path, o: prm.o, p: prm.p, q: prm.q);
        } on Object {
          candidates = null;
        }
      }
      if (!mounted || generation != _pathGeneration) {
        candidates?.dispose();
        return;
      }
      _candidates[key] = candidates;
    }
    final _Route route = _routeOf(key);
    LandmarkPath? path;
    try {
      path = await candidates?.search(
        rho: widget.core.landmarkRhoChoices[route.rho],
        exponent: widget.core.landmarkExponentChoices[route.exponent],
      );
    } on Object {
      path = null;
    }
    if (!mounted || generation != _pathGeneration) {
      path?.wipe();
      return;
    }
    final LandmarkPath? found = path;
    setState(() {
      _pathsPending.remove(key);
      _paths[key]?.path.wipe();
      // If the route changed meanwhile, the next build searches again.
      _paths[key] = found == null
          ? null
          : (
              path: found,
              rho: route.rho,
              exponent: route.exponent,
              overlay: _canvasPathOf(found, _routeOf(key).visible),
            );
    });
    if (found == null && _showPath) _toast('No landmark path for this point.');
  }

  /// A landmark path as an overlay: each stop at its barycentre, its feature
  /// highlighted from its own cells. With [visible] set, only that many stops
  /// before the leaf are drawn, the shallowest hidden first. The cells are
  /// shared, so wiping the path blanks the overlay too.
  CanvasPath _canvasPathOf(LandmarkPath path, int? visible) {
    return CanvasPath(
      stops: <CanvasPathStop>[
        for (final LandmarkFeature f in _visibleOf(path, visible))
          CanvasPathStop(
            re: fixedToDouble(f.barycentreRe),
            im: fixedToDouble(f.barycentreIm),
            cells: CanvasCells(
              originRe: fixedToDouble(f.cellsOriginRe),
              originIm: fixedToDouble(f.cellsOriginIm),
              cellSize: fixedToDouble(f.cellRaw),
              width: f.cellsWidth,
              height: f.cellsHeight,
              cells: f.cells,
            ),
          ),
      ],
    );
  }

  /// The route panel of the active board's path, while it is shown: ρ
  /// (left favours zooming, right panning), the exponent (fewer or more
  /// stops) and the stops visible before the leaf. Both route sliders give
  /// more stops to the right. Words only: the values are the engine's.
  Widget? _routePanel() {
    if (!_showPath || !_isBoardSlot || _slotIndex < 1) return null;
    final (int, int) key = (_activeStage, _slotIndex);
    final _ShownPath? shown = _paths[key];
    if (shown == null) return null;
    final _Route route = _routeOf(key);
    final int rhos = widget.core.landmarkRhoChoices.length;
    final int exponents = widget.core.landmarkExponentChoices.length;
    final int before = shown.path.stops.length - 1;
    final int visible = (route.visible ?? before).clamp(0, before);
    Widget row(String left, String right, int value, int max,
            ValueChanged<int>? onChanged) =>
        Row(
          children: <Widget>[
            SizedBox(
                width: _kRouteLabelWidth,
                child: Text(left, style: _routeLabel)),
            Expanded(
              child: Slider(
                value: value.toDouble(),
                max: max < 1 ? 1 : max.toDouble(),
                divisions: max < 1 ? 1 : max,
                onChanged: max < 1 || onChanged == null
                    ? null
                    : (double v) => onChanged(v.round()),
              ),
            ),
            SizedBox(
              width: _kRouteLabelWidth,
              child: Text(right, style: _routeLabel, textAlign: TextAlign.end),
            ),
          ],
        );
    // Compact thumbs, so the three rows fit the pane without scrolling.
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        overlayShape:
            const RoundSliderOverlayShape(overlayRadius: _kRouteThumbReach),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Higher ρ favours zooming: the list runs right to left.
          row('zoom', 'pan', rhos - 1 - route.rho, rhos - 1,
              (int v) => _setRoute(key, (
                    rho: rhos - 1 - v,
                    exponent: route.exponent,
                    visible: route.visible,
                  ))),
          row('fewer', 'more stops', route.exponent, exponents - 1,
              (int v) => _setRoute(key, (
                    rho: route.rho,
                    exponent: v,
                    visible: route.visible,
                  ))),
          row('no stops', 'all shown', visible, before,
              (int v) => _setRoute(key, (
                    rho: route.rho,
                    exponent: route.exponent,
                    visible: v,
                  ))),
        ],
      ),
    );
  }

  static const TextStyle _routeLabel =
      TextStyle(color: Colors.white, fontSize: 12);

  /// Width of a route slider's end labels, and the reach of its thumb's touch
  /// overlay (half a row's height), in logical pixels.
  static const double _kRouteLabelWidth = 72;
  static const double _kRouteThumbReach = 14;

  /// Select stage [index] (its tab or Alt+digit), unless an advance runs.
  void _selectStage(int index) {
    if (_busy) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    _selectOrbitStage(index);
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
    // o_{index} = H*(u_{index-1}) from the (now complete) preceding stage.
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
    final int r = _requiredOf(stage);
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
  /// `o_target = H*(u_{target-1})` (via [GreatWallCore.startOrbitAdvance] in a
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
      _toast('Place stage $from’s ${_requiredOf(from)} required points '
          'first.');
      return;
    }
    final Uint8List? shBytes = _stageShBytes(from);
    if (shBytes == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Place stage $from’s ${_requiredOf(from)} required points '
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
          ? 'Advance into Stage $target halted after $done/$steps passes — '
              'kept. Resume (${_hint(_Cmd.halt)}) continues from there; Write '
              '(${_hint(_Cmd.save)}) keeps it across sessions (the file then '
              'holds the partial derivation — guard it). Changing D, or '
              're-placing a point in a shallower stage, discards it.'
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
      _toast('Advance halted again after $done/$steps passes — kept. Resume '
          '(${_hint(_Cmd.halt)}) continues from there.');
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

  /// Recenter the canvas to the default position/zoom and reset brightness,
  /// without touching the session. Triggered automatically on arriving at a
  /// stage (the old `R` behaviour, now folded into stage selection).
  void _recenter() {
    _viewport.viewport = _initialViewport;
    _brightness.reset();
    setState(() {});
  }

  /// Stage-0 fractal slot (`#j≥1`): the real orbit board `θ_0_(j-1)` derived
  /// from σ → o₀. Any slot may carry a placed point (shown as a white cross)
  /// until `r_0` are placed; the rest then derive and lock. Point
  /// entry: Place by click arms a manual click (the canvas takes a click only
  /// while it is armed). When σ is unset/invalid a "set σ first" panel is shown.
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
      // A click lands only while Place by click is armed; on a leaf that
      // cannot encode the mode stays armed to retry.
      onSelect: _editPointMode
          ? (FractalSelection sel) {
              if (_placeableBoardSlot && _placePrimaryAt(_slotIndex, sel)) {
                setState(() => _editPointMode = false);
              }
            }
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
      path: _showPath && pt != null ? _pathOverlay(slot) : null,
    );
  }

  /// The orbit point `o_i` for [stage]. Stage 0 is `o_0 = H(σ)` (derived on the
  /// fly from slot 0's Namtso salt, so there is no separate `o_0` state to keep
  /// in sync); a deep stage's `o_i = H*(u_{i-1})` is read from [_orbitO], filled
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
  /// speck. Pure visualisation; never affects encoded bits.
  CoreDiscoveryParams get _islandVizParams {
    final CoreDiscoveryParams b = widget.core.encodeParams;
    return CoreDiscoveryParams(
      maxIter: b.maxIter,
      targetGood: b.targetGood,
      maxFloodPoints: widget.core.canonicalMaxFloodPoints,
      minGridCells: b.minGridCells,
      pMaxShift: b.pMaxShift,
      exclusionThresholdNum: b.exclusionThresholdNum,
      rngSeed: b.rngSeed,
    );
  }

  /// Build the canonical-island decoration (cells + bbox) for a known leaf on the
  /// board's `(o, p, q)`, or null if the island can't be resolved.
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
  /// of the engine's canonical-island enumeration).
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
  /// always framed.
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
  /// [_changePointGenerated].
  void _generatePrimary(int slot) {
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (prm == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Set σ in slot 0 first.');
      return;
    }
    final List<int> bits = Entropy.randomBits(EncodingConstants.bitsPerPoint);
    final EncodedPoint pt = widget.core
        .encodeStage(List<int>.of(bits), o: prm.o, p: prm.p, q: prm.q)
        .first;
    _setPrimary(slot, bits, (reRaw: pt.reRaw, imRaw: pt.imRaw));
    Entropy.wipe(bits);
    _sounds.play(UiSound.selectPoint);
  }

  /// The point's bits from the import editor's hex (exactly
  /// [_kHexDigitsPerPoint] digits). Null, with the reason told, when the
  /// input does not give them; the caller owns and wipes the bits.
  List<int>? _importedBits() {
    try {
      final List<int> bits =
          Entropy.hexToBits(_pointImport.text.trim().toUpperCase());
      if (bits.length != EncodingConstants.bitsPerPoint) {
        Entropy.wipe(bits);
        throw const FormatException(
            'Enter $_kHexDigitsPerPoint hex digits.');
      }
      return bits;
    } on FormatException catch (e) {
      _sounds.play(UiSound.denyInput);
      _toast(e.message);
      return null;
    }
  }

  /// Hex digits in a point: 4 bits a digit.
  static const int _kHexDigitsPerPoint = EncodingConstants.bitsPerPoint ~/ 4;

  /// Open the inline hex editor for slot [slot]'s point.
  void _beginBoardImport(int slot) {
    _pointImport.clear();
    setState(() => _boardImportSlot = slot);
    _pointImportFocus.requestFocus();
  }

  /// Width and height of the Dragon Dice wizard's dialog, in logical pixels.
  static const double _kDiceWizardWidth = 960;
  static const double _kDiceWizardHeight = 620;

  /// Enter slot [_slotIndex]'s point with the Dragon Dice wizard: rolls of
  /// real dice until they carry the point's bits; the point is the first
  /// bits of their digest (dragon-dice/doc/FORMAT.md).
  Future<void> _rollDice() async {
    final int slot = _slotIndex;
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (prm == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Set σ in slot 0 first.');
      return;
    }
    DiceRolls? rolled;
    await _dialog(
      _Cue.dice,
      () => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => Dialog(
          child: SizedBox(
            width: _kDiceWizardWidth,
            height: _kDiceWizardHeight,
            child: DragonDiceWizard(
              targetBits: EncodingConstants.bitsPerPoint.toDouble(),
              purpose: 'Slot $slot’s point',
              onCue: _cue,
              onDone: (DiceRolls r) {
                rolled = r;
                Navigator.of(ctx).pop();
              },
              onCancel: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      ),
    );
    final DiceRolls? r = rolled;
    if (r == null) return;
    final Uint8List digest = r.digest();
    r.wipe();
    final List<int> bits = digestBits(digest, EncodingConstants.bitsPerPoint);
    digest.fillRange(0, digest.length, 0);
    if (!mounted) {
      Entropy.wipe(bits);
      return;
    }
    final EncodedPoint pt = widget.core
        .encodeStage(List<int>.of(bits), o: prm.o, p: prm.p, q: prm.q)
        .first;
    _setPrimary(slot, bits, (reRaw: pt.reRaw, imRaw: pt.imRaw));
    Entropy.wipe(bits);
    _sounds.play(UiSound.selectPoint);
  }

  /// Apply the inline import to the pending board slot: 8 hex → 32 bits,
  /// encoded to a board point.
  void _applyBoardImport() {
    final int slot = _boardImportSlot!;
    final ({int o, int p, int q})? prm = _boardPrm(slot);
    if (prm == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Set σ in slot 0 first.');
      return;
    }
    final List<int>? bits = _importedBits();
    if (bits == null) return;
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
      title: 'Slot $slot',
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
      // (o_{i+1}=H*(u_i)), so their advanced o_i / K_i and any placed points no
      // longer decode — drop them; the user re-advances from the settled prefix.
      _invalidateDeeperThan(stage);
      // This map, and the stage's derived shares, hold new points.
      _mapsChanged((int st, int sl) =>
          st == stage && (sl == slot || !_placed(st, sl)));
      // Placing this point (and re-deriving the shares) invalidates the cached
      // island decorations; the canonical view (if any) referred to the old one.
      _boardDecoCache.clear();
      _dropPaths();
      _boardCanonicalView = false;
    });
    // Pick the marker mode for the freshly placed point at the current zoom.
    _updateBoardMarkerMode();
  }

  /// Drop every stage deeper than [stage] (wiping its chunks, points, `o_i` and
  /// `K_i`). Called when an earlier stage's point changes, since a re-rooted
  /// prefix invalidates the whole memory-hard advance chain beyond it. Must run
  /// inside a [setState].
  void _invalidateDeeperThan(int stage) {
    // A halted advance into any deeper stage was derived from the prefix that
    // just changed, so its checkpoint no longer leads anywhere.
    final ({int stage, int pass, Uint8List digest})? cp = _advanceCheckpoint;
    if (cp != null && cp.stage > stage) _clearAdvanceCheckpoint();
    // The deeper stages' maps are gone until re-advanced, to other maps.
    _mapsChanged((int st, int _) => st > stage, drop: true);
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
    final int r = _requiredOf(stage);
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
    // accumulate; should a file carry more, the lowest-indexed r_i win and the
    // surplus re-derive below.
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
      _dropPaths();
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
    _mapsChanged((int _, int __) => true);
    _deck = null;
    _dropPaths();
    _boardCanonicalView = false;
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
    // Re-point the render source every build (cheap): another board may have
    // set its own reservoirs since this one was last shown, so reclaim the
    // shared source for the board on screen.
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

  /// Show an inline console confirmation and complete with the user's choice
  /// when they press a button. Shared by every confirm flow (re-derive, abort,
  /// reset). Ensures the console is expanded so the prompt is visible.
  Future<bool> _consoleConfirm({
    required String message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
    bool warning = false,
  }) {
    final Completer<bool> completer = Completer<bool>();
    _resolvePrompt(false); // decline any already-pending prompt first
    // A confirmation is being raised: the disclaimer's, or an ordinary one.
    _cue(warning ? _Cue.alertWarning : _Cue.alertConfirm);
    setState(() {
      _chromeMinimized = false; // make sure the prompt is visible
      _prompt = _ConsolePrompt(
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        completer: completer,
        warning: warning,
      );
    });
    return completer.future;
  }

  /// Place a point on the map from the device's random generator (Setup
  /// board), after the disclaimer.
  Future<void> _systemRandom() async {
    if (!await _confirmSystemRandom() || !mounted) return;
    if (_placeableBoardSlot) _generatePrimary(_slotIndex);
  }

  /// The disclaimer before every use of the device's random generator for a
  /// point.
  Future<bool> _confirmSystemRandom() => _consoleConfirm(
        message: 'SYSTEM RANDOMNESS. This point’s entropy is only as good as '
            'this device’s random generator. If that generator is weak or '
            'compromised, so is your point — and this app bears no '
            'responsibility for it. If in doubt, use Dragon Dice '
            '(${_hint(_Cmd.dice)}) or another entropy source you trust more.',
        confirmLabel: 'Use system randomness',
        warning: true,
      );

  Widget _progressOverlay() {
    // The stage tab above fills as the bar; this states the cost in passes and
    // offers Halt: cancelling kills the worker isolate, costing at most the
    // pass in flight.
    return ColoredBox(
      color: Colors.black54,
      child: Align(
        alignment: const Alignment(0, 0.3),
        child: Column(
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
              onPressed: _press(
                _Cue.advanceHalt,
                _advanceJob == null
                    ? null
                    : () => _advanceJob?.cancel(),
              ),
              child: const Text('Halt'),
            ),
          ],
        ),
      ),
    );
  }

  // --- Console ----------------------------------------------------------------

  /// Console palette: "Gunmetal" — a cool, near-neutral blue-grey, translucent
  /// over the canvas so the fractal faintly bleeds through. The slight blue cast
  /// (channels offset a few levels from pure grey) reads as a *material* rather
  /// than an abstract flat grey; it stays unsaturated enough to sit neutrally
  /// against all six fractal hue schemes. See great-wall-ux/SCOPE.md
  /// §"Console palette" for the rationale.
  static const Color _kConsoleBg = Color(0xE6131519); // ~90% opaque gunmetal
  static const Color _kConsoleFg = Color(0xFFE9EDF2); // cool off-white
  static const Color _kConsoleAccent = Color(0xFFB8C2CC); // brighter, same cast
  static const Color _kConsoleWarning = Color(0xFFFFB300); // amber: a disclaimer

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
    final String status = _prompt?.message ??
        focusHelp ??
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
          tooltip: 'Restore (F1)',
          color: _kConsoleFg,
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: _press(
            _Cue.panelRestore,
            () => setState(() => _chromeMinimized = false),
          ),
        ),
      ],
    );
  }

  /// Height of the expanded bottom panel: the command board's tabs and three
  /// rows, with their padding.
  static const double _kPanelHeight = 30 +
      kBoardGap +
      kBoardRows * (kBoardButtonHeight + kBoardGap) +
      _kPanelPadding * 2;
  static const double _kPanelPadding = 8;

  /// The expanded bottom panel: the command board flush left, the context's
  /// pane ([_contextPane]), and the log — an inline prompt, focus help, then
  /// the recent lines.
  /// While a board button or tab has the pointer or focus, its explanation
  /// takes the log's place; the log returns when it leaves.
  Widget _consoleExpanded() {
    return SizedBox(
      height: _kPanelHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(_kPanelPadding),
            child: CommandBoard(
              active: _context,
              commands: _board(),
              layout: _layout,
              colour: _kConsoleFg,
              onContext: _setContext,
              onExplain: _explain,
              onCue: _cue,
            ),
          ),
          VerticalDivider(
            width: 1,
            color: _kConsoleAccent.withValues(alpha: 0.25),
          ),
          SizedBox(width: _kPaneWidth, child: _contextPane()),
          VerticalDivider(
            width: 1,
            color: _kConsoleAccent.withValues(alpha: 0.25),
          ),
          Expanded(child: _logArea()),
        ],
      ),
    );
  }

  /// The log side of the bottom panel.
  Widget _logArea() {
    const EdgeInsets pad = EdgeInsets.fromLTRB(12, 8, 12, 0);
    final String? explaining = _explaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header.
        Row(
          children: <Widget>[
            const SizedBox(width: 12),
            const Icon(Icons.terminal),
            const SizedBox(width: 8),
            Text('Log',
                style: _termStyle.copyWith(
                    color: _kConsoleAccent, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              tooltip: 'Collapse (F1)',
              color: _kConsoleFg,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _press(_Cue.panelCollapse, _togglePanel),
            ),
          ],
        ),
        Divider(height: 1, color: _kConsoleAccent.withValues(alpha: 0.25)),
        // A pending confirmation takes the whole log, over any explanation.
        if (_prompt != null)
          Expanded(
            child: Padding(
              padding: pad.copyWith(bottom: _kPanelPadding),
              child: _consolePromptBlock(),
            ),
          )
        else if (explaining != null)
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.info_outline, size: 14),
                  const SizedBox(width: 6),
                  Expanded(child: Text(explaining)),
                ],
              ),
            ),
          )
        else ...<Widget>[
          // The focused field's help; it scrolls rather than overflow.
          if (_focusedField != null)
            Flexible(
              child: SingleChildScrollView(
                padding: pad,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.info_outline, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_fieldHelp(_focusedField!))),
                  ],
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final String line in _consoleLog) Text('› $line'),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// The inline confirmation block (replaces modal dialogs): the prompt message,
  /// scrolling if long, over Cancel / Confirm buttons that complete the pending
  /// future. Fills the height it is given.
  Widget _consolePromptBlock() {
    final _ConsolePrompt p = _prompt!;
    final Color accent = p.warning ? _kConsoleWarning : _kConsoleFg;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent, width: p.warning ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              child: p.warning
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.warning_amber, color: accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            p.message,
                            style: TextStyle(
                                color: accent, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    )
                  : Text(p.message),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                style: TextButton.styleFrom(foregroundColor: _kConsoleFg),
                onPressed:
                    _press(_Cue.promptCancel, () => _resolvePrompt(false)),
                child: Text(p.cancelLabel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _kConsoleFg,
                  foregroundColor: _kConsoleBg,
                ),
                onPressed:
                    _press(_Cue.promptConfirm, () => _resolvePrompt(true)),
                child: Text(p.confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The Setup board's pane: an open import editor, else the field the board
  /// last brought up (key label, profile or steps D) — input only, centred.
  Widget? _setupPane() {
    if (_boardImportSlot != null) return _boardImportEditor();
    return switch (_paneField[CommandContext.setup]) {
      _Field.exportLabel => _exportLabelField(),
      _Field.profile => _argon2ProfileSlider(),
      _Field.iterations => _iterationsInput(),
      _ => null,
    };
  }

  /// Width of a board context's pane, between the board and the log.
  static const double _kPaneWidth = 380;

  /// The board context's pane, between the board and the log. Always there,
  /// at a fixed width, so nothing beside it moves: Main the versions and the
  /// file path, Setup its field, Path the route, View the hue wheel. Input
  /// sits centred; nothing scrolls.
  Widget _contextPane() {
    final Widget? body = switch (_context) {
      CommandContext.main => null,
      CommandContext.setup => _setupPane(),
      CommandContext.path => _routePanel(),
      CommandContext.view => _track(
          _Field.hue,
          _HueWheelControl(
            value: _hue,
            focusNode: _hueFocus,
            onChanged: (HueOffset h) {
              _cue('$kCuePress.${_Cue.hueWheel}');
              setState(() => _hue = h);
            },
          ),
        ),
    };
    final Widget centre = body == null
        ? const SizedBox.shrink()
        : Center(child: body);
    if (_context != CommandContext.main) {
      return Padding(padding: const EdgeInsets.all(12), child: centre);
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_paneField[CommandContext.main] == _Field.vault)
                    _vaultPathField(),
                  if (_vaultBusy)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
          _versions(),
        ],
      ),
    );
  }

  /// The versions this build runs: the protocol (what a setup derives), the
  /// engine (the renderer and encoder's output) and the path finder.
  Widget _versions() {
    final TextStyle? style = Theme.of(context).textTheme.bodySmall;
    Widget row(String what, String version) => Row(
          children: <Widget>[
            SizedBox(
              width: _kVersionLabelWidth,
              child: Text(what, style: style),
            ),
            Text(version, style: style),
          ],
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        row('Protocol', widget.core.protocolVersion),
        row('Engine', widget.core.engineVersion),
        row('Path finder', widget.core.landmarkPathVersion),
      ],
    );
  }

  /// Width of the version labels' column, in logical pixels.
  static const double _kVersionLabelWidth = 96;

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
  /// Open the spacious Argon2 calibration dialog (Setup board). It benchmarks on this
  /// device, solves the iteration count N for a chosen target time, and — on
  /// Apply — returns N, which we write into the derivation-steps field. Exit is
  /// Esc + confirm (handled inside the dialog).
  Future<void> _openCalibrationDialog() async {
    if (_busy) return;
    final int profileIdx =
        _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
    final int? n = await _dialog(_Cue.calibrate, () => showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => _CalibrationDialog(
        core: widget.core,
        sounds: _sounds,
        profile: _profile,
        profileLabel: _profileLabels[profileIdx],
        initialStages: _pointStages,
      ),
    ));
    if (!mounted || n == null) return;
    setState(() {
      _iterations = n;
      _iterationsField.text = n.toString();
    });
    _sounds.play(UiSound.confirm);
  }

  Widget _iterationsInput() {
    final String raw = _iterationsField.text.trim();
    final bool invalid = raw.isNotEmpty && !_iterationsValid;
    // Label/help live in the console (focus _Field.iterations); keep only the
    // field (with its validation error) in the panel.
    return _track(
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
      );
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


  // --- Orbit provisional key: capture / write / restore ----------------------
  // It lives on the screen because the orbit state does: σ, D, P, o_i and the
  // placed points are all screen-owned fields.

  /// The single failure message every vault open reports. A wrong key, a corrupt
  /// file and a doctored payload MUST be indistinguishable — otherwise someone
  /// holding the file learns from probing it whether a candidate key was
  /// right. (GCM authentication makes them identical; this keeps the parse
  /// failures from breaking that.) Only a file that decrypted — the key was
  /// right, and its contents are its holder's anyway — may be named: a
  /// pre-orbit chain or non-standard setup.
  static const String _vaultOpaqueError =
      'Could not open — wrong key, or not a setup file.';

  /// A file that decrypts but holds a pre-orbit chain setup.
  static const String _vaultChainError =
      'Could not open — a pre-orbit chain setup. Chain setups are no longer '
      'supported; only orbit setups open.';

  /// A file whose stages require other than the standard number of points.
  static const String _vaultNonStandardError =
      'Could not open — a non-standard setup. Only standard setups are '
      'supported: $_rootRequired points at stage 0, $_deepRequired at every '
      'deeper stage.';

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
  /// read straight off the screen-owned state.
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
      deck: _deckForSave(deepest),
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
            required: _requiredOf(i),
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
  /// key. The screen does its own file I/O: it owns the state.
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
      _deck = vault.deck; // what the file now holds
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

  /// Restore a settled orbit setup from [vault].
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
  /// cheap `o_i == H*(u_{i-1})` check — that check *is* the memory-hard advance
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
      if (stage.required != _requiredOf(i)) return _vaultNonStandardError;
      final List<int>? oI = stage.orbit;
      if (i == 0) {
        // σ is o₀'s only source; a file that also carries one disagrees with
        // itself about the root and is rejected rather than silently preferred.
        if (oI != null) return _vaultOpaqueError;
        orbits.add(widget.core.orbitRoot(sigma));
      } else {
        // Width is load-bearing, not cosmetic: a short o_i would be zero-padded
        // by the FFI marshalling and derive a different orbit in silence.
        if (oI == null || oI.length != kOrbitPointLen) return _vaultOpaqueError;
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
      // The saved deck and its maps' routes.
      _deck = vault.deck;
      for (final MemCard c in vault.deck?.cards ?? const <MemCard>[]) {
        final Cues? cues = c.cues;
        final _Route? route = cues == null ? null : _routeOfCues(cues);
        if (route != null) _routes[(c.stageIndex, c.slot)] = route;
      }
      _sigmaCtrl.text = vault.sigma;
      _iterations = vault.iterations;
      _iterationsField.text = '${vault.iterations}';
      _profile = vault.profile;
      for (int i = 1; i <= deepest; i++) {
        // o₀ is never stored: [_stageOrbit] re-derives it from σ on demand.
        _orbitO[i] = orbits[i];
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
          r.digest.length == kOrbitPointLen &&
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
  Widget _vaultPathField() {
    // Heading + explanation live in the console (focus _Field.vault). The
    // provisional key is entered / shown / copied only inside the Write and
    // Open dialogs — never in a panel field — so it is never an idle on-screen
    // artifact.
    return _track(
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
          labelText: 'File path',
          hintText: '/path/to/setup.gwvault',
        ),
      ),
    );
  }

  /// Bring up the setup file path field (Main board).
  void _focusVaultPath() =>
      _showField(_Field.vault, _vaultPathFocus, 'setup file path');

  /// Write (save) the settled orbit setup to the file path as an
  /// [OrbitVault], encrypted under a fresh app-generated 128-bit key, then
  /// open the key dialog. The key can be overridden with the user's own
  /// entropy from inside that dialog.
  Future<void> _writeSetup() async {
    if (!_orbitSettled) {
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
    final ({String? error, Uint8List? key}) result =
        await _saveOrbitVaultToFile(path);
    if (!mounted) return;
    setState(() => _vaultBusy = false);
    if (result.error != null || result.key == null) {
      _sounds.play(UiSound.denyInput);
      _toast(result.error ?? 'Could not save.');
      return;
    }
    _sounds.play(UiSound.exportOk);
    await _showKeyDialog(path, result.key!);
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

    await _dialog(_Cue.openFile, () => showDialog<void>(
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
                    onPressed: _press(_Cue.openScan, scan),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan (Q)'),
                  ),
                TextButton(
                  onPressed: _press(_Cue.openCancel, () => Navigator.of(ctx).pop()),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _press(_Cue.openLoad, loadHex),
                  child: const Text('Load'),
                ),
              ],
            ),
          ),
        );
      },
    ));
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
    await _dialog(_Cue.scan, () => showDialog<void>(
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
            onPressed: _press(_Cue.scanCancel, () => Navigator.of(ctx).pop()),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ));
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
  /// Only an orbit setup (`kind: 'orbit'`) restores ([_restoreOrbitVault]).
  /// A file that decrypts but holds anything else is a pre-orbit chain setup
  /// and is refused as such ([_vaultChainError]); every other failure after
  /// the file is read reports the same [_vaultOpaqueError]. The caller owns
  /// and wipes [keyBytes].
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
    // It decrypted, so the key was right, but it holds no orbit: a pre-orbit
    // chain setup, no longer supported.
    return _vaultChainError;
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
  Future<void> _showKeyDialog(String path, Uint8List keyBytes) async {
    Uint8List key = keyBytes;
    int keyLen = key.length; // 16 (128-bit) or 32 (256-bit)
    qr.QrImage matrix = _keyMatrix(key);
    final bool canScan = _scanSupported || _desktopScanSupported;
    bool showQr = false;
    bool copiedOnce = false;
    bool busy = false;
    final TextEditingController hexInput = TextEditingController();
    final FocusNode hexFocus = FocusNode(debugLabel: 'write-hex');

    await _dialog(_Cue.key, () => showDialog<void>(
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
            final ({String? error, Uint8List? key}) r =
                await _saveOrbitVaultToFile(path,
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
                          'template (Main board).  Alt+Q — copy the key for a password '
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
                    onPressed: _press(_Cue.keyQr, busy ? null : onShowQr),
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(showQr ? 'Switch bits (Q)' : 'Show QR (Q)'),
                  ),
                  TextButton.icon(
                    onPressed: _press(_Cue.keyCopy, busy ? null : onCopy),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy key (Alt+Q)'),
                  ),
                  if (canScan)
                    TextButton.icon(
                      onPressed:
                          _press(_Cue.keyOwn, busy ? null : scanOwnKey),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan to reuse (I)'),
                    ),
                  TextButton(
                    onPressed: _press(_Cue.keyClose, () => Navigator.of(ctx).pop()),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ));
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

  /// The inline hex editor for a point: a masked field labelled with
  /// [title], and Apply/Cancel (Enter / Esc).
  Widget _importEditorBody({
    required String title,
    required VoidCallback onApply,
    required VoidCallback onCancel,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _pointImport,
          focusNode: _pointImportFocus,
          obscureText: _importHidden,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
            TextInputFormatter.withFunction(
              (TextEditingValue o, TextEditingValue n) =>
                  n.copyWith(text: n.text.toUpperCase()),
            ),
          ],
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: '$title — $_kHexDigitsPerPoint hex digits',
            hintText: 'A1B2C3D4',
            suffixIcon: IconButton(
              tooltip: _importHidden ? 'Show' : 'Hide',
              icon: Icon(
                _importHidden ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: _press(
                _Cue.importReveal,
                () => setState(() => _importHidden = !_importHidden),
              ),
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
            FilledButton(
              style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact),
              onPressed: _press(_Cue.importApply, onApply),
              child: const Text('Apply'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact),
              onPressed: _press(_Cue.importCancel, onCancel),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  // --- Expansion (grow the setup with more point stages) ---------------------

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
      message: 'Exclude Stage $k and every deeper stage? The orbit keeps '
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

  /// The master-secret export affordances for the **currently displayed** stage:
  /// an explanation, the optional per-stage export-label field (restricted
  /// `[A-Z0-9-]`, versioning the key), and the blind copy. The Argon2id pass
  /// covers stages `1..displayStageIndex` (DESIGN.md §"Master-Secret Export").
  /// The key label: an optional salt that versions the exported key.
  Widget _exportLabelField() {
    // Heading + explanation live in the console (focus _Field.exportLabel);
    // a formatting warning too (see _onExportLabelRestricted).
    return _track(
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
          labelText: 'Key label (optional)',
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
    );
  }

  /// Copy the active stage's key (Setup board): `K` the conventional
  /// first-32-chars view, the full digest with [full].
  Future<void> _copyMasterSecret({bool full = false}) =>
      _copyOrbitMaster(full: full);

  /// Entropy actually behind the exported key at [stage]: the placed points,
  /// `Σ r_j × 32` bits over stages `0..stage`. This is what an attacker must
  /// guess; the 512-bit state and the copied view can each *cap* what is
  /// carried, never raise it.
  int _placedEntropyBits(int stage) {
    int bits = 0;
    for (int i = 0; i <= stage && i <= _maxStage; i++) {
      bits += _requiredOf(i) * EncodingConstants.bitsPerPoint;
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
            ? 'this view — ${_hint(_Cmd.copyDigest)} copies all $stateBits bits'
            : 'the orbit state';
    return '$usable bits usable at stage $stage '
        '($placed placed, $viewBits in this view; limited by $limit)';
  }

  /// Copy the active stage's key to the clipboard, blind: `K_i^L =
  /// TH(export-label, K_i ‖ L)` under the key label L (the empty one too, so
  /// `K_i` itself is never handed out) — one setup, many keys. The
  /// conventional first-32-hex view, or the whole digest with [full]. Cheap
  /// hashes only, no Argon2id pass.
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

  /// Surface a warning on the console and make sure it is seen: restore the
  /// bottom panel, then log it.
  void _warnOnConsole(String message) {
    if (!mounted) return;
    _cue(_Cue.alertLog);
    setState(() => _chromeMinimized = false);
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
      case _Field.iterations:
        final String n = _iterationsField.text.trim();
        return 'Derivation steps per stage (D) = ${n.isEmpty ? '—' : n} (0…∞): '
            'the memory-hard passes each stage runs — the orbit advance '
            'oᵢ₊₁ = H*(Kᵢ). Higher = longer, '
            'stronger (hours to weeks); 0 = instant pass-through (dev only, not '
            'memory-hard).';
      case _Field.profile:
        final int idx =
            _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
        return 'Argon2 profile: ${_profileLabels[idx]} — memory per pass. '
            '← → or drag to change.';
      case _Field.exportLabel:
        return 'Key (master-secret export): this stage’s orbit key '
            'Kᵢ = TH(tag, oᵢ ‖ Shᵢ), fixed once rᵢ fractals are placed and '
            'domain-separated from the orbit advance — leaking it does not '
            'expose the deeper stages. What you copy is Kᵢ salted by this '
            'label. '
            '${_exportEntropyNote(_activeStage, MasterSecret.displayChars * 4)}. '
            'Paste into another wallet or use as a downstream pepper. The '
            'optional salt versions the key (e.g. SIGNING-1, '
            'uppercase/digits/hyphen). ${_hint(_Cmd.copyKey)} copies it — '
            'blind, never shown.';
      case _Field.hue:
        return 'Colour scheme: ${_hue.name}. ← → to cycle through the six hues.';
      case _Field.vault:
        return 'Provisional key: encrypt this setup to a file (AES-256-GCM) for '
            'the memorisation window — a transient crutch, not a backup; delete '
            'it at graduation. Protect it with your own password (managed/deleted '
            'in a password manager) or an app-generated key shown as a small QR '
            'to print and keep OFFLINE. The file is useless without its secret.';
    }
  }

  /// Answer the pending console confirmation, completing its future.
  void _resolvePrompt(bool ok) {
    final _ConsolePrompt? p = _prompt;
    if (p == null) return;
    setState(() => _prompt = null);
    if (!p.completer.isCompleted) p.completer.complete(ok);
  }

  /// Reset behind an inline console confirmation, so the Reset key (or a stray
  /// keypress) cannot discard a setup by accident.
  Future<void> _confirmReset() async {
    final bool ok = await _consoleConfirm(
      message: 'Reset and discard the current setup? σ, every placed point and '
          'every stage reached will be lost.',
      confirmLabel: 'Reset',
    );
    if (ok && mounted && !_busy) _reset();
  }

  /// Halt the running advance behind a console confirmation (Setup board).
  /// Kills only the current pass; every pass completed is kept, and the same
  /// key then resumes. No-op with a deny cue when nothing is deriving.
  Future<void> _abortDerivation() async {
    if (!_busy) {
      _sounds.play(UiSound.deny);
      return;
    }
    final bool ok = await _consoleConfirm(
      message: 'Halt the running derivation? Only the current pass (~1 min) is '
          'dropped — every digest completed so far on this stage is kept, and '
          'the stages already derived stay usable.',
      confirmLabel: 'Halt',
    );
    if (!ok || !mounted) return;
    _advanceJob?.cancel(); // the advance reports the halt itself
  }

  void _reset() {
    _resolvePrompt(false); // drop any pending console confirmation
    _brightness.reset();
    _viewport.viewport = _initialViewport;
    _exportLabel.clear();
    _sigmaCtrl.clear();
    setState(() {
      _clearOrbitPlacements();
      _exportLabelRestricted = false;
      _slotIndex = 0;
    });
    _setOrbitStage(0);
    _focusViewer(); // hotkeys act on the viewer
  }
}


/// A stage-0 board's canonical-island decoration: the island cells plus its
/// bounding box (fractal coords), used to draw the square frame and to size the
/// cross↔square switch.
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


/// The input controls whose label + live value are conveyed in the console while
/// focused (so the panel itself can stay label-free).
enum _Field {
  iterations,
  profile,
  exportLabel,
  hue,
  vault,
}

/// The command board's commands, each at its context and position (an index
/// into [kBoardKeys]: rows top to bottom, left to right).
enum _Cmd {
  layout(CommandContext.main, 0),
  save(CommandContext.main, 1),
  open(CommandContext.main, 2),
  templates(CommandContext.main, 3),
  volumeDown(CommandContext.main, 4),
  volumeUp(CommandContext.main, 5),
  secrets(CommandContext.main, 6),
  filePath(CommandContext.main, 7),
  reset(CommandContext.main, 8),
  label(CommandContext.setup, 0),
  profile(CommandContext.setup, 1),
  steps(CommandContext.setup, 2),
  calibrate(CommandContext.setup, 3),
  newPoint(CommandContext.setup, 4),
  dice(CommandContext.setup, 5),
  importHex(CommandContext.setup, 6),
  placeByClick(CommandContext.setup, 7),
  exclude(CommandContext.setup, 8),
  halt(CommandContext.setup, 9),
  copyKey(CommandContext.setup, 10),
  copyDigest(CommandContext.setup, 11),
  prevStop(CommandContext.path, 0),
  nextStop(CommandContext.path, 1),
  rhoZoom(CommandContext.path, 2),
  rhoPan(CommandContext.path, 3),
  numbers(CommandContext.path, 4),
  lines(CommandContext.path, 5),
  exponentDown(CommandContext.path, 6),
  exponentUp(CommandContext.path, 7),
  path(CommandContext.path, 8),
  framePath(CommandContext.path, 9),
  stopsDown(CommandContext.path, 10),
  stopsUp(CommandContext.path, 11),
  islands(CommandContext.view, 0),
  deepRender(CommandContext.view, 1),
  autoBrightness(CommandContext.view, 2),
  brightnessDown(CommandContext.view, 4),
  brightnessUp(CommandContext.view, 5),
  slopeDown(CommandContext.view, 6),
  slopeUp(CommandContext.view, 7),
  hueDown(CommandContext.view, 8),
  hueUp(CommandContext.view, 9);

  const _Cmd(this.context, this.slot);
  final CommandContext context;
  final int slot;

  /// Its sound-cue name stem, e.g. `setup.dice` (under `press.` / `hover.`).
  String get cue => '${context.name}.$name';
}

/// The sound-cue names this screen plays besides the board's (see
/// [SoundCueMap]): every name falls back to its dotted parent, so a line for
/// `press.key` in the cue map covers all the key dialog's buttons.
abstract final class _Cue {
  // Tabs, under `press.` / `hover.`, then the stage or slot number.
  static const String stageTab = 'tab.stage';
  static const String slotTab = 'tab.slot';

  // Function keys.
  static const String f1Collapse = 'key.f1.collapse';
  static const String f1Restore = 'key.f1.restore';
  static const String f2 = 'key.f2';
  static const String f3 = 'key.f3';
  static const String f4 = 'key.f4';
  static const String f5 = 'key.f5';

  // Alerts: a confirmation raised, the disclaimer's, a warning in the log.
  static const String alertConfirm = 'alert.confirm';
  static const String alertWarning = 'alert.warning';
  static const String alertLog = 'alert.log';

  // Dialogs, under `dialog.open.` / `dialog.close.`.
  static const String dialogOpen = 'dialog.open';
  static const String dialogClose = 'dialog.close';
  static const String calibrate = 'calibrate';
  static const String calibrateLeave = 'calibrate.leave';
  static const String openFile = 'open';
  static const String scan = 'scan';
  static const String dice = 'dice';
  static const String key = 'key';
  static const String harvestDate = 'harvest.date';
  static const List<String> dialogs = <String>[
    calibrate,
    calibrateLeave,
    openFile,
    scan,
    key,
    dice,
    harvestDate,
  ];

  // Buttons outside the board, under `press.`.
  static const String harvest = 'salt.harvest';
  static const String harvestCancel = 'salt.cancel';
  static const String advanceHalt = 'advance.halt';
  static const String panelCollapse = 'panel.collapse';
  static const String panelRestore = 'panel.restore';
  static const String promptCancel = 'prompt.cancel';
  static const String promptConfirm = 'prompt.confirm';
  static const String hueWheel = 'view.hueWheel';
  static const String importReveal = 'import.reveal';
  static const String importApply = 'import.apply';
  static const String importCancel = 'import.cancel';
  static const String openScan = 'open.scan';
  static const String openCancel = 'open.cancel';
  static const String openLoad = 'open.load';
  static const String scanCancel = 'scan.cancel';
  static const String keyQr = 'key.qr';
  static const String keyCopy = 'key.copy';
  static const String keyOwn = 'key.own';
  static const String keyClose = 'key.close';
  static const String calibrateClose = 'calibrate.close';
  static const String calibrateBench = 'calibrate.bench';
  static const String calibrateScope = 'calibrate.scope';
  static const String calibrateStagesDown = 'calibrate.stages.down';
  static const String calibrateStagesUp = 'calibrate.stages.up';
  static const String calibrateTarget = 'calibrate.target';
  static const String calibratePassesDown = 'calibrate.passes.down';
  static const String calibratePassesUp = 'calibrate.passes.up';
  static const String calibrateApply = 'calibrate.apply';
  static const String calibrateStay = 'calibrate.leave.stay';
  static const String calibrateLeaveOk = 'calibrate.leave.ok';
  static const List<String> buttons = <String>[
    harvest,
    harvestCancel,
    advanceHalt,
    panelCollapse,
    panelRestore,
    promptCancel,
    promptConfirm,
    hueWheel,
    importReveal,
    importApply,
    importCancel,
    openScan,
    openCancel,
    openLoad,
    scanCancel,
    keyQr,
    keyCopy,
    keyOwn,
    keyClose,
    calibrateClose,
    calibrateBench,
    calibrateScope,
    calibrateStagesDown,
    calibrateStagesUp,
    calibrateTarget,
    calibratePassesDown,
    calibratePassesUp,
    calibrateApply,
    calibrateStay,
    calibrateLeaveOk,
  ];

  /// Every name above, in full, for the cue map's catalogue.
  static List<String> get all => <String>[
        f1Collapse,
        f1Restore,
        f2,
        f3,
        f4,
        f5,
        alertConfirm,
        alertWarning,
        alertLog,
        for (final String d in dialogs) ...<String>[
          '$dialogOpen.$d',
          '$dialogClose.$d',
        ],
        for (final String b in buttons) '$kCuePress.$b',
      ];
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
    this.warning = false,
  });

  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final Completer<bool> completer;

  /// A disclaimer: drawn in the warning colour, under a warning sign.
  final bool warning;
}

/// Maps the number-row and numpad digit keys to a stage index, so pressing a
/// number focuses that stage (when no text field holds the keystroke). Valid
/// stages are 0..4 ([OrbitProtocol.maxStage]); 5..9 are included so they
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
/// the current setup (a hollow frame the orbit can still grow into).
class _StageTab extends StatelessWidget {
  const _StageTab({
    required this.index,
    required this.inSetup,
    required this.selected,
    required this.available,
    required this.deriving,
    required this.progress,
    required this.explanation,
    required this.onExplain,
    required this.cue,
    required this.onCue,
    required this.onTap,
  });

  final int index;

  /// Its sound-cue name stem, e.g. `tab.slot.3` (under `press.` / `hover.`),
  /// played through [onCue].
  final String cue;
  final ValueChanged<String> onCue;

  /// What the tab is and what pressing it does: reported through [onExplain]
  /// while it has the pointer or focus (shown in the log), null when it
  /// leaves.
  final String explanation;
  final ValueChanged<String?> onExplain;

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
    final VoidCallback? tap = onTap;
    return MouseRegion(
      onEnter: (_) {
        onExplain(explanation);
        onCue('$kCueHover.$cue');
      },
      onExit: (_) => onExplain(null),
      child: InkWell(
        onTap: tap == null
            ? null
            : () {
                onCue('$kCuePress.$cue');
                tap();
              },
        onFocusChange: (bool has) {
          onExplain(has ? explanation : null);
          if (has) onCue('$kCueHover.$cue');
        },
        borderRadius: BorderRadius.circular(6),
        child: deriving ? _derivingFace(scheme) : _restingFace(scheme),
      ),
    );
  }

  /// A non-deriving box: ghost (out of setup), pending (grey), or lit
  /// (available / selected).
  Widget _restingFace(ColorScheme scheme) {
    if (!inSetup) {
      // Ghost: a faint hollow slot — an open quest the orbit can grow into.
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
/// `bs_salt_pepper_canonicalize`) — the *same* canonicalisation the key label
/// is hashed with, so the field shows exactly the bytes that will be hashed.
/// The `[A-Z0-9-]` restriction (DESIGN.md "Strong text restrictions") exists
/// so the text reproduces identically across devices; a stray
/// case/accent/look-alike would silently change the exported key.
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
/// A landmark route: indices into the engine's ρ and exponent choices, and
/// how many stops before the leaf are visible (null: all).
typedef _Route = ({int rho, int exponent, int? visible});

/// A landmark path with the ρ and exponent (indices) it was searched for, and
/// the overlay it is drawn as.
typedef _ShownPath = ({
  LandmarkPath path,
  int rho,
  int exponent,
  CanvasPath overlay,
});

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
    _stages = widget.initialStages.clamp(1, OrbitProtocol.maxStage);
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
    widget.sounds.cue('${_Cue.dialogOpen}.${_Cue.calibrateLeave}');
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Close calibration?'),
        content: const Text(
            'The benchmark result is discarded unless you Apply it first.'),
        actions: <Widget>[
          TextButton(
              onPressed: _press(_Cue.calibrateStay, () => Navigator.pop(ctx, false)),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _press(_Cue.calibrateLeaveOk, () => Navigator.pop(ctx, true)),
              child: const Text('Close')),
        ],
      ),
    );
    widget.sounds.cue('${_Cue.dialogClose}.${_Cue.calibrateLeave}');
    return ok ?? false;
  }

  /// [f], voicing the press of control [id] first; null stays null.
  VoidCallback? _press(String id, VoidCallback? f) => f == null
      ? null
      : () {
          widget.sounds.cue('$kCuePress.$id');
          f();
        };

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
                          onPressed: _press(_Cue.calibrateClose, _attemptClose),
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
                          onPressed: _press(_Cue.calibrateBench, _benching ? _cancelBench : _bench),
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
                        widget.sounds.cue('$kCuePress.${_Cue.calibrateScope}');
                        _recompute();
                      }),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Text('Stages: ', style: theme.textTheme.bodyMedium),
                        IconButton(
                          onPressed: _press(_Cue.calibrateStagesDown, _stages > 1
                              ? () => setState(() {
                                    _stages--;
                                    _recompute();
                                  })
                              : null),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text('$_stages', style: theme.textTheme.titleMedium),
                        IconButton(
                          onPressed: _press(_Cue.calibrateStagesUp, _stages < OrbitProtocol.maxStage
                              ? () => setState(() {
                                    _stages++;
                                    _recompute();
                                  })
                              : null),
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
                                  widget.sounds
                                      .cue('$kCuePress.${_Cue.calibrateTarget}');
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
                              onPressed: _press(_Cue.calibratePassesDown, (_benching || _passes <= 1)
                                  ? null
                                  : () => setState(() => _passes--)),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            Text('$_passes',
                                style: theme.textTheme.titleMedium),
                            IconButton(
                              onPressed: _press(_Cue.calibratePassesUp, (_benching || _passes >= 7)
                                  ? null
                                  : () => setState(() => _passes++)),
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
                          onPressed: _press(_Cue.calibrateClose, _attemptClose),
                          child: Text(_benching ? 'Stop' : 'Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _press(_Cue.calibrateApply, (_benching || n == null)
                              ? null
                              : () => Navigator.of(context).pop(n)),
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
