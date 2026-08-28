:::mermaid
sequenceDiagram
    participant User
    participant SettingsPage
    participant SharedPreferences
    participant FirebaseAuth
    participant Firestore

    User->>SettingsPage: Opens page
    SettingsPage->>SharedPreferences: Load saved config JSON
    SharedPreferences-->>SettingsPage: Returns serialized configs
    SettingsPage->>FirebaseAuth: Get current user
    FirebaseAuth-->>SettingsPage: Returns user instance
    SettingsPage->>Firestore: Fetch runningSessions
    Firestore-->>SettingsPage: Returns QuerySnapshot
    SettingsPage->>SettingsPage: Parse territories and compute default order
    SettingsPage->>SettingsPage: Update state (_isLoading = false)
    
    User->>SettingsPage: Reorders or toggles visibility
    SettingsPage->>SettingsPage: setState()
    SettingsPage->>SharedPreferences: Save updated config JSON
:::