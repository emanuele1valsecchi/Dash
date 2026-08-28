:::mermaid
sequenceDiagram
    participant HomePage
    participant FirebaseAuth
    participant Firestore
    participant SharedPreferences
    participant WearBridge
    participant RunTrackingPage

    User->>HomePage: Open home page
    HomePage->>FirebaseAuth: Get current user
    HomePage->>Firestore: Subscribe to profile, sessions, stats, badges
    HomePage->>SharedPreferences: Load leaderboard configuration
    HomePage->>WearBridge: Start wearable bridge
    Firestore-->>HomePage: Emit live data updates
    HomePage-->>User: Render dashboard

    User->>HomePage: Pull to refresh
    HomePage->>SharedPreferences: Reapply leaderboard preferences
    SharedPreferences-->>HomePage: Return saved order and visibility
    HomePage-->>User: Update leaderboard carousel

    User->>HomePage: Start a run
    HomePage->>RunTrackingPage: Open live tracking page
    RunTrackingPage-->>HomePage: Return run summary
    HomePage-->>User: Show saved or discarded result
:::