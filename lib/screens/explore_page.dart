import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/map_style.dart';
import '../services/claimed_area_repository.dart';
import '../services/location_service.dart';
import '../widgets/map/area_details_sheet.dart';
import '../widgets/map/claimed_areas_layer.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  // ── Location ──────────────────────────────────────────────────────────────
  LatLng? _currentPosition;
  bool _locationPermissionGranted = false;
  bool _isLoadingLocation = true;
  StreamSubscription<LatLng>? _positionSub;

  // ── Claimed areas from Firestore ────────────────────────────────────────
  // Loaded incrementally (not a live listener — see ClaimedAreaRepository)
  // from every user, then split for rendering by ownership of the signed-in
  // user. _areaHitNotifier drives tap detection on the polygons themselves.
  List<ClaimedArea> _allAreas = [];
  final LayerHitNotifier<String> _areaHitNotifier = ValueNotifier(null);

  // ── Map settings ──────────────────────────────────────────────────────────
  // Independent filters over `claimedAreas` by ownership: "other users'
  // territory" (what's contestable) vs. "my own territory" (already
  // secured). Both default on, bound to the grid/cable panel buttons.
  bool _showOtherAreas = true;
  bool _showMyAreas = true;

  // ── Search ────────────────────────────────────────────────────────────────
  bool _isSearching = false;

  static const double _defaultZoom = 16.0;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadClaimedAreas();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _mapController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ── Location helpers ──────────────────────────────────────────────────────

  /// Uses the app-wide [LocationService] instead of requesting a fresh fix
  /// itself — usually already warm by the time this page opens, since
  /// `HomeScreen` starts it right after login, so there's nothing to wait on.
  Future<void> _initLocation() async {
    await LocationService.instance.start();
    if (!mounted) return;

    final cached = LocationService.instance.current;
    setState(() {
      _locationPermissionGranted = LocationService.instance.permissionGranted;
      _currentPosition = cached;
      _isLoadingLocation = false;
    });
    if (cached != null) {
      _mapController.move(cached, _defaultZoom);
    }

    _positionSub = LocationService.instance.updates.listen((pos) {
      setState(() => _currentPosition = pos);
    });
  }

  void _centerOnUser() {
    if (_currentPosition != null) {
      _mapController.move(_currentPosition!, _defaultZoom);
    }
  }

  // ── Claimed areas ─────────────────────────────────────────────────────────

  Future<void> _loadClaimedAreas() async {
    final areas = await ClaimedAreaRepository.instance.fetchAllAreas();
    if (!mounted) return;
    setState(() => _allAreas = areas);
  }

  /// [_allAreas] split by ownership of the signed-in user and filtered by
  /// the grid/cable toggles — each area is either "mine" or "someone
  /// else's", never both, so the two toggles cover the whole collection
  /// between them.
  List<ClaimedArea> get _visibleAreas {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return _allAreas.where((area) {
      final isMine = area.userId == uid;
      return isMine ? _showMyAreas : _showOtherAreas;
    }).toList();
  }

  // ── Map controls ──────────────────────────────────────────────────────────

  void _resetNorth() => _mapController.rotate(0);

  // ── City search (Nominatim) ───────────────────────────────────────────────

  Future<void> _searchCity(String query) async {
    if (query.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSearching = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query.trim())}&format=json&limit=1',
      );
      final response = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List<dynamic>;
        if (results.isNotEmpty) {
          final first = results[0] as Map<String, dynamic>;
          final lat = double.parse(first['lat'] as String);
          final lon = double.parse(first['lon'] as String);
          _mapController.move(LatLng(lat, lon), 13.0);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('City "$query" not found')),
          );
        }
      }
    } catch (_) {
      // Silently ignore network errors — map stays where it was
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(),
          SafeArea(child: _buildTopControls()),
          _buildVerticalButtonPanel(),
          if (_isLoadingLocation) _buildLoadingOverlay(),
          if (!_locationPermissionGranted && !_isLoadingLocation)
            _buildPermissionBanner(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // ── Map ───────────────────────────────────────────────────────────────────

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentPosition ?? const LatLng(45.4642, 9.1900),
        initialZoom: _defaultZoom,
        // Dismiss keyboard when the user taps the map; open the area sheet
        // if the tap landed on a claimed-area polygon.
        onTap: (_, _) {
          FocusScope.of(context).unfocus();
          handleAreaTap(context, _areaHitNotifier, _visibleAreas);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: MapStyle.terrainTileUrl,
          userAgentPackageName: 'com.dash',
          retinaMode: RetinaMode.isHighDensity(context),
        ),
        // Claimed areas — filtered by the grid ("other users'") and cable
        // ("my own") panel toggles.
        ClaimedAreasLayer(areas: _visibleAreas, hitNotifier: _areaHitNotifier),
        if (_currentPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _currentPosition!,
                width: 60,
                height: 60,
                child: const _LocationDot(),
              ),
            ],
          ),
      ],
    );
  }

  // ── Top controls (search bar + leaderboard button) ────────────────────────

  Widget _buildTopControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          Expanded(child: _buildSearchBar()),
          const SizedBox(width: 8),
          _buildLeaderboardButton(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: TextField(
        controller: _searchController,
        onSubmitted: _searchCity,
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search a city…',
          hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
          prefixIcon: _isSearching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : const Icon(Icons.search, color: Colors.grey, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildLeaderboardButton() {
    return GestureDetector(
      onTap: () {
        // TODO: open leaderboard screen
      },
      child: Container(
        width: 46,
        height: 46,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFCAF0B8),
        ),
        child: const Icon(
          Icons.bar_chart_rounded,
          color: Color(0xFF425143),
          size: 24,
        ),
      ),
    );
  }

  // ── Vertical button panel (bottom-right) ──────────────────────────────────

  Widget _buildVerticalButtonPanel() {
    return Positioned(
      bottom: 16,
      right: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // My-location button — standalone above the settings group
          _MapRoundButton(
            icon: Icons.my_location,
            onTap: _centerOnUser,
          ),
          const SizedBox(height: 8),
          // 4-button settings card
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 3.1 Compass — resets map rotation to north-up
                _PanelButton(
                  icon: Icons.explore_outlined,
                  onTap: _resetNorth,
                  position: _PanelPosition.top,
                ),
                _PanelDivider(),
                // 3.2 Grid — toggle other users' claimed territory
                _PanelButton(
                  icon: Icons.grid_on_outlined,
                  onTap: () =>
                      setState(() => _showOtherAreas = !_showOtherAreas),
                  active: _showOtherAreas,
                  position: _PanelPosition.middle,
                ),
                _PanelDivider(),
                // 3.3 Toggle my own claimed territory
                _PanelButton(
                  icon: Icons.cable_outlined,
                  onTap: () => setState(() => _showMyAreas = !_showMyAreas),
                  active: _showMyAreas,
                  position: _PanelPosition.bottom,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom navigation ─────────────────────────────────────────────────────

  Widget _buildBottomNav() {
    return NavigationBar(
      height: 82,
      backgroundColor: const Color(0xFFECEFE6),
      selectedIndex: 0,
      indicatorColor: const Color(0xFFCFE8BD),
      onDestinationSelected: (index) {
        if (index == 1) {
          // Home tab — return to HomeScreen
          Navigator.of(context).pop();
          return;
        }
        // Profile (index 2) — TODO
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Areas',
        ),
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    );
  }

  // ── Loading / permission overlays ─────────────────────────────────────────

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black45,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text(
              'Getting your location…',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionBanner() {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 72, // leave room for the button panel on the right
      child: Material(
        borderRadius: BorderRadius.circular(12),
        color: Colors.red.shade700,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.location_off, color: Colors.white),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Location permission denied. Enable it in settings.',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: openAppSettings,
                child: const Text(
                  'Settings',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable map UI widgets ───────────────────────────────────────────────────

enum _PanelPosition { top, middle, bottom }

/// Standalone round button (e.g. "My location").
class _MapRoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MapRoundButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(icon, size: 22, color: const Color(0xFF425143)),
        ),
      ),
    );
  }
}

/// Button inside the vertical settings panel — handles corner rounding.
class _PanelButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final _PanelPosition position;

  const _PanelButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    required this.position,
  });

  BorderRadius get _radius {
    const r = Radius.circular(12);
    return switch (position) {
      _PanelPosition.top => const BorderRadius.vertical(top: r),
      _PanelPosition.bottom => const BorderRadius.vertical(bottom: r),
      _PanelPosition.middle => BorderRadius.zero,
    };
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: _radius,
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Icon(
          icon,
          size: 22,
          color: active ? const Color(0xFF4A8C52) : const Color(0xFF425143),
        ),
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: const Color(0xFFE8E8E8),
      margin: const EdgeInsets.symmetric(horizontal: 8),
    );
  }
}

// ── GPS location dot ──────────────────────────────────────────────────────────

class _LocationDot extends StatelessWidget {
  const _LocationDot();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue.withValues(alpha: 0.2),
          ),
        ),
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4),
            ],
          ),
        ),
      ],
    );
  }
}