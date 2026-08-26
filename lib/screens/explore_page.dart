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
import '../services/place_search_service.dart';
import '../widgets/map/area_details_sheet.dart';
import '../widgets/map/claimed_areas_layer.dart';
import 'leaderboard_page.dart';
import '../widgets/map/enhanced_map_gestures.dart';

class ExplorePage extends StatefulWidget {
  final String? targetSessionId; // <--- AGGIUNTO PER INTERCETTARE LA NOTIFICA

  const ExplorePage({super.key, this.targetSessionId});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  bool _isCameraAnimating = false;

  // ── Location ──────────────────────────────────────────────────────────────
  LatLng? _currentPosition;
  bool _locationPermissionGranted = false;
  bool _isLoadingLocation = true;
  StreamSubscription<LatLng>? _positionSub;

  // ── Claimed areas from Firestore ────────────────────────────────────────
  List<ClaimedArea> _allAreas = [];
  // Il notifier si aspetta un LayerHitResult, non una semplice String
  final LayerHitNotifier<String> _areaHitNotifier = ValueNotifier(null);

  // ── Map settings ──────────────────────────────────────────────────────────
  bool _showOtherAreas = true;
  bool _showMyAreas = true;

  // ── City context for leaderboard ────────────────────────────────────────
  String _activeCityFilter = 'Global Leaderboard';

  // ── Place search (same PlaceSearchService/ranking/full-screen-takeover
  // UI as RouteCreatePage's search bar and RouteSearchPage's address
  // fields — see place_search_service.dart) ───────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  List<Place> _searchSuggestions = [];
  bool _searchSuppressNext = false;

  bool get _searchActive => _searchFocusNode.hasFocus;

  /// The most recently selected search result, shown as a small pin on the
  /// map — replaced by the next selection, never auto-cleared otherwise.
  LatLng? _searchResultPin;

  static const double _defaultZoom = 16.0;

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadClaimedAreas();
    _searchCtrl.addListener(_onSearchChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _mapController.dispose();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
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
      // Centra sull'utente SOLO se non stiamo cercando un'area rubata dalla notifica
      if (widget.targetSessionId == null) {
        _mapController.move(cached, _defaultZoom);
      }
      await _updateCityForCurrentLocation(cached);
    }

