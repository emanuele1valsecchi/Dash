import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class ProfileService {
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _storage = FirebaseStorage.instance;

  String get _uid => _auth.currentUser!.uid;

  // ── Controlla se il profilo esiste già ────────────────────────────────────
  Future<bool> profileExists() async {
    final doc = await _firestore.collection('profiles').doc(_uid).get();
    return doc.exists;
  }

  // ── Crea il profilo (primo accesso) ───────────────────────────────────────
  Future<void> createProfile({
    required String username,
    required String name,
    required String surname,
    required String bio,
    File? profileImage,
  }) async {
    String profileImageUrl = '';

    if (profileImage != null) {
      final ref = _storage
          .ref()
          .child('profile_images')
          .child('$_uid.jpg');
      await ref.putFile(profileImage);
      profileImageUrl = await ref.getDownloadURL();
    }

    await _firestore.collection('profiles').doc(_uid).set({
      'username':        username.trim(),
      'name':            name.trim(),
      'surname':         surname.trim(),
      'bio':             bio.trim(),
      'profileImageUrl': profileImageUrl,
      'totalPoints':     0,
      'createdAt':       FieldValue.serverTimestamp(),
    });
  }

  // ── Salva il nickname separato (come da tua struttura Firestore) ──────────
  Future<void> saveNickname(String username) async {
    await _firestore.collection('nicknames').doc(username.trim()).set({
      'uid': _uid,
    });
  }

  // ── Controlla se username è già preso ─────────────────────────────────────
  Future<bool> isUsernameTaken(String username) async {
    final doc = await _firestore
        .collection('nicknames')
        .doc(username.trim())
        .get();
    return doc.exists;
  }
}