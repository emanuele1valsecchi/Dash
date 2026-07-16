import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// Assicurati che questo import combaci con la cartella del tuo progetto
import '../config/map_style.dart'; 

class SessionDetailScreen extends StatelessWidget {
  final Map<String, dynamic> sessionData;
  final List<LatLng> routePolyline;

  const SessionDetailScreen({
    super.key,
    required this.sessionData,
    required this.routePolyline,
  });

  // Converte il formato decimale del passo nel classico formato M'SS" /km
  String _formatPace(double paceDecimal) {
    if (paceDecimal <= 0) return '--';
    int minutes = paceDecimal.floor();
    int seconds = ((paceDecimal - minutes) * 60).round();
    return '$minutes\'${seconds.toString().padLeft(2, '0')}"';
  }

  @override
  Widget build(BuildContext context) {
    // Estrazione dei dati dalla sessione
    final name = sessionData['name'] ?? 'Untitled run';
    final distanceMeters = (sessionData['distanceMeters'] as num?)?.toDouble() ?? 0.0;
    final durationMs = (sessionData['durationMs'] as num?)?.toInt() ?? 0;
    final calories = (sessionData['caloriesBurned'] as num?)?.toDouble() ?? 0.0;
    
    // Controlliamo avgPaceMinPerKm se esiste, altrimenti fallback su maxPaceMinPerKm
    final pace = (sessionData['avgPaceMinPerKm'] as num?)?.toDouble() ?? 
                 (sessionData['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;
    final loops = (sessionData['loopsCompleted'] as num?)?.toInt() ?? 0;
    
    final distKm = (distanceMeters / 1000).toStringAsFixed(2);
    final timeMin = (durationMs / 60000).round();

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Color(0xFF495348), size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          name,
          style: const TextStyle(
            color: Color(0xFF4A554A),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Column(
        children: [
          // ── Sezione Mappa ──
          if (routePolyline.isNotEmpty)
            Container(
              height: 250,
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
                    initialCameraFit: CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints(routePolyline),
                      padding: const EdgeInsets.all(32),
                    ),
                    // Permettiamo all'utente di muoversi e zoomare nella schermata di dettaglio
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all,
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
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
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
                    childAspectRatio: 2.3,
                    children: [
                      _buildStatCard(Icons.straighten_rounded, 'Distance', '$distKm km'),
                      _buildStatCard(Icons.timer_outlined, 'Duration', '$timeMin min'),
                      _buildStatCard(Icons.speed_rounded, 'Avg Pace', '${_formatPace(pace)} /km'),
                      _buildStatCard(Icons.local_fire_department_rounded, 'Calories', '${calories.toStringAsFixed(0)} kcal'),
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () {
                  // TODO: Collegare alla schermata per iniziare l'allenamento
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Route pre-loading functionality coming soon!'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
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