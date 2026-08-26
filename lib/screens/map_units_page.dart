import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:material_symbols_icons/symbols.dart';

class MapUnitsPage extends StatefulWidget {
  const MapUnitsPage({super.key});

  @override
  State<MapUnitsPage> createState() => _MapUnitsPageState();
}

class _MapUnitsPageState extends State<MapUnitsPage> {
  bool _useMiles = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  // Load the saved measurement system from SharedPreferences
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _useMiles = prefs.getBool('useMiles') ?? false;
      _isLoading = false;
    });
  }

  // Save the new preference to SharedPreferences
  Future<void> _updatePreference(bool useMiles) async {
    setState(() => _useMiles = useMiles);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('useMiles', useMiles);
    
    // Optionally: if you want this synced across devices, 
    // you can also update a 'preferences' map in the Firestore profile document here.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.secondary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Map & Units',
          style: TextStyle(
            color: Theme.of(context).colorScheme.secondary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Text(
                    'MEASUREMENT SYSTEM',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                  ),
                ),
                
                // --- MEASUREMENT SYSTEM (Wrapped in RadioGroup for Flutter 3.32+) ---
                RadioGroup<bool>(
                  groupValue: _useMiles,
                  onChanged: (value) {
                    if (value != null) _updatePreference(value);
                  },
                  child: Column(
                    children: [
                      // Kilometers Option
                      RadioListTile<bool>(
                        title: const Text('Kilometers (km)'),
                        subtitle: const Text('Standard metric system'),
                        value: false, // false = use Kilometers
                        activeColor: const Color(0xFF4A8C52),
                        secondary: const Icon(Symbols.straighten_rounded),
                        // groupValue and onChanged are now handled by the parent RadioGroup!
                      ),
                      
                      // Miles Option
                      RadioListTile<bool>(
                        title: const Text('Miles (mi)'),
                        subtitle: const Text('Imperial system'),
                        value: true, // true = use Miles
                        activeColor: const Color(0xFF4A8C52),
                        secondary: const Icon(Symbols.social_distance_rounded),
                        // groupValue and onChanged are now handled by the parent RadioGroup!
                      ),
                    ],
                  ),
                ),
                
                const Divider(height: 40),
                
                // You can expand this section later with Map Styles
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  leading: const Icon(Symbols.map_rounded),
                  title: const Text('Map Theme'),
                  subtitle: const Text('Coming soon'),
                  trailing: const Icon(Icons.lock_rounded, color: Colors.grey, size: 20),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Map Themes will be unlocked in a future update! 🗺️")),
                    );
                  },
                )
              ],
            ),
    );
  }
}