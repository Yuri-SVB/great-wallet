/// Wiping the setup file: overwritten with random bytes, flushed, then
/// deleted, along with any temporary file a save or cover write left beside
/// it. On flash storage the overwrite may land elsewhere than the old bytes,
/// so this is best effort: what makes the old bytes useless is that they are
/// ciphertext whose key is meant to go too.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Bytes overwritten per write, so a large file never needs one large buffer.
const int _kChunk = 64 * 1024;

/// Wipe the file at [path] and its `.tmp`. Null on success (a missing file is
/// nothing to wipe), else what failed.
Future<String?> wipeFile(String path) async {
  for (final String p in <String>[path, '$path.tmp']) {
    final File f = File(p);
    if (!f.existsSync()) continue;
    try {
      final int length = f.lengthSync();
      final math.Random rng = math.Random.secure();
      final RandomAccessFile raf = await f.open(mode: FileMode.writeOnly);
      try {
        for (int at = 0; at < length; at += _kChunk) {
          final int n = math.min(_kChunk, length - at);
          await raf.writeFrom(
              Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256))));
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
      await f.delete();
    } on FileSystemException catch (e) {
      return 'Could not wipe $p (${e.osError?.message ?? e.message}).';
    }
  }
  return null;
}
