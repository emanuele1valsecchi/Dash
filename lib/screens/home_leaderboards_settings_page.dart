import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../utils/leaderboard_order.dart';
import '../utils/session_leaderboards.dart';

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
  /// Test seams. Production leaves both null and the state resolves
  /// `.instance` lazily — an eager field initializer would throw
  /// `[core/no-app]` when the widget is *constructed*, before `runApp`.
  @visibleForTesting
  final FirebaseFirestore? firestore;
  @visibleForTesting
  final FirebaseAuth? auth;

  const HomeLeaderboardsSettingsPage({super.key, this.firestore, this.auth});

  @override
  State<HomeLeaderboardsSettingsPage> createState() => _HomeLeaderboardsSettingsPageState();
}

class _HomeLeaderboardsSettingsPageState extends State<HomeLeaderboardsSettingsPage> {
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;
  late final FirebaseAuth _auth = widget.auth ?? FirebaseAuth.instance;

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

    final user = _auth.currentUser;
    if (user != null) {
      final sessionsSnap = await _db
          .collection('runningSessions')
          .where('userId', isEqualTo: user.uid)
          .get();

      // Discovered territories, most recently scored in first, plus the
      // runner's metropolitan area tracked separately — `LeaderboardOrder`
      // owns where each one lands, so this only has to gather them.
      final Map<String, DateTime> territoryLastRun = {};
      String? myMetroTerritory;
      DateTime? myMetroAt;

      for (var doc in sessionsSnap.docs) {
        final data = doc.data();
        // The same board list `home_page.dart` accumulates into — the two
        // have to agree, or settings would offer leaderboards the home screen
        // never shows, or hide ones it does. A run counts toward both its
        // locality and its metropolitan area; see `leaderboardsForSession`.
        final rawTerritory = (data['territoryCity'] as String?)?.trim() ?? '';
        final boards = leaderboardsForSession(
          startLocality: data['startLocality'] as String?,
          territoryCity: data['territoryCity'] as String?,
          territoryBroad: data['territoryBroad'] as String?,
        );

        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        if (boards.isEmpty || createdAt == null) continue;

        for (final city in boards) {
          final seen = territoryLastRun[city];
          if (seen == null || createdAt.isAfter(seen)) {
            territoryLastRun[city] = createdAt;
          }
        }
        // Only a curated metro polygon sets `territoryCity`; the broad region
        // fallback does not, and does not earn the promoted slot.
        if (rawTerritory.isNotEmpty &&
            (myMetroAt == null || createdAt.isAfter(myMetroAt))) {
          myMetroTerritory = rawTerritory;
          myMetroAt = createdAt;
        }
      }

      final byRecency = territoryLastRun.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // Anything not already saved is appended in the shared default order,
      // so a first-time visitor sees global, then their metro area, then the
      // rest — matching exactly what the home screen already shows them.
      for (final title in LeaderboardOrder.defaultOrder(
        byRecency.map((e) => e.key),
        metroTerritory: myMetroTerritory,
      )) {
        if (!loadedConfigs.any((c) => c.title == title)) {
          loadedConfigs.add(LeaderboardViewConfig(title: title, isVisible: true));
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
      // No `if (newIndex > oldIndex) newIndex -= 1` here. That adjustment
      // belongs to the deprecated `onReorder` callback, which reported the
      // index the item was dropped *before* while it was still in the list.
      // `onReorderItem` — used above — already accounts for the removal, so
      // subtracting again cancelled every downward move: dragging a board
      // down did nothing at all. Covered by
      // `home_leaderboards_settings_page_test.dart`'s "moving a board down".
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
                      final bool isGlobal =
                          config.title == LeaderboardOrder.globalTitle;
                      
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