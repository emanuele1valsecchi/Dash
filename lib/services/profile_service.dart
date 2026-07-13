import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class ProfileService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  String get _uid => _auth.currentUser!.uid;

  // ── Ritorna il documento profilo ───────────────────────────────────────────
  Future<DocumentSnapshot<Map<String, dynamic>>> getProfileDoc() async {
    return await _firestore.collection('profiles').doc(_uid).get();
  }

  // ── Ritorna lo username di un utente arbitrario (es. proprietario di
  //    un'area conquistata) — non necessariamente l'utente corrente ────────
  Future<String?> fetchUsername(String uid) async {
    final doc = await _firestore.collection('profiles').doc(uid).get();
    final username = (doc.data()?['username'] as String?)?.trim();
    return (username == null || username.isEmpty) ? null : username;
  }

  // ── Controlla se il profilo è davvero completo ─────────────────────────────
  Future<bool> isProfileComplete() async {
    final doc = await _firestore.collection('profiles').doc(_uid).get();

    if (!doc.exists) return false;

    final data = doc.data();
    if (data == null) return false;

    final username = (data['username'] ?? '').toString().trim();
    final name = (data['name'] ?? '').toString().trim();
    final surname = (data['surname'] ?? '').toString().trim();

    final profileCompleted = data['profileCompleted'] == true;

    return profileCompleted &&
        username.isNotEmpty &&
        name.isNotEmpty &&
        surname.isNotEmpty;
  }

  // ── Crea/Completa il profilo senza sovrascrivere il bootstrap doc ─────────
  Future<void> createProfile({
    required String username,
    required String name,
    required String surname,
    required String bio,
    File? profileImage,
  }) async {
    String? profileImageUrl;

    if (profileImage != null) {
      final ref = _storage
          .ref()
          .child('profile_images')
          .child('$_uid.jpg');

      await ref.putFile(profileImage);
      profileImageUrl = await ref.getDownloadURL();
    }

    final docRef = _firestore.collection('profiles').doc(_uid);
    final existingDoc = await docRef.get();
    final existingData = existingDoc.data();

    // Rimuoviamo 'totalPoints', non serve passarlo!
    await docRef.set({
      'username': username.trim(),
      'name': name.trim(),
      'surname': surname.trim(),
      'bio': bio.trim(),
      'profileImageUrl': profileImageUrl ??
          (existingData != null
              ? (existingData['profileImageUrl'] ?? '')
              : ''),
      'profileCompleted': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ── Salva nickname separato ────────────────────────────────────────────────
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