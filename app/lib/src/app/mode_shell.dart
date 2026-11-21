import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/great_wall_core.dart';
import '../formosa/formosa_screen.dart';
import '../setup/setup_screen.dart';

/// The great-wallet modes (ARCHITECTURE.md §"7. great-wallet"), on F2–F6.
/// **Setup** builds the orbit (protocol 0.5.0); **Train** recalls its maps
/// (celestial-peace-nf-core), on the same screen and the same open setup;
/// **Formosa** is the password manager, apart from the setup; Accelerate /
/// Inherit depend on libraries (jade-clock, phoenix-scroll) still in
/// development.
enum WalletMode {
  setup('Setup', Icons.auto_awesome_mosaic),
  train('Train', Icons.school),
  formosa('Formosa', Icons.password),
  accelerate('Accelerate', Icons.bolt),
  inherit('Inherit', Icons.account_tree);

  const WalletMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Top-level navigation shell that switches between the four modes.
class ModeShell extends StatefulWidget {
  const ModeShell({
    super.key,
    required this.core,
    this.initialPath,
    this.notice,
  });

  final GreatWallCore core;

  /// The setup file path from the launch, and its line for the log
  /// ([SetupScreen.initialPath], [SetupScreen.notice]).
  final String? initialPath;
  final String? notice;

  @override
  State<ModeShell> createState() => _ModeShellState();
}

class _ModeShellState extends State<ModeShell> {
  WalletMode _mode = WalletMode.setup;

  /// Each screen's focus scope: switching mode restores the keys to the one
  /// shown, where they were last.
  final FocusScopeNode _setupScope = FocusScopeNode(debugLabel: 'setup');
  final FocusScopeNode _formosaScope = FocusScopeNode(debugLabel: 'formosa');

  @override
  void dispose() {
    _setupScope.dispose();
    _formosaScope.dispose();
    super.dispose();
  }

  /// Setup or Train, whichever the setup screen last showed: it stays
  /// mounted (and its setup open) while another mode is shown.
  bool _training = false;

  void _select(WalletMode m) {
    setState(() {
      _mode = m;
      if (m == WalletMode.setup || m == WalletMode.train) {
        _training = m == WalletMode.train;
      }
    });
    final FocusScopeNode? scope = switch (m) {
      WalletMode.setup || WalletMode.train => _setupScope,
      WalletMode.formosa => _formosaScope,
      _ => null,
    };
    if (scope != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => scope.requestFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Great Wallet — ${_mode.label}')),
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _mode.index,
            onDestinationSelected: (int i) => _select(WalletMode.values[i]),
            labelType: NavigationRailLabelType.all,
            destinations: <NavigationRailDestination>[
              for (final WalletMode m in WalletMode.values)
                NavigationRailDestination(
                  icon: Icon(m.icon),
                  label: Text(m.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    final bool screen =
        _mode == WalletMode.setup || _mode == WalletMode.train;
    final bool formosa = _mode == WalletMode.formosa;
    return Stack(
      children: <Widget>[
        // Formosa stays mounted too, so its open vault survives a visit to
        // Setup; shown, it takes the keys.
        Offstage(
          offstage: !formosa,
          child: TickerMode(
            enabled: formosa,
            child: FocusScope(
              node: _formosaScope,
              child: FormosaScreen(
                onFunctionKey: (LogicalKeyboardKey k) => _select(
                    k == LogicalKeyboardKey.f3
                        ? WalletMode.train
                        : WalletMode.setup),
              ),
            ),
          ),
        ),
        Offstage(
          offstage: !screen,
          child: TickerMode(
            enabled: screen,
            child: FocusScope(
              node: _setupScope,
              child: SetupScreen(
                core: widget.core,
                training: _training,
                initialPath: widget.initialPath,
                notice: widget.notice,
                onTrainingChanged: (bool t) =>
                    _select(t ? WalletMode.train : WalletMode.setup),
                onFormosa: () => _select(WalletMode.formosa),
              ),
            ),
          ),
        ),
        if (!screen && !formosa) _comingSoon(_mode),
      ],
    );
  }

  Widget _comingSoon(WalletMode mode) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(mode.icon, size: 48),
            const SizedBox(height: 16),
            Text('${mode.label} mode is in development.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Setup and Train are wired (great-wall-core, great-wall-ux, '
              'celestial-peace-nf-core). This mode depends on libraries that '
              'are not yet public.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
