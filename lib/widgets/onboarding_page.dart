import 'package:flutter/material.dart';

class OnboardingPage extends StatelessWidget {
  final String backgroundImage; // asset path o network url
  final String title;
  final List<TextSpan> bodySpans;

  const OnboardingPage({
    super.key,
    required this.backgroundImage,
    required this.title,
    required this.bodySpans,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Immagine di sfondo
        Image.asset(
          backgroundImage,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1A2A2A), Color(0xFF0D1515)],
              ),
            ),
          ),
        ),

        // Overlay scuro gradiente
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Color(0x44000000),
                Color(0xCC000000),
              ],
              stops: [0.0, 0.35, 1.0],
            ),
          ),
        ),

        // Contenuto testuale in alto
        Positioned(
          top: 120,
          left: 24,
          right: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.2,
                  shadows: [
                    Shadow(
                      blurRadius: 12,
                      color: Colors.black54,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.white,
                    height: 1.5,
                    shadows: [
                      Shadow(
                        blurRadius: 8,
                        color: Colors.black45,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  children: bodySpans,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}