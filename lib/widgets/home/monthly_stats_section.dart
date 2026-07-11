import 'dart:math' as math;
import 'package:dash_application/models/home_models.dart';
import 'package:flutter/material.dart';
// import '../../models/home_models.dart'; // Assicurati di importare il modello aggiornato

class MonthlyStatsSection extends StatelessWidget {
  final List<MonthlyStatData> stats;

  const MonthlyStatsSection({
    super.key,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          icon: Icons.insert_chart_outlined_rounded,
          title: 'Last 30 days statistics', // Titolo aggiornato
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 210, // Altezza aumentata per far spazio al testo inferiore
          child: ListView.separated(
            physics: const ClampingScrollPhysics(),
            scrollDirection: Axis.horizontal,
            itemCount: stats.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              return _StatGaugeCard(data: stats[index]);
            },
          ),
        ),
      ],
    );
  }
}

class _StatGaugeCard extends StatelessWidget {
  final MonthlyStatData data;

  const _StatGaugeCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140, // Larghezza fissa per ogni elemento dello scroll
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            height: 130,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Il nostro arco custom
                CustomPaint(
                  size: const Size(130, 130),
                  painter: _GaugePainter(
                    progress: data.progress,
                    strokeWidth: 8.5,
                    trackColor: const Color(0xFFD9DCD4),
                    progressColor: const Color(0xFF425A60),
                  ),
                ),
                // Contenuto testuale all'interno dell'arco
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          data.icon,
                          size: 16,
                          color: const Color(0xFF5A6B56),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            data.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF5A6B56),
                              height: 1.15,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      data.value,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2E3D2B),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Testo inferiore (Record o Best overall)
          Text(
            data.bottomText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF7A8374),
            ),
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color trackColor;
  final Color progressColor;

  const _GaugePainter({
    required this.progress,
    required this.strokeWidth,
    required this.trackColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Angoli per creare l'effetto "contachilometri" aperto in basso
    const startAngle = math.pi * 0.75; // Parte da in basso a sinistra
    const sweepAngle = math.pi * 1.5;  // Copre 3/4 del cerchio

    // Disegna il binario grigio di base
    canvas.drawArc(rect, startAngle, sweepAngle, false, trackPaint);

    // Disegna il progresso se maggiore di zero
    if (progress > 0) {
      final validProgress = progress.clamp(0.0, 1.0);
      canvas.drawArc(rect, startAngle, sweepAngle * validProgress, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionTitle({
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 22, color: const Color(0xFF4A554A)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Color(0xFF394137),
          ),
        ),
      ],
    );
  }
}