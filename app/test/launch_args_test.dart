import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/launch_args.dart';

/// The launch arguments: a setup file path, flags ignored.
void main() {
  test('the first argument that is not a flag is the path', () {
    expect(LaunchArgs.parse(<String>['--verbose', '/s.gw']).path, '/s.gw');
    expect(LaunchArgs.parse(<String>['/s.gw', '/t.gw']).path, '/s.gw');
    expect(LaunchArgs.parse(const <String>[]).path, isNull);
  });

  test('a path gives a line for the log; none, none', () {
    expect(const LaunchArgs(path: '/s.gw').notice, contains('/s.gw'));
    expect(const LaunchArgs().notice, isNull);
  });
}
