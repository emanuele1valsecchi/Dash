import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class DashNavigationbar extends StatefulWidget {
  const DashNavigationbar({super.key});

  @override
  State<DashNavigationbar> createState() => _DashNavigationbarState();
}

class _DashNavigationbarState extends State<DashNavigationbar> {

  int _currentPageIndex = 0;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      onDestinationSelected: (int index) {
        setState(() {
          _currentPageIndex = index;
        });
      },
      selectedIndex: _currentPageIndex,
      destinations: const <Widget>[
        NavigationDestination(
          selectedIcon: Icon(Symbols.map_rounded), 
          icon: Icon(Symbols.map_rounded), 
          label: "Explore"
        ),
        
        NavigationDestination(
          selectedIcon: Icon(Symbols.home_filled_rounded),
          icon: Icon(Symbols.home_rounded), 
          label: "Home"
        ),

        NavigationDestination(
          selectedIcon: Icon(Symbols.person_filled_rounded), 
          icon: Icon(Symbols.person_rounded), 
          label: "Profile"
        ),
      ]
    );
  }
}