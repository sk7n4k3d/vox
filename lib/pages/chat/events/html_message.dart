import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/pages/chat/events/code_block_widget.dart';
import 'package:fluffychat/utils/event_checkbox_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:matrix/matrix.dart';

import '../../../utils/url_launcher.dart';

/// LRU cache for parsed HTML bodies — bounded to [_kHtmlCacheCap] entries
/// keyed by `identityHashCode(html)` + `html.length`. Memoization avoids
/// re-parsing the same message HTML on every scroll/rebuild (audit
/// AUDIT-FLUFFYCHAT-FORK-2026-05-23 finding-010).
const int _kHtmlCacheCap = 256;
final LinkedHashMap<String, dom.Element> _htmlCache =
    LinkedHashMap<String, dom.Element>();

dom.Element _parseHtmlCached(String html) {
  final key = '${html.length}:${html.hashCode}';
  final cached = _htmlCache[key];
  if (cached != null) {
    // Refresh LRU recency.
    _htmlCache.remove(key);
    _htmlCache[key] = cached;
    return cached;
  }
  final parsed = parser.parse(html).body ?? dom.Element.html('');
  if (_htmlCache.length >= _kHtmlCacheCap) {
    _htmlCache.remove(_htmlCache.keys.first);
  }
  _htmlCache[key] = parsed;
  return parsed;
}

class HtmlMessage extends StatelessWidget {
  final String html;
  final Room room;
  final Color textColor;
  final double fontSize;
  final TextStyle linkStyle;
  final void Function(LinkableElement) onOpen;
  final String? eventId;
  final Set<Event>? checkboxCheckedEvents;
  final bool limitHeight;

  const HtmlMessage({
    super.key,
    required this.html,
    required this.room,
    required this.fontSize,
    required this.linkStyle,
    this.textColor = Colors.black,
    required this.onOpen,
    this.eventId,
    this.checkboxCheckedEvents,
    this.limitHeight = true,
  });

  /// Keep in sync with: https://spec.matrix.org/latest/client-server-api/#mroommessage-msgtypes
  static const Set<String> allowedHtmlTags = {
    'font',
    'del',
    's',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'blockquote',
    'p',
    'a',
    'ul',
    'ol',
    'sup',
    'sub',
    'li',
    'b',
    'i',
    'u',
    'strong',
    'em',
    'strike',
    'code',
    'hr',
    'br',
    'div',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
    'caption',
    'pre',
    'span',
    'img',
    'details',
    'summary',
    // Not in the allowlist of the matrix spec yet but should be harmless:
    'ruby',
    'rp',
    'rt',
    'html',
    'body',
  };

  static const Set<String> ignoredHtmlTags = {'mx-reply'};

  /// We add line breaks before these tags:
  static const Set<String> blockHtmlTags = {
    'p',
    'ul',
    'ol',
    'pre',
    'div',
    'table',
    'details',
    'blockquote',
  };

  /// We add line breaks before these tags:
  static const Set<String> fullLineHtmlTag = {
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
  };

  /// Adding line breaks before block elements.
  List<InlineSpan> _renderWithLineBreaks(
    dom.NodeList nodes,
    BuildContext context, {
    int depth = 1,
  }) {
    final onlyElements = nodes.whereType<dom.Element>().toList();
    return [
      for (var i = 0; i < nodes.length; i++) ...[
        // Actually render the node child:
        _renderHtml(nodes[i], context, depth: depth + 1),
        // Add linebreaks between blocks:
        if (nodes[i] is dom.Element &&
            onlyElements.indexOf(nodes[i] as dom.Element) <
                onlyElements.length - 1) ...[
          if (blockHtmlTags.contains((nodes[i] as dom.Element).localName))
            const TextSpan(text: '\n\n'),
          if (fullLineHtmlTag.contains((nodes[i] as dom.Element).localName))
            const TextSpan(text: '\n'),
        ],
      ],
    ];
  }

