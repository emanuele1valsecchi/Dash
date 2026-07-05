import 'package:firebase_storage/firebase_storage.dart';

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<String> getDownloadUrl(String path) async {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return _storage.ref().child(cleanPath).getDownloadURL();
  }
}