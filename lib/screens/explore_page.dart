import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';
import '../services/claimed_area_repository.dart';
import '../services/location_service.dart';
import '../widgets/map/area_details_sheet.dart';
import '../widgets/map/claimed_areas_layer.dart';
import 'leaderboard_screen.dart';
import '../widgets/map/enhanced_map_gestures.dart';

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
  List<ClaimedArea> _allAreas = [];
  final LayerHitNotifier<String> _areaHitNotifier = ValueNotifier(null);

  // ── Map settings ──────────────────────────────────────────────────────────
  bool _showOtherAreas = true;
  bool _showMyAreas = true;

  // ── Search & City Context for Leaderboard ─────────────────────────────────
  bool _isSearching = false;
  String _activeCityFilter = 'Global Leaderboard'; 

  static const double _defaultZoom = 16.0;

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
      await _updateCityForCurrentLocation(cached);
    }

    _positionSub = LocationService.instance.updates.listen((pos) {
      setState(() => _currentPosition = pos);
    });
  }

  void _centerOnUser() {
    if (_currentPosition != null) {
      _mapController.move(_currentPosition!, _defaultZoom);
      _updateCityForCurrentLocation(_currentPosition!);
    }
  }

  // Rileva la città basata sulle coordinate attuali (Reverse Geocoding)
  Future<void> _updateCityForCurrentLocation(LatLng pos) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=${pos.latitude}&lon=${pos.longitude}&format=json',
      );
      final response = await http
          .get(uri, headers: {'User-Agent': 'DashApp/1.0'})
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>?;
        
        final city = address?['city'] ?? 
                     address?['town'] ?? 
                     address?['village'] ?? 
                     address?['municipality'];

        if (city != null && mounted) {
          setState(() {
            _activeCityFilter = city.toString().trim();
          });
        }
      }
    } catch (_) {
      // In caso di errore di rete, mantiene il fallback
    }
  }

  Future<void> _loadClaimedAreas() async {
    final areas = await ClaimedAreaRepository.instance.fetchAllAreas();
    if (!mounted) return;
    setState(() => _allAreas = areas);
  }

  List<ClaimedArea> get _visibleAreas {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return _allAreas.where((area) {
      final isMine = area.userId == uid;
      return isMine ? _showMyAreas : _showOtherAreas;
    }).toList();
  }

  void _resetNorth() => _mapController.rotate(0);

  // ── City search (Nominatim) ───────────────────────────────────────────────

  Future<void> _searchCity(String query) async {
    if (query.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSearching = true);
    
    final cleanQuery = query.trim();

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(cleanQuery)}&format=json&limit=1',
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
          
          setState(() {
            _activeCityFilter = cleanQuery[0].toUpperCase() + cleanQuery.substring(1).toLowerCase();
          });
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('City "$cleanQuery" not found')),
          );
        }
      }
    } catch (_) {
      // Silently ignore network errors
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

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

  Widget _buildMap() {
    return EnhancedMapGestures(
      mapController: _mapController,
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _currentPosition ?? const LatLng(45.4642, 9.1900),
          initialZoom: _defaultZoom,
          minZoom: MapStyle.minZoom,
          cameraConstraint: CameraConstraint.contain(bounds: MapStyle.safeCameraBounds),
          interactionOptions: const InteractionOptions(
            // Fling stays enabled (single-finger drag momentum is a real,
            // wanted feature) — EnhancedMapGestures cancels it specifically
            // when it was triggered by the corrupted post-multi-touch
            // velocity reading instead of blanket-disabling it; see that
            // widget's class doc, point 3.
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
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
            tileProvider: CachedTileProvider.instance,
          ),
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
      ),
    );
  }

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
                    if (_currentPosition != null) {
                      _updateCityForCurrentLocation(_currentPosition!);
                    }
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
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LeaderboardScreen(cityFilter: _activeCityFilter),
          ),
        );
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

  Widget _buildVerticalButtonPanel() {
    return Positioned(
      bottom: 16,
      right: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MapRoundButton(
            icon: Icons.my_location,
            onTap: _centerOnUser,
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PanelButton(
                  icon: Icons.explore_outlined,
                  onTap: _resetNorth,
                  position: _PanelPosition.top,
                ),
                _PanelDivider(),
                _PanelButton(
                  icon: Icons.grid_on_outlined,
                  onTap: () =>
                      setState(() => _showOtherAreas = !_showOtherAreas),
                  active: _showOtherAreas,
                  position: _PanelPosition.middle,
                ),
                _PanelDivider(),
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

  Widget _buildBottomNav() {
    return NavigationBar(
      height: 82,
      backgroundColor: const Color(0xFFECEFE6),
      selectedIndex: 0,
      indicatorColor: const Color(0xFFCFE8BD),
      onDestinationSelected: (index) {
        if (index == 1) {
          Navigator.of(context).pop();
          return;
        }
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
      right: 72,
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

enum _PanelPosition { top, middle, bottom }

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