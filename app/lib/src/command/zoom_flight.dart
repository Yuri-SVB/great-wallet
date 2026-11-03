import 'dart:math' as math;

/// Van Wijk & Nuij's recommended trade-off between zooming and panning,
/// √2 ("Smooth and efficient zooming and panning", IEEE InfoVis 2003).
const double kFlightRho = math.sqrt2;

/// Seconds of flight per unit of zoom-space length: a constant speed, so a
/// long hop takes longer than a short one.
const double kFlightSecondsPerUnit = 0.45;

/// Shortest and longest flight, in seconds.
const double kFlightMinSeconds = 0.35;
const double kFlightMaxSeconds = 3.0;

/// Below this fraction of the larger view width, two centres count as the
/// same and the flight is a pure zoom.
const double _kSameCentre = 1e-12;

/// The smooth flight from one view to another (van Wijk & Nuij 2003): the
/// shortest path in their zoom space, where a view is a centre `c` and a width
/// `w`. It zooms out, pans, and zooms in again as much as that saves — the
/// same metric the landmark path's hops are measured in.
class ZoomFlight {
  ZoomFlight._({
    required this.length,
    required double re0,
    required double im0,
    required double dRe,
    required double dIm,
    required double Function(double s) u,
    required double Function(double s) w,
  })  : _re0 = re0,
        _im0 = im0,
        _dRe = dRe,
        _dIm = dIm,
        _u = u,
        _w = w;

  /// The flight from centre `(re0, im0)` at width [w0] to `(re1, im1)` at
  /// width [w1] (both positive), with trade-off [rho].
  factory ZoomFlight({
    required double re0,
    required double im0,
    required double w0,
    required double re1,
    required double im1,
    required double w1,
    double rho = kFlightRho,
  }) {
    final double dRe = re1 - re0;
    final double dIm = im1 - im0;
    final double u1 = math.sqrt(dRe * dRe + dIm * dIm);
    if (u1 <= _kSameCentre * math.max(w0, w1)) {
      // The same centre: a pure zoom, at a constant rate.
      final double k = math.log(w1 / w0);
      return ZoomFlight._(
        length: k.abs() / rho,
        re0: re0,
        im0: im0,
        dRe: dRe,
        dIm: dIm,
        u: (double s) => 0,
        w: (double s) => w0 * math.exp(k.sign * rho * s),
      );
    }
    final double rho2 = rho * rho;
    final double rho4u = rho2 * rho2 * u1 * u1;
    double b(double wi, double sign) =>
        (w1 * w1 - w0 * w0 + sign * rho4u) / (2 * wi * rho2 * u1);
    final double r0 = _asinh(-b(w0, 1));
    final double r1 = _asinh(-b(w1, -1));
    final double cosh0 = _cosh(r0);
    final double sinh0 = _sinh(r0);
    return ZoomFlight._(
      length: (r1 - r0) / rho,
      re0: re0,
      im0: im0,
      dRe: dRe / u1,
      dIm: dIm / u1,
      u: (double s) =>
          w0 / rho2 * (cosh0 * _tanh(rho * s + r0) - sinh0),
      w: (double s) => w0 * cosh0 / _cosh(rho * s + r0),
    );
  }

  /// Its length in zoom space.
  final double length;
  final double _re0;
  final double _im0;
  final double _dRe;
  final double _dIm;
  final double Function(double s) _u;
  final double Function(double s) _w;

  /// Its duration, at [kFlightSecondsPerUnit] within the bounds.
  Duration get duration {
    final double seconds = (length * kFlightSecondsPerUnit)
        .clamp(kFlightMinSeconds, kFlightMaxSeconds);
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  /// The view a fraction [t] (0 to 1) of the way: its centre and width.
  ({double re, double im, double w}) at(double t) {
    final double s = t.clamp(0.0, 1.0) * length;
    final double u = _u(s);
    return (re: _re0 + u * _dRe, im: _im0 + u * _dIm, w: _w(s));
  }
}

double _cosh(double x) => (math.exp(x) + math.exp(-x)) / 2;
double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
double _tanh(double x) {
  if (x.abs() > 20) return x.sign;
  final double e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// `asinh`, stable for large arguments of either sign.
double _asinh(double x) {
  final double a = x.abs();
  final double r = math.log(a + math.sqrt(a * a + 1));
  return x < 0 ? -r : r;
}