  /// Transforms a Node to an InlineSpan.
  InlineSpan _renderHtml(dom.Node node, BuildContext context, {int depth = 1}) {
    // We must not render elements nested more than 100 elements deep:
    if (depth >= 100) return const TextSpan();

    if (node is dom.Element &&
        ignoredHtmlTags.contains(node.localName?.toLowerCase())) {
      return const TextSpan();
    }

    // This is a text node or not permitted node, so we render it as text:
    if (node is! dom.Element || !allowedHtmlTags.contains(node.localName)) {
      var text = node.text ?? '';
      // Single linebreak nodes between Elements are ignored:
      if (text == '\n') text = '';

      return LinkifySpan(
        text: text,
        options: const LinkifyOptions(humanize: false),
        linkStyle: linkStyle,
        onOpen: onOpen,
      );
    }

    switch (node.localName) {
      case 'br':
        return const TextSpan(text: '\n');
      case 'a':
        final href = node.attributes['href'];
        if (href == null) continue block;
        final matrixId = node.attributes['href']
            ?.parseIdentifierIntoParts()
            ?.primaryIdentifier;
        if (matrixId != null) {
          if (matrixId.sigil == '@') {
            final user = room.unsafeGetUserFromMemoryOrFallback(matrixId);
            return WidgetSpan(
              child: MatrixPill(
                key: Key('user_pill_$matrixId'),
                name: user.calcDisplayname(),
                avatar: user.avatarUrl,
                uri: href,
                outerContext: context,
                fontSize: fontSize,
                color: linkStyle.color,
              ),
            );
          }
          if (matrixId.sigil == '#' || matrixId.sigil == '!') {
            final room = matrixId.sigil == '!'
                ? this.room.client.getRoomById(matrixId)
                : this.room.client.getRoomByAlias(matrixId);
            return WidgetSpan(
              child: MatrixPill(
                name: room?.getLocalizedDisplayname() ?? matrixId,
                avatar: room?.avatar,
                uri: href,
                outerContext: context,
                fontSize: fontSize,
                color: linkStyle.color,
              ),
            );
          }
        }
        return WidgetSpan(
          child: Tooltip(
            message: href,
            child: InkWell(
              splashColor: Colors.transparent,
              onTap: () => UrlLauncher(context, href, node.text).launchUrl(),
              child: Text.rich(
                TextSpan(
                  children: _renderWithLineBreaks(
                    node.nodes,
                    context,
                    depth: depth,
                  ),
                  style: linkStyle,
                ),
                style: const TextStyle(height: 1.25),
              ),
            ),
          ),
        );
      case 'li':
        if (!{'ol', 'ul'}.contains(node.parent?.localName)) {
          continue block;
        }
        final eventId = this.eventId;

        final isCheckbox = node.className == 'task-list-item';
        final checkboxIndex = isCheckbox
            ? node.rootElement
                      .getElementsByClassName('task-list-item')
                      .indexOf(node) +
                  1
            : null;
        final checkedByReaction = !isCheckbox
            ? null
            : checkboxCheckedEvents?.firstWhereOrNull(
                (event) => event.checkedCheckboxId == checkboxIndex,
              );
        final staticallyChecked =
            isCheckbox && node.children.first.attributes['checked'] == 'true';

        return WidgetSpan(
          child: Padding(
            padding: EdgeInsets.only(left: fontSize),
            child: Text.rich(
              TextSpan(
                children: [
                  if (!isCheckbox) ...[
                    if (node.parent?.localName == 'ul')
                      const TextSpan(text: '• '),
                    if (node.parent?.localName == 'ol')
                      TextSpan(
                        text:
                            '${(node.parent?.nodes.whereType<dom.Element>().toList().indexOf(node) ?? 0) + (int.tryParse(node.parent?.attributes['start'] ?? '1') ?? 1)}. ',
                      ),
                  ],
                  if (node.className == 'task-list-item')
                    WidgetSpan(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: SizedBox.square(
                          dimension: fontSize + 2,
                          child: CupertinoCheckbox(
                            checkColor: textColor,
                            side: BorderSide(color: textColor),
                            activeColor: textColor.withAlpha(64),
                            value:
                                staticallyChecked || checkedByReaction != null,
                            onChanged:
                                eventId == null ||
                                    checkboxIndex == null ||
                                    staticallyChecked ||
                                    !room.canSendDefaultMessages ||
                                    (checkedByReaction != null &&
                                        checkedByReaction.senderId !=
                                            room.client.userID)
                                ? null
                                : (_) => showFutureLoadingDialog(
                                    context: context,
                                    future: () => checkedByReaction != null
                                        ? room.redactEvent(
                                            checkedByReaction.eventId,
                                          )
                                        : room.checkCheckbox(
                                            eventId,
                                            checkboxIndex,
                                          ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ..._renderWithLineBreaks(node.nodes, context, depth: depth),
                ],
                style: TextStyle(fontSize: fontSize, color: textColor),
              ),
            ),
          ),
        );
      case 'blockquote':
        final cyber = Theme.of(context).extension<CyberpunkTheme>() ??
            CyberpunkTheme.dark();
        return WidgetSpan(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4.0),
            padding: const EdgeInsets.fromLTRB(12.0, 8.0, 10.0, 8.0),
            decoration: BoxDecoration(
              color: cyber.cyan.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              border: Border(
                left: BorderSide(color: cyber.cyan, width: 3),
              ),
            ),
            child: Text.rich(
              TextSpan(
                children: _renderWithLineBreaks(
                  node.nodes,
                  context,
                  depth: depth,
                ),
              ),
              style: TextStyle(
                fontSize: fontSize,
                height: 1.4,
                color: textColor.withValues(alpha: 0.85),
              ),
            ),
          ),
        );
      case 'table':
        return WidgetSpan(
          alignment: PlaceholderAlignment.top,
          child: _MdTable(
            element: node,
            renderHtml: _renderHtml,
            renderWithLineBreaks: _renderWithLineBreaks,
            fontSize: fontSize,
            textColor: textColor,
            depth: depth,
          ),
        );
      case 'thead':
      case 'tbody':
      case 'tr':
      case 'td':
      case 'th':
      case 'caption':
        return const TextSpan();
      case 'pre':
        final codeChild = node.children.firstWhereOrNull(
          (child) => child.localName == 'code',
        );
        final codeElement = codeChild ?? node;
        final rawCode = codeElement.text;
        final language = codeChild == null
            ? null
            : CodeBlockWidget.extractLanguage(codeChild);
        return WidgetSpan(
          child: CodeBlockWidget(
            rawCode: rawCode,
            language: language,
            fontSize: fontSize,
          ),
        );
      case 'code':
        if (node.parent?.localName == 'pre') {
          return const TextSpan();
        }
        final cyber = Theme.of(context).extension<CyberpunkTheme>() ??
            CyberpunkTheme.dark();
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            decoration: BoxDecoration(
              color: cyber.cyan.withValues(alpha: 0.1),
              border: Border.all(
                color: cyber.cyan.withValues(alpha: 0.3),
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Text(
              node.text,
              style: TextStyle(
                fontFamily: FluffyTypography.mono,
                fontSize: fontSize * 0.9,
                color: cyber.cyan,
              ),
            ),
          ),
        );
      case 'img':
        final mxcUrl = Uri.tryParse(node.attributes['src'] ?? '');
        if (mxcUrl == null || mxcUrl.scheme != 'mxc') {
          return TextSpan(text: node.attributes['alt']);
        }

        final width = double.tryParse(node.attributes['width'] ?? '');
        final height = double.tryParse(node.attributes['height'] ?? '');
        const defaultDimension = 64.0;
        final actualWidth = width ?? height ?? defaultDimension;
        final actualHeight = height ?? width ?? defaultDimension;

        return WidgetSpan(
          child: SizedBox(
            width: actualWidth,
            height: actualHeight,
            child: MxcImage(
              uri: mxcUrl,
              width: actualWidth,
              height: actualHeight,
              isThumbnail: (actualWidth * actualHeight) > (256 * 256),
            ),
          ),
        );
      case 'hr':
        final cyber = Theme.of(context).extension<CyberpunkTheme>() ??
            CyberpunkTheme.dark();
        return WidgetSpan(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 10.0),
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  cyber.cyan.withValues(alpha: 0.0),
                  cyber.cyan.withValues(alpha: 0.5),
                  cyber.cyan.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        );
      case 'details':
        var obscure = true;
        return WidgetSpan(
          child: StatefulBuilder(
            builder: (context, setState) => InkWell(
              splashColor: Colors.transparent,
              onTap: () => setState(() {
                obscure = !obscure;
              }),
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      child: Icon(
                        obscure ? Icons.arrow_right : Icons.arrow_drop_down,
                        size: fontSize * 1.2,
                        color: textColor,
                      ),
                    ),
                    if (obscure)
                      ...node.nodes
                          .where(
                            (node) =>
                                node is dom.Element &&
                                node.localName == 'summary',
                          )
                          .map(
                            (node) => _renderHtml(node, context, depth: depth),
                          )
                    else
                      ..._renderWithLineBreaks(
                        node.nodes,
                        context,
                        depth: depth,
                      ),
                  ],
                ),
                style: TextStyle(fontSize: fontSize, color: textColor),
              ),
            ),
          ),
        );
      case 'font':
        final fontColor = (node.attributes['color'] ??
                node.attributes['data-mx-color'])
            ?.hexToColor;
        final fontBg = node.attributes['data-mx-bg-color']?.hexToColor;
        return TextSpan(
          style: TextStyle(color: fontColor, backgroundColor: fontBg),
          children: _renderWithLineBreaks(
            node.nodes,
            context,
            depth: depth + 1,
          ),
        );
      case 'span':
        if (!node.attributes.containsKey('data-mx-spoiler')) {
          continue block;
        }
        var obscure = true;
        return WidgetSpan(
          child: StatefulBuilder(
            builder: (context, setState) => InkWell(
              splashColor: Colors.transparent,
              onTap: () => setState(() {
                obscure = !obscure;
              }),
              child: Text.rich(
                TextSpan(
                  children: _renderWithLineBreaks(
                    node.nodes,
                    context,
                    depth: depth,
                  ),
                ),
                style: TextStyle(
                  fontSize: fontSize,
                  color: textColor,
                  backgroundColor: obscure ? textColor : null,
                ),
              ),
            ),
          ),
        );
      block:
      default:
        return TextSpan(
          style: switch (node.localName) {
            'body' => TextStyle(fontSize: fontSize, color: textColor),
            'a' => linkStyle,
            'strong' => const TextStyle(fontWeight: FontWeight.bold),
            'em' || 'i' => const TextStyle(fontStyle: FontStyle.italic),
            'del' || 's' || 'strikethrough' => const TextStyle(
              decoration: TextDecoration.lineThrough,
            ),
            'u' => const TextStyle(decoration: TextDecoration.underline),
            'h1' => TextStyle(fontSize: fontSize * 1.6, height: 2),
            'h2' => TextStyle(fontSize: fontSize * 1.5, height: 2),
            'h3' => TextStyle(fontSize: fontSize * 1.4, height: 2),
            'h4' => TextStyle(fontSize: fontSize * 1.3, height: 1.75),
            'h5' => TextStyle(fontSize: fontSize * 1.2, height: 1.75),
            'h6' => TextStyle(fontSize: fontSize * 1.1, height: 1.5),
            'span' => TextStyle(
              color:
                  node.attributes['color']?.hexToColor ??
                  node.attributes['data-mx-color']?.hexToColor ??
                  textColor,
              backgroundColor: node.attributes['data-mx-bg-color']?.hexToColor,
            ),
            'sup' => const TextStyle(
              fontFeatures: [FontFeature.superscripts()],
            ),
            'sub' => const TextStyle(fontFeatures: [FontFeature.subscripts()]),
            _ => null,
          },
          children: _renderWithLineBreaks(node.nodes, context, depth: depth),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final element = _parseHtmlCached(html);
    return Text.rich(
      _renderHtml(element, context),
      // Pin the root inline style so markdown renders at the same perceived
      // size as plain text. Without an explicit fontFamily/height the root
      // Text.rich inherits the ambient DefaultTextStyle (textTheme.bodyMedium,
      // Inter with height: 1.45), inflating line height and making rich text
      // look larger than the nominal fontSizeFactor. We keep fontSize driven
      // by the caller (fontSizeFactor * messageFontSize) and only fix the
      // family + line height to the value used elsewhere in this renderer.
      style: TextStyle(
        fontFamily: FluffyTypography.inter,
        height: 1.25,
        fontSize: fontSize,
        color: textColor,
      ),
      maxLines: limitHeight ? 64 : null,
      overflow: TextOverflow.fade,
      selectionColor: textColor.withAlpha(128),
    );
  }
}

