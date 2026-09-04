import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/cached_tile_provider.dart';

/// Map tiles, cached to disk app-wide.
///
/// flutter_map's default provider only keeps decoded images in memory for the
/// process's lifetime, so every app launch — and every navigation between the
/// several screens that each build their own `FlutterMap` — re-fetched tiles
/// already downloaded, against Jawg's request-rate limit. Nothing about that
/// failure is visible locally: it looks like a working map right up until the
/// quota is hit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final provider = CachedTileProvider.instance;

  // `flutter_cache_manager` asks path_provider for a directory the moment a
  // cache manager is constructed, so without this every test that touches one
  // dies on a MissingPluginException rather than on its assertion.
  //
  // One directory for the whole file, not one per test: the managers are lazy
  // singletons that capture the path on first use, so deleting it between
  // tests leaves the second test creating a subdirectory under a parent that
  // no longer exists.
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('dash_tile_cache');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Built inside a test, never at top level: `TileLayer`'s constructor
  /// creates a `NetworkTileProvider`, which creates an `HttpClient` — and
  /// `flutter_test` refuses that outside a test zone. Passing our own provider
  /// also stops a network one being built at all.
  TileLayer layer() => TileLayer(
        urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.dash',
        tileProvider: CachedTileProvider.instance,
      );

  const coords = TileCoordinates(3, 5, 7);

  test('is a single shared instance', () {
    // One instance means one cache. A provider built per screen would give
    // each map its own store and defeat the point.
    expect(identical(CachedTileProvider.instance, CachedTileProvider.instance),
        isTrue);
  });

  test('serves tiles through the disk cache, not the default provider', () {
    final image = provider.getImage(coords, layer());

    expect(image, isA<CachedNetworkImageProvider>());
  });

  test('requests the URL the layer template resolves to', () {
    final image =
        provider.getImage(coords, layer()) as CachedNetworkImageProvider;

    expect(image.url, provider.getTileUrl(coords, layer()));
    expect(image.url, 'https://tiles.example/7/3/5.png');
  });

  test('uses a tile-only cache, not the app-wide default one', () {
    // The documented decision: tiles are far more numerous, smaller and
    // longer-lived than profile and badge images, so they must not compete
    // with them for the same eviction budget. Sharing
    // `DefaultCacheManager` would let a pan around a city evict avatars.
    final image =
        provider.getImage(coords, layer()) as CachedNetworkImageProvider;

    expect(image.cacheManager, isNotNull);
    expect(image.cacheManager, isNot(same(DefaultCacheManager())));
  });

  test('the same cache manager is reused across tiles', () {
    final a = provider.getImage(coords, layer()) as CachedNetworkImageProvider;
    final b = provider.getImage(const TileCoordinates(9, 9, 9), layer())
        as CachedNetworkImageProvider;

    expect(identical(a.cacheManager, b.cacheManager), isTrue,
        reason: 'a manager per tile would mean a cache per tile');
  });
}