    _positionSub = LocationService.instance.updates.listen((pos) {
      setState(() => _currentPosition = pos);
    });
  }

  void _centerOnUser() {
    final pos = _currentPosition;
    if (pos != null) {
      _animateCameraTo(pos, _defaultZoom);
      _updateCityForCurrentLocation(pos);
    }
  }

  /// Animates the camera to [targetCenter]/[targetZoom] over a short tween
  /// instead of jumping instantly — same "my location" pan/zoom flourish as
  /// `RunTrackingPage._centerOnUser`. flutter_map has no built-in animated
  /// move, so this drives one manually: an [AnimationController] ticks a
  /// lat/lng/zoom [Tween] and calls [MapController.move] each frame, then
  /// disposes itself once the animation finishes.
  Future<void> _animateCameraTo(LatLng targetCenter, double targetZoom) async {
    if (_isCameraAnimating) return;
    _isCameraAnimating = true;

    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      _isCameraAnimating = false;
      return; // Map not attached yet.
    }

    final latTween = Tween<double>(begin: camera.center.latitude, end: targetCenter.latitude);
    final lngTween = Tween<double>(begin: camera.center.longitude, end: targetCenter.longitude);
    final zoomTween = Tween<double>(begin: camera.zoom, end: targetZoom);

    final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic);

    void tick() {
      try {
        _mapController.move(
          LatLng(latTween.transform(curved.value), lngTween.transform(curved.value)),
          zoomTween.transform(curved.value),
        );
      } catch (_) {}
    }

    controller.addListener(tick);
    try {
      await controller.forward();
    } finally {
      controller.removeListener(tick);
      controller.dispose();
      _isCameraAnimating = false;
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

    // Se arriviamo da una notifica "areaStolen", cerchiamo l'area
    if (widget.targetSessionId != null) {
      _focusOnStolenArea(widget.targetSessionId!);
    }
  }

  void _focusOnStolenArea(String targetSessionId) {
    try {
      // 1. Cerca l'area incriminata
      final targetArea = _allAreas.firstWhere(
        (area) => area.contributions.any((c) => c.sessionId == targetSessionId)
      );

      // 2. Assicurati che le aree degli altri siano visibili
      if (!_showOtherAreas) {
        setState(() => _showOtherAreas = true);
      }

      // 3. Calcola il centro esatto dell'area (bounding box)
      LatLng centerPoint;
      if (targetArea.polygons.isNotEmpty && targetArea.polygons.first.outer.isNotEmpty) {
        final outerPoints = targetArea.polygons.first.outer;
        
        double minLat = outerPoints.first.latitude;
        double maxLat = outerPoints.first.latitude;
        double minLng = outerPoints.first.longitude;
        double maxLng = outerPoints.first.longitude;

        for (var p in outerPoints) {
          if (p.latitude < minLat) minLat = p.latitude;
          if (p.latitude > maxLat) maxLat = p.latitude;
          if (p.longitude < minLng) minLng = p.longitude;
          if (p.longitude > maxLng) maxLng = p.longitude;
        }

        centerPoint = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
      } else {
        // Se per qualche motivo il poligono è vuoto
        centerPoint = const LatLng(45.4642, 9.1900); 
      }
      
      // 4. Sposta la telecamera con uno zoom minore per allargare la vista (16.0 o 16.5)
      _mapController.move(centerPoint, 14.0);

      // 5. Apre la tendina simulando il tocco
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          // ignore: invalid_use_of_internal_member
          _areaHitNotifier.value = LayerHitResult<String>(
            hitValues: [targetArea.id],
            coordinate: centerPoint,
            point: const Offset(0, 0),
          );

          handleAreaTap(context, _areaHitNotifier, _visibleAreas);
        }
      });
    } catch (e) {
      debugPrint('Area rubata non trovata o già riconquistata.');
    }
  }

  List<ClaimedArea> get _visibleAreas {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return _allAreas.where((area) {
      final isMine = area.userId == uid;
      return isMine ? _showMyAreas : _showOtherAreas;
    }).toList();
  }

  void _resetNorth() => _mapController.rotate(0);

  // ── Place search ─────────────────────────────────────────────────────────
  //
  // Same PlaceSearchService/ranking as RouteCreatePage's search bar and
  // RouteSearchPage's address fields (Nominatim + Overpass POI fallback,
  // re-ranked by text-match quality/importance/proximity — see that
  // service for why), and the same full-screen white takeover look —
  // state lives directly on this State like RouteCreatePage's does, since
  // the results list (`_buildSearchOverlay`) is a Stack sibling of the
  // search field, not a descendant of it.

  void _onSearchFocusChanged() {
    if (!mounted) return;
    setState(() {
      if (!_searchFocusNode.hasFocus) _searchSuggestions = [];
    });
  }

  void _onSearchChanged() {
    if (_searchSuppressNext) {
      _searchSuppressNext = false;
      return;
    }
    _searchDebounce?.cancel();
    final text = _searchCtrl.text.trim();
    if (text.length < 3) {
      if (mounted) setState(() => _searchSuggestions = []);
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _fetchSearchResults(text),
    );
  }

  /// Delegates to [PlaceSearchService.search] and applies each emission as
  /// it arrives, bailing out if the field's text has moved on to a
  /// different query since. Raised past the service's own defaults (10
  /// ranked / 15 raw) — Explore is a browse-the-map page where a longer
  /// results list is more useful than on the route-planning screens, which
  /// stay at the defaults.
  static const int _searchResultsLimit = 20;

  Future<void> _fetchSearchResults(String query) async {
    await for (final places in PlaceSearchService.search(
      query,
      near: _currentPosition,
      limit: _searchResultsLimit,
      rawLimit: _searchResultsLimit,
    )) {
      if (!mounted || _searchCtrl.text.trim() != query) return;
      setState(() => _searchSuggestions = places);
    }
  }

  void _selectSearchResult(Place place) {
    // Any pending debounced fetch (e.g. from text typed just before this tap
    // landed) is now for a stale query — don't let it resolve later and
    // repopulate the list right after we've moved on.
    _searchDebounce?.cancel();
    _searchSuppressNext = true;
    // Set text + selection together in one `.value` assignment rather than
    // as two separate `.text =` / `.selection =` assignments — see
    // RouteCreatePage's `_selectSearchResult` for why (each fires the
    // controller's listener independently, and `_searchSuppressNext` only
    // survives the first).
    _searchCtrl.value = TextEditingValue(
      text: place.displayName,
      selection: TextSelection.collapsed(offset: place.displayName.length),
    );
    setState(() {
      _searchSuggestions = [];
      _searchResultPin = place.latLng;
    });
    _searchFocusNode.unfocus();
    _mapController.move(place.latLng, _defaultZoom);
    // Re-derive the leaderboard city filter from wherever the search
    // actually landed (a street/POI's *containing* city, via the same
    // reverse-geocode already used for "current position → current city"),
    // rather than just capitalizing the raw typed query — correct for any
    // kind of result, not just a plain city name.
    _updateCityForCurrentLocation(place.latLng);
  }

  /// Backs out of the full-screen search takeover without leaving the page —
  /// used by the top-bar close button and the system back gesture (see
  /// [build]'s `PopScope`) whenever search is active.
  void _closeSearch() {
    _searchFocusNode.unfocus();
    setState(() => _searchSuggestions = []);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // System/gesture back closes an active search instead of leaving the
      // page — same principle as RouteCreatePage's PopScope.
      canPop: !_searchActive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _closeSearch();
      },
      child: Scaffold(
        body: Stack(
          // Every child carries a stable Key: the search overlay is only
          // conditionally present, which shifts the top bar's *index* in
          // this list the instant search becomes active. Without keys,
          // Stack's list reconciliation matches old/new children by index,
          // not identity — an index shift reads as "this is a different
          // widget", so it tears down and recreates everything from the
          // insertion point onward (the top bar/search field included)
          // instead of just updating it in place. That teardown was
          // destroying the TextField's freshly-focused EditableText mid
          // keyboard-show request — the field still ended up focused, but
          // the platform keyboard never actually appeared, needing a
          // second tap on the (by-then-stable) field to ask again. Keys
          // let Flutter recognize each child by identity across the index
          // shift and update it in place instead.
          children: [
            KeyedSubtree(key: const ValueKey('map'), child: _buildMap()),
            KeyedSubtree(
              key: const ValueKey('verticalButtons'),
              child: _buildVerticalButtonPanel(),
            ),
            // Covers the map/vertical buttons while searching — a Stack
            // sibling of the top bar (painted after it below), so the top
            // bar itself always stays on top and interactive.
            if (_searchActive)
              KeyedSubtree(
                key: const ValueKey('searchOverlay'),
                child: _buildSearchOverlay(),
              ),
            KeyedSubtree(
              key: const ValueKey('topControls'),
              child: SafeArea(child: _buildTopControls()),
            ),
            if (_isLoadingLocation)
              KeyedSubtree(
                key: const ValueKey('loading'),
                child: _buildLoadingOverlay(),
              ),
            if (!_locationPermissionGranted && !_isLoadingLocation)
              KeyedSubtree(
                key: const ValueKey('permissionBanner'),
                child: _buildPermissionBanner(),
              ),
          ],
        ),
      ),
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
          if (_searchResultPin != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _searchResultPin!,
                  width: 34,
                  height: 34,
                  // Anchors the icon's bottom tip (not its center) to the
                  // point — a drop-pin shape should visually point exactly
                  // at the searched location, not sit centered over it.
                  alignment: Alignment.topCenter,
                  child: const _SearchResultPin(),
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
      // Every child is keyed for the same reason the outer Stack's children
      // are (see `build`): the close button's conditional presence shifts
      // the search field's *index* in this Row the instant `_searchActive`
      // flips, and this turned out to be the actual site of the
      // double-tap-for-keyboard bug the Stack-level keys didn't fix — this
      // Row sits directly between the Stack and the TextField, and Row
      // reconciles its children by index just like Stack does. `Expanded`
      // takes `key` directly (it's a plain `Widget` param) rather than
      // needing a `KeyedSubtree` wrapper, which would break its flex
      // sizing — `Row`/`Column` only special-case *direct* children that
      // are `Expanded`/`Flexible`.
      child: Row(
        children: [
          if (_searchActive) ...[
            KeyedSubtree(
              key: const ValueKey('searchCloseButton'),
              child: _buildSearchCloseButton(),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            key: const ValueKey('searchField'),
            child: _buildSearchField(),
          ),
          if (!_searchActive) ...[
            const SizedBox(width: 8),
            KeyedSubtree(
              key: const ValueKey('leaderboardButton'),
              child: _buildLeaderboardButton(),
            ),
          ],
        ],
      ),
    );
  }

  /// Shown only while search is active, in place of the leaderboard button —
  /// same circular white-button treatment as RouteCreatePage's back arrow.
  Widget _buildSearchCloseButton() {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _closeSearch,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.arrow_back, color: Color(0xFF425143), size: 22),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
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
        controller: _searchCtrl,
        focusNode: _searchFocusNode,
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          // isCollapsed drops InputDecorator's own implicit vertical
          // padding, which — combined with this fixed-height 46px
          // container — would otherwise push the text off-centre.
          isCollapsed: true,
          hintText: 'Search a place…',
          hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
          prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 20,
          ),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchSuggestions = []);
                    if (_currentPosition != null) {
                      _updateCityForCurrentLocation(_currentPosition!);
                    }
                  },
                )
              : null,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 20,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  // ── Full-screen search overlay ───────────────────────────────────────────
  //
  // Same "whole page goes white" takeover as RouteCreatePage's search —
  // map, vertical button panel, and leaderboard button all covered — so
  // there's a full screen of room for results instead of a cramped strip.

  /// Matches the top bar's own on-screen height (12 top padding + 46 field
  /// height) so the results list starts right below the search field
  /// (rendered separately, on top of this overlay — see `build`) instead of
  /// underneath it.
  static const double _searchOverlayTopGap = 58.0;

  Widget _buildSearchOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.white,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: _searchOverlayTopGap),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: _searchSuggestions.isEmpty
                      ? _buildSearchEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _searchSuggestions.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            indent: 20,
                            endIndent: 20,
                          ),
                          itemBuilder: (_, i) =>
                              _buildSearchResultTile(_searchSuggestions[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 40, color: Color(0xFFB9C2B5)),
            SizedBox(height: 12),
            Text(
              'Search for a place, city, or landmark',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultTile(Place place) {
    final parts = place.displayName.split(',');
    final primary = parts.first.trim();
    final secondary = parts.skip(1).join(',').trim();

    return InkWell(
      onTap: () => _selectSearchResult(place),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(
                Icons.location_on_outlined,
                size: 18,
                color: Color(0xFF4A8C52),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    primary,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1F3020),
                    ),
                  ),
                  if (secondary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      secondary,
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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

/// Small drop-pin marker for the currently selected search result — paired
/// with `alignment: Alignment.topCenter` on its `Marker` (see `_buildMap`)
/// so the icon's bottom tip, not its center, lands on the actual point.
class _SearchResultPin extends StatelessWidget {
  const _SearchResultPin();

  @override
  Widget build(BuildContext context) {
    // Deliberately no drop shadow: `Icon.shadows` paints via TextStyle's
    // own shadow mechanism, which doesn't get repositioned correctly on
    // every frame as flutter_map moves this marker during a pan — it was
    // visibly left behind at the screen position the marker first appeared
    // at (dead center, right after the post-search `MapController.move`)
    // instead of tracking the icon. A `BoxShadow` (the pattern `_LocationDot`
    // above already uses successfully) would need a boxy backing shape to
    // decorate, which doesn't suit a teardrop pin glyph — simplest correct
    // fix is just not drawing a shadow here at all.
    return const Icon(Icons.location_on, size: 34, color: Color(0xFF4A8C52));
  }
}