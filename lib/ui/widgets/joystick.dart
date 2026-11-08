import 'dart:math' as math;

import 'package:flutter/material.dart';

/// On-screen analog stick. Reports x/y in [-1, 1] (y positive = up/north).
/// Also supports WASD / arrow keys on desktop via [JoystickKeys].
class Joystick extends StatefulWidget {
  const Joystick({super.key, required this.onChanged, this.size = 120});
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
              color: const Color(0x99101013),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
                  color: const Color(0xFFE9E9EE),
                  boxShadow: [BoxShadow(color: const Color(0xFF9A8CF0).withValues(alpha: 0.35), blurRadius: 14)],
                ),
                child: const Icon(Icons.directions_walk_rounded, color: Colors.black54, size: 20),
              ),
            ),
          ),
          if (_knob == Offset.zero)
            for (var i = 0; i < 4; i++)
              Align(
                alignment: Alignment(math.cos(i * math.pi / 2) * 0.82, math.sin(i * math.pi / 2) * 0.82),
                child: Transform.rotate(
                  angle: i * math.pi / 2,
                  child: const Icon(Icons.chevron_right, color: Colors.white24, size: 16),
                ),
              ),
        ]),
      ),
    );
  }
}
