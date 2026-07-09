import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
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

  static const _maxFileSizeBytes = 5 * 1024 * 1024;

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

      final file = File(picked.path);
      final error = await _validate(file, picked.name);
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

  static Future<String?> _validate(File file, String fileName) async {
    if (!await file.exists()) return "File non trovato.";

    final size = await file.length();
    if (size > _maxFileSizeBytes) {
      return "Il file supera i 5MB (${(size / 1024 / 1024).toStringAsFixed(1)}MB).";
    }
    if (size == 0) return "Il file è vuoto.";

    final baseName = fileName.split('/').last;
    final parts = baseName.split('.');
    if (parts.length != 2) {
      return "Nome file non valido.";
    }

    final ext = parts.last.toLowerCase();
    if (!_allowedExtensions.contains(ext)) {
      return "Formato non supportato. Usa JPG, PNG o WebP.";
    }

    final headerBytes = await file.openRead(0, 12).first;
    final mimeType = lookupMimeType(fileName, headerBytes: headerBytes);

    if (mimeType == null || !_allowedMimeTypes.contains(mimeType)) {
      return "Il contenuto del file non è un'immagine valida.";
    }

    final isJpegAlias =
        mimeType == 'image/jpeg' && (ext == 'jpg' || ext == 'jpeg');
    final expectedExt = extensionFromMime(mimeType);
    if (expectedExt != ext && !isJpegAlias) {
      return "Estensione e contenuto del file non corrispondono.";
    }

    return null;
  }

  static Future<String?> _uploadToStorage(File file, String fileName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final ext = fileName.split('.').last.toLowerCase();
    final storagePath = 'profile_pictures/${user.uid}/avatar.$ext';

    final ref = FirebaseStorage.instance.ref().child(storagePath);
    final mimeType = lookupMimeType(fileName);

    final metadata = SettableMetadata(
      contentType: mimeType ?? 'image/jpeg',
    );

    await ref.putFile(file, metadata);
    final downloadUrl = await ref.getDownloadURL();

    await user.updatePhotoURL(downloadUrl);
    await user.reload();

    await FirebaseFirestore.instance
        .collection('profiles')
        .doc(user.uid)
        .set({
      'profileImageUrl': downloadUrl,
      'profileImagePath': storagePath,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return downloadUrl;
  }
}