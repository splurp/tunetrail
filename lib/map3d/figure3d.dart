import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/widgets/stick_figure.dart';
import 'camera.dart';

/// Idle activities the character can drift into when standing still.
enum IdleActivity { none, headphones, turntable }

/// Drives walking/idle blending and look-around. Updated every frame by the
/// map screen; all transitions are eased so the figure never snaps.
class IdleDirector {
  IdleDirector([int? seed]) : _r = math.Random(seed);
  final math.Random _r;

  /// 0 = standing, 1 = full walk cycle (smoothed).
  double walk = 0;

  /// Current activity and how far into it we've blended (0..1).
  IdleActivity activity = IdleActivity.none;
  double blend = 0;

  /// Seconds since the current activity started.
  double activityTime = 0;

  /// Head yaw relative to the body, degrees (look-around).
  double lookYaw = 0;

  double _stillFor = 0, _nextIdleAt = 5, _activityLength = 16, _lookTarget = 0, _lookTimer = 2;
  bool _ending = false;
  IdleActivity _last = IdleActivity.turntable;

  void update(double dt, bool moving) {
    dt = dt.clamp(0.0, 0.1);
    walk += ((moving ? 1.0 : 0.0) - walk) * math.min(1.0, dt * 7);
    if (moving) {
      _stillFor = 0;
      if (activity != IdleActivity.none) _ending = true;
    } else {
      _stillFor += dt;
    }

    if (activity == IdleActivity.none) {
      if (!moving && _stillFor > _nextIdleAt) {
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
        _nextIdleAt = 6 + _r.nextDouble() * 6;
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
  });

  final Camera3D camera;
  final FigureLook look;
  final double time; // seconds
  final IdleDirector idle;
  final double facing; // degrees clockwise from north
  final Color accent;

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

    (double, double, double) elbow(double side, double a) => (math.sin(a) * armLen / 2, side * 1.0 * s, shZ - math.cos(a) * armLen / 2);
    (double, double, double) hand(double side, double a) {
      final e = elbow(side, a);
      return (e.$1 + math.sin(a + 0.35) * armLen / 2, side * 1.25 * s, e.$3 - math.cos(a + 0.35) * armLen / 2);
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
    final beat = math.sin(t * math.pi * 2 * 2.0);
    final nod = math.max(0.0, beat) * 0.25 * s;
    // Scratch: quick back-and-forth bursts with short pauses.
    final burst = math.sin(t * 1.3) > -0.3 ? 1.0 : 0.15;
    final scratch = math.sin(t * math.pi * 2 * 3.2) * 0.45 * s * burst;
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

    (double, double, double) w((double, double, double) p) => (cam.px + fx * p.$1 + rx * p.$2, cam.py + fy * p.$1 + ry * p.$2, p.$3);
    (double, double, double) wl(double f, double r, double z) => w((f, r, z));
    Offset? proj((double, double, double) p) => cam.project(p.$1, p.$2, p.$3);
    double depthOf((double, double, double) p) => cam.depth(cam.alignY(p.$1, p.$2), p.$3);
    Offset? pj(String k) => proj(w(pose.j[k]!));

    // Ground shadow + soft accent disc.
    final shadow = Path(), disc = Path();
    for (var i = 0; i <= 32; i++) {
      final a = i * 2 * math.pi / 32;
      final p = cam.project(cam.px + math.cos(a) * 2.8 * s, cam.py + math.sin(a) * 2.8 * s);
      final q = cam.project(cam.px + math.cos(a) * 5.5 * s, cam.py + math.sin(a) * 5.5 * s);
      if (p != null) i == 0 ? shadow.moveTo(p.dx, p.dy) : shadow.lineTo(p.dx, p.dy);
      if (q != null) i == 0 ? disc.moveTo(q.dx, q.dy) : disc.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(disc, Paint()..color = accent.withValues(alpha: 0.10));
    canvas.drawPath(
        disc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = accent.withValues(alpha: 0.4));
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

    // Facing relative to camera: faY > 0 = facing away (back visible).
    final (faX, faY) = cam.worldDirToAligned(fx, fy);
    final widthF = 0.45 + 0.55 * faY.abs();
    final kx = 0.1 * s * pxPerM;
    final ky = (hipP.dy - neckP.dy) / 40;

    // Turntable in front of the character: draw before or after depending on
    // whether it's nearer the camera than the body.
    final deckCenter = wl(2.6 * s, 0.4 * s, 0);
    final deckInFront = depthOf(deckCenter) < depthOf(w(pose.j['hip']!));
    if (act == IdleActivity.turntable && rise > 0.01 && !deckInFront) _drawTurntable(canvas, cam, wl, deckTop, idle.activityTime);

    void limb(String a, String b, String c) {
      final p0 = pj(a), p1 = pj(b), p2 = pj(c);
      if (p0 == null || p1 == null || p2 == null) return;
      canvas.drawPath(Path()
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy), limbPaint);
    }

    void backpack() {
      if (look.backpack == null) return;
      canvas.save();
      final shift = look.backpack == 'bag_wings' ? 0.0 : 14 + 16 * faX;
      canvas.translate(neckP.dx, neckP.dy);
      canvas.scale(kx * widthF, ky);
      canvas.translate(shift, -36);
      StickFigurePainter.drawBackpack(canvas, look.backpack, walk > 0.3, phase);
      canvas.restore();
    }

    final backVisible = faY > 0;
    if (!backVisible) backpack();

    // One consistent colour for every limb (no depth shading).
    limb('hip', 'kneeL', 'footL');
    limb('hip', 'kneeR', 'footR');
    limb('shoulder', 'elbowL', 'handL');
    limb('shoulder', 'elbowR', 'handR');
    canvas.drawLine(neckP, hipP, limbPaint);
    if (look.shirt != null) {
      canvas.save();
      canvas.translate(neckP.dx, neckP.dy);
      final torsoAngle = math.atan2(hipP.dx - neckP.dx, hipP.dy - neckP.dy);
      canvas.rotate(-torsoAngle);
      canvas.scale(kx * widthF, ((hipP - neckP).distance) / 40);
      canvas.translate(0, -36);
      StickFigurePainter.drawShirt(canvas, look.shirt, const Offset(0, 36), const Offset(0, 76));
      canvas.restore();
      for (final side in ['L', 'R']) {
        final el = pj('elbow$side');
        if (el != null) StickFigurePainter.drawSleeve(canvas, look.shirt, shP, el, lineW * 1.9);
      }
    }
    if (backVisible) backpack();

    // Head: a sphere drawn as a disc; the eyes live on its surface.
    final headR = 1.4 * s * pxPerM;
    canvas.drawCircle(headP, headR, Paint()..color = const Color(0xFF0E0E12));
    canvas.drawCircle(headP, headR, limbPaint);
    _drawEyes(canvas, cam, headW, headR, pxPerM, color);

    final k = headR / 14;
    if (look.hat != null) {
      canvas.save();
      canvas.translate(headP.dx, headP.dy);
      canvas.scale(k, k);
      canvas.translate(0, -22);
      StickFigurePainter.drawHat(canvas, look.hat, const Offset(0, 22), phase);
      canvas.restore();
    }
    // Headphones slide on during the headphones idle.
    if (act == IdleActivity.headphones && look.hat != 'hat_headphones') {
      final hp = _ease((idle.blend - 0.45) / 0.45);
      if (hp > 0) {
        canvas.save();
        canvas.translate(headP.dx, headP.dy - (1 - hp) * headR * 1.4);
        canvas.scale(k, k);
        canvas.translate(0, -22);
        canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: hp));
        StickFigurePainter.drawHat(canvas, 'hat_headphones', const Offset(0, 22), phase);
        canvas.restore();
        canvas.restore();
      }
      _drawNotes(canvas, headP, headR, idle.activityTime, e);
    }

