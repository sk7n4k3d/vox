import 'dart:async';
import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors received Matrix image/video attachments into the Android public
/// MediaStore (Pictures/VOX, Movies/VOX) through the native SMS bridge, so
/// gallery clients such as Nextcloud auto-upload them. Gated by
/// [AppSettings.autoExportMedia] and deduplicated by event id (persisted,
/// FIFO-capped). Best-effort: never throws, never blocks playback.
class MediaExporter {
  MediaExporter._();
  static final MediaExporter instance = MediaExporter._();

  static const String _prefsKey = 'chat.fluffy.exported.matrix_events';
  static const int _maxEntries = 2000;

  /// Message types whose incoming attachments are exported on receipt.
  /// A sticker is an image, so it belongs to this set — the same set
  /// the timeline renders through MxcImage / the video player.
  static const Set<String> _autoExportMessageTypes = {
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Sticker,
  };

  List<String>? _exported;
  Future<void>? _loadFuture;

  Future<void> _ensureLoaded() =>
      _loadFuture ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          _exported = List<String>.of(
            prefs.getStringList(_prefsKey) ?? const [],
          );
        } catch (_) {
          _exported = <String>[];
        }
      }();

  /// Exports the (already downloaded/decrypted) [file] of [event] when it is an
  /// image or a video received from someone else. No-op otherwise.
  Future<void> exportMatrixEvent(Event event, MatrixFile file) async {
    try {
      if (!AppSettings.autoExportMedia.value) return;
      if (!PlatformInfos.isAndroid) return;
      final mime = file.mimeType.toLowerCase();
      if (!mime.startsWith('image/') && !mime.startsWith('video/')) return;
      if (event.senderId == event.room.client.userID) return;

      await _ensureLoaded();
      final exported = _exported ?? <String>[];
      if (exported.contains(event.eventId)) return;

      final tmpDir = await getTemporaryDirectory();
      final dir = Directory('${tmpDir.path}/vox_export');
      if (!await dir.exists()) await dir.create(recursive: true);
      final safeName = file.name.isEmpty ? 'vox_${event.eventId}' : file.name;
      final tmp = File(
        '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$safeName',
      );
      await tmp.writeAsBytes(file.bytes, flush: false);

      final uri = await SmsBridge.instance.exportMediaFile(
        tmp.path,
        file.mimeType,
        safeName,
      );
      unawaited(tmp.delete().then((_) {}, onError: (_) {}));

      if (uri == null) return;
      exported.add(event.eventId);
      while (exported.length > _maxEntries) {
        exported.removeAt(0);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, exported);
    } catch (e) {
      debugPrint('MediaExporter: matrix export failed: $e');
    }
  }

  /// Receive-path entry point: called for every incoming timeline event
  /// ([Client.onTimelineEvent], fired after decryption). Downloads the
  /// attachment of an incoming image/video message and mirrors it into
  /// the public MediaStore, without the user having to open the
  /// conversation first. The display-time hooks (MxcImage, video
  /// player) keep calling [exportMatrixEvent]; the event-id dedup here
  /// and the native content-hash dedup make the two paths overlap-safe.
  Future<void> exportIncomingEvent(Event event) async {
    try {
      if (!AppSettings.autoExportMedia.value) return;
      if (!PlatformInfos.isAndroid) return;
      if (event.redacted) return;
      if (event.senderId == event.room.client.userID) return;
      if (!_autoExportMessageTypes.contains(event.messageType)) return;

      await _ensureLoaded();
      if ((_exported ?? const []).contains(event.eventId)) return;

      final file = await event.downloadAndDecryptAttachment();
      await exportMatrixEvent(event, file);
    } catch (e) {
      debugPrint('MediaExporter: matrix receive export failed: $e');
    }
  }
}
