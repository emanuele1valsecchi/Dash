import 'package:flutter/material.dart';
import 'login_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // The text from your Figma prototype
  final List<Map<String, String>> _pages = [
    {
      "title": "The world is your circuit!",
      "body": "Don't just run a route - own it. Dash transforms your neighborhood into a map for you to claim, conquer, and defend."
    },
    {
      "title": "Steal the Crown",
      "body": "See a territory you want? Take it. Outrun the current champion to claim their XP and mark the map as yours."
    },
    {
      "title": "Rule Your Territory!",
      "body": "Track your dominance with real-time stats and audio coaching. From average speed to total land grabbed."
    },
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Grabbing your MTB Theme
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      // Placeholder dark background to simulate the photos in your Figma
      backgroundColor: const Color(0xFF1E1E1E), 
      body: Stack(
        children: [
          // 1. The Swipable Pages
          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });
            },
            itemCount: _pages.length,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 100), 
                    Text(
                      _pages[index]["title"]!,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white, // Forcing white text over the dark photo placeholder
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _pages[index]["body"]!,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),

          // 2. The Dots and Button at the bottom
          Positioned(
            bottom: 50,
            left: 30,
            right: 30,
            child: Column(
              children: [
                // Page Indicator Dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _pages.length,
                    (index) => AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      height: 10,
                      width: _currentPage == index ? 20 : 10, // Active dot is wider
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        color: _currentPage == index
                            ? colorScheme.primaryContainer // Using your Figma light green
                            : Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                // Next / Login Button
                ElevatedButton(
                  onPressed: () {
                    if (_currentPage < 2) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    } else {
                      // Navigate to the Login Screen we built!
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const LoginScreen()),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primaryContainer,
                    foregroundColor: colorScheme.onPrimaryContainer,
                  ),
                  child: Text(
                    _currentPage == 2 ? "Login or Register" : "Next",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}