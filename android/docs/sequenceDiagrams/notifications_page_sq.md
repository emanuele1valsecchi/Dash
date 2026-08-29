```mermaid
sequenceDiagram
    participant NotificationsScreen
    participant Firestore
    participant ExplorePage
    participant LeaderboardScreen
    participant BadgePage

    User->>NotificationsScreen: Open notifications
    NotificationsScreen->>Firestore: Subscribe to user notifications
    Firestore-->>NotificationsScreen: Return ordered notification documents
    NotificationsScreen->>NotificationsScreen: Convert documents to NotificationItem
    NotificationsScreen-->>User: Render notification feed

    User->>NotificationsScreen: Tap notification
    NotificationsScreen->>Firestore: Mark notification as read
    NotificationsScreen->>NotificationsScreen: Check type and payload
    NotificationsScreen->>ExplorePage: Open stolen-territory location
    NotificationsScreen->>LeaderboardScreen: Open ranking destination
    NotificationsScreen->>BadgePage: Open unlocked badge page
```