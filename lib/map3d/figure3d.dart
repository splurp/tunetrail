import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/widgets/stick_figure.dart';
import 'camera.dart';
import 'outfit3d.dart';

/// Idle activities the character can drift into when standing still.
enum IdleActivity { none, headphones, turntable }

/// One-off actions the character plays at a glowing map feature.
enum FigureActionKind { dig, fish, mine }

/// An action in progress: [t] runs 0 → 1; [reach] is how far ahead of the
/// character (metres) the thing it's working on is.
class FigureAction {
  const FigureAction(this.kind, this.t, {this.reach = 22});
  final FigureActionKind kind;
  final double t;
  final double reach;
}

/// Drives walking/idle blending and look-around. Updated every frame by the
/// map screen; all transitions are eased so the figure never snaps.
class IdleDirector {
  IdleDirector([int? seed, this.activities = true]) : _r = math.Random(seed);
  final math.Random _r;

  /// Sit down for headphones / the turntable now and then (off: only look
  /// around — e.g. a head-and-shoulders portrait).
  final bool activities;

  /// 0 = standing, 1 = full walk cycle (smoothed).
  double walk = 0;

  /// Current activity and how far into it we've blended (0..1).
  IdleActivity activity = IdleActivity.none;
  double blend = 0;

  /// Seconds since the current activity started.
  double activityTime = 0;

  /// Head yaw relative to the body, degrees (look-around).
  double lookYaw = 0;

  double _stillFor = 0, _nextIdleAt = 10, _activityLength = 16, _lookTarget = 0, _lookTimer = 2;
  bool _ending = false;
  IdleActivity _last = IdleActivity.turntable;

  /// Stands at the turntable until further notice (a DJ in a battle): the
  /// deck rises out of the ground as usual.
  void holdTurntable() {
    if (activity != IdleActivity.turntable) {
      activity = IdleActivity.turntable;
      activityTime = 0;
      blend = 0;
    }
    _ending = false;
    _activityLength = double.infinity;
  }

  /// [moving]: the character walks (ends any idle). [busy]: something
  /// else, like the camera turning, that only keeps a new idle from
  /// starting — one already playing carries on through it.
  void update(double dt, bool moving, {bool busy = false}) {
    dt = dt.clamp(0.0, 0.1);
    walk += ((moving ? 1.0 : 0.0) - walk) * math.min(1.0, dt * 7);
    if (moving) {
      _stillFor = 0;
      if (activity != IdleActivity.none) _ending = true;
    } else if (busy && activity == IdleActivity.none) {
      _stillFor = 0;
    } else {
      _stillFor += dt;
    }

    if (activity == IdleActivity.none) {
      if (activities && !moving && _stillFor > _nextIdleAt) {
        activity = _last == IdleActivity.headphones ? IdleActivity.turntable : IdleActivity.headphones;
        if (_r.nextInt(4) == 0) activity = _last; // occasionally repeat
        _last = activity;
        activityTime = 0;
        _activityLength = 14 + _r.nextDouble() * 8;
        _ending = false;
      }
    } else {
      activityTime += dt;
      if (activityTime > _activityLength) _ending = true;
      final target = _ending ? 0.0 : 1.0;
      // Ease in over ~1.2 s; get up quickly (~0.5 s) when the player moves.
      final speed = _ending ? (moving ? 2.4 : 1.1) : 0.85;
      blend += (target - blend).sign * dt * speed;
      blend = blend.clamp(0.0, 1.0);
      if (_ending && blend <= 0) {
        activity = IdleActivity.none;
        _ending = false;
        _stillFor = 0;
        // Roughly half as frequent as before: 12–24 s of standing between idles.
        _nextIdleAt = 12 + _r.nextDouble() * 12;
      }
    }

    // Occasional glances around while standing.
    _lookTimer -= dt;
    if (moving || blend > 0.2) {
      _lookTarget = 0;
    } else if (_lookTimer <= 0) {
      _lookTarget = _r.nextInt(3) == 0 ? 0 : (_r.nextDouble() * 2 - 1) * 60;
      _lookTimer = 1.6 + _r.nextDouble() * 3.2;
    }
    lookYaw += (_lookTarget - lookYaw) * math.min(1.0, dt * 2.6);
  }
}

