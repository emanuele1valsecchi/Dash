/// Centralized tile-layer configuration so every map in the app uses the
/// same style. Swap the style/token here rather than editing each screen.
///
/// Known security debt (same class of issue as the OpenRouteService key in
/// `RoutingService`): this token is shipped in the compiled app and is
/// trivially extractable. Jawg tokens can be restricted by domain/bundle id
/// in the Jawg dashboard, which should be done for production. Longer term,
/// prefer loading this from a non-committed config/secret store.
class MapStyle {
  MapStyle._();

  static const String _jawgAccessToken =
      'WSDdquUBWoGdNroBrfVtxwIHYVydz1nro7jGj9A3EyppPzWy0dPgiKfc9Twbykp6';

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