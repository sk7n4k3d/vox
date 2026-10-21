import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/utils/client_download_content_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:fluffychat/utils/media/media_exporter.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

class MxcImage extends StatefulWidget {
  final Uri? uri;
  final Event? event;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final bool isThumbnail;
  final bool animated;
  final Duration retryDuration;
  final Duration animationDuration;
  final Curve animationCurve;
  final ThumbnailMethod thumbnailMethod;
  final Widget Function(BuildContext context)? placeholder;
  final String? cacheKey;
  final Client? client;
  final BorderRadius borderRadius;

  const MxcImage({
    this.uri,
    this.event,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.isThumbnail = true,
    this.animated = false,
    this.animationDuration = FluffyThemes.animationDuration,
    this.retryDuration = const Duration(seconds: 2),
    this.animationCurve = FluffyThemes.animationCurve,
    this.thumbnailMethod = ThumbnailMethod.scale,
    this.cacheKey,
    this.client,
    this.borderRadius = BorderRadius.zero,
    super.key,
  });

  @override
  State<MxcImage> createState() => _MxcImageState();
}

class _MxcImageState extends State<MxcImage> {
  static final Map<String, Uint8List> _imageDataCache = {};
  Uint8List? _imageDataNoCache;

  Uint8List? get _imageData => widget.cacheKey == null
      ? _imageDataNoCache
      : _imageDataCache[widget.cacheKey];

  set _imageData(Uint8List? data) {
    if (data == null) return;
    final cacheKey = widget.cacheKey;
    cacheKey == null
        ? _imageDataNoCache = data
        : _imageDataCache[cacheKey] = data;
  }

  Future<void> _load() async {
    if (!mounted) return;
    final client =
        widget.client ?? widget.event?.room.client ?? Matrix.of(context).client;
    final uri = widget.uri;
    final event = widget.event;

    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final width = widget.width;
    final realWidth = width == null ? null : width * devicePixelRatio;
    final height = widget.height;
    final realHeight = height == null ? null : height * devicePixelRatio;

    if (uri != null) {
      final remoteData = await client.downloadMxcCached(
        uri,
        width: realWidth,
        height: realHeight,
        thumbnailMethod: widget.thumbnailMethod,
        isThumbnail: widget.isThumbnail,
        animated: widget.animated,
      );
      if (!mounted) return;
      setState(() {
        _imageData = remoteData;
      });
    }

    if (event != null) {
      final loaded = await _loadEventMedia(
        client,
        realWidth: realWidth,
        realHeight: realHeight,
      );
      if (loaded == null) return;
      if (!mounted) return;
      setState(() {
        _imageData = loaded.bytes;
      });
      if (!widget.isThumbnail && loaded.file != null) {
        unawaited(MediaExporter.instance.exportMatrixEvent(event, loaded.file!));
      }
      return;
    }
  }

