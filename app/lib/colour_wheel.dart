import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Hue/saturation wheel: angle = hue (0-360), distance from centre = saturation (0-100).
class ColourWheel extends StatelessWidget {
  const ColourWheel({super.key, required this.hue, required this.sat, required this.onChanged, required this.onChangeEnd});
  final double hue, sat;
  final void Function(double hue, double sat) onChanged, onChangeEnd;

  (double, double) _pick(Offset p, double size) {
    final c = Offset(size / 2, size / 2);
    final d = p - c;
    var h = math.atan2(d.dy, d.dx) * 180 / math.pi; // 0 = right, clockwise
    if (h < 0) h += 360;
    final s = (d.distance / (size / 2) * 100).clamp(0.0, 100.0);
    return (h, s);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(builder: (context, box) {
        final size = math.min(box.maxWidth, 320.0);
        void move(Offset p, void Function(double, double) cb) {
          final (h, s) = _pick(p, size);
          cb(h, s);
        }

        return GestureDetector(
          onPanStart: (d) => move(d.localPosition, onChanged),
          onPanUpdate: (d) => move(d.localPosition, onChanged),
          onPanEnd: (_) => onChangeEnd(hue, sat),
          onTapUp: (d) => move(d.localPosition, onChangeEnd),
          child: CustomPaint(size: Size.square(size), painter: _WheelPainter(hue, sat)),
        );
      }),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.hue, this.sat);
  final double hue, sat;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    final sweep = SweepGradient(colors: [
      for (var i = 0; i <= 360; i += 30) HSLColor.fromAHSL(1, i.toDouble() % 360, 1, 0.5).toColor(),
    ]);
    canvas.drawCircle(c, r, Paint()..shader = sweep.createShader(rect));
    // white in the centre fades out to full saturation at the rim
    canvas.drawCircle(
        c, r, Paint()..shader = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(rect));
    final a = hue * math.pi / 180;
    final p = c + Offset(math.cos(a), math.sin(a)) * (sat / 100 * r);
    canvas.drawCircle(p, 12, Paint()..color = HSLColor.fromAHSL(1, hue, sat / 100, 0.5 + (1 - sat / 100) * 0.5).toColor());
    canvas.drawCircle(p, 12, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = Colors.white);
    canvas.drawCircle(p, 13.5, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = Colors.black54);
  }

  @override
  bool shouldRepaint(_WheelPainter o) => o.hue != hue || o.sat != sat;
}

/// Quick-pick colours: (label, hue, saturation).
const presets = <(String, double, double)>[
  ('Red', 0, 100),
  ('Orange', 30, 100),
  ('Yellow', 55, 100),
  ('Green', 120, 100),
  ('Cyan', 180, 100),
  ('Blue', 240, 100),
  ('Purple', 275, 100),
  ('Pink', 320, 80),
  ('White', 0, 0),
];

class PresetRow extends StatelessWidget {
  const PresetRow({super.key, required this.onPick});
  final void Function(double hue, double sat) onPick;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 12, runSpacing: 12, children: [
        for (final (name, h, s) in presets)
          Tooltip(
            message: name,
            child: InkResponse(
              onTap: () => onPick(h, s),
              radius: 28,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: HSLColor.fromAHSL(1, h, s / 100, 0.5 + (1 - s / 100) * 0.5).toColor(),
                  border: Border.all(color: Colors.black26, width: 1.5),
                ),
              ),
            ),
          ),
      ]);
}
