```mermaid
sequenceDiagram
    participant LoginScreen
    participant AuthService
    participant ProfileService
    participant PushNotifications
    participant Navigation

    User->>LoginScreen: Enter credentials or select Google sign-in
    LoginScreen->>AuthService: Request authentication
    AuthService-->>LoginScreen: Return authentication result
    LoginScreen->>ProfileService: Check profile completion
    ProfileService-->>LoginScreen: Return profile status
    LoginScreen->>PushNotifications: Initialize notifications
    LoginScreen->>Navigation: Route to RootScreen or WelcomeRegisterScreen

    User->>LoginScreen: Open registration
    LoginScreen->>Navigation: Navigate to RegisterScreen

    User->>LoginScreen: Open terms or privacy policy
    LoginScreen->>Navigation: Navigate to LegalScreen
```