  /// Charge le média porté par l'event à la meilleure qualité possible.
  ///
  /// L'event transporte souvent une miniature minuscule (96x96 px sur Synapse,
  /// 320x240 sur Element X) : la rendre telle quelle dans une bulle de
  /// 400x300 = gros pixelisé. La chaîne de chargement est donc, par ordre de
  /// préférence :
  /// 1. média NON chiffré : miniature à la taille d'affichage générée par le
  ///    serveur (il la met en cache) ;
  /// 2. miniature de l'event, si elle est déjà assez grande pour l'affichage ;
  /// 3. fichier complet (déchiffré si besoin), que le widget décode à la
  ///    taille d'affichage : net, mais plus coûteux en data (le SDK le met en
  ///    cache disque, donc payé une seule fois par média).
  Future<({Uint8List bytes, MatrixFile? file})?> _loadEventMedia(
    Client client, {
    num? realWidth,
    num? realHeight,
  }) async {
    final event = widget.event!;
    final displayPx = [
      realWidth,
      realHeight,
    ].whereType<num>().fold<num>(0, (a, b) => a > b ? a : b);

    if (widget.isThumbnail) {
      // 1) média non chiffré : le serveur sait re-dimensionner.
      if (!event.isAttachmentEncrypted && displayPx > 0) {
        final attachmentUri = event.attachmentMxcUrl;
        if (attachmentUri != null) {
          try {
            final sized = await client.downloadMxcCached(
              attachmentUri,
              width: realWidth,
              height: realHeight,
              thumbnailMethod: widget.thumbnailMethod,
              isThumbnail: true,
              animated: widget.animated,
            );
            return (bytes: sized, file: null);
          } catch (_) {
            // Le serveur ne sait pas (ou ne veut pas) produire cette miniature.
          }
        }
      }
      // 2) la miniature de l'event suffit-elle ? Une image trop petite ne
      //    peut pas être agrandie proprement : on part alors sur le fichier
      //    complet. (Les vidéos gardent leur miniature : télécharger le film
      //    pour une vignette serait absurde.)
      final thumbPx = _eventThumbnailSize(event);
      final isImage = event.attachmentMimetype.startsWith('image/');
      if (!isImage || (thumbPx > 0 && thumbPx >= displayPx * 0.5)) {
        final thumb = await event.downloadAndDecryptAttachment(
          getThumbnail: true,
        );
        if (thumb.detectFileType is MatrixImageFile || widget.isThumbnail) {
          return (bytes: thumb.bytes, file: thumb);
        }
        return null;
      }
      // 3) image dont la miniature est trop petite : on prend le fichier
      //    complet, que le widget décodera à la taille d'affichage.
    }
    final data = await event.downloadAndDecryptAttachment(
      getThumbnail: widget.isThumbnail,
    );
    if (data.detectFileType is MatrixImageFile || widget.isThumbnail) {
      return (bytes: data.bytes, file: data);
    }
    return null;
  }

  /// Taille en px (côté long) de la miniature portée par l'event, 0 si
  /// inconnue ou absente.
  int _eventThumbnailSize(Event event) {
    final info = event.thumbnailInfoMap;
    final w = info['w'];
    final h = info['h'];
    if (w is int && h is int) return w > h ? w : h;
    return 0;
  }

  Future<void> _tryLoad() async {
    if (_imageData != null) {
      return;
    }
    try {
      await _load();
    } on IOException catch (_) {
      if (!mounted) return;
      await Future.delayed(widget.retryDuration);
      _tryLoad();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryLoad());
  }

  @override
  Widget build(BuildContext context) {
    final data = _imageData;
    final hasData = data != null && data.isNotEmpty;

    return AnimatedSwitcher(
      duration: FluffyThemes.animationDuration,
      child: hasData
          ? ClipRRect(
              borderRadius: widget.borderRadius,
              child: Image.memory(
                data,
                width: widget.width,
                height: widget.height,
                fit: widget.fit,
                // Décode à la taille d'affichage (en pixels physiques) au lieu
                // de décoder la photo entière : une image de 12 Mpx = 48 Mo de
                // texture GPU pour une bulle de 400x300, et un
                // ré-échantillonnage sans mipmap (FilterQuality.low) qui
                // aliasse violemment les images réduites.
                cacheWidth: widget.width == null
                    ? null
                    : (widget.width! * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, e, s) {
                  Logs().d('Unable to render mxc image', e, s);
                  return SizedBox(
                    width: widget.width,
                    height: widget.height,
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: min(widget.height ?? 64, 64),
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  );
                },
              ),
            )
          : _MxcImagePlaceholder(
              width: widget.width,
              height: widget.height,
              placeholder: widget.placeholder,
            ),
    );
  }
}

class _MxcImagePlaceholder extends StatelessWidget {
  final double? width;
  final double? height;
  final Widget Function(BuildContext context)? placeholder;

  const _MxcImagePlaceholder({
    required this.width,
    required this.height,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return placeholder?.call(context) ??
        Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          child: const CircularProgressIndicator.adaptive(strokeWidth: 2),
        );
  }
}
