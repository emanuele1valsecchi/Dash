/// The deep link that identifies a Dash profile, and the parser that reads one
/// back.
///
/// Both halves live together deliberately. The link is *written* by
/// `share_profile_page` (into a QR code and the clipboard) and *read* by
/// `qr_scanner_page`; while the format was spelled out separately in each,
/// nothing stopped one side changing and the other silently failing to match
/// — and the symptom would be a QR code that scans as "nothing here" rather
/// than any kind of error. [profileLinkRoundTrips] in
/// `test/unit_test/profile_link_test.dart` pins them to each other.
class ProfileLink {
  ProfileLink._();

  /// Where a scanned link points when opened in a browser rather than the app.
  static const host = 'dash-efb1d.web.app';

  /// The path segment marking a link as a profile link.
  static const _profileSegment = 'profile';

  /// The shareable link for [userId].
  static String forUser(String userId) =>
      'https://$host/$_profileSegment/$userId';

  /// The user id encoded in [rawValue], or null if it is not a profile link.
  ///
  /// Deliberately tolerant about *where* the link points: only the path shape
  /// is checked, not the host. A profile is public to any signed-in user, so a
  /// link served from somewhere else grants nothing that scanning the
  /// canonical one would not — and being strict would break the moment the
  /// hosting domain changed, silently, on already-printed QR codes.
  static String? userIdFrom(String? rawValue) {
    if (rawValue == null) return null;

    final uri = Uri.tryParse(rawValue);
    if (uri == null) return null;

    final segments = uri.pathSegments;
    if (segments.length < 2 || segments.first != _profileSegment) return null;

    final userId = segments[1];
    return userId.isEmpty ? null : userId;
  }
}
