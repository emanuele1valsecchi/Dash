:::mermaid
classDiagram
    class LeaderboardViewConfig {
        +String title
        +bool isVisible
        +LeaderboardViewConfig(title, isVisible)
        +toJson() Map~String, dynamic~
        +fromJson(Map) LeaderboardViewConfig
    }

    class HomeLeaderboardsSettingsPage {
        +const HomeLeaderboardsSettingsPage()
        +createState() State~HomeLeaderboardsSettingsPage~
    }

    class _HomeLeaderboardsSettingsPageState {
        -List~LeaderboardViewConfig~ _leaderboards
        -bool _isLoading
        +initState()
        -_loadConfig() Future~void~
        -_saveConfig() Future~void~
        -_onReorder(int, int) void
        +build(BuildContext) Widget
    }

    HomeLeaderboardsSettingsPage --> _HomeLeaderboardsSettingsPageState : creates
    _HomeLeaderboardsSettingsPageState "1" o-- "many" LeaderboardViewConfig : manages
:::