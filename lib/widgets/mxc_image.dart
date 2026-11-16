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

  /// Nombre de tentatives de chargement (la boucle de retry est plafonnée :
  /// sinon un média inaccessible fait saturer le réseau en boucle).
  int _retries = 0;

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

  /// Charge le média et l'affiche.
  ///
  /// Deux temps, pour ne JAMAIS bloquer l'interface sur un téléchargement :
  /// 1. la source rapide (miniature du serveur pour un mxc, miniature de
  ///    l'event sinon) s'affiche tout de suite ;
  /// 2. une version plus nette est demandée en tâche de fond et remplacera la
  ///    première quand elle arrive (cf. [_loadSharperVersion]).
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

    // 1) mxc : le serveur sait générer une miniature à la bonne taille.
    if (uri != null) {
      try {
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
        return;
      } catch (e) {
        Logs().w('MxcImage: miniature serveur indisponible', e);
      }
    }

    if (event == null) return;

    // 2) la miniature portée par l'event : rapide, toujours disponible.
    try {
      final data = await event.downloadAndDecryptAttachment(
        getThumbnail: widget.isThumbnail,
      );
      if (data.detectFileType is MatrixImageFile || widget.isThumbnail) {
        if (!mounted) return;
        setState(() {
          _imageData = data.bytes;
        });
        if (!widget.isThumbnail) {
          unawaited(MediaExporter.instance.exportMatrixEvent(event, data));
        }
      }
    } catch (e) {
      Logs().w('MxcImage: miniature de l\'event indisponible', e);
      return;
    }

    // 3) version plus nette, en tâche de fond (l'UI n'attend pas).
    if (widget.isThumbnail) {
      _enqueueUpgrade(
        () => _loadSharperVersion(client, realWidth, realHeight),
      );
    }
  }

  /// File d'attente des améliorations : une seule à la fois, sinon un cache
  /// vidé triggers une rafale de téléchargements (le serveur sature et
  /// l'app gèle au démarrage).
  static Future<void> _upgradeQueue = Future<void>.value();

  static void _enqueueUpgrade(Future<void> Function() job) {
    _upgradeQueue = _upgradeQueue.then((_) => job()).catchError((_) {});
  }

  /// Demande une version plus nette de l'image de l'event, sans jamais
  /// bloquer l'interface.
  ///
  /// L'event transporte souvent une miniature minuscule (96x96 px sur Synapse,
  /// 320x240 sur Element X) : la rendre telle quelle dans une bulle de
  /// 400x300 = gros pixelisé.
  ///  - média NON chiffré : on demande au serveur une miniature à la taille
  ///    d'affichage (il la génère et la met en cache) ;
  ///  - média CHIFFRÉ : le serveur ne voit que du chiffre, il ne peut pas
  ///    re-dimensionner → on prend le fichier complet (déchiffré par le SDK,
  ///    mis en cache disque) et le widget le décode à la taille d'affichage.
  Future<void> _loadSharperVersion(
    Client client,
    num? realWidth,
    num? realHeight,
  ) async {
    final event = widget.event;
    if (event == null) return;
    final displayPx = [
      realWidth,
      realHeight,
    ].whereType<num>().fold<num>(0, (a, b) => a > b ? a : b);
    if (displayPx <= 0) return;
    final isImage = event.attachmentMimetype.startsWith('image/');
    final isVideo = event.attachmentMimetype.startsWith('video/');
    // Un fichier non-image/non-vidéo : on garde la miniature de l'event.
    if (!isImage && !isVideo) return;
    // La miniature est déjà assez grande pour l'affichage : rien à faire.
    final thumbPx = _eventThumbnailSize(event);
    if (thumbPx > 0 && thumbPx >= displayPx * 0.5) return;

    try {
      final Uint8List? better;
      if (!event.isAttachmentEncrypted) {
        // Média non chiffré : le serveur peut re-dimensionner (image nette
        // générée ; pour une vidéo, une miniature réelle si le serveur sait
        // extraire une frame — sinon il rend une erreur et on garde ce qu'on
        // a déjà).
        final attachmentUri = event.attachmentMxcUrl;
        if (attachmentUri == null) return;
        better = await client
            .downloadMxcCached(
              attachmentUri,
              width: realWidth,
              height: realHeight,
              thumbnailMethod: widget.thumbnailMethod,
              isThumbnail: true,
              animated: widget.animated,
            )
            .timeout(const Duration(seconds: 20));
        // Garde-fou vidéo : certains serveurs rendent l'original quand ils ne
        // savent pas thumbscanner. Une vignette de > 2 Mo est un gaspillage
        // réseau, on la jette.
        if (isVideo && better.length > 2 * 1024 * 1024) return;
      } else if (isImage) {
        // Vidéo chiffrée : le serveur ne voit que du chiffre et télécharger
        // le film pour une vignette serait absurde → on garde la miniature.
        final size = event.infoMap['size'];
        if (size is int && size > 8 * 1024 * 1024) return; // trop lourd
        final full = await event
            .downloadAndDecryptAttachment(getThumbnail: false)
            .timeout(const Duration(seconds: 30));
        better = full.bytes;
      } else {
        return;
      }
      if (better.isEmpty || !mounted) return;
      setState(() {
        _imageData = better;
      });
    } catch (e) {
      Logs().w('MxcImage: version plus nette indisponible', e);
    }
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
    // Au bout de quelques échecs on abandonne : une boucle de retry infinie
    // sature le réseau et laisse l'app sur un écran de chargement.
    if (_retries >= 3) return;
    try {
      await _load();
    } on IOException catch (_) {
      if (!mounted) return;
      _retries++;
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
