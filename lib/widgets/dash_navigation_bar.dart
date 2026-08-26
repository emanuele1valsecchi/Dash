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
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        iconTheme: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          return (states.contains(WidgetState.selected))
            ? IconThemeData(
              fill: 1.0, 
              weight: 700.0,
              color: Theme.of(context).colorScheme.primary,
            )
            : IconThemeData(
              fill: 0.0, 
              weight: 400.0,
              color: Theme.of(context).colorScheme.outline,
            );
        }),

        labelTextStyle: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          return (states.contains(WidgetState.selected))
          ? TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold
          )
          : TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontWeight: FontWeight.normal
          );
        }),
      ),

      child: NavigationBar(
        onDestinationSelected: onDestinationSelected,
        selectedIndex: selectedIndex,
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Symbols.map_rounded), 
            label: "Explore",
          ),

          NavigationDestination(
            icon: Icon(Symbols.home_rounded), 
            label: "Home",
          ),

          NavigationDestination(
            icon: Icon(Symbols.person_rounded), 
            label: "Profile",
          ),
        ]
      ),
    );
  }
}