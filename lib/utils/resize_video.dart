import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/utils/video/video_bridge.dart';
import 'package:matrix/matrix.dart';

extension ResizeVideo on XFile {
  /// Video ready to be sent to Matrix. Compression goes through the native
  /// Media3 bridge (`VideoBridge`); `video_compress` used to hang forever on
  /// heavy files. Throws [VideoCompressionException] when compression fails or
  /// is cancelled — the sender shows a retry instead of a dead spinner.
  Future<MatrixVideoFile> getVideoInfo({bool compress = true}) async {
    if (compress) {
      final job = await VideoBridge.instance.start(path, compress: true);
      if (job != null) {
        final result = await VideoBridge.instance.waitFor(job.jobId);
        return MatrixVideoFile(
          bytes: await XFile(result.outputPath).readAsBytes(),
          name: name,
          mimeType: mimeType,
          width: result.width,
          height: result.height,
          duration: (result.durationMs / 1000).round(),
        );
      }
    }
    // Pas de compression (interrupteur de la boîte d'envoi) ou pont natif
    // indisponible : métadonnées lues nativement, octets tels quels.
    final meta = await VideoBridge.instance.meta(path);
    return MatrixVideoFile(
      bytes: await readAsBytes(),
      name: name,
      mimeType: mimeType,
      width: meta?.width,
      height: meta?.height,
      duration: meta == null ? null : (meta.durationMs / 1000).round(),
    );
  }

  Future<MatrixImageFile?> getVideoThumbnail() async {
    try {
      final bytes = await VideoBridge.instance.thumbnail(path);
      if (bytes == null) return null;
      return MatrixImageFile(bytes: bytes, name: name);
    } on Object catch (e, s) {
      Logs().w('Error while fetching video thumbnail', e, s);
      return null;
    }
  }
}