/// Smoothstep-style ease.
double _ease(double t) {
  t = t.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

(double, double, double) _mix((double, double, double) a, (double, double, double) b, double t) =>
    (a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t, a.$3 + (b.$3 - a.$3) * t);

/// Joint positions in the figure's local frame: (forward, right, up) metres.
class _Pose {
  _Pose(this.j);
  final Map<String, (double, double, double)> j;

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose({
        for (final k in a.j.keys)
          k: (
            a.j[k]!.$1 + (b.j[k]!.$1 - a.j[k]!.$1) * t,
            a.j[k]!.$2 + (b.j[k]!.$2 - a.j[k]!.$2) * t,
            a.j[k]!.$3 + (b.j[k]!.$3 - a.j[k]!.$3) * t,
          )
      });
}

/// Draws the player as a true 3D stick figure standing on the map.
///
/// The skeleton lives in world space, is animated (walk cycle, idle
/// activities, look-around) and is projected through the same camera as the
/// ground. Cosmetics are camera-facing art anchored to projected joints.
class Figure3DPainter extends CustomPainter {
  Figure3DPainter({
    required this.camera,
    required this.look,
    required this.time,
    required this.idle,
    required this.facing,
    required this.accent,
    required this.contrast,
    this.wave = 0,
    this.x,
    this.y,
    this.disc = true,
    this.action,
    this.beat,
  });

  /// Where the figure stands in world metres (the camera's player
  /// position when null).
  final double? x, y;

  /// Draw the accent disc under the figure (the player's own marker).
  final bool disc;

  /// A one-off action being played (digging, fishing, mining).
  final FigureAction? action;

  /// At a turntable: progress through the current beat (0 on the beat →
  /// 1 just before the next), so the scratching follows the music.
  final double? beat;

  /// Progress through a wave hello (0 = not waving, 0→1 over the wave).
  final double wave;

  final Camera3D camera;
  final FigureLook look;
  final double time; // seconds
  final IdleDirector idle;
  final double facing; // degrees clockwise from north
  final Color accent;

  /// Colour for idle props (headphones, notes) that contrasts with the map.
  final Color contrast;

  /// Figure scale: deliberately oversized (Pokémon-Go style).
  static const s = 3.6;

  static double _z(double designY) => (112 - designY) * 0.1 * s;

  // ------------------------------------------------------------- poses
  _Pose _walkPose(double phase, double walk) {
    final bob = math.sin(phase * 2).abs() * 0.35 * s * walk + math.sin(time * 1.6) * 0.06 * s * (1 - walk);
    final swing = math.sin(phase) * 0.6 * walk;
    final hipZ = _z(76) + bob;
    final shZ = _z(42) + bob;
    const legLen = 3.4 * s, armLen = 3.0 * s;
    (double, double, double) knee(double side, double a) => (math.sin(a) * legLen / 2, side * 0.45 * s, hipZ - math.cos(a) * legLen / 2);
    (double, double, double) foot(double side, double a) {
      final bend = 0.55 * math.max(0, math.sin(phase * side + math.pi / 2)) * walk;
      final k = knee(side, a);
      return (k.$1 + math.sin(a - bend) * legLen / 2, side * 0.55 * s, math.max(0.0, k.$3 - math.cos(a - bend) * legLen / 2));
    }

    // Arms hang clear of the torso — a little wider with backpack straps
    // round the chest, so the straps pass under them, not through them.
    final strapped = look.backpack != null && look.backpack != 'bag_wings';
    final spread = strapped ? 1.68 : 1.3;
    (double, double, double) elbow(double side, double a) => (math.sin(a) * armLen / 2, side * spread * s, shZ - math.cos(a) * armLen / 2);
    (double, double, double) hand(double side, double a) {
      final e = elbow(side, a);
      return (e.$1 + math.sin(a + 0.35) * armLen / 2, side * (spread + 0.22) * s, e.$3 - math.cos(a + 0.35) * armLen / 2);
    }

    return _Pose({
      'hip': (0, 0, hipZ),
      'shoulder': (0, 0, shZ),
      'neck': (0, 0, _z(36) + bob),
      'head': (0, 0, _z(22) + bob),
      'kneeL': knee(-1, swing),
      'footL': foot(-1, swing),
      'kneeR': knee(1, -swing),
      'footR': foot(1, -swing),
      'elbowL': elbow(-1, -swing * 0.9),
      'handL': hand(-1, -swing * 0.9),
      'elbowR': elbow(1, swing * 0.9),
      'handR': hand(1, swing * 0.9),
    });
  }

  /// Sitting cross-legged, head bobbing to the music.
  _Pose _headphonesPose(double t) {
    final beat = math.sin(t * math.pi * 2 * 1.9);
    final nod = math.max(0.0, beat) * 0.35 * s;
    const hipZ = 0.75 * s;
    return _Pose({
      'hip': (0, 0, hipZ),
      'shoulder': (0.15 * s, 0, hipZ + 3.3 * s),
      'neck': (0.2 * s + nod * 0.4, 0, hipZ + 3.9 * s),
      'head': (0.3 * s + nod, 0, hipZ + 5.3 * s - nod * 0.3),
      'kneeL': (1.3 * s, -1.6 * s, 0.9 * s),
      'footL': (1.2 * s, 0.6 * s, 0.25 * s),
      'kneeR': (1.3 * s, 1.6 * s, 0.9 * s),
      'footR': (1.0 * s, -0.6 * s, 0.25 * s),
      'elbowL': (0.6 * s, -1.4 * s, hipZ + 1.8 * s),
      'handL': (1.2 * s, -1.6 * s, 1.1 * s),
      // Right hand taps the knee to the beat.
      'elbowR': (0.6 * s, 1.4 * s, hipZ + 1.8 * s),
      'handR': (1.2 * s, 1.6 * s, 1.1 * s + math.max(0.0, beat) * 0.4 * s),
    });
  }

  /// Standing at a turntable: one hand scratching, one on the fader.
  _Pose _turntablePose(double t, double deckTop) {
    final u = this.beat;
    final beat = u == null ? math.sin(t * math.pi * 2 * 2.0) : math.exp(-u * 5);
    final nod = math.max(0.0, beat) * 0.25 * s;
    // Scratch: quick back-and-forth bursts with short pauses — or, in a
    // battle, a sharp scratch on every beat.
    final burst = math.sin(t * 1.3) > -0.3 ? 1.0 : 0.15;
    final scratch = u == null ? math.sin(t * math.pi * 2 * 3.2) * 0.45 * s * burst : math.sin(u * math.pi * 6) * math.exp(-u * 3.5) * 0.75 * s;
    final fader = math.sin(t * math.pi * 2 * 0.9) * 0.35 * s;
    final hipZ = _z(76) - 0.25 * s;
    return _Pose({
      'hip': (0, 0, hipZ),
      'shoulder': (0.55 * s, 0, _z(42) - 0.35 * s),
      'neck': (0.65 * s + nod * 0.3, 0, _z(36) - 0.4 * s),
      'head': (0.85 * s + nod, 0, _z(22) - 0.45 * s - nod * 0.2),
      'kneeL': (0.35 * s, -0.55 * s, hipZ * 0.5),
      'footL': (0.1 * s, -0.7 * s, 0),
      'kneeR': (0.35 * s, 0.55 * s, hipZ * 0.5),
      'footR': (0.1 * s, 0.7 * s, 0),
      'elbowL': (1.3 * s, -1.25 * s, deckTop + 0.9 * s),
      'handL': (2.15 * s, -0.15 * s + fader, deckTop + 0.15 * s),
      'elbowR': (1.4 * s, 1.35 * s, deckTop + 1.0 * s),
      'handR': (2.55 * s + scratch * 0.4, 1.05 * s + scratch, deckTop + 0.15 * s),
    });
  }

  // ------------------------------------------------------------ actions
  static double _strike(double q) => q < 0.6 ? _ease(q / 0.6) * 0.15 : 0.15 + 0.85 * math.pow((q - 0.6) / 0.4, 3).toDouble();

  /// The pose while digging, fishing or mining (blended in and out at the
  /// ends so the character never snaps).
  _Pose _actionPose(_Pose base, FigureAction a) {
    final t = a.t.clamp(0.0, 1.0);
    final amt = _ease(t / 0.08) * _ease((1 - t) / 0.06);
    final shZ = _z(42), hipZ = _z(76);
    final j = Map.of(base.j);
    void set(String k, (double, double, double) v) => j[k] = _mix(j[k]!, v, amt);
    void lean(double f, double down) {
      for (final (k, up) in const [('shoulder', 0.7), ('neck', 0.85), ('head', 1.0)]) {
        final p = base.j[k]!;
        set(k, (p.$1 + f * up, p.$2, p.$3 - down * up));
      }
    }

    switch (a.kind) {
      case FigureActionKind.dig:
        if (t < 0.7) {
          // Four digs: the shovel goes in, then lifts and tosses.
          final q = (t / 0.7 * 4) % 1.0;
          final d = math.sin(q * math.pi);
          lean(0.9 * s * d, 0.5 * s * d);
          set('elbowR', (1.0 * s + 0.5 * s * d, 1.2 * s, shZ - 1.3 * s - 0.6 * s * d));
          set('handR', (1.9 * s + 0.9 * s * d, 0.35 * s, shZ - 2.2 * s - 1.5 * s * d));
          set('elbowL', (0.5 * s + 0.3 * s * d, -1.2 * s, shZ - 1.1 * s - 0.4 * s * d));
          set('handL', (1.0 * s + 0.5 * s * d, -0.3 * s, shZ - 1.2 * s - 1.0 * s * d));
        } else {
          // The chest comes up: arms thrown in the air.
          final c = _ease((t - 0.7) / 0.12);
          final bounce = math.sin(t * 40) * 0.12 * s * c;
          set('elbowR', (0.2 * s, 1.7 * s, shZ + 0.8 * s * c));
          set('handR', (0.3 * s, 2.0 * s, shZ + 2.6 * s * c + bounce));
          set('elbowL', (0.2 * s, -1.7 * s, shZ + 0.8 * s * c));
          set('handL', (0.3 * s, -2.0 * s, shZ + 2.6 * s * c - bounce));
        }
      case FigureActionKind.fish:
        final ang = _rodAngle(t);
        // The rod hand follows the rod: back over the shoulder to cast,
        // out in front while waiting, up high for the catch.
        final hx = 1.5 * s * math.cos(ang).clamp(-0.4, 1.0), hz = shZ - 0.5 * s + 1.0 * s * math.sin(ang).clamp(0.0, 1.0);
        set('elbowR', (0.6 * s + hx * 0.3, 1.4 * s, shZ - 1.2 * s + (hz - shZ) * 0.3));
        set('handR', (0.4 * s + hx, 1.0 * s, hz));
        set('elbowL', (0.5 * s, -1.3 * s, shZ - 1.4 * s));
        set('handL', (1.1 * s, -0.5 * s, hipZ + 0.6 * s));
        if (t > 0.75) lean(-0.5 * s * _ease((t - 0.75) / 0.1), 0);
      case FigureActionKind.mine:
        // Five swings of the pickaxe: up over the head, then down hard.
        final q = (t * 5) % 1.0;
        final k = _strike(q); // 0 = raised, 1 = struck
        final up = 1 - k;
        lean(0.3 * s + 0.9 * s * k, 0.6 * s * k);
        set('elbowR', (0.8 * s + 0.6 * s * k, 1.2 * s, shZ + 0.9 * s * up - 0.9 * s * k));
        set('handR', (0.9 * s + 1.5 * s * k, 0.3 * s, shZ + 2.2 * s * up - 1.6 * s * k));
        set('elbowL', (0.7 * s + 0.6 * s * k, -1.2 * s, shZ + 0.8 * s * up - 0.9 * s * k));
        set('handL', (0.7 * s + 1.3 * s * k, -0.3 * s, shZ + 1.8 * s * up - 1.3 * s * k));
    }
    return _Pose(j);
  }

  /// The fishing rod's angle above the horizon (radians) through the cast,
  /// the wait and the catch.
  static double _rodAngle(double t) {
    if (t < 0.1) return 0.7 + 1.6 * _ease(t / 0.1); // swing back
    if (t < 0.2) return 2.3 - 1.75 * _ease((t - 0.1) / 0.1); // cast
    if (t < 0.75) return 0.55 + 0.05 * math.sin(t * 30);
    return 0.55 + 1.0 * _ease((t - 0.75) / 0.1); // strike!
  }

  /// The tool in the character's hands, and what it's working on.
  void _drawActionProps(Canvas canvas, Camera3D cam, FigureAction a, _Pose pose, (double, double, double) Function((double, double, double)) w, double lineW) {
    final t = a.t.clamp(0.0, 1.0);
    final amt = _ease(t / 0.08) * _ease((1 - t) / 0.06);
    if (amt <= 0.02) return;
    Offset? pr((double, double, double) p) {
      final q = w(p);
      return cam.project(q.$1, q.$2, q.$3);
    }

    final outline = HSLColor.fromColor(contrast).lightness > 0.5 ? const Color(0xFF101014) : Colors.white;
    void line((double, double, double) p0, (double, double, double) p1, double width, {Color? color}) {
      final o0 = pr(p0), o1 = pr(p1);
      if (o0 == null || o1 == null) return;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      if (color == null) canvas.drawLine(o0, o1, paint..color = outline.withValues(alpha: amt)..strokeWidth = width + 2);
      canvas.drawLine(o0, o1, paint..color = (color ?? contrast).withValues(alpha: amt)..strokeWidth = width);
    }

    final hR = pose.j['handR']!, hL = pose.j['handL']!;
    final reach = a.reach.clamp(4.5 * s, 9.0 * s);
    switch (a.kind) {
      case FigureActionKind.dig:
        if (t < 0.7) {
          // Shovel: shaft through both hands down to the blade.
          final dx = hR.$1 - hL.$1, dz = hR.$3 - hL.$3;
          final l = math.max(0.01, math.sqrt(dx * dx + dz * dz));
          final tip = (hR.$1 + dx / l * 2.0 * s, hR.$2, math.max(0.0, hR.$3 + dz / l * 2.0 * s));
          line((hL.$1 - dx / l * 0.6 * s, hL.$2, hL.$3 - dz / l * 0.6 * s), tip, lineW * 0.55);
          line(tip, (tip.$1 + dx / l * 0.9 * s, tip.$2, math.max(0.0, tip.$3 + dz / l * 0.9 * s)), lineW * 1.5);
          // Dirt flying from the hole.
          final q = (t / 0.7 * 4) % 1.0;
          if (q > 0.55) {
            final f = (q - 0.55) / 0.45;
            for (var k = 0; k < 4; k++) {
              final o = pr((3.2 * s - f * (1.5 + k * 0.5) * s, (k - 1.5) * 0.7 * s, (0.6 + 2.6 * math.sin(f * math.pi) + k * 0.3) * s));
              if (o != null) canvas.drawCircle(o, lineW * (0.42 - 0.05 * k), Paint()..color = contrast.withValues(alpha: amt * (1 - f)));
            }
          }
        }
        _drawChest(canvas, cam, w, t, amt, lineW);
      case FigureActionKind.fish:
        final ang = _rodAngle(t);
        final tip = (hR.$1 + math.cos(ang) * 5.2 * s, hR.$2, hR.$3 + math.sin(ang) * 5.2 * s);
        line(hR, tip, lineW * 0.42);
        // The line: slack while the rod swings, then out to the float.
        final cast = _ease((t - 0.12) / 0.14);
        final bob = math.sin(t * 22) * 0.25 * s;
        var end = (hR.$1 + (reach - hR.$1) * cast, hR.$2 * (1 - cast), 0.4 * s + bob * cast + (1 - cast) * (tip.$3 - 2 * s));
        if (t > 0.75) {
          final up = _ease((t - 0.75) / 0.15);
          end = (end.$1 + (tip.$1 - end.$1) * up * 0.75, end.$2, end.$3 + (tip.$3 - 1.5 * s - end.$3) * up);
        }
        if (t > 0.1) line(tip, end, math.max(1.0, lineW * 0.14), color: outline);
        final e = pr(end);
        if (e != null && t > 0.2) {
          if (t < 0.75) {
            canvas.drawCircle(e, lineW * 0.5, Paint()..color = const Color(0xFFE5484D).withValues(alpha: amt));
            // Ripples on the water.
            for (var k = 0; k < 2; k++) {
              final r = ((t * 6 + k * 0.5) % 1.0);
              canvas.drawOval(
                  Rect.fromCenter(center: e.translate(0, lineW * 0.3), width: lineW * (2 + 6 * r), height: lineW * (0.8 + 2.4 * r)),
                  Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 1.2
                    ..color = contrast.withValues(alpha: amt * (1 - r) * 0.8));
            }
          } else {
            _drawCatch(canvas, e, lineW, amt);
          }
        }
      case FigureActionKind.mine:
        final q = (t * 5) % 1.0;
        final k = _strike(q);
        // Handle through both hands; the head swings from behind the
        // shoulder down onto the rocks.
        final ang = 2.15 - 2.5 * k;
        final top = (hR.$1 + math.cos(ang) * 3.0 * s, (hR.$2 + hL.$2) / 2, hR.$3 + math.sin(ang) * 3.0 * s);
        line(((hR.$1 + hL.$1) / 2 - math.cos(ang) * 0.7 * s, (hR.$2 + hL.$2) / 2, (hR.$3 + hL.$3) / 2 - math.sin(ang) * 0.7 * s), top, lineW * 0.55);
        final px = -math.sin(ang), pz = math.cos(ang);
        final a0 = (top.$1 + px * 1.5 * s - math.cos(ang) * 0.5 * s, top.$2, top.$3 + pz * 1.5 * s - math.sin(ang) * 0.5 * s);
        final a1 = (top.$1 - px * 1.5 * s - math.cos(ang) * 0.5 * s, top.$2, top.$3 - pz * 1.5 * s - math.sin(ang) * 0.5 * s);
        line(a0, top, lineW * 0.6);
        line(top, a1, lineW * 0.6);
        // Sparks and chips at each strike.
        if (q > 0.92 || q < 0.18) {
          final f = q > 0.92 ? (q - 0.92) / 0.26 : (q + 0.08) / 0.26;
          final hit = pr((math.min(reach, 4.6 * s), 0, 1.2 * s));
          if (hit != null) {
            for (var i = 0; i < 6; i++) {
              final an = -math.pi * (0.15 + 0.7 * i / 5);
              final r0 = lineW * (0.6 + 2.2 * f), r1 = lineW * (1.4 + 3.4 * f);
              canvas.drawLine(
                  hit + Offset(math.cos(an) * r0, math.sin(an) * r0),
                  hit + Offset(math.cos(an) * r1, math.sin(an) * r1),
                  Paint()
                    ..strokeCap = StrokeCap.round
                    ..strokeWidth = math.max(1.2, lineW * 0.2)
                    ..color = accent.withValues(alpha: amt * (1 - f)));
            }
          }
        }
        if (t > 0.86) {
          final e = pr((math.min(reach, 4.6 * s), 0, (1.5 + 5 * _ease((t - 0.86) / 0.1)) * s));
          if (e != null) _drawCatch(canvas, e, lineW, amt);
        }
    }
  }

  /// A little glowing song card: what was fished up or mined.
  void _drawCatch(Canvas canvas, Offset at, double lineW, double alpha) {
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: at, width: lineW * 2.6, height: lineW * 3.6), Radius.circular(lineW * 0.4));
    canvas.drawRRect(
        r.inflate(lineW * 0.9),
        Paint()
          ..color = accent.withValues(alpha: 0.45 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, lineW * 1.2));
    canvas.drawRRect(r, Paint()..color = const Color(0xFF17171C).withValues(alpha: alpha));
    canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, lineW * 0.22)
          ..color = accent.withValues(alpha: alpha));
    canvas.drawCircle(at.translate(0, -lineW * 0.3), lineW * 0.55, Paint()..color = accent.withValues(alpha: alpha));
  }

  /// The treasure chest rising out of the hole (the last third of a dig).
  void _drawChest(Canvas canvas, Camera3D cam, (double, double, double) Function((double, double, double)) w, double t, double alpha, double lineW) {
    if (t < 0.66) return;
    final rise = Curves.easeOutBack.transform(((t - 0.66) / 0.16).clamp(0.0, 1.0));
    const h = 1.9 * s, f0 = 2.3 * s, f1 = 4.3 * s, r0 = -1.6 * s, r1 = 1.6 * s;
    final top = h * rise, base = top - h;
    Offset? p(double f, double r, double z) {
      final q = w((f, r, math.max(0.0, z)));
      return cam.project(q.$1, q.$2, q.$3);
    }

    final corners = [(f0, r0), (f1, r0), (f1, r1), (f0, r1)];
    final faces = <(double, List<Offset>)>[];
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      final pts = [p(a.$1, a.$2, base), p(b.$1, b.$2, base), p(b.$1, b.$2, top), p(a.$1, a.$2, top)];
      if (pts.any((o) => o == null)) return;
      final mid = w(((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2, top / 2));
      faces.add((cam.depth(cam.alignY(mid.$1, mid.$2), mid.$3), [for (final o in pts) o!]));
    }
    faces.sort((x, y) => y.$1.compareTo(x.$1));
    Path quad(List<Offset> pts) => Path()..addPolygon(pts, true);
    const wood = Color(0xFF7A4A21), woodDark = Color(0xFF5C3616), gold = Color(0xFFE3B341);
    final trim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, lineW * 0.22)
      ..strokeJoin = StrokeJoin.round
      ..color = gold.withValues(alpha: alpha);
    for (var i = 0; i < faces.length; i++) {
      canvas.drawPath(quad(faces[i].$2), Paint()..color = (i.isEven ? woodDark : wood).withValues(alpha: alpha));
      canvas.drawPath(quad(faces[i].$2), trim);
    }
    final lid = [for (final c in corners) p(c.$1, c.$2, top)];
    if (lid.any((o) => o == null)) return;
    final lidPts = [for (final o in lid) o!];
    // The lid swings open at the end and the bits inside shine out.
    final open = _ease((t - 0.84) / 0.08);
    if (open > 0) {
      final c = lidPts.reduce((a, b) => a + b) / 4;
      canvas.drawCircle(
          c,
          lineW * (2.5 + 2.5 * open),
          Paint()
            ..color = gold.withValues(alpha: 0.55 * open * alpha)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, lineW * 2));
      canvas.drawPath(quad(lidPts), Paint()..color = const Color(0xFFFFE9A8).withValues(alpha: alpha));
      for (var k = 0; k < 5; k++) {
        final u = ((t - 0.84) * 5 + k * 0.2) % 1.0;
        canvas.drawCircle(c + Offset((k - 2) * lineW * 0.9, -u * lineW * 7), lineW * 0.32 * (1 - u), Paint()..color = gold.withValues(alpha: alpha * (1 - u)));
      }
    } else {
      canvas.drawPath(quad(lidPts), Paint()..color = wood.withValues(alpha: alpha));
    }
    canvas.drawPath(quad(lidPts), trim);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final fr = facing * math.pi / 180;
    final fx = math.sin(fr), fy = math.cos(fr); // forward (east, north)
    final rx = math.cos(fr), ry = -math.sin(fr); // right
    final walk = idle.walk;
    final phase = time * 7.5;
    final act = idle.activity;
    final e = _ease(idle.blend);
    const deckTopFull = 2.9 * s;
    final rise = act == IdleActivity.turntable ? Curves.easeOutBack.transform(e.clamp(0.0, 1.0)) : 0.0;
    final deckTop = deckTopFull * rise;

    var pose = _walkPose(phase, walk);
    if (act == IdleActivity.headphones) pose = _Pose.lerp(pose, _headphonesPose(idle.activityTime), e);
    if (act == IdleActivity.turntable) pose = _Pose.lerp(pose, _turntablePose(idle.activityTime, deckTopFull), e);
    // Waving hello: the right arm swings up and waves from the elbow while
    // the upper body leans in towards the viewer.
    final waveAmt = wave <= 0 || wave >= 1 ? 0.0 : _ease(wave / 0.18) * _ease((1 - wave) / 0.22);
    var waveAngle = 0.0, waveSpeed = 0.0;
    if (waveAmt > 0) {
      final cycles = 2.5;
      // Swings out to the side and back, never across the face.
      waveAngle = 0.32 + 0.42 * math.sin(wave * math.pi * 2 * cycles);
      waveSpeed = math.cos(wave * math.pi * 2 * cycles);
      final sh = pose.j['shoulder']!;
      const fore = 1.55 * s;
      final elbow = (sh.$1 + 0.6 * s, sh.$2 + 2.5 * s, sh.$3 + 1.15 * s);
      final hand = (elbow.$1 + 0.35 * s, elbow.$2 + math.sin(waveAngle) * fore, elbow.$3 + math.cos(waveAngle) * fore);
      final lean = 0.8 * s * waveAmt;
      final j = Map.of(pose.j);
      j['elbowR'] = _mix(j['elbowR']!, elbow, waveAmt);
      j['handR'] = _mix(j['handR']!, hand, waveAmt);
      for (final k in const ['shoulder', 'neck', 'head', 'elbowL', 'handL']) {
        final p = j[k]!;
        final up = k == 'head' ? 1.0 : (k == 'neck' ? 0.85 : 0.7);
        j[k] = (p.$1 + lean * up, p.$2, p.$3 - 0.15 * s * waveAmt * up);
      }
      j['elbowR'] = (j['elbowR']!.$1 + lean * 0.7, j['elbowR']!.$2, j['elbowR']!.$3);
      j['handR'] = (j['handR']!.$1 + lean * 0.7, j['handR']!.$2, j['handR']!.$3);
      pose = _Pose(j);
    }

    final ox = x ?? cam.px, oy = y ?? cam.py;
    // Off-screen or behind the camera: nothing to draw.
    if (x != null) {
      final ya = cam.alignY(ox, oy);
      if (ya < cam.yNear + 20 || ya > cam.yFar * 0.6) return;
      final zc = cam.depth(ya, 0);
      if (zc <= 2) return;
      final sx = cam.sx(cam.alignX(ox, oy), zc);
      if (sx < -120 || sx > size.width + 120) return;
    }
    final act0 = action;
    if (act0 != null) pose = _actionPose(pose, act0);
    (double, double, double) w((double, double, double) p) => (ox + fx * p.$1 + rx * p.$2, oy + fy * p.$1 + ry * p.$2, p.$3);
    (double, double, double) wl(double f, double r, double z) => w((f, r, z));
    Offset? proj((double, double, double) p) => cam.project(p.$1, p.$2, p.$3);
    double depthOf((double, double, double) p) => cam.depth(cam.alignY(p.$1, p.$2), p.$3);
    Offset? pj(String k) => proj(w(pose.j[k]!));

    // Ground shadow + soft accent disc.
    final shadow = Path(), disc = Path();
    for (var i = 0; i <= 32; i++) {
      final a = i * 2 * math.pi / 32;
      final p = cam.project(ox + math.cos(a) * 2.8 * s, oy + math.sin(a) * 2.8 * s);
      final q = cam.project(ox + math.cos(a) * 5.5 * s, oy + math.sin(a) * 5.5 * s);
      if (p != null) i == 0 ? shadow.moveTo(p.dx, p.dy) : shadow.lineTo(p.dx, p.dy);
      if (q != null) i == 0 ? disc.moveTo(q.dx, q.dy) : disc.lineTo(q.dx, q.dy);
    }
    if (this.disc) {
      canvas.drawPath(disc, Paint()..color = accent.withValues(alpha: 0.10));
      canvas.drawPath(
          disc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = accent.withValues(alpha: 0.4));
    }
    canvas.drawPath(
        shadow,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));

    final hipP = pj('hip'), neckP = pj('neck'), headP = pj('head'), shP = pj('shoulder');
    if (hipP == null || neckP == null || headP == null || shP == null) return;
    final headW = w(pose.j['head']!);
    final pxPerM = cam.focal / depthOf(headW);
    final lineW = 0.62 * s * pxPerM;
    final color = look.color;
    final limbPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineW
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Turntable in front of the character: draw before or after depending on
    // whether it's nearer the camera than the body.
    final deckCenter = wl(2.6 * s, 0.4 * s, 0);

    // ---- Depth-sorted scene: limbs, 3D shirt/backpack faces, head, pet and
    // turntable are drawn far-to-near so everything occludes correctly.
    final items = <(double, void Function())>[];
    final camPos = () {
      final br = cam.bearing * math.pi / 180, pr = cam.pitch * math.pi / 180;
      final back = cam.distance * math.cos(pr);
      return (cam.px - math.sin(br) * back, cam.py - math.cos(br) * back, cam.distance * math.sin(pr));
    }();

    final shirt = look.shirt;
    final longSleeves = shirt == 'shirt_hoodie' || shirt == 'shirt_tux';
    void bone(String a, String b) {
      if (shirt != null) {
        // The 3D shirt covers the spine and (part of) the upper arms; only
        // draw the bit of each arm that sticks out of the sleeve.
        if (a == 'neck') return;
        if (a == 'shoulder') {
          if (longSleeves) return;
          final pa = pose.j[a]!, pb = pose.j[b]!;
          final from = (pa.$1 + (pb.$1 - pa.$1) * 0.6, pa.$2 + (pb.$2 - pa.$2) * 0.6, pa.$3 + (pb.$3 - pa.$3) * 0.6);
          final wa = w(from), wb = w(pb);
          final p0 = proj(wa), p1 = proj(wb);
          if (p0 == null || p1 == null) return;
          items.add(((depthOf(wa) + depthOf(wb)) / 2, () => canvas.drawLine(p0, p1, limbPaint)));
          return;
        }
        if (longSleeves && (a == 'elbowL' || a == 'elbowR')) {
          final pa = pose.j[a]!, pb = pose.j[b]!;
          final from = (pa.$1 + (pb.$1 - pa.$1) * 0.7, pa.$2 + (pb.$2 - pa.$2) * 0.7, pa.$3 + (pb.$3 - pa.$3) * 0.7);
          final wa = w(from), wb = w(pb);
          final p0 = proj(wa), p1 = proj(wb);
          if (p0 == null || p1 == null) return;
          items.add(((depthOf(wa) + depthOf(wb)) / 2, () => canvas.drawLine(p0, p1, limbPaint)));
          return;
        }
      }
      final wa = w(pose.j[a]!), wb = w(pose.j[b]!);
      final p0 = proj(wa), p1 = proj(wb);
      if (p0 == null || p1 == null) return;
      items.add(((depthOf(wa) + depthOf(wb)) / 2, () => canvas.drawLine(p0, p1, limbPaint)));
    }

    for (final (a, b) in const [
      ('hip', 'kneeL'), ('kneeL', 'footL'), ('hip', 'kneeR'), ('kneeR', 'footR'), //
      ('shoulder', 'elbowL'), ('elbowL', 'handL'), ('shoulder', 'elbowR'), ('elbowR', 'handR'), ('neck', 'hip'),
    ]) {
      bone(a, b);
    }

    // 3D clothing, backpack and hat. Faces are grouped into their convex
    // parts (torso, each sleeve, pack, strap segment, hat piece) and whole
    // parts are depth-sorted against the limbs and head; within a part only
    // front faces are drawn. Sorting single triangles made faces of
    // different parts poke through each other.
    final outfit = OutfitBuilder();
    if (look.shirt != null) buildShirt(outfit, look.shirt!, pose.j, s, StickFigurePainter.shirtColor(look.shirt!));
    if (look.backpack != null) buildBackpack(outfit, look.backpack!, pose.j, s, time, walk > 0.3);
    final hatStart = outfit.tris.length;
    if (look.hat != null) buildHat(outfit, look.hat!, pose.j['head']!, 1.4 * s, time);
    // The hat turns with the head when it looks around (as the eyes do).
    if (idle.lookYaw.abs() > 0.01 && outfit.tris.length > hatStart) {
      final d = idle.lookYaw * math.pi / 180, cd = math.cos(d), sd = math.sin(d);
      final hc = pose.j['head']!;
      (double, double, double) rot((double, double, double) p) {
        final f = p.$1 - hc.$1, r = p.$2 - hc.$2;
        return (hc.$1 + f * cd - r * sd, hc.$2 + f * sd + r * cd, p.$3);
      }

      (double, double, double)? rotDir((double, double, double)? v) => v == null ? null : (v.$1 * cd - v.$2 * sd, v.$1 * sd + v.$2 * cd, v.$3);
      for (var i = hatStart; i < outfit.tris.length; i++) {
        final t = outfit.tris[i];
        outfit.tris[i] = OutfitTri(rot(t.a), rot(t.b), rot(t.c), t.color, rot(t.center), host: t.host == null ? null : rot(t.host!), mount: rotDir(t.mount));
      }
    }
    const lx = -0.35, ly = 0.45, lz = 0.82; // light from above, slightly to one side
    final parts = <(double, double, double), List<(Offset, Offset, Offset, Color, double)>>{};
    // Details mounted on a part (speakers, pockets), drawn right after it.
    final mounted = <(double, double, double), List<(Offset, Offset, Offset, Color, double)>>{};
    final origin = w((0, 0, 0));
    final mountVisible = <(double, double, double), bool>{};
    final partHat = <(double, double, double), bool>{};
    for (var ti = 0; ti < outfit.tris.length; ti++) {
      final t = outfit.tris[ti];
      final a = w(t.a), b = w(t.b), c = w(t.c), ctr = w(t.center);
      final ux = b.$1 - a.$1, uy = b.$2 - a.$2, uz = b.$3 - a.$3;
      final vx = c.$1 - a.$1, vy = c.$2 - a.$2, vz = c.$3 - a.$3;
      var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-9) continue;
      nx /= nl;
      ny /= nl;
      nz /= nl;
      final mx = (a.$1 + b.$1 + c.$1) / 3, my = (a.$2 + b.$2 + c.$2) / 3, mz = (a.$3 + b.$3 + c.$3) / 3;
      if (nx * (mx - ctr.$1) + ny * (my - ctr.$2) + nz * (mz - ctr.$3) < 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
      }
      if (nx * (camPos.$1 - mx) + ny * (camPos.$2 - my) + nz * (camPos.$3 - mz) <= 0) continue;
      final host = t.host;
      if (host != null) {
        // Only while the surface it's mounted on faces the camera.
        final vis = mountVisible[t.mount!] ??= () {
          final m = w(t.mount!);
          final dx = m.$1 - origin.$1, dy = m.$2 - origin.$2, dz = m.$3 - origin.$3;
          final hw = w(host);
          return dx * (camPos.$1 - hw.$1) + dy * (camPos.$2 - hw.$2) + dz * (camPos.$3 - hw.$3) > 0;
        }();
        if (!vis) continue;
      }
      final pa = proj(a), pb = proj(b), pc = proj(c);
      if (pa == null || pb == null || pc == null) continue;
      final k = 0.62 + 0.38 * math.max(0.0, nx * lx + ny * ly + nz * lz);
      final col = Color.fromARGB(255, (t.color.r * 255 * k).round().clamp(0, 255), (t.color.g * 255 * k).round().clamp(0, 255), (t.color.b * 255 * k).round().clamp(0, 255));
      final face = (pa, pb, pc, col, (depthOf(a) + depthOf(b) + depthOf(c)) / 3);
      if (host != null) {
        parts.putIfAbsent(host, () => []);
        (mounted[host] ??= []).add(face);
      } else {
        (parts[t.center] ??= []).add(face);
      }
      if (ti >= hatStart) partHat[t.center] = true;
    }
    final fill = Paint()..isAntiAlias = true;
    final seam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..strokeJoin = StrokeJoin.round;
    for (final e in parts.entries) {
      final faces = e.value..sort((x, y) => y.$5.compareTo(x.$5));
      final extra = mounted[e.key];
      if (extra != null) faces.addAll(extra..sort((x, y) => y.$5.compareTo(x.$5)));
      // Hat pieces sit on the head: nudge them in front of the head disc
      // unless they're clearly behind it.
      final bias = partHat[e.key] == true ? -0.5 * s : 0.0;
      items.add((
        depthOf(w(e.key)) + bias,
        () {
          for (final (pa, pb, pc, col, _) in faces) {
            final path = Path()
              ..moveTo(pa.dx, pa.dy)
              ..lineTo(pb.dx, pb.dy)
              ..lineTo(pc.dx, pc.dy)
              ..close();
            canvas
              ..drawPath(path, fill..color = col)
              ..drawPath(path, seam..color = col);
          }
        }
      ));
    }

    // Head: a sphere drawn as a disc; the eyes live on its surface.
    final headR = 1.4 * s * pxPerM;
    final k = headR / 14;
    items.add((
      depthOf(headW),
      () {
        canvas.drawCircle(headP, headR, Paint()..color = const Color(0xFF0E0E12));
        canvas.drawCircle(headP, headR, limbPaint);
        _drawEyes(canvas, cam, headW, headR, pxPerM, color);
        // Headphones slide on during the headphones idle.
        if (act == IdleActivity.headphones && look.hat != 'hat_headphones') {
          final hp = _ease((idle.blend - 0.45) / 0.45);
          if (hp > 0) {
            canvas.save();
            canvas.translate(headP.dx, headP.dy - (1 - hp) * headR * 1.4);
            canvas.scale(k, k);
            canvas.translate(0, -22);
            canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: hp));
            _drawHeadphones(canvas, const Offset(0, 22));
            canvas.restore();
            canvas.restore();
          }
        }
      }
    ));

    if (act == IdleActivity.turntable && rise > 0.01) {
      items.add((depthOf(deckCenter), () => _drawTurntable(canvas, cam, wl, deckTop, idle.activityTime)));
    }

    // Pet trots beside the player — sorted by depth like everything else, so
    // it's hidden behind the player when it's on the far side.
    if (look.pet != null) {
      final petW = wl(-1.2 * s, 4.2 * s, 0);
      final pp = proj(petW);
      if (pp != null) {
        final kp = 0.1 * s * cam.focal / depthOf(petW);
        items.add((
          depthOf(wl(-1.2 * s, 4.2 * s, 1.5 * s)),
          () {
            canvas.save();
            canvas.translate(pp.dx, pp.dy);
            canvas.scale(kp, kp * 0.85);
            canvas.translate(0, -118);
            StickFigurePainter.drawPet(canvas, look.pet!, phase, walk > 0.3);
            canvas.restore();
          }
        ));
      }
    }

    items.sort((a, b) => b.$1.compareTo(a.$1));
    for (final it in items) {
      it.$2();
    }

    // Motion lines beside the waving hand.
    if (waveAmt > 0.15) {
      final hp = pj('handR'), ep = pj('elbowR');
      if (hp != null && ep != null) {
        final v = hp - ep;
        final r = v.distance;
        final a0 = math.atan2(v.dy, v.dx);
        // On the side the hand is moving away from (trailing it).
        final behind = waveSpeed >= 0 ? -1.0 : 1.0;
        final linePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          // A quarter of the arm's thickness.
          ..strokeWidth = lineW * 0.25
          ..color = contrast.withValues(alpha: 0.75 * ((waveAmt - 0.15) / 0.85).clamp(0.0, 1.0) * (0.45 + 0.55 * waveSpeed.abs()));
        for (var k = 0; k < 3; k++) {
          final rr = r * (0.82 + k * 0.2);
          final span = 0.26 - k * 0.05;
          final start = a0 + behind * (0.32 + k * 0.06);
          canvas.drawArc(Rect.fromCircle(center: ep, radius: rr), behind > 0 ? start : start - span, span, false, linePaint);
        }
      }
    }

    if (act0 != null) _drawActionProps(canvas, cam, act0, pose, w, lineW);

    // Floating notes always sit on top.
    if (act == IdleActivity.headphones) _drawNotes(canvas, headP, headR, idle.activityTime, e);
    if (act == IdleActivity.turntable && e > 0.3) _drawNotes(canvas, headP, headR, idle.activityTime * 0.8, (e - 0.3) / 0.7);
  }

  /// Eyes are points on the head sphere. Their visibility and width follow
  /// how directly they face the camera, so they turn smoothly into and out of
  /// view (no popping) — including when the head glances around.
  void _drawEyes(Canvas canvas, Camera3D cam, (double, double, double) head, double headR, double pxPerM, Color color) {
    final yaw = (facing + idle.lookYaw) * math.pi / 180;
    final hx = math.sin(yaw), hy = math.cos(yaw); // head forward
    final rx = math.cos(yaw), ry = -math.sin(yaw); // head right
    // Direction from the head towards the camera.
    final br = cam.bearing * math.pi / 180;
    final pr = cam.pitch * math.pi / 180;
    final cx = -math.sin(br) * math.cos(pr), cy = -math.cos(br) * math.cos(pr), cz = math.sin(pr);
    final rWorld = headR / pxPerM;
    for (final side in [-1.0, 1.0]) {
      // Eye normal on the sphere: mostly forward, a little to the side and up.
      var nx = hx * 0.88 + rx * side * 0.42, ny = hy * 0.88 + ry * side * 0.42;
      const nz = 0.12;
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      nx /= l;
      ny /= l;
      final facingCam = nx * cx + ny * cy + (nz / l) * cz;
      final vis = _ease(facingCam / 0.35);
      if (vis <= 0) continue;
      final p = cam.project(head.$1 + nx * rWorld * 0.92, head.$2 + ny * rWorld * 0.92, head.$3 + (nz / l) * rWorld * 0.92);
      if (p == null) continue;
      final er = headR * 0.16;
      canvas.drawOval(
        Rect.fromCenter(center: p, width: er * 2 * (0.35 + 0.65 * facingCam.clamp(0.0, 1.0)), height: er * 2),
        Paint()..color = color.withValues(alpha: vis),
      );
    }
  }

  /// Little music notes floating up from the character.
  /// Idle headphones in the theme's contrast colour, with an outline so
  /// they read on any ground.
  void _drawHeadphones(Canvas canvas, Offset head) {
    final outline = HSLColor.fromColor(contrast).lightness > 0.5 ? const Color(0xFF101014) : Colors.white;
    final band = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final arc = Rect.fromCircle(center: head, radius: 17);
    canvas.drawArc(arc, math.pi * 1.05, math.pi * 0.9, false, band);
    canvas.drawArc(arc, math.pi * 1.05, math.pi * 0.9, false, band..color = contrast..strokeWidth = 3.5);
    for (final dx in [-16.0, 16.0]) {
      final cup = RRect.fromRectAndRadius(Rect.fromCenter(center: head + Offset(dx, 2), width: 9, height: 15), const Radius.circular(4.5));
      canvas.drawRRect(cup.inflate(1.5), Paint()..color = outline);
      canvas.drawRRect(cup, Paint()..color = contrast);
    }
  }

  void _drawNotes(Canvas canvas, Offset head, double headR, double t, double strength) {
    if (strength <= 0) return;
    for (var k = 0; k < 6; k++) {
      final age = (t * 0.45 + k / 6) % 1.0;
      final side = k.isEven ? -1.0 : 1.0;
      final x = head.dx + side * headR * (1.1 + age * 1.2) + math.sin((t + k) * 2.4) * headR * 0.3;
      final y = head.dy - headR * 0.2 - age * headR * 4.2;
      final a = strength * (age < 0.15 ? age / 0.15 : 1 - (age - 0.15) / 0.85);
      final sz = headR * (0.42 + 0.12 * (k % 3));
      final alpha = a.clamp(0.0, 1.0);
      final outline = (HSLColor.fromColor(contrast).lightness > 0.5 ? const Color(0xFF101014) : Colors.white).withValues(alpha: alpha * 0.85);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(math.sin(t * 2 + k) * 0.25);
      // Note head + stem (+ flag on alternating notes): outlined, then filled.
      for (final paint in [
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, sz * 0.12)
          ..strokeJoin = StrokeJoin.round,
        Paint()..color = contrast.withValues(alpha: alpha),
      ]) {
        canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: sz * 0.62, height: sz * 0.46), paint);
        canvas.drawRect(Rect.fromLTWH(sz * 0.22, -sz * 1.15, sz * 0.1, sz * 1.15), paint);
        if (k % 3 != 0) {
          canvas.drawPath(
              Path()
                ..moveTo(sz * 0.32, -sz * 1.15)
                ..quadraticBezierTo(sz * 0.75, -sz * 0.9, sz * 0.55, -sz * 0.45)
                ..lineTo(sz * 0.32, -sz * 0.8)
                ..close(),
              paint);
        }
      }
      canvas.restore();
    }
  }

  /// A DJ deck that rises out of the ground in front of the character.
  void _drawTurntable(Canvas canvas, Camera3D cam, (double, double, double) Function(double, double, double) wl, double top, double t) {
    if (top <= 0.05) return;
    Offset? p(double f, double r, double z) {
      final q = wl(f, r, z);
      return cam.project(q.$1, q.$2, q.$3);
    }

    const f0 = 1.9 * s, f1 = 3.3 * s, r0 = -1.9 * s, r1 = 1.9 * s;
    final corners = [(f0, r0), (f1, r0), (f1, r1), (f0, r1)];
    Path quad(List<Offset?> pts) {
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final o = pts[i]!;
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      return path..close();
    }

    final body = Paint()..color = const Color(0xFF26262C);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = accent.withValues(alpha: 0.5);
    // Side faces, far ones first.
    final faces = <(double, List<Offset?>)>[];
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      final pts = [p(a.$1, a.$2, 0), p(b.$1, b.$2, 0), p(b.$1, b.$2, top), p(a.$1, a.$2, top)];
      if (pts.any((o) => o == null)) return;
      final mid = wl((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2, top / 2);
      faces.add((cam.depth(cam.alignY(mid.$1, mid.$2), mid.$3), pts));
    }
    faces.sort((x, y) => y.$1.compareTo(x.$1));
    for (final f in faces) {
      canvas.drawPath(quad(f.$2), body);
      canvas.drawPath(quad(f.$2), edge);
    }
    final topFace = [for (final c in corners) p(c.$1, c.$2, top)];
    if (topFace.any((o) => o == null)) return;
    canvas.drawPath(quad(topFace), Paint()..color = const Color(0xFF34343C));
    canvas.drawPath(quad(topFace), edge);
    // Two platters with spinning records + a mixer between them.
    for (final side in [-1.0, 1.0]) {
      final cf = 2.6 * s, cr = side * 1.05 * s;
      final ring = Path();
      for (var i = 0; i <= 24; i++) {
        final a = i * 2 * math.pi / 24;
        final o = p(cf + math.cos(a) * 0.62 * s, cr + math.sin(a) * 0.62 * s, top + 0.02);
        if (o == null) return;
        i == 0 ? ring.moveTo(o.dx, o.dy) : ring.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(ring, Paint()..color = const Color(0xFF0B0B0D));
      final spin = t * (side > 0 ? 4.0 + math.sin(t * 6) * 3 : 3.5);
      final c = p(cf, cr, top + 0.03), m = p(cf + math.cos(spin) * 0.5 * s, cr + math.sin(spin) * 0.5 * s, top + 0.03);
      if (c != null && m != null) {
        canvas.drawLine(
            c,
            m,
            Paint()
              ..color = accent
              ..strokeWidth = 1.5);
        canvas.drawCircle(c, 2.5, Paint()..color = accent);
      }
    }
    final mix = [p(2.25 * s, -0.25 * s, top + 0.03), p(2.95 * s, -0.25 * s, top + 0.03), p(2.95 * s, 0.25 * s, top + 0.03), p(2.25 * s, 0.25 * s, top + 0.03)];
    if (!mix.any((o) => o == null)) canvas.drawPath(quad(mix), Paint()..color = const Color(0xFF1B1B20));
  }

  @override
  bool shouldRepaint(Figure3DPainter old) => true;
}
