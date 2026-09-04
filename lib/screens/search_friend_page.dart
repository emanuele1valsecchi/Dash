import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/qr_scanner_page.dart';
import 'package:dash/utils/profile_navigator.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_text_form_field.dart';
import 'package:dash/widgets/dash_user_tile.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchFriendPage extends StatefulWidget {
  /// Test seam. Production leaves it null and the state resolves `.instance`
  /// lazily — an eager field initializer would throw `[core/no-app]` when the
  /// widget is *constructed*, before `runApp`.
  @visibleForTesting
  final FirebaseFirestore? firestore;

  const SearchFriendPage({super.key, this.firestore});

  @override
  State<SearchFriendPage> createState() => _SearchFriendPageState();
}

class _SearchFriendPageState extends State<SearchFriendPage> {
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;

  final TextEditingController _searchController = TextEditingController();

  static const String _recentsKey = 'recent_friend_searches';
  List<Map<String, dynamic>> _recentSearches = [];
  List<Map<String, dynamic>> _searchResults = [];

  String _searchQuery = '';
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData contextTheme = Theme.of(context);

    final bool isSearching = _searchQuery.trim().isNotEmpty;
    
    return Scaffold(
      backgroundColor: contextTheme.scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Add a friend",
        actions: [
          IconButton(
            onPressed: () async {
              PermissionStatus status = await Permission.camera.status;

              if (status.isDenied) {
                status = await Permission.camera.request();
              }

              if (status.isPermanentlyDenied) {
                openAppSettings();
                return;
              }
              
              if (status.isGranted && context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const QrScannerPage(),
                  ),
                );
              }
            }, 
            icon: Icon(
              Symbols.qr_code_scanner_rounded
            )
          )
        ],
      ),

      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          spacing: ResponsiveSpacing().md,
          children: [
            DashTextFormField(
              controller: _searchController,
              hintText: 'Search for a friend',
              widthFactor: 1.0,
              charactersCounter: false,
              clearOption: true,
              prefixIconSymbols: Symbols.search_rounded,
              onChanged: _performSearch,
            ),
            
            _buildTextRow(contextTheme, (!isSearching && _recentSearches.isNotEmpty)),

            _buildSearchedList(isSearching),
          ],
        ),
      ),
    );
  }

  Widget _buildTextRow(ThemeData contextTheme, bool canBeCleared){
    TextStyle contextTextStyle = contextTheme.textTheme.bodySmall!.copyWith(
      fontWeight: FontWeight.bold
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: [
        Text(
          'Recent',
          style: contextTextStyle,
        ),
        GestureDetector(
          onTap: (canBeCleared) ? _clearAll : null,
          child: Text(
            'Clear All',
            style: (canBeCleared)
              ? contextTextStyle.copyWith(
                color: contextTheme.colorScheme.tertiary
              )
              : contextTextStyle.copyWith(
                color: contextTheme.colorScheme.outlineVariant
              ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchedList(bool isSearching){
    final List<Map<String, dynamic>> displayList = isSearching ? _searchResults : _recentSearches;

    if (_isLoading && isSearching){
      return Center(
        child: CircularProgressIndicator(),
      );
    } else {
      return Expanded(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: ResponsiveSpacing().md, 
            children: List.generate(displayList.length, (index) {
              final Map<String, dynamic> user = displayList[index];

              return DashUserTile(
                name: user['name'] ?? 'Unknown', 
                surname: user['surname'] ?? '', 
                email: user['email'] ?? 'No email provided', 
                profileImageUrl: user['profileImageUrl'] ?? '',
                onTap: () => _profileTileTap(user),
                trailingIcon: !isSearching 
                  ? IconButton(
                    icon: const Icon(
                      Symbols.close,
                    ),
                    onPressed: () => _removeRecent(index),
                    ) 
                  : null,
              );
            }),
          ),
        ),
      );
    }
  }

  Future<void> _loadRecents() async {
    final prefs = await SharedPreferences.getInstance();
    final String? recentsJson = prefs.getString(_recentsKey);
    if (recentsJson != null) {
      final List<dynamic> decoded = jsonDecode(recentsJson);
      setState(() {
        _recentSearches = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      });
    }
  }

  Future<void> _saveRecent(Map<String, dynamic> user) async {
    final Map<String, dynamic> cleanUser = {
      'uid': user['uid'] ?? '',
      'name': user['name'] ?? '',
      'surname': user['surname'] ?? '',
      'email': user['email'] ?? '',
      'profileImageUrl': user['profileImageUrl'] ?? '',
    };

    _recentSearches.removeWhere((element) => element['uid'] == cleanUser['uid']);
    _recentSearches.insert(0, cleanUser);

    if (_recentSearches.length > 10) {
      _recentSearches = _recentSearches.sublist(0, 10);
    }

    setState(() {});

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_recentsKey, jsonEncode(_recentSearches));
    } catch (e) {
      debugPrint("Error saving recent search: $e");
    }
  }

  void _removeRecent(int index) async {
    setState(() {
      _recentSearches.removeAt(index);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_recentsKey, jsonEncode(_recentSearches));
  }

  Future<void> _clearAll() async {
    setState(() {
      _recentSearches.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentsKey);
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _searchQuery = query;
    });

    if (query.trim().isEmpty) {
      setState(() {
        _searchResults.clear();
        _isLoading = false;
      });
      return;
    }

    setState(() { _isLoading = true; });

    try {
      final String searchPrefix = query.trim();
      
      final snapshot = await _db
          .collection('profiles')
          .where('name', isGreaterThanOrEqualTo: searchPrefix)
          .where('name', isLessThanOrEqualTo: '$searchPrefix\uf8ff')
          .get();

      final results = snapshot.docs.map((doc) {
        final data = doc.data();
        data['uid'] = doc.id;
        return data;
      }).toList();

      if (mounted) {
        setState(() {
          _searchResults = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error searching profiles: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _profileTileTap(Map<String, dynamic> user){
    _saveRecent(user);

    ProfileNavigation.openProfile(context, user['uid']);
  }
}