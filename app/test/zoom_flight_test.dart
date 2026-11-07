import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/command/zoom_flight.dart';

/// The smooth flight between views (van Wijk & Nuij 2003).
void main() {
  void expectView(
    ({double re, double im, double w}) v,
    double re,
    double im,
    double w,
  ) {
    expect(v.re, closeTo(re, 1e-9 * (1 + re.abs())));
    expect(v.im, closeTo(im, 1e-9 * (1 + im.abs())));
    expect(v.w, closeTo(w, 1e-9 * w));
  }

  test('starts and ends at the two views', () {
    final ZoomFlight f =
        ZoomFlight(re0: 0, im0: 0, w0: 4, re1: 1, im1: -0.5, w1: 0.01);
    expectView(f.at(0), 0, 0, 4);
    expectView(f.at(1), 1, -0.5, 0.01);
    expect(f.length, greaterThan(0));
  });

  test('the same centre is a pure zoom at a constant rate', () {
    final ZoomFlight f =
        ZoomFlight(re0: 1, im0: 1, w0: 1, re1: 1, im1: 1, w1: 1 / 16);
    expect(f.length, closeTo(math.log(16) / kFlightRho, 1e-12));
    expectView(f.at(0.5), 1, 1, 0.25);
  });

  test('a long pan between close-up views zooms out on the way', () {
    final ZoomFlight f =
        ZoomFlight(re0: 0, im0: 0, w0: 0.01, re1: 10, im1: 0, w1: 0.01);
    expect(f.at(0.5).w, greaterThan(1.0));
    expect(f.at(0.5).re, closeTo(5, 1e-6), reason: 'symmetric');
  });

  test('a deep zoom stays finite and lands', () {
    final ZoomFlight f =
        ZoomFlight(re0: 0, im0: 0, w0: 4, re1: -1.76, im1: 0.03, w1: 1e-12);
    for (int k = 0; k <= 20; k++) {
      final ({double re, double im, double w}) v = f.at(k / 20);
      expect(v.w.isFinite && v.w > 0, isTrue);
      expect(v.re.isFinite && v.im.isFinite, isTrue);
    }
    expectView(f.at(1), -1.76, 0.03, 1e-12);
    expect(f.duration.inMilliseconds,
        (kFlightMaxSeconds * 1000).round(), reason: 'capped');
  });
}
