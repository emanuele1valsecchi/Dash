import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// Assicurati che questo import sia corretto per il tuo progetto
import '../config/map_style.dart';
import '../services/cached_tile_provider.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  Map<DateTime, List<Map<String, dynamic>>> _activityDays = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _loadCalendarSessions();
  }

  Future<void> _loadCalendarSessions() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final querySnapshot = await FirebaseFirestore.instance
          .collection('runningSessions')
          .where('userId', isEqualTo: user.uid)
          .get();

      final Map<DateTime, List<Map<String, dynamic>>> loadedDays = {};

      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

        if (createdAt != null) {
          final normalizedDay = DateTime(createdAt.year, createdAt.month, createdAt.day);
          
          if (loadedDays.containsKey(normalizedDay)) {
            loadedDays[normalizedDay]!.add(data);
          } else {
            loadedDays[normalizedDay] = [data];
          }
        }
      }

      if (mounted) {
        setState(() {
          _activityDays = loadedDays;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Errore nel caricamento delle sessioni per il calendario: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    return _activityDays[normalizedDay] ?? [];
  }

  List<LatLng> _extractPolyline(Map<String, dynamic> data) {
    final path = data['path'] as List<dynamic>?;
    if (path == null) return [];

    return path.map((point) {
      if (point is GeoPoint) {
        return LatLng(point.latitude, point.longitude);
      }
      return const LatLng(0, 0);
    }).where((latLng) => latLng.latitude != 0 && latLng.longitude != 0).toList();
  }

  @override
  Widget build(BuildContext context) {
    final selectedDayActivities = _selectedDay != null ? _getEventsForDay(_selectedDay!) : [];

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      // L'AppBar normale viene rimossa da qui e inserita come SliverAppBar nel NestedScrollView
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Color(0xFF3B5E62)))
        : NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                // L'AppBar che resta fissa (pinned: true) mentre il resto scorre sotto
                SliverAppBar(
                  backgroundColor: const Color(0xFFF3F5EE),
                  surfaceTintColor: Colors.transparent, // Previene i cambi di colore in Material 3
                  elevation: 0,
                  pinned: true,
                  centerTitle: true,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Color(0xFF495348)),
                    onPressed: () => Navigator.pop(context),
                  ),
                  title: const Text(
                    'Calendar',
                    style: TextStyle(
                      color: Color(0xFF4A554A),
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Il Calendario che scompare scorrendo verso l'alto
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: TableCalendar(
                      firstDay: DateTime.utc(2020, 1, 1),
                      lastDay: DateTime.utc(2030, 12, 31),
                      focusedDay: _focusedDay,
                      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                      onDaySelected: (selectedDay, focusedDay) {
                        if (!isSameDay(_selectedDay, selectedDay)) {
                          setState(() {
                            _selectedDay = selectedDay;
                            _focusedDay = focusedDay;
                          });
                        }
                      },
                      eventLoader: _getEventsForDay,
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      headerStyle: const HeaderStyle(
                        formatButtonVisible: false,
                        titleCentered: true,
                        leftChevronIcon: Icon(Icons.chevron_left, color: Color(0xFF495348)),
                        rightChevronIcon: Icon(Icons.chevron_right, color: Color(0xFF495348)),
                        titleTextStyle: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF2A3028),
                        ),
                      ),
                      daysOfWeekStyle: const DaysOfWeekStyle(
                        weekdayStyle: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF495348)),
                        weekendStyle: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF495348)),
                      ),
                      calendarStyle: CalendarStyle(
                        outsideDaysVisible: true,
                        outsideTextStyle: const TextStyle(color: Color(0xFFD3D5CE)),
                        defaultTextStyle: const TextStyle(color: Color(0xFF2A3028), fontWeight: FontWeight.w500),
                        weekendTextStyle: const TextStyle(color: Color(0xFF2A3028), fontWeight: FontWeight.w500),
                        selectedDecoration: const BoxDecoration(
                          color: Color(0xFF3B5E62),
                          shape: BoxShape.circle,
                        ),
                        todayDecoration: BoxDecoration(
                          color: const Color(0xFF3B5E62).withValues(alpha: 0.3),
                          shape: BoxShape.circle,
                        ),
                        todayTextStyle: const TextStyle(color: Color(0xFF2A3028), fontWeight: FontWeight.bold),
                        markerDecoration: const BoxDecoration(
                          color: Color(0xFF3B5E62),
                          shape: BoxShape.circle,
                        ),
                        markersMaxCount: 1,
                        markerMargin: const EdgeInsets.only(top: 6.0),
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ];
            },
            // Il body è la parte bianca inferiore che sale a coprire lo schermo
            body: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFFFAFBF7),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(30),
                  topRight: Radius.circular(30),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 16),
                    child: Text(
                      'Your activities',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2A3028),
                      ),
                    ),
                  ),
                  Expanded(
                    child: selectedDayActivities.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.directions_run_rounded, size: 48, color: Colors.grey[300]),
                                const SizedBox(height: 12),
                                Text(
                                  'No activities on this day',
                                  style: TextStyle(color: Colors.grey[500], fontSize: 16),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: selectedDayActivities.length,
                            itemBuilder: (context, index) {
                              final session = selectedDayActivities[index];
                              
                              final name = session['name'] ?? 'Untitled run';
                              final distanceMeters = (session['distanceMeters'] as num?)?.toDouble() ?? 0.0;
                              final durationMs = (session['durationMs'] as num?)?.toInt() ?? 0;
                              final loopsCompleted = (session['loopsCompleted'] as num?)?.toInt() ?? 0;
                              
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16.0),
                                child: SessionCard(
                                  name: name,
                                  distanceKm: distanceMeters / 1000,
                                  timeMin: (durationMs / 60000).round(),
                                  isLoop: loopsCompleted > 0,
                                  routePolyline: _extractPolyline(session),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
    );
  }
}

