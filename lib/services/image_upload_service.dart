import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

class ImageUploadService {

  static const _allowedMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
  };

  static const _allowedExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'
  };

  static const _maxFileSizeBytes = 5 * 1024 * 1024; // 5MB

  static Future<String?> pickAndUpload({
    required ImageSource source,
    required void Function(String error) onError,
  }) async {
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );

      if (picked == null) return null;

      final File file = File(picked.path);

      final String? error = await _validate(file, picked.name);
      if (error != null) {
        onError(error);
        return null;
      }

      return await _uploadToStorage(file, picked.name);

    } catch (e) {
      onError("Errore imprevisto durante l'upload: $e");
      return null;
    }
  }

  // ─── Validazione ───────────────────────────────────────────────────────────

  static Future<String?> _validate(File file, String fileName) async {
    if (!await file.exists()) return "File non trovato.";

    final int size = await file.length();
    if (size > _maxFileSizeBytes) {
      return "Il file supera i 5MB (${(size / 1024 / 1024).toStringAsFixed(1)}MB).";
    }
    if (size == 0) return "Il file è vuoto.";

    // Blocca nomi con estensioni multiple (es: foto.jpg.php)
    final String baseName = fileName.split('/').last;
    final List<String> parts = baseName.split('.');
    if (parts.length > 2) {
      return "Nome file non valido: estensioni multiple non consentite.";
    }

    final String ext = parts.last.toLowerCase();
    if (!_allowedExtensions.contains(ext)) {
      return "Formato non supportato. Usa JPG, PNG o WebP.";
    }

    // Legge i magic bytes reali del file (non si fida del nome)
    final List<int> headerBytes = await file.openRead(0, 12).first;
    final String? mimeType = lookupMimeType(fileName, headerBytes: headerBytes);

    if (mimeType == null || !_allowedMimeTypes.contains(mimeType)) {
      return "Il contenuto del file non è un'immagine valida.";
    }

    // Verifica coerenza tra estensione e MIME type
    final bool isJpegAlias =
        mimeType == 'image/jpeg' && (ext == 'jpg' || ext == 'jpeg');
    final String? expectedExt = extensionFromMime(mimeType);
    if (expectedExt != null && expectedExt != ext && !isJpegAlias) {
      return "Estensione e contenuto del file non corrispondono.";
    }

    return null; // ✅ tutto ok
  }

  // ─── Upload Firebase Storage ───────────────────────────────────────────────

  static Future<String?> _uploadToStorage(File file, String fileName) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final String ext = fileName.split('.').last.toLowerCase();
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String storagePath =
        'profile_pictures/${user.uid}/avatar_$timestamp.$ext';

    final Reference ref = FirebaseStorage.instance.ref(storagePath);
    final String? mimeType = lookupMimeType(fileName);
    final SettableMetadata metadata = SettableMetadata(
      contentType: mimeType ?? 'image/jpeg',
    );

    await ref.putFile(file, metadata);
    final String downloadUrl = await ref.getDownloadURL();

    // Aggiorna il photoURL su Firebase Auth
    await user.updatePhotoURL(downloadUrl);

    return downloadUrl;
  }
}