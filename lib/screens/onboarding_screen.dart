import 'package:flutter/material.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import '../widgets/onboarding_page.dart';
import 'login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;
  final int _totalPages = 3;

  // Colore accent verde menta dalle schermate
  static const Color _accent = Color(0xFFB8F5C8);
  //static const Color _accentDark = Color(0xFF00C9A0);

  final List<_OnboardingData> _pages = [
    _OnboardingData(
      backgroundImage: 'assets/images/onboarding_1.png',
      title: 'The world is your circuit!',
      bodySpans: [
        const TextSpan(text: "Don't just run a route - "),
        const TextSpan(
          text: 'own it',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text: '. Dash transforms your neighborhood into a map for you to ',
        ),
        const TextSpan(
          text: 'claim',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: ', '),
        const TextSpan(
          text: 'conquer',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: ', and '),
        const TextSpan(
          text: 'defend',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    ),
    _OnboardingData(
      backgroundImage: 'assets/images/onboarding_2.png',
      title: 'Steal the Crown',
      bodySpans: [
        const TextSpan(text: 'See a territory you want? '),
        const TextSpan(
          text: 'Take it',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: '.\nOutrun the current '),
        const TextSpan(
          text: 'champion',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: ' to '),
        const TextSpan(
          text: 'claim their XP',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: '\nand '),
        const TextSpan(
          text: 'mark the map',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: ' as yours.\nSpeed is the '),
        const TextSpan(
          text: 'only',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const TextSpan(text: ' currency that matters'),
      ],
    ),
    _OnboardingData(
      backgroundImage: 'assets/images/onboarding_3.png',
      title: 'Rule Your Territory!',
      bodySpans: [
        const TextSpan(text: 'Track your '),
        const TextSpan(
          text: 'dominance',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: ' with real-time stats and '),
        const TextSpan(
          text: 'audio coaching',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text: '.\nFrom average speed to total ',
        ),
        const TextSpan(
          text: 'land grabbed',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: ', see\nhow you stack up '),
        const TextSpan(
          text: 'against the world',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    ),
  ];

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

void _goToLogin() {
  Navigator.of(context).pushReplacement(
    PageRouteBuilder(
      pageBuilder: (_, animation, _) => const LoginScreen(),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 350),
    ),
  );
}

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _currentPage == _totalPages - 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // PageView con le schermate
          PageView.builder(
            controller: _controller,
            itemCount: _totalPages,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (context, index) {
              final page = _pages[index];
              return OnboardingPage(
                backgroundImage: page.backgroundImage,
                title: page.title,
                bodySpans: page.bodySpans,
              );
            },
          ),

          // Bottone X (solo ultima pagina)
          if (isLastPage)
            Positioned(
              top: 48,
              right: 16,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 24),
                  onPressed: _goToLogin,
                ),
              ),
            ),

          // Indicatori di pagina + bottone in basso
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Dot indicator
                  SmoothPageIndicator(
                    controller: _controller,
                    count: _totalPages,
                    effect: const ExpandingDotsEffect(
                      activeDotColor: Colors.white,
                      dotColor: Colors.white38,
                      dotHeight: 8,
                      dotWidth: 8,
                      expansionFactor: 2,
                      spacing: 6,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Bottone Next / Login or Register
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: isLastPage ? _goToLogin : _nextPage,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.black87,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: Text(
                        isLastPage ? 'Login or Register' : 'Next',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A3A2A),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingData {
  final String backgroundImage;
  final String title;
  final List<TextSpan> bodySpans;

  const _OnboardingData({
    required this.backgroundImage,
    required this.title,
    required this.bodySpans,
  });
}