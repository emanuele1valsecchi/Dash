import 'dart:math' as math;
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// Assicurati che questo import combaci con la cartella del tuo progetto
import '../config/map_style.dart';
import '../widgets/units_scope.dart';

class SessionDetailScreen extends StatelessWidget {
  final Map<String, dynamic> sessionData;
  final List<LatLng> routePolyline;

  const SessionDetailScreen({
    super.key,
    required this.sessionData,
    required this.routePolyline,
  });

  @override
  Widget build(BuildContext context) {
    // Rileviamo le dimensioni dello schermo per adattare i widget
    final size = MediaQuery.of(context).size;
    final units = Units.of(context);
    
    // Estrazione dei dati dalla sessione
    final name = sessionData['name'] ?? 'Untitled run';
    final distanceMeters = (sessionData['distanceMeters'] as num?)?.toDouble() ?? 0.0;
    final durationMs = (sessionData['durationMs'] as num?)?.toInt() ?? 0;
    final calories = (sessionData['caloriesBurned'] as num?)?.toDouble() ?? 0.0;
    final points = (sessionData['pointsEarned'] as num?)?.toInt() ?? 0;
    
    // Controlliamo avgPaceMinPerKm se esiste, altrimenti fallback su maxPaceMinPerKm
    final pace = (sessionData['avgPaceMinPerKm'] as num?)?.toDouble() ?? 
                 (sessionData['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;
    final loops = (sessionData['loopsCompleted'] as num?)?.toInt() ?? 0;
    
    final timeMin = (durationMs / 60000).round();

    // 1. Calcoliamo i confini esatti della corsa
    final routeBounds = routePolyline.isNotEmpty 
        ? LatLngBounds.fromPoints(routePolyline) 
        : null;

    // 2. Creiamo il recinto elastico a prova di crash (Addio Kiev)
    LatLngBounds? safeCameraLimits;
    if (routeBounds != null) {
      final latSpan = (routeBounds.north - routeBounds.south).abs();
      final lngSpan = (routeBounds.east - routeBounds.west).abs();
      
      // Prendiamo la dimensione maggiore tra larghezza e altezza della corsa
      final maxSpan = math.max(latSpan, lngSpan);
      
      // Il buffer è proporzionale al lato più lungo (80%), con un minimo vitale di ~3km (0.03 gradi)
      // per evitare che corse molto piccole schiaccino il rettangolo della telecamera.
      final buffer = math.max(maxSpan * 0.8, 0.03);

      safeCameraLimits = LatLngBounds(
        LatLng(routeBounds.south - buffer, routeBounds.west - buffer),
        LatLng(routeBounds.north + buffer, routeBounds.east + buffer),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      appBar: DashNavigationTopBar(
        title: name
      ),
      body: SafeArea(
        bottom: true,
        top: false,
        child: Column(
          children: [
            // ── Sezione Mappa ──
            if (routePolyline.isNotEmpty && routeBounds != null && safeCameraLimits != null)
              Container(
                height: (size.height * 0.28).clamp(180.0, 260.0),
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x11000000),
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: FlutterMap(
                    options: MapOptions(
                      // All'apertura inquadra comodamente il percorso esatto
                      initialCameraFit: CameraFit.bounds(
                        bounds: routeBounds,
                        padding: const EdgeInsets.all(32),
                      ),
                      minZoom: 11.0,
                      // Blocco dinamico calcolato sulle proporzioni per non andare a Kiev!
                      cameraConstraint: CameraConstraint.contain(
                        bounds: safeCameraLimits,
                      ),
                      // Fling disabled: a fast pinch released with the two
                      // fingers lifting even a few ms apart can corrupt
                      // flutter_map's own velocity reading via a real
                      // Flutter gesture-recognizer focal-point discontinuity,
                      // risking an unwanted glide in a near-random direction
                      // (see EnhancedMapGestures' class doc, point 3, for
                      // the full root-cause trace — this screen doesn't use
                      // that widget, but the same underlying flutter_map/
                      // Flutter-framework mechanism still applies here).
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.flingAnimation,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: MapStyle.terrainTileUrl,
                        userAgentPackageName: 'com.dash',
                        retinaMode: RetinaMode.isHighDensity(context),
                      ),
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: routePolyline,
                            color: const Color(0xFF4A8C52),
                            strokeWidth: 4.0,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              
            // ── Sezione Statistiche ──
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Workout Stats',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2A3028),
                      ),
                    ),
                    const SizedBox(height: 16),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 2.15,
                      children: [
                        _buildStatCard(Icons.straighten_rounded, 'Distance', units.distanceMajor(distanceMeters)),
                        _buildStatCard(Icons.timer_outlined, 'Duration', '$timeMin min'),
                        _buildStatCard(Icons.speed_rounded, 'Avg ${units.rateLabel}', units.rateFromPace(pace)),
                        _buildStatCard(Icons.local_fire_department_rounded, 'Calories', units.energy(calories)),
                        _buildStatCard(
                          Icons.bolt_rounded, 
                          'Points', 
                          '$points XP', 
                          iconColor: const Color(0xFF4A8C52),
                        ),
                        if (loops > 0)
                          _buildStatCard(
                            Icons.loop_rounded, 
                            'Loops', 
                            '$loops closed', 
                            iconColor: const Color(0xFF4A8C52),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            // ── Pulsante in basso ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    context.showInformationSnackBar("Route pre-loading functionality coming soon!");
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFCAF0B8),
                    foregroundColor: const Color(0xFF1F3020),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Start run with this route',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(IconData icon, String title, String value, {Color? iconColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E5DD)),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor ?? const Color(0xFF7A8377), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7A8377),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2A3028),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}