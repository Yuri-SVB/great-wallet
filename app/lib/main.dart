import 'package:flutter/material.dart';
import 'package:great_wall_ux/great_wall_ux.dart';

import 'great_wallet.dart';
import 'src/setup/launch_args.dart';

/// `great_wallet [setup file]` — with `flutter run`, the path goes after `-a`
/// (`flutter run -d linux -a /path/to/setup.gw`). It is where Save and Open
/// start; started at login with it, the app is the review reminder.
void main(List<String> args) {
  final LaunchArgs launch = LaunchArgs.parse(args);
  runApp(GreatWalletApp(initialPath: launch.path, notice: launch.notice));
}

/// Root widget. Opens the great-wall-core engine once and hands it to the
/// mode shell. If the engine `cdylib` is missing, an actionable error screen
/// is shown instead of a crash.
class GreatWalletApp extends StatefulWidget {
  const GreatWalletApp({super.key, this.initialPath, this.notice});

  /// The setup file path from the launch, and its line for the log.
  final String? initialPath;
  final String? notice;

  @override
  State<GreatWalletApp> createState() => _GreatWalletAppState();
}

class _GreatWalletAppState extends State<GreatWalletApp> {
  GreatWallCore? _core;
  Object? _openError;

  @override
  void initState() {
    super.initState();
    try {
      _core = GreatWallCore.open();
    } catch (e) {
      _openError = e;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Great Wallet',
      // Adopt great-wall-ux's chrome typography (Ubuntu Mono) across the app,
      // so the wallet shares the "sober, but game-like" terminal aesthetic of
      // the canvas surface rather than the default Material face.
      theme: GreatWallTypography.themed(ThemeData.dark(useMaterial3: true)),
      home: _core != null
          ? ModeShell(
              core: _core!,
              initialPath: widget.initialPath,
              notice: widget.notice,
            )
          : _EngineMissing(error: _openError),
    );
  }
}

class _EngineMissing extends StatelessWidget {
  const _EngineMissing({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Great Wallet')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.extension_off, size: 48),
              const SizedBox(height: 16),
              Text(
                'The great-wall-core engine could not be loaded.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Build it with native/build_core.sh '
                '(cargo build --release in '
                'great-wall-core/burning_ship/rust_engine).',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              SelectableText(
                '$error',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
