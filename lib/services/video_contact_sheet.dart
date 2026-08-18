import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Lays video frames out as a single grid image.
///
/// The whole attachment path — picker, preview bubble, `generate(imagePath:)`,
/// the cloud encoder — carries exactly one image. Rather than widen all of that
/// to a list for one file type, the frames are composited into one picture, in
/// playback order, left to right and top to bottom. Vision models read a contact
/// sheet perfectly well, and it costs the model one image encode instead of N.
class VideoContactSheet {
  /// Long edge of the finished sheet. Matches the ballpark the vision path
  /// already resizes single images to; larger just wastes encode time.
  static const sheetMaxEdge = 1024;

  /// Composite [framePaths] into a JPEG and return its bytes.
  ///
  /// Returns null when nothing could be decoded — the caller then reports the
  /// video as unreadable instead of attaching a blank image.
  static Uint8List? compose(List<String> framePaths) {
    final frames = <img.Image>[];
    for (final path in framePaths) {
      final decoded = img.decodeImage(File(path).readAsBytesSync());
      if (decoded != null) frames.add(decoded);
    }
    if (frames.isEmpty) return null;
    if (frames.length == 1) {
      return Uint8List.fromList(img.encodeJpg(_fit(frames.first, sheetMaxEdge), quality: 85));
    }

    // Square-ish grid: 4 frames -> 2x2, 6 -> 3x2, 2 -> 2x1.
    final columns = (frames.length <= 2) ? frames.length : (frames.length / 2).ceil();
    final rows = (frames.length / columns).ceil();

    // Every cell is the same size, so a frame keeps its aspect ratio inside its
    // cell and is centred — stretching frames to fill would distort whatever the
    // model is being asked to read.
    final cellW = (sheetMaxEdge / columns).floor();
    final cellH = (sheetMaxEdge / columns * frames.first.height / frames.first.width).floor();

    final sheet = img.Image(width: cellW * columns, height: cellH * rows);
    img.fill(sheet, color: img.ColorRgb8(0, 0, 0));

    for (var i = 0; i < frames.length; i++) {
      final scaled = _fitBox(frames[i], cellW, cellH);
      final col = i % columns;
      final row = i ~/ columns;
      img.compositeImage(
        sheet,
        scaled,
        dstX: col * cellW + (cellW - scaled.width) ~/ 2,
        dstY: row * cellH + (cellH - scaled.height) ~/ 2,
      );
    }

    return Uint8List.fromList(img.encodeJpg(sheet, quality: 85));
  }

  static img.Image _fit(img.Image src, int maxEdge) {
    final longEdge = src.width > src.height ? src.width : src.height;
    if (longEdge <= maxEdge) return src;
    return src.width >= src.height
        ? img.copyResize(src, width: maxEdge)
        : img.copyResize(src, height: maxEdge);
  }

  static img.Image _fitBox(img.Image src, int boxW, int boxH) {
    final scale = (boxW / src.width) < (boxH / src.height)
        ? boxW / src.width
        : boxH / src.height;
    return img.copyResize(
      src,
      width: (src.width * scale).floor().clamp(1, boxW),
      height: (src.height * scale).floor().clamp(1, boxH),
    );
  }
}
