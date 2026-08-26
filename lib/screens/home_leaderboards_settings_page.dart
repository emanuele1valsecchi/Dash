import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LeaderboardViewConfig {
  final String title;
  bool isVisible;

  LeaderboardViewConfig({required this.title, this.isVisible = true});

  Map<String, dynamic> toJson() => {'title': title, 'isVisible': isVisible};
  
  factory LeaderboardViewConfig.fromJson(Map<String, dynamic> json) {
    return LeaderboardViewConfig(
      title: json['title'] as String,
      isVisible: json['isVisible'] as bool? ?? true,
    );
  }
}

class HomeLeaderboardsSettingsPage extends StatefulWidget {
  const HomeLeaderboardsSettingsPage({super.key});

  @override
  State<HomeLeaderboardsSettingsPage> createState() => _HomeLeaderboardsSettingsPageState();
}

class _HomeLeaderboardsSettingsPageState extends State<HomeLeaderboardsSettingsPage> {
  List<LeaderboardViewConfig> _leaderboards = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedData = prefs.getString('home_leaderboard_config');
    
    List<LeaderboardViewConfig> loadedConfigs = [];

    if (savedData != null) {
      final List<dynamic> decoded = jsonDecode(savedData);
      loadedConfigs = decoded.map((e) => LeaderboardViewConfig.fromJson(e)).toList();
    }

    // Cerchiamo le città reali dell'utente dal db per assicurarci di non perdere le nuove
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final sessionsSnap = await FirebaseFirestore.instance
          .collection('runningSessions')
          .where('userId', isEqualTo: user.uid)
          .get();

      Set<String> myCities = {'Global Leaderboard'};
      for (var doc in sessionsSnap.docs) {
        final data = doc.data();
        final rawLocality = (data['startLocality'] as String?)?.trim() ?? '';
        final rawTerritory = (data['territoryCity'] as String?)?.trim() ?? '';
        final city = rawLocality.isNotEmpty ? rawLocality : (rawTerritory.isNotEmpty ? rawTerritory : 'Unknown');
        if (city != 'Unknown') myCities.add(city);
      }

      // Aggiungiamo le città nuove in fondo se non erano salvate nelle preferenze
      for (var city in myCities) {
        if (!loadedConfigs.any((c) => c.title == city)) {
          loadedConfigs.add(LeaderboardViewConfig(title: city, isVisible: true));
        }
      }
    }

    if (mounted) {
      setState(() {
        _leaderboards = loadedConfigs;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_leaderboards.map((c) => c.toJson()).toList());
    await prefs.setString('home_leaderboard_config', encoded);
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _leaderboards.removeAt(oldIndex);
      _leaderboards.insert(newIndex, item);
    });
    _saveConfig();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.secondary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Customize Home',
          style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4A8C52)))
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(20.0),
                  child: Text('Drag to reorder how leaderboards appear on your home screen. Turn off the switch to hide them entirely.', style: TextStyle(color: Colors.grey, fontSize: 14)),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _leaderboards.length,
                    onReorderItem: _onReorder,

                    proxyDecorator: (Widget child, int index, Animation<double> animation) {
                      return Material(
                        elevation: 10, 
                        color: Colors.transparent, 
                        shadowColor: Colors.black45,
                        borderRadius: BorderRadius.circular(16), 
                        child: child,
                      );
                    },

                    itemBuilder: (context, index) {
                      final config = _leaderboards[index];
                      // --- NEW: Check if this is the Global Leaderboard ---
                      final bool isGlobal = config.title == 'Global Leaderboard';
                      
                      return Card(
                        key: ValueKey(config.title),
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        color: config.isVisible ? Colors.white : Colors.grey.shade200,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          leading: CircleAvatar(
                            backgroundColor: config.isVisible ? const Color(0xFF4A8C52) : Colors.grey.shade400,
                            foregroundColor: Colors.white,
                            child: Text('${index + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          title: Text(
                            config.title, 
                            style: TextStyle(
                              fontWeight: FontWeight.bold, 
                              color: config.isVisible ? const Color(0xFF2A3028) : Colors.grey.shade500
                            )
                          ),
                          // --- NEW: Custom subtitle for Global ---
                          subtitle: Text(
                            isGlobal ? 'Always visible' : (config.isVisible ? 'Visible on Home' : 'Hidden'), 
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                // Force true if it's Global
                                value: isGlobal ? true : config.isVisible,
                                activeThumbColor: const Color(0xFF4A8C52),
                                // --- NEW: Disable the switch if it's Global ---
                                onChanged: isGlobal ? null : (value) {
                                  setState(() => config.isVisible = value);
                                  _saveConfig();
                                },
                              ),
                              const SizedBox(width: 8),
                              Icon(Symbols.drag_handle_rounded, color: Colors.grey.shade400),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}