import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/file_wipe.dart';

/// Wiping the setup file: it and its temporary file gone; nothing to wipe is
/// no error.
void main() {
  test('the file and its .tmp are deleted', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gw-wipe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File f = File('${dir.path}/setup.gw')
      ..writeAsBytesSync(List<int>.filled(200000, 7));
    final File tmp = File('${f.path}.tmp')..writeAsBytesSync(<int>[1, 2, 3]);
    expect(await wipeFile(f.path), isNull);
    expect(f.existsSync(), isFalse);
    expect(tmp.existsSync(), isFalse);
    expect(await wipeFile(f.path), isNull, reason: 'nothing left to wipe');
  });
}
