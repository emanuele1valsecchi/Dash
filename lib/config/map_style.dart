import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Centralized tile-layer configuration so every map in the app uses the
/// same style. Swap the style/token here rather than editing each screen.
///
/// The Jawg access token is supplied at build/run time via `--dart-define`
/// (see `config/secrets.example.json` and the "Working conventions" section
/// of CLAUDE.md) rather than committed as a source constant — it is never
/// present in git history for builds made after this change.
///
/// This token is still shipped inside the compiled app binary, same as any
/// tile-service key embedded in a mobile map SDK (Mapbox, Google Maps, Jawg
/// itself) — a raster tile URL is requested directly by the map widget on
/// every pan/zoom, so proxying each tile through a backend would multiply
/// latency and cost and defeat the on-disk tile cache (`CachedTileProvider`)
/// built specifically to cut down on tile requests. The actual mitigation
/// for a client-embedded tile token is restricting it by app bundle
/// id/domain in the Jawg dashboard — do this for the production token.
class MapStyle {
  MapStyle._();

  static const String _jawgAccessToken =
      String.fromEnvironment('JAWG_ACCESS_TOKEN');

  /// Jawg Terrain — a low-detail, low-clutter basemap (vs. standard OSM
  /// carto) used across the app to keep the map focused on the run/route
  /// data drawn on top of it.
  ///
  /// The `{r}` placeholder is filled with `@2x` by `TileLayer` when
  /// `retinaMode` is on, requesting sharp tiles on high-density phone
  /// screens instead of upscaling standard-resolution ones (which blurs
  /// text like street names).
  static const String terrainTileUrl =
      'https://tile.jawg.io/jawg-terrain/{z}/{x}/{y}{r}.png?access-token=$_jawgAccessToken';

  /// Floor for every zoomable map in the app, applied via `MapOptions.minZoom`
  /// — without it flutter_map lets a pinch-out keep going until the world
  /// tile repeats several times across the viewport. 4 is roughly "a
  /// continent barely fills the screen" (Europe at this zoom is about as far
  /// out as makes sense to go); `session_detail_screen.dart` intentionally
  /// uses its own tighter floor instead, since that map is always fitted to
  /// one specific route.
  static const double minZoom = 4.0;

  /// Web Mercator (EPSG:3857 — what every slippy-map tile provider,
  /// including Jawg, serves) is only defined up to roughly this latitude;
  /// beyond it there's no tile data at all, which is what let a user pan
  /// far enough north/south to fill half the screen with genuinely empty
  /// space (e.g. well above Greenland).
  static const double _maxMercatorLatitude = 85.05112878;

  /// Paired with `minZoom` on every pannable map via `MapOptions.cameraConstraint:
  /// CameraConstraint.contain(bounds: MapStyle.safeCameraBounds)` — keeps the
  /// *edges* of the viewport within the valid latitude range, not just its
  /// center, so the map stops right at the edge of real tile data instead of
  /// letting the center get close while an edge/corner still pokes past it
  /// into empty space. `CameraConstraint.contain` already accounts for
  /// rotation on its own (flutter_map's `MapCamera.size` is the *rotated*
  /// bounding-box size, not the raw widget size — see `calculateRotatedSize`
  /// in the flutter_map source), so a rotated viewport's corner reaching
  /// further than an unrotated edge would is also caught, not just plain
  /// north/south panning. Longitude is left essentially unbounded (±180) —
  /// only latitude has a genuine "there's nothing there" cutoff; east/west
  /// wrapping isn't the problem being solved here.
  static final LatLngBounds safeCameraBounds = LatLngBounds(
    const LatLng(-_maxMercatorLatitude, -180),
    const LatLng(_maxMercatorLatitude, 180),
  );
}
