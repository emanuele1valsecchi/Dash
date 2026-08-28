:::mermaid
sequenceDiagram
    participant Navigation
    participant LegalScreen
    participant LegalType
    participant LegalDocumentView

    User->>Navigation: Select legal document
    Navigation->>LegalScreen: Create screen with selected type
    LegalScreen->>LegalType: Check terms or privacy value
    LegalScreen->>LegalScreen: Select constant legal text
    LegalScreen->>LegalDocumentView: Build scrollable document view
    LegalDocumentView-->>User: Display legal document
:::