import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/image_upload_service.dart';

/// The upload validator. CLAUDE.md lists this under "Security & performance —
/// non-negotiable": every user-supplied file must be checked for size, a
/// permitted extension, a *sniffed* MIME type, and agreement between the two.
/// It had no tests at all.
///
/// The interesting cases are the ones where the two signals disagree — a
/// `.png` whose bytes are something else entirely — because an extension is
/// attacker-controlled and the magic bytes are the only thing that is not.
/// Real temp files are used rather than a mocked filesystem: the validator
/// reads the first 12 bytes off disk, and that read is the thing under test.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dash_upload_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// The first bytes of each format, which is all `lookupMimeType` reads.
  final png = Uint8List.fromList(
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]);
  final jpeg = Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1]);
  final gif = Uint8List.fromList(
      [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0]);
  final webp = Uint8List.fromList([
    0x52, 0x49, 0x46, 0x46, 0x1A, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
  ]);

  /// Writes [bytes] to [name] and validates it under that same name.
  Future<String?> check(String name, List<int> bytes) async {
    final file = File('${tmp.path}/$name');
    await file.writeAsBytes(bytes);
    return ImageUploadService.validate(file, name);
  }

  group('accepts real images', () {
    test('a PNG named .png', () async {
      expect(await check('avatar.png', png), isNull);
    });

    test('a JPEG named .jpg', () async {
      expect(await check('avatar.jpg', jpeg), isNull);
    });

    test('a JPEG named .jpeg', () async {
      // Both spellings map to image/jpeg, so the validator carries an explicit
      // alias for them; without it one of the two would be rejected.
      expect(await check('avatar.jpeg', jpeg), isNull);
    });

    test('a WebP named .webp', () async {
      expect(await check('avatar.webp', webp), isNull);
    });

    test('a HEIC named .heic — the default iPhone photo format', () async {
      // Guards the sniffing fix below: it works by refusing to fall back to
      // the extension, which would break every allowed format that has no
      // magic number. HEIC does have one (an ISO-BMFF `ftyp` box with a
      // `heic` brand), and this is the test that says so.
      final heic = <int>[
        0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, // size + 'ftyp'
        0x68, 0x65, 0x69, 0x63, //               'heic'
      ];
      expect(await check('photo.heic', heic), isNull);
    });
  });

  group('size', () {
    test('rejects a file over 5 MB', () async {
      final big = Uint8List(5 * 1024 * 1024 + 1)
        ..setRange(0, png.length, png);
      final error = await check('big.png', big);

      expect(error, isNotNull);
      expect(error, contains('5MB'));
    });

    test('accepts a file just under the cap', () async {
      final ok = Uint8List(5 * 1024 * 1024 - 1)..setRange(0, png.length, png);
      expect(await check('ok.png', ok), isNull);
    });

    test('rejects an empty file', () async {
      // Zero bytes sniff as nothing, so this would otherwise fall through to
      // the content check with a confusing message.
      final error = await check('empty.png', <int>[]);
      expect(error, contains('vuoto'));
    });
  });

  group('the file must exist', () {
    test('a missing file is rejected rather than thrown on', () async {
      final missing = File('${tmp.path}/nope.png');
      expect(await ImageUploadService.validate(missing, 'nope.png'), isNotNull);
    });
  });

  group('extension allow-list', () {
    test('rejects an executable even with image bytes', () async {
      // The bytes are a valid PNG; the extension is what makes this dangerous.
      final error = await check('payload.exe', png);
      expect(error, contains('Formato non supportato'));
    });

    test('rejects an SVG, which is script-capable', () async {
      final error = await check('logo.svg', '<svg></svg>'.codeUnits);
      expect(error, contains('Formato non supportato'));
    });

    test('rejects a GIF, which is not on the list', () async {
      final error = await check('anim.gif', gif);
      expect(error, contains('Formato non supportato'));
    });

    test('is case-insensitive, so .PNG is fine', () async {
      expect(await check('AVATAR.PNG', png), isNull);
    });

    test('rejects a file with no extension at all', () async {
      expect(await check('avatar', png), contains('Nome file non valido'));
    });
  });

  group('content sniffing beats the extension', () {
    test('rejects a text file wearing a .png name', () async {
      // The case the sniffing exists for: an extension is attacker-controlled,
      // the magic bytes are not.
      final error = await check('not-an-image.png', 'hello world'.codeUnits);
      expect(error, contains("contenuto del file non è un'immagine"));
    });

    test('rejects an ELF binary wearing a .png name', () async {
      final elf = <int>[0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0];
      final error = await check('payload.png', elf);
      expect(error, isNotNull);
    });

    test('rejects a GIF wearing a .png name', () async {
      // Both are images and GIF would fail the allow-list anyway — this is
      // specifically the cross-check between a *permitted* extension and
      // different real content.
      final error = await check('sneaky.png', gif);
      expect(error, isNotNull);
    });

    test('rejects a real JPEG mislabelled .png', () async {
      // Harmless in itself, but it is the same disagreement the check exists
      // to catch, and it must not be waved through by the jpg/jpeg alias.
      final error = await check('mislabelled.png', jpeg);
      expect(error, contains('non corrispondono'));
    });

    test('rejects a real PNG mislabelled .webp', () async {
      expect(await check('mislabelled.webp', png), contains('non corrispondono'));
    });
  });

  group('the filename itself', () {
    test('a directory traversal attempt is judged on its base name', () async {
      // `_validate` splits on '/' and keeps the last segment, so the traversal
      // cannot smuggle in a second extension. The upload path is built from
      // the uid server-side regardless, but this is the first line.
      final file = File('${tmp.path}/avatar.png');
      await file.writeAsBytes(png);

      expect(await ImageUploadService.validate(file, '../../etc/avatar.png'),
          isNull);
    });

    test('a double extension is rejected outright', () async {
      // `parts.length != 2` means anything with more than one dot fails,
      // which stops `avatar.png.exe` — at the cost of also rejecting an
      // innocent `my.photo.png`. See the note in TEST_NOTES.
      expect(await check('avatar.png.exe', png), contains('Nome file non valido'));
    });

    test('an innocent name with two dots is rejected too', () async {
      // Documented so the trade-off above is visible rather than surprising.
      final file = File('${tmp.path}/holiday.png');
      await file.writeAsBytes(png);

      expect(await ImageUploadService.validate(file, 'my.holiday.png'),
          contains('Nome file non valido'));
    });
  });
}
