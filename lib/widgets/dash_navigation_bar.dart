import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class DashNavigationbar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  
  const DashNavigationbar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected
  });



  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      onDestinationSelected: onDestinationSelected,
      selectedIndex: selectedIndex,
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