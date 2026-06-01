import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

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
  StreamSubscription<Position>? _positionStream;

  // ── Claimed areas from Firestore ──────────────────────────────────────────
  StreamSubscription<QuerySnapshot>? _areasSubscription;
  List<Map<String, dynamic>> _claimedAreas = [];

  // ── Map settings ──────────────────────────────────────────────────────────
  bool _isSatellite = false;

  // TODO: wire _showAreas to the PolygonLayer once claimedAreas are populated in Firestore
  bool _showAreas = true;

  // ── Search ────────────────────────────────────────────────────────────────
  bool _isSearching = false;

  static const double _defaultZoom = 16.0;

  static const String _osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  // ESRI World Imagery — no API key required; note y/x order in the path
  static const String _satelliteTileUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initLocation();
    _listenToClaimedAreas();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _areasSubscription?.cancel();
    _mapController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ── Location helpers ──────────────────────────────────────────────────────

  Future<void> _initLocation() async {
    final granted = await _requestLocationPermission();
    if (!granted) {
      setState(() => _isLoadingLocation = false);
      return;
    }
    setState(() => _locationPermissionGranted = true);
    await _fetchCurrentLocation();
    _startLocationUpdates();
  }

  Future<bool> _requestLocationPermission() async {
    final status = await Permission.locationWhenInUse.request();
    return status.isGranted;
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final latLng = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentPosition = latLng;
        _isLoadingLocation = false;
      });
      _mapController.move(latLng, _defaultZoom);
    } catch (_) {
      setState(() => _isLoadingLocation = false);
    }
  }

  void _startLocationUpdates() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      setState(() => _currentPosition = LatLng(pos.latitude, pos.longitude));
    });
  }

  void _centerOnUser() {
    if (_currentPosition != null) {
      _mapController.move(_currentPosition!, _defaultZoom);
    }
  }

  // ── Firestore claimed areas ───────────────────────────────────────────────

  void _listenToClaimedAreas() {
    _areasSubscription = FirebaseFirestore.instance
        .collection('claimedAreas')
        .snapshots()
        .listen((snapshot) {
      final areas = snapshot.docs.map((doc) {
        final data = doc.data();
        final polygon = (data['polygon'] as List).map((g) {
          final pt = g as GeoPoint;
          return LatLng(pt.latitude, pt.longitude);
        }).toList();
        return {
          'polygon': polygon,
          'colorHex': data['colorHex'] as String? ?? '#1E88E5',
        };
      }).toList();
      setState(() => _claimedAreas = areas);
    });
  }

  Color _hexToColor(String hex) =>
      Color(int.parse(hex.replaceFirst('#', '0xFF')));

  // ── Map controls ──────────────────────────────────────────────────────────

  void _resetNorth() => _mapController.rotate(0);

  void _openLayerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _LayerPickerSheet(
        isSatellite: _isSatellite,
        onChanged: (val) {
          setState(() => _isSatellite = val);
          Navigator.pop(context);
        },
      ),
    );
  }

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
        // Dismiss keyboard when the user taps the map
        onTap: (_, _) => FocusScope.of(context).unfocus(),
      ),
      children: [
        TileLayer(
          urlTemplate: _isSatellite ? _satelliteTileUrl : _osmTileUrl,
          userAgentPackageName: 'com.dash',
        ),
        // Claimed areas polygons (hidden when _showAreas is false)
        if (_claimedAreas.isNotEmpty && _showAreas)
          PolygonLayer(
            polygons: _claimedAreas.map((area) {
              final points = area['polygon'] as List<LatLng>;
              final color = _hexToColor(area['colorHex'] as String);
              return Polygon(
                points: points,
                color: color.withValues(alpha: 0.25),
                borderColor: color.withValues(alpha: 0.8),
                borderStrokeWidth: 2.0,
              );
            }).toList(),
          ),
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
                // 4.1 Compass — resets map rotation to north-up
                _PanelButton(
                  icon: Icons.explore_outlined,
                  onTap: _resetNorth,
                  position: _PanelPosition.top,
                ),
                _PanelDivider(),
                // 4.2 Layers — opens map-style picker (standard / satellite)
                _PanelButton(
                  icon: Icons.layers_outlined,
                  onTap: _openLayerPicker,
                  active: _isSatellite,
                  position: _PanelPosition.middle,
                ),
                _PanelDivider(),
                // 4.3 Grid — reserved for future feature
                _PanelButton(
                  icon: Icons.grid_on_outlined,
                  onTap: () {},
                  position: _PanelPosition.middle,
                ),
                _PanelDivider(),
                // 4.4 Toggle claimed-area polygons visibility
                // TODO: no-op until claimedAreas are populated in Firestore
                _PanelButton(
                  icon: Icons.cable_outlined,
                  onTap: () => setState(() => _showAreas = !_showAreas),
                  active: _showAreas,
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

// ── Layer picker bottom sheet ──────────────────────────────────────────────────

class _LayerPickerSheet extends StatelessWidget {
  final bool isSatellite;
  final ValueChanged<bool> onChanged;

  const _LayerPickerSheet(
      {required this.isSatellite, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Map style',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _StyleOption(
                label: 'Standard',
                icon: Icons.map_outlined,
                selected: !isSatellite,
                onTap: () => onChanged(false),
              ),
              const SizedBox(width: 12),
              _StyleOption(
                label: 'Satellite',
                icon: Icons.satellite_alt_outlined,
                selected: isSatellite,
                onTap: () => onChanged(true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StyleOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _StyleOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4A8C52);
    const accentBg = Color(0xFFEAF7E0);

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: selected ? accentBg : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  color: selected ? accent : Colors.grey[500], size: 28),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? accent : Colors.grey[600],
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