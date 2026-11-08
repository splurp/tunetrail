import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationSource { none, gps, joystick, teleport }

/// Player position: real GPS, or the debug joystick / teleport override.
class LocationService extends ChangeNotifier {
  LocationService(LatLng initial) : position = initial;

  LatLng position;
  double heading = 0; // degrees, 0 = north
  bool moving = false;
  LocationSource source = LocationSource.none;
  String? gpsError;
  bool joystickMode = false;
  double speedMultiplier = 1;

  /// Called with metres travelled for quest/stat tracking.
  void Function(double meters)? onTravel;

  StreamSubscription<Position>? _gpsSub;
  Timer? _joyTimer;
  Offset2 _joy = const Offset2(0, 0);
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  static const walkSpeed = 1.6; // m/s at 1×

  Future<void> start() async {
    if (!kIsWeb && Platform.isLinux) {
      gpsError = 'GPS not supported on Linux desktop';
      notifyListeners();
      return;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        gpsError = 'Location services are off';
        notifyListeners();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        gpsError = 'Location permission denied';
        notifyListeners();
        return;
      }
      try {
        final first = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high))
            .timeout(const Duration(seconds: 10));
        _onGps(first);
      } catch (_) {}
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 2),
      ).listen(_onGps, onError: (Object e) {
        gpsError = '$e';
        notifyListeners();
      });
    } catch (e) {
      gpsError = 'GPS unavailable on this device';
      notifyListeners();
    }
  }

  void _onGps(Position p) {
    if (joystickMode) return;
    final next = LatLng(p.latitude, p.longitude);
    final d = const Distance().as(LengthUnit.Meter, position, next);
    if (source == LocationSource.gps && d < 200) onTravel?.call(d);
    if (d > 0.5) {
      heading = const Distance().bearing(position, next);
      moving = true;
      _lastMove = DateTime.now();
    }
    position = next;
    source = LocationSource.gps;
    gpsError = null;
    notifyListeners();
    Future<void>.delayed(const Duration(seconds: 3), _settle);
  }

  void _settle() {
    if (DateTime.now().difference(_lastMove) > const Duration(milliseconds: 2500) && moving) {
      moving = false;
      notifyListeners();
    }
  }

  void setJoystickMode(bool on) {
    joystickMode = on;
    if (!on) {
      _joy = const Offset2(0, 0);
      _joyTimer?.cancel();
      _joyTimer = null;
      moving = false;
    }
    notifyListeners();
  }

  /// Joystick vector, each axis in [-1, 1] (y up = north).
  void setJoystick(double x, double y) {
    _joy = Offset2(x, y);
    if (_joy.length < 0.05) {
      _joyTimer?.cancel();
      _joyTimer = null;
      if (moving) {
        moving = false;
        notifyListeners();
      }
      return;
    }
    _joyTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _stepJoystick(0.033));
  }

  void _stepJoystick(double dt) {
    final mag = math.min(1.0, _joy.length);
    if (mag < 0.05) return;
    final meters = walkSpeed * speedMultiplier * mag * dt * 2.5;
    final bearing = (math.atan2(_joy.x, _joy.y) * 180 / math.pi + 360) % 360;
    final next = const Distance().offset(position, meters, bearing);
    position = next;
    heading = bearing;
    moving = true;
    source = LocationSource.joystick;
    onTravel?.call(meters);
    notifyListeners();
  }

  void teleport(LatLng p) {
    position = p;
    source = LocationSource.teleport;
    moving = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _joyTimer?.cancel();
    super.dispose();
  }
}

class Offset2 {
  const Offset2(this.x, this.y);
  final double x;
  final double y;
  double get length => math.sqrt(x * x + y * y);
}