    if (act == IdleActivity.turntable && rise > 0.01 && deckInFront) _drawTurntable(canvas, cam, wl, deckTop, idle.activityTime);
    if (act == IdleActivity.turntable && e > 0.3) _drawNotes(canvas, headP, headR, idle.activityTime * 0.8, (e - 0.3) / 0.7);

    // Pet trots beside the player.
    if (look.pet != null) {
      final petW = wl(-1.2 * s, 4.2 * s, 0);
      final pp = proj(petW);
      if (pp != null) {
        final kp = 0.1 * s * cam.focal / depthOf(petW);
        canvas.save();
        canvas.translate(pp.dx, pp.dy);
        canvas.scale(kp, kp * 0.85);
        canvas.translate(0, -118);
        StickFigurePainter.drawPet(canvas, look.pet!, phase, walk > 0.3);
        canvas.restore();
      }
    }
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
  void _drawNotes(Canvas canvas, Offset head, double headR, double t, double strength) {
    if (strength <= 0) return;
    for (var k = 0; k < 6; k++) {
      final age = (t * 0.45 + k / 6) % 1.0;
      final side = k.isEven ? -1.0 : 1.0;
      final x = head.dx + side * headR * (1.1 + age * 1.2) + math.sin((t + k) * 2.4) * headR * 0.3;
      final y = head.dy - headR * 0.2 - age * headR * 4.2;
      final a = strength * (age < 0.15 ? age / 0.15 : 1 - (age - 0.15) / 0.85);
      final sz = headR * (0.42 + 0.12 * (k % 3));
      final paint = Paint()..color = accent.withValues(alpha: a.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(math.sin(t * 2 + k) * 0.25);
      // Note head + stem (+ flag on alternating notes).
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
