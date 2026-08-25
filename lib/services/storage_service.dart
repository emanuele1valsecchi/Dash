import 'package:firebase_storage/firebase_storage.dart';

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Restituisce l'URL di download per il path indicato.
  /// Lancia un'eccezione se il file non esiste o l'accesso è negato:
  /// usa questa versione quando vuoi gestire l'errore esplicitamente
  /// nel chiamante (try/catch), come già fa _loadBadges() in home_screen.dart.
  Future<String> getDownloadUrl(String path) async {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return _storage.ref().child(cleanPath).getDownloadURL();
  }

  /// Versione "safe": non lancia eccezioni, restituisce null se il file
  /// non esiste, il path è vuoto, o l'accesso è negato (403/404).
  /// Usa questa nei punti dove vuoi solo un fallback pulito senza try/catch
  /// esterno, es. quando carichi avatar per una lista di utenti.
  Future<String?> getDownloadUrlSafe(String? path) async {
    if (path == null || path.trim().isEmpty) return null;
    try {
      return await getDownloadUrl(path);
    } catch (_) {
      return null;
    }
  }
}