class MatrixPill extends StatelessWidget {
  final String name;
  final BuildContext outerContext;
  final Uri? avatar;
  final String uri;
  final double? fontSize;
  final Color? color;

  const MatrixPill({
    super.key,
    required this.name,
    required this.outerContext,
    this.avatar,
    required this.uri,
    required this.fontSize,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      splashColor: Colors.transparent,
      onTap: UrlLauncher(outerContext, uri).launchUrl,
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              child: Padding(
                padding: const EdgeInsets.only(right: 4.0),
                child: Avatar(mxContent: avatar, name: name, size: 16),
              ),
            ),
            TextSpan(
              text: name,
              style: TextStyle(
                color: color,
                decorationColor: color,
                decoration: TextDecoration.underline,
                fontSize: fontSize,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  Color? get hexToColor {
    var hexCode = this;
    if (hexCode.startsWith('#')) hexCode = hexCode.substring(1);
    if (hexCode.length == 6) hexCode = 'FF$hexCode';
    final colorValue = int.tryParse(hexCode, radix: 16);
    return colorValue == null ? null : Color(colorValue);
  }
}

extension on dom.Element {
  dom.Element get rootElement => parent?.rootElement ?? this;
}

class _MdTable extends StatelessWidget {
  final dom.Element element;
  final InlineSpan Function(dom.Node, BuildContext, {int depth}) renderHtml;
  final List<InlineSpan> Function(
    dom.NodeList,
    BuildContext, {
    int depth,
  })
  renderWithLineBreaks;
  final double fontSize;
  final Color textColor;
  final int depth;

  const _MdTable({
    required this.element,
    required this.renderHtml,
    required this.renderWithLineBreaks,
    required this.fontSize,
    required this.textColor,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trNodes = element.querySelectorAll('tr');
    if (trNodes.isEmpty) {
      return const SizedBox.shrink();
    }
    final maxCols = trNodes
        .map(
          (tr) => tr.children
              .where((c) => c.localName == 'td' || c.localName == 'th')
              .length,
        )
        .reduce((a, b) => a > b ? a : b);
    if (maxCols == 0) return const SizedBox.shrink();

    final rows = trNodes.map((tr) {
      final cells = tr.children
          .where((c) => c.localName == 'td' || c.localName == 'th')
          .toList();
      while (cells.length < maxCols) {
        cells.add(dom.Element.tag('td'));
      }
      return TableRow(
        children: cells.map((cell) {
          final isHeader = cell.localName == 'th';
          return TableCell(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: isHeader
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: textColor,
                  ),
                  children: renderWithLineBreaks(
                    cell.nodes,
                    context,
                    depth: depth + 1,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
    }).toList();

    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: TableBorder.all(
        color: scheme.outlineVariant,
        width: 0.5,
        borderRadius: BorderRadius.circular(8),
      ),
      children: rows,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: GestureDetector(
        onTap: () => _openZoomableTable(context, table),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: MediaQuery.sizeOf(context).width * 0.4,
            ),
            child: table,
          ),
        ),
      ),
    );
  }

  void _openZoomableTable(BuildContext context, Widget table) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return Dialog.fullscreen(
          backgroundColor: theme.colorScheme.surface,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    boundaryMargin: const EdgeInsets.all(80),
                    minScale: 0.5,
                    maxScale: 6.0,
                    panEnabled: true,
                    scaleEnabled: true,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: table,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHigh,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
