import 'package:flutter/material.dart';
import '../../models/home_models.dart'; 

class LeaderboardPreviewCard extends StatelessWidget {
  final LeaderboardPreviewData data;
  final VoidCallback onTap;

  const LeaderboardPreviewCard({
    super.key,
    required this.data,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Troviamo il pin dell'utente corrente per sapere dove fermare la linea scura
    final currentUserPin = data.pins.where((p) => p.isCurrentUser).firstOrNull;
    final progressPercent = currentUserPin?.normalizedPosition ?? 0.0;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: const Color.fromARGB(232, 235, 238, 233),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE6E8E0), width: 1.5),
        ),
        child: Column(
          children: [
            // ── Intestazione con la Città ──
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.location_on_rounded, size: 14, color: Color(0xFF8A9389)),
                const SizedBox(width: 4),
                Text(
                  data.city.isNotEmpty ? data.city : 'Unknown territory',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF8A9389),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Sezione Grafica (Track & Pins) ──
            SizedBox(
              height: 110,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth;
                  // Sottraiamo la larghezza del pin (42) per evitare che escano dal bordo destro
                  final trackWidth = maxWidth - 42; 

                  return Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      // Linea di sfondo (grigio/azzurrino)
                      Container(
                        height: 8,
                        width: maxWidth,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD6E5EB),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      
                      // Linea di progresso (Verde scuro) fino all'utente corrente
                      Container(
                        height: 8,
                        width: (trackWidth * progressPercent) + 21, // +21 per farla arrivare al centro del pin
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B5E62),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),

                      // ── Renderizza tutti i Pin dinamicamente ──
                      ...data.pins.map((pin) {
                        return Positioned(
                          // Se non è l'utente corrente va sopra, altrimenti va sotto
                          top: pin.isCurrentUser ? 50 : 0, 
                          left: trackWidth * pin.normalizedPosition,
                          child: _MapPin(
                            imageUrl: pin.profileImageUrl,
                            isCurrentUser: pin.isCurrentUser,
                            isTop: !pin.isCurrentUser,
                          ),
                        );
                      }),
                    ],
                  );
                },
              ),
            ),
            
            const SizedBox(height: 16),
            
            // ── Sezione Statistiche ──
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildStatColumn('Position', '#${data.position}'),
                _buildStatColumn('Points', '${data.points} pt'),
                _buildStatColumn('Variation', data.variation?.toString() ?? '—'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatColumn(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8A9389),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            color: Color(0xFF4A554A),
          ),
        ),
      ],
    );
  }
}

// ── Widget Custom per disegnare il Map Pin ──
class _MapPin extends StatelessWidget {
  final String imageUrl;
  final bool isCurrentUser;
  final bool isTop;

  const _MapPin({
    required this.imageUrl,
    required this.isCurrentUser,
    required this.isTop,
  });

  @override
  Widget build(BuildContext context) {
    final pinColor = isCurrentUser ? const Color(0xFF3B5E62) : const Color(0xFFD3D6CE);
    final size = isCurrentUser ? 46.0 : 38.0; // Utente corrente leggermente più grande

    return SizedBox(
      width: size,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: isTop ? 0 : null,
            top: !isTop ? 0 : null,
            child: Transform.rotate(
              angle: isTop ? 0.785398 : 3.92699, // 45° o 225°
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: pinColor,
                  borderRadius: const BorderRadius.only(
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          
          Positioned(
            top: isTop ? 0 : null,
            bottom: !isTop ? 0 : null,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: pinColor,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(3.0),
                child: CircleAvatar(
                  backgroundColor: Colors.grey.shade300,
                  backgroundImage: imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
                  child: imageUrl.isEmpty 
                    ? Icon(Icons.person, size: isCurrentUser ? 20 : 16, color: Colors.grey.shade600)
                    : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}