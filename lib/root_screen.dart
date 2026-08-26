import 'package:dash/screens/explore_page.dart';
import 'package:dash/screens/home_page.dart';
import 'package:dash/screens/profile_page.dart';
import 'package:dash/widgets/dash_navigation_bar.dart';
import 'package:flutter/material.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _currentIndex = 1;

  final List<Widget> _pages = const [
    ExplorePage(),
    HomeScreen(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: DashNavigationbar(
        selectedIndex: _currentIndex, 
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}