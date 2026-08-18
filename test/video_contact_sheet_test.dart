import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:privatelm/services/video_contact_sheet.dart';

/// Writes a solid-colour JPEG and returns its path — stands in for a frame the
/// platform decoder handed back.
String _frame(Directory dir, String name, int w, int h, img.ColorRgb8 colour) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: colour);
  final path = '${dir.path}/$name.jpg';
  File(path).writeAsBytesSync(img.encodeJpg(image));
  return path;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sheet_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('four frames compose into a 2x2 sheet within the size budget', () {
    final frames = [
      _frame(tmp, 'a', 640, 360, img.ColorRgb8(255, 0, 0)),
      _frame(tmp, 'b', 640, 360, img.ColorRgb8(0, 255, 0)),
      _frame(tmp, 'c', 640, 360, img.ColorRgb8(0, 0, 255)),
      _frame(tmp, 'd', 640, 360, img.ColorRgb8(255, 255, 0)),
    ];

    final bytes = VideoContactSheet.compose(frames);
    expect(bytes, isNotNull);

    final sheet = img.decodeImage(bytes!)!;
    expect(sheet.width, VideoContactSheet.sheetMaxEdge);
    // 16:9 frames in a 2-wide grid: each cell is half the width, two rows tall.
    expect(sheet.height, closeTo(VideoContactSheet.sheetMaxEdge * 9 / 16, 2));
  });

  test('a single frame is passed through, not gridded', () {
    final bytes = VideoContactSheet.compose(
      [_frame(tmp, 'only', 320, 240, img.ColorRgb8(10, 20, 30))],
    );
    final sheet = img.decodeImage(bytes!)!;
    expect(sheet.width, 320);
    expect(sheet.height, 240);
  });

  test('an oversized single frame is scaled down to the budget', () {
    final bytes = VideoContactSheet.compose(
      [_frame(tmp, 'big', 4000, 2000, img.ColorRgb8(1, 2, 3))],
    );
    final sheet = img.decodeImage(bytes!)!;
    expect(sheet.width, VideoContactSheet.sheetMaxEdge);
  });

  test('no readable frames yields null rather than a blank attachment', () {
    final bogus = '${tmp.path}/not-an-image.jpg';
    File(bogus).writeAsStringSync('this is not a JPEG');
    expect(VideoContactSheet.compose([bogus]), isNull);
    expect(VideoContactSheet.compose([]), isNull);
  });
}
