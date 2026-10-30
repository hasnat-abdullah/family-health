import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Shrinks images for profile pictures and AI uploads. Decoding goes through the
/// platform, which understands HEIC and applies EXIF rotation.
class ImageTools {
  static Future<Uint8List> toJpeg(Uint8List encoded, {required int maxSide, int quality = 85}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = descriptor.width > descriptor.height ? descriptor.width : descriptor.height;
    final scale = longest > maxSide ? maxSide / longest : 1.0;
    final codec = await descriptor.instantiateCodec(targetWidth: (descriptor.width * scale).round(), targetHeight: (descriptor.height * scale).round());
    final image = (await codec.getNextFrame()).image;
    try {
      final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      return await rgbaToJpeg(rgba, image.width, image.height, quality);
    } finally {
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  static Future<Uint8List> rgbaToJpeg(Uint8List rgba, int width, int height, int quality) => Isolate.run(() {
    final image = img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4);
    // JPEG has no transparency; paper is white.
    final flat = img.Image(width: width, height: height)..clear(img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, image);
    return img.encodeJpg(flat, quality: quality);
  });
}
