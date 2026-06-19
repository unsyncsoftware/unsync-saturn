import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/saturn_theme.dart';

class SaturnHome extends StatelessWidget {
  const SaturnHome({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SaturnTheme.voidBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 132,
                height: 92,
                child: CustomPaint(painter: _SaturnLogoPainter()),
              ),
              const SizedBox(height: 28),
              Text(
                'SATURN',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppConstants.appTagline.toUpperCase(),
                textAlign: TextAlign.center,
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textMuted,
                  fontSize: 10,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Try: mesh://@bossing.site',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _QuickNavChip(
                    label: '@bossing.site',
                    onTap: () => onNavigate('mesh://@bossing.site'),
                  ),
                  _QuickNavChip(
                    label: 'unsync.uk',
                    onTap: () => onNavigate('https://unsync.uk'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickNavChip extends StatelessWidget {
  const _QuickNavChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: SaturnTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: SaturnTheme.border),
        ),
        child: Text(
          label,
          style: SaturnTheme.mono.copyWith(
            color: SaturnTheme.textPrimary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _SaturnLogoPainter extends CustomPainter {
  const _SaturnLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final planetRadius = size.height * 0.26;
    final planetFill = Paint()
      ..color = SaturnTheme.meshAccent.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final planetStroke = Paint()
      ..color = SaturnTheme.meshAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final ringPaint = Paint()
      ..color = SaturnTheme.cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-math.pi / 10);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size.width * 0.88,
        height: size.height * 0.28,
      ),
      ringPaint,
    );
    canvas.restore();

    canvas.drawCircle(center, planetRadius, planetFill);
    canvas.drawCircle(center, planetRadius, planetStroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
