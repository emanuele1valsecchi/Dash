:::mermaid
classDiagram
    class LeaderboardEntry {
        +String userId
        +int totalPoints
        +String name
        +String surname
        +String profileImageUrl
        +int rank
    }

    class LeaderboardScreen {
        +String cityFilter
        +LeaderboardScreen()
        +createState() State
    }

    class LeaderboardScreenState {
        -bool isLoading
        -List leaderboard
        -LeaderboardEntry currentUserEntry
        +initState()
        -fetchLeaderboardData() Future
        -formatName(String, String) String
        -buildPodiumSection() Widget
        -buildListItem(LeaderboardEntry) Widget
        +build(BuildContext) Widget
    }

    class Firestore {
        +get() Future
        +collection(String) CollectionReference
    }

    class FirebaseAuth {
        +currentUser User
    }

    class PublicProfilePage {
        +String userId
        +build(BuildContext) Widget
    }

    LeaderboardScreen ..> LeaderboardScreenState : creates
    LeaderboardScreenState "1" o-- "0..*" LeaderboardEntry : contains
    LeaderboardScreenState --> Firestore : reads
    LeaderboardScreenState --> FirebaseAuth : reads current user
    LeaderboardScreenState --> PublicProfilePage : opens
:::