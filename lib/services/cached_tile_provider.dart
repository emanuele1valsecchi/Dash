import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';

/// Persists map tiles to disk instead of flutter_map's default
/// [NetworkTileProvider], which only caches decoded images in memory for
/// the lifetime of the app process (Flutter's built-in `ImageCache`).
///
/// Without this, every screen's `TileLayer` re-fetches from Jawg on every
/// fresh app launch, and — since each of this app's several map screens
/// (explore, route create/search, run tracking, calendar, temp profile,
/// test run creator) builds its own `FlutterMap` — ordinary navigation
/// between them was re-requesting tiles the user had just downloaded
/// seconds earlier on a different screen, all counting against Jawg's
/// request-rate limit (the source of the 429s seen in testing). All
/// screens share this single instance (`CachedTileProvider.instance`) and
/// its one on-disk cache, so "revisit somewhere already seen" — even
/// across screens, even across app restarts — becomes a disk read instead
/// of a network request.
class CachedTileProvider extends TileProvider {
  CachedTileProvider._();

  static final CachedTileProvider instance = CachedTileProvider._();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return CachedNetworkImageProvider(
      getTileUrl(coordinates, options),
      cacheManager: _TileCacheManager.instance,
      headers: headers,
    );
  }
}

/// A cache dedicated to map tiles, separate from `cached_network_image`'s
/// own shared `DefaultCacheManager` (used elsewhere in the app for profile/
/// badge images) — tiles are far more numerous, smaller, and longer-lived
/// than those, so they shouldn't compete for the same eviction budget.
class _TileCacheManager extends CacheManager {
  static const _cacheKey = 'jawgTileCacheV1';

  static final _TileCacheManager instance = _TileCacheManager._();

  _TileCacheManager._()
    : super(
        Config(
          _cacheKey,
          // Terrain/street basemap tiles essentially never change — long
          // enough that a returning user practically never pays for a
          // re-fetch of ground already covered, while still eventually
          // refreshing if Jawg's styling changes.
          stalePeriod: const Duration(days: 30),
          // Tiles are numerous (a single screen at one zoom level can show
          // dozens) and small, so this caps out around a couple hundred MB
          // worst case — a reasonable disk budget for a map-heavy app, and
          // generous enough that ordinary use (panning around a city,
          // revisiting the same neighbourhood across screens/sessions)
          // stays served from disk rather than falling back to the network.
          maxNrOfCacheObjects: 2000,
        ),
      );
}
