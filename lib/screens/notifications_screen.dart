import 'package:flutter/material.dart';

// ==========================================
// MODELLI DATI
// ==========================================
enum NotificationType {
  userLeaderboard, // Es: L'utente raggiunge la top 5
  friendRequest,   // Es: Richiesta di amicizia
  systemLeaderboard, // Es: La classifica è cambiata
  systemArea,      // Es: La tua area è cambiata
}

class NotificationItem {
  final String id;
  final NotificationType type;
  final String boldText; // Il nome dell'utente o la parte in grassetto
  final String regularText; // L'azione ("just reached the top 5")
  final String timestamp;
  final String? imageUrl; // Per gli avatar degli utenti

  NotificationItem({
    required this.id,
    required this.type,
    required this.boldText,
    required this.regularText,
    required this.timestamp,
    this.imageUrl,
  });
}

// ==========================================
// SCHERMATA NOTIFICHE
// ==========================================
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // Lista di mock basata esattamente sul tuo design
  final List<NotificationItem> _notifications = [
    NotificationItem(
      id: '1',
      type: NotificationType.userLeaderboard,
      boldText: 'Name',
      regularText: ' just reached the top 5',
      timestamp: '13 March 2026 - 14:57',
      imageUrl: 'https://i.pravatar.cc/150?img=11', // Sostituisci con URL reali
    ),
    NotificationItem(
      id: '2',
      type: NotificationType.userLeaderboard,
      boldText: 'Name',
      regularText: ' has entered the podium',
      timestamp: '12 March 2026 - 14:57',
      imageUrl: 'https://i.pravatar.cc/150?img=12',
    ),
    NotificationItem(
      id: '3',
      type: NotificationType.friendRequest,
      boldText: 'Name Surname',
      regularText: ' added\nyou as friend',
      timestamp: '13 March 2026 - 14:57',
    ),
    NotificationItem(
      id: '4',
      type: NotificationType.systemLeaderboard,
      boldText: '',
      regularText: 'The leader board is changed',
      timestamp: '13 March 2026 - 14:57',
    ),
    NotificationItem(
      id: '5',
      type: NotificationType.systemLeaderboard,
      boldText: '',
      regularText: 'The leader board is changed',
      timestamp: '13 March 2026 - 14:57',
    ),
    NotificationItem(
      id: '6',
      type: NotificationType.systemLeaderboard,
      boldText: '',
      regularText: 'The leader board is changed',
      timestamp: '13 March 2026 - 14:57',
    ),
    NotificationItem(
      id: '7',
      type: NotificationType.systemArea,
      boldText: '',
      regularText: 'Your area has changed',
      timestamp: '13 March 2026 - 14:57',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F0), // Sfondo in linea con il design
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF495348)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Notification',
          style: TextStyle(
            color: Color(0xFF4A8C52), // Verde del titolo
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView.separated(
        itemCount: _notifications.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          thickness: 1,
          color: Colors.black.withValues(alpha: 0.06), // Linea divisoria leggera
        ),
        itemBuilder: (context, index) {
          final notification = _notifications[index];
          return _buildNotificationTile(notification);
        },
      ),
    );
  }

  Widget _buildNotificationTile(NotificationItem item) {
    return InkWell(
      onTap: () {
        // TODO: Gestisci il tap sulla notifica
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildLeadingIcon(item),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF1E241D),
                        height: 1.3,
                      ),
                      children: [
                        if (item.boldText.isNotEmpty)
                          TextSpan(
                            text: item.boldText,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        TextSpan(
                          text: item.regularText,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.timestamp,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF8A9389),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildTrailingWidget(item),
          ],
        ),
      ),
    );
  }

  // Costruisce l'icona o l'avatar a sinistra in base al tipo di notifica
  Widget _buildLeadingIcon(NotificationItem item) {
    switch (item.type) {
      case NotificationType.userLeaderboard:
        return CircleAvatar(
          radius: 24,
          backgroundColor: Colors.grey.shade300,
          backgroundImage: item.imageUrl != null ? NetworkImage(item.imageUrl!) : null,
          child: item.imageUrl == null ? const Icon(Icons.person, color: Colors.white) : null,
        );
      
      case NotificationType.friendRequest:
        return const CircleAvatar(
          radius: 24,
          backgroundColor: Color(0xFF5C6B59), // Grigio/Verde scuro
          child: Icon(Icons.person_add_alt_1_rounded, color: Colors.white, size: 22),
        );
      
      case NotificationType.systemLeaderboard:
        return const CircleAvatar(
          radius: 24,
          backgroundColor: Color(0xFF5C6B59), // Grigio/Verde scuro
          child: Icon(Icons.bar_chart_rounded, color: Colors.white, size: 24),
        );
      
      case NotificationType.systemArea:
        return const CircleAvatar(
          radius: 24,
          backgroundColor: Color(0xFF5C6B59), // Grigio/Verde scuro
          child: Icon(Icons.route_rounded, color: Colors.white, size: 24),
        );
    }
  }

  // Costruisce la freccia a destra o il bottone "Follow back"
  Widget _buildTrailingWidget(NotificationItem item) {
    if (item.type == NotificationType.friendRequest) {
      return GestureDetector(
        onTap: () {
          // TODO: Logica per accettare l'amicizia
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFCAF0B8), // Verde chiaro
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            'Follow back',
            style: TextStyle(
              color: Color(0xFF2E4029), // Testo scuro
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    return const Icon(
      Icons.chevron_right_rounded,
      color: Color(0xFF8A9389),
      size: 24,
    );
  }
}