import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/code_highlight_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:highlight/highlight.dart' as hl show Node;
import 'package:html/dom.dart' as dom;

class CodeBlockWidget extends StatefulWidget {
  final String rawCode;
  final String? language;
  final double fontSize;

  const CodeBlockWidget({
    super.key,
    required this.rawCode,
    required this.fontSize,
    this.language,
  });

  /// Extracts the language identifier from a `language-xxx` className token.
  /// Returns `null` if no recognizable language class is present.
  static String? extractLanguage(dom.Element node) {
    for (final raw in node.className.split(RegExp(r'\s+'))) {
      if (!raw.startsWith('language-')) continue;
      final lang = raw.substring('language-'.length).toLowerCase().trim();
      if (lang.isEmpty) return null;
      return codeLanguageAliases[lang] ?? lang;
    }
    return null;
  }

  @override
  State<CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<CodeBlockWidget> {
  bool _justCopied = false;

  Future<void> _copy(BuildContext context) async {
    final l10n = L10n.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: widget.rawCode));
    if (!mounted) return;
    setState(() => _justCopied = true);
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.codeCopied)),
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _justCopied = false);
    });
  }

  InlineSpan _renderHighlightNode(hl.Node node, Map<String, TextStyle> theme) {
    final style = node.className == null
        ? theme['root']
        : theme[node.className] ?? theme['root'];
    if (node.value != null) {
      return TextSpan(text: node.value, style: style);
    }
    final children = node.children
        ?.map((c) => _renderHighlightNode(c, theme))
        .toList();
    return TextSpan(children: children, style: style);
  }

  TextSpan _buildHighlighted(Map<String, TextStyle> theme) {
    List<hl.Node>? nodes;
    final lang = widget.language;
    try {
      if (lang != null) {
        nodes = highlight.parse(widget.rawCode, language: lang).nodes;
      } else {
        nodes = highlight.parse(widget.rawCode, language: 'plaintext').nodes;
      }
    } catch (_) {
      nodes = null;
    }
    if (nodes == null || nodes.isEmpty) {
      return TextSpan(text: widget.rawCode, style: theme['root']);
    }
    return TextSpan(
      style: theme['root'],
      children: nodes.map((n) => _renderHighlightNode(n, theme)).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = isDark ? atomOneDarkTheme : atomOneLightTheme;
    final background = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerLow;
    final pillBackground = theme.colorScheme.surfaceContainerHigh.withAlpha(
      217,
    );
    final pillForeground = theme.colorScheme.onSurfaceVariant;
    final l10n = L10n.of(context);

    final codeStyle = TextStyle(
      fontFamily: 'RobotoMono',
      fontFamilyFallback: const ['monospace', 'Courier'],
      fontSize: widget.fontSize,
      height: 1.35,
      color: palette['root']?.color,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText.rich(
                TextSpan(
                  style: codeStyle,
                  children: [_buildHighlighted(palette)],
                ),
                style: codeStyle,
              ),
            ),
          ),
          PositionedDirectional(
            top: 4,
            end: 4,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.language != null && widget.language!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: pillBackground,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.language!,
                      style: TextStyle(
                        fontFamily: 'RobotoMono',
                        fontFamilyFallback: const ['monospace'],
                        fontSize: widget.fontSize * 0.8,
                        color: pillForeground,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Tooltip(
                  message: l10n.copyCode,
                  child: Material(
                    color: pillBackground,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _copy(context),
                      child: Padding(
                        padding: const EdgeInsets.all(6.0),
                        child: Icon(
                          _justCopied ? Icons.check : Icons.copy_outlined,
                          size: widget.fontSize,
                          color: pillForeground,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
