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
}
