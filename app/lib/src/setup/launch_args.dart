/// The app's launch arguments: an optional setup file path, which Save and
/// Open start from. Flags (`--…`) are ignored.
///
/// Nothing about the file is read before its key opens it: the file holds
/// nothing in the clear, so a leaked copy cannot tell when its owner will next
/// open it (next-steps/timing-concealment-onions-and-mock-flows.md). Started
/// at login with the path, the app is the reminder.
class LaunchArgs {
  const LaunchArgs({this.path});

  factory LaunchArgs.parse(List<String> args) {
    for (final String a in args) {
      if (!a.startsWith('--')) return LaunchArgs(path: a);
    }
    return const LaunchArgs();
  }

  final String? path;

  /// The line for the log when the app was started with a path.
  String? get notice => path == null
      ? null
      : 'Setup file: $path. Open it (Main board › E) to see what is due.';
}
