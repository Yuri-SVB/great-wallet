import 'dart:async';
import 'dart:io';

import 'package:great_wall_ux/great_wall_ux.dart';
import 'package:path_provider/path_provider.dart';

/// The environment variable naming the sound-cue folder, overriding the
/// default one in the app's data folder.
const String kSoundCuesEnv = 'GREAT_WALL_SOUNDS';

/// The default folder's name, under the app's data folder.
const String kSoundCuesDir = 'sound_cues';

/// The cue map's file in the folder.
const String kCueMapFile = 'cues.txt';

/// The sound files the folder may hold, by extension.
const List<String> kCueFileExtensions = <String>['.wav', '.mp3', '.ogg'];

/// How long the folder must be quiet before a reload: editors save in bursts.
const Duration kCueReloadDelay = Duration(milliseconds: 250);

/// The folder a user swaps sound cues in, at run time.
///
/// It holds [kCueMapFile] — the plain-text cue map ([SoundCueMap]), written
/// on first run with every built-in cue and a list of every cue the app
/// plays — and any sound files the map names, which are played before the
/// bundled ones. Saving the map or dropping in a file reloads the cues. A
/// cue left out of the map keeps its built-in default.
class SoundCueFolder {
  SoundCueFolder({
    required this.apply,
    required this.appDefaults,
    required this.catalogue,
    required this.onLog,
    this.folder,
  });

  /// Puts a map in effect, its files played from the given paths first;
  /// returns the files it could not find ([SoundBoard.applyCues]).
  final List<String> Function(SoundCueMap map, Map<String, String> localFiles)
      apply;

  /// The folder to use; null for [kSoundCuesEnv]'s, else the app data
  /// folder's [kSoundCuesDir].
  final Directory? folder;

  /// The app's own default lines, over [SoundCueMap.defaults]: in effect
  /// from the start, and written into a new map.
  final String appDefaults;

  /// [SoundCueMap.defaults] with [appDefaults] over them.
  SoundCueMap get base =>
      SoundCueMap.defaults.overlaidWith(SoundCueMap.parse(appDefaults));

  /// Every cue name the app plays, listed (commented out) in a new map.
  final List<String> catalogue;

  /// Where to report the folder, reloads and problems (the log).
  final void Function(String message) onLog;

  Directory? _dir;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _reload;

  /// Apply the defaults, then find or create the folder, load it, and watch
  /// it. Never throws: without a folder (no data folder on this platform, no
  /// permission) the defaults play.
  Future<void> start() async {
    apply(base, const <String, String>{});
    try {
      final Directory dir = folder ?? await _defaultFolder();
      await dir.create(recursive: true);
      final File map = _mapFile(dir);
      if (!await map.exists()) await map.writeAsString(_newMap());
      _dir = dir;
      onLog('Sound cues: ${map.path} — edit it, or drop sound files next '
          'to it; changes play at once.');
      await _load();
      _watch = dir.watch().listen((_) {
        _reload?.cancel();
        _reload = Timer(kCueReloadDelay, () => unawaited(_load(reload: true)));
      });
    } catch (_) {
      // Sound cues are feedback only: the built-in map stays in effect.
    }
  }

  /// [kSoundCuesEnv]'s folder, else the app data folder's [kSoundCuesDir].
  static Future<Directory> _defaultFolder() async {
    final String? named = Platform.environment[kSoundCuesEnv];
    if (named != null && named.isNotEmpty) return Directory(named);
    final Directory data = await getApplicationSupportDirectory();
    return Directory('${data.path}${Platform.pathSeparator}$kSoundCuesDir');
  }

  File _mapFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$kCueMapFile');

  /// A new map: the built-in cues, then every cue name the app plays.
  String _newMap() {
    final StringBuffer out = StringBuffer(SoundCueMap.defaultText)
      ..writeln()
      ..write(appDefaults)
      ..writeln()
      ..writeln('# --- Every cue this app plays -------------------------'
          '------------------')
      ..writeln('# Uncomment one and give it a file to give it its own sound;')
      ..writeln('# a line removed from this file reverts to its built-in '
          'default.');
    for (final String name in catalogue) {
      out.writeln('# $name');
    }
    return out.toString();
  }

  Future<void> _load({bool reload = false}) async {
    final Directory? dir = _dir;
    if (dir == null) return;
    try {
      final List<SoundCueError> errors = <SoundCueError>[];
      final SoundCueMap mine =
          SoundCueMap.parse(await _mapFile(dir).readAsString(), errors: errors);
      final Map<String, String> files = <String, String>{
        await for (final FileSystemEntity e in dir.list())
          if (e is File && _isSound(e.path)) _name(e.path): e.path,
      };
      final List<String> missing = apply(base.overlaidWith(mine), files);
      for (final SoundCueError e in errors) {
        onLog('Sound cues, $e — that line is skipped.');
      }
      for (final String f in missing) {
        onLog('Sound cues: no file $f — its cues are silent.');
      }
      if (reload) onLog('Sound cues reloaded.');
    } catch (_) {
      // A half-written file or a vanished folder: keep the cues in effect.
    }
  }

  static bool _isSound(String path) =>
      kCueFileExtensions.any((String x) => path.toLowerCase().endsWith(x));

  static String _name(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  /// Stop watching.
  Future<void> dispose() async {
    _reload?.cancel();
    await _watch?.cancel();
  }
}
