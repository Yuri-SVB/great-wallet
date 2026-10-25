import 'package:flutter/material.dart';

import '../core/great_wall_core.dart';
import '../setup/setup_screen.dart';

/// The great-wallet modes (ARCHITECTURE.md §"7. great-wallet"). **Setup** hosts
/// both the legacy 0.3.0 chain and the 0.5.0 orbit board flow (the orbit build
/// is morphed into the Setup screen); Train / Accelerate / Inherit depend on
/// libraries (celestial-peace-nf-core, jade-clock, phoenix-scroll) still in
/// development.
enum WalletMode {
  setup('Setup', Icons.auto_awesome_mosaic),
  train('Train', Icons.school),
  accelerate('Accelerate', Icons.bolt),
  inherit('Inherit', Icons.account_tree);

  const WalletMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Top-level navigation shell that switches between the four modes.
class ModeShell extends StatefulWidget {
  const ModeShell({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<ModeShell> createState() => _ModeShellState();
}

class _ModeShellState extends State<ModeShell> {
  WalletMode _mode = WalletMode.setup;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Great Wallet — ${_mode.label}')),
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _mode.index,
            onDestinationSelected: (int i) =>
                setState(() => _mode = WalletMode.values[i]),
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
    switch (_mode) {
      case WalletMode.setup:
        return SetupScreen(core: widget.core);
      case WalletMode.train:
      case WalletMode.accelerate:
      case WalletMode.inherit:
        return _comingSoon(_mode);
    }
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
              'This integration pass wires Setup (great-wall-core + '
              'great-wall-ux). The remaining modes depend on libraries that '
              'are not yet public.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
