import 'dart:math' as math;

import 'package:flutter/material.dart';

/// On-screen analog stick. Reports x/y in [-1, 1] (y positive = up/north).
/// Also supports WASD / arrow keys on desktop via [JoystickKeys].
class Joystick extends StatefulWidget {
  const Joystick({super.key, required this.onChanged, this.size = 130});
  final void Function(double x, double y) onChanged;
  final double size;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero;

  void _update(Offset local) {
    final r = widget.size / 2;
    var v = local - Offset(r, r);
    if (v.distance > r) v = v / v.distance * r;
    setState(() => _knob = v);
    widget.onChanged(v.dx / r, -v.dy / r);
  }

  void _end() {
    setState(() => _knob = Offset.zero);
    widget.onChanged(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return GestureDetector(
      onPanStart: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _end(),
      onPanCancel: _end,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.35),
              border: Border.all(color: Colors.white38, width: 2),
            ),
          ),
          Center(
            child: Transform.translate(
              offset: _knob,
              child: Container(
                width: s * 0.42,
                height: s * 0.42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(colors: [Color(0xFF80F7FF), Color(0xFF00ACC1)]),
                  boxShadow: [BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.5), blurRadius: 12)],
                ),
                child: Icon(Icons.directions_walk, color: Colors.black.withValues(alpha: 0.6)),
              ),
            ),
          ),
          if (_knob == Offset.zero)
            for (var i = 0; i < 4; i++)
              Align(
                alignment: Alignment(math.cos(i * math.pi / 2) * 0.82, math.sin(i * math.pi / 2) * 0.82),
                child: Transform.rotate(
                  angle: i * math.pi / 2,
                  child: const Icon(Icons.chevron_right, color: Colors.white54, size: 18),
                ),
              ),
        ]),
      ),
    );
  }
}