// ==========================================
// WIDGET CARD DELLA SESSIONE
// ==========================================
class SessionCard extends StatelessWidget {
  final String name;
  final double distanceKm;
  final int timeMin;
  final bool isLoop;
  final List<LatLng> routePolyline;

  const SessionCard({
    super.key,
    required this.name,
    required this.distanceKm,
    required this.timeMin,
    required this.isLoop,
    required this.routePolyline,
  });

  @override
  Widget build(BuildContext context) {
    final distLabel = distanceKm < 1
        ? '${(distanceKm * 1000).round()} m'
        : '${distanceKm.toStringAsFixed(2)} km';
    
    final timeLabel = timeMin < 60
        ? '${timeMin.round()} min'
        : '${(timeMin / 60).floor()}h ${(timeMin % 60).round()}min';

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Map preview ──
          if (routePolyline.length >= 2)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: SizedBox(
                height: 160,
                child: FlutterMap(
                  options: MapOptions(
                    initialCameraFit: CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints(routePolyline),
                      padding: const EdgeInsets.all(28),
                    ),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: MapStyle.terrainTileUrl,
                      userAgentPackageName: 'com.dash',
                      retinaMode: RetinaMode.isHighDensity(context),
                      tileProvider: CachedTileProvider.instance,
                    ),
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: routePolyline,
                          color: const Color(0xFF4A8C52),
                          strokeWidth: 3.5,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          // ── Info row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: Color(0xFF2A3028),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.straighten_rounded, size: 13, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(distLabel, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(width: 12),
                    const Icon(Icons.timer_outlined, size: 13, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(timeLabel, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    if (isLoop) ...[
                      const SizedBox(width: 12),
                      const Icon(Icons.loop_rounded, size: 13, color: Color(0xFF4A8C52)),
                      const SizedBox(width: 4),
                      const Text('Loop', style: TextStyle(fontSize: 12, color: Color(0xFF4A8C52))),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}