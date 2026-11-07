import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wall_ux/great_wall_ux.dart';
import 'package:great_wallet_app/src/app/sound_cue_folder.dart';

/// The sound-cue folder: written on first run, read, and reloaded when it
/// changes.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cues'));
  tearDown(() => dir.deleteSync(recursive: true));

  const String appDefaults = 'press.app.own   select.wav\n';
  const Duration settle = Duration(seconds: 2);

  test('a first run writes the map; edits and new files reload it', () async {
    final List<SoundCueMap> applied = <SoundCueMap>[];
    final List<Map<String, String>> files = <Map<String, String>>[];
    final List<String> log = <String>[];
    final SoundCueFolder folder = SoundCueFolder(
      apply: (SoundCueMap m, Map<String, String> f) {
        applied.add(m);
        files.add(f);
        return <String>[
          for (final String x in m.files)
            if (!SoundBoard.bundledFiles.contains(x) && !f.containsKey(x)) x,
        ];
      },
      appDefaults: appDefaults,
      catalogue: const <String>['press.main.save', 'hover.main.save'],
      onLog: log.add,
      folder: dir,
    );
    await folder.start();
    addTearDown(folder.dispose);

    final File map = File('${dir.path}/$kCueMapFile');
    final String text = map.readAsStringSync();
    expect(text, contains('press.app.own'));
    expect(text, contains('# press.main.save'));
    expect(applied.last.resolve('press.app.own')!.cue.file, 'select.wav');
    expect(applied.last.resolve('hover.main.save')!.name, 'hover');

    // An edit, a bad line and a missing file: reported, the rest applied.
    final Completer<void> reloaded = Completer<void>();
    final int before = applied.length;
    Timer.periodic(const Duration(milliseconds: 50), (Timer t) {
      if (applied.length > before && log.contains('Sound cues reloaded.')) {
        t.cancel();
        if (!reloaded.isCompleted) reloaded.complete();
      }
    });
    File('${dir.path}/mine.wav').writeAsBytesSync(<int>[0]);
    map.writeAsStringSync('$text\npress.main.save  mine.wav\n'
        'hover  gone.wav\nbroken line here and more\n');
    await reloaded.future.timeout(settle * 5);
    expect(applied.last.resolve('press.main.save')!.cue.file, 'mine.wav');
    expect(files.last['mine.wav'], '${dir.path}/mine.wav');
    expect(log.any((String l) => l.contains('no file gone.wav')), isTrue);
    expect(log.any((String l) => l.contains('that line is skipped')), isTrue);
  });

  test('an existing map is left as it is', () async {
    File('${dir.path}/$kCueMapFile').writeAsStringSync('press  -\n');
    SoundCueMap? applied;
    final SoundCueFolder folder = SoundCueFolder(
      apply: (SoundCueMap m, Map<String, String> f) {
        applied = m;
        return const <String>[];
      },
      appDefaults: appDefaults,
      catalogue: const <String>[],
      onLog: (_) {},
      folder: dir,
    );
    await folder.start();
    addTearDown(folder.dispose);
    expect(File('${dir.path}/$kCueMapFile').readAsStringSync(), 'press  -\n');
    expect(applied!.resolve('press.main.save')!.cue.file, isNull);
    // A line the user left out keeps its default.
    expect(applied!.resolve('hover')!.cue.file,
        SoundCueMap.defaults.entries['hover']!.file);
  });
}
