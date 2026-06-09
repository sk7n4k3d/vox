import 'package:linkify/linkify.dart';

/// Linkifies French-style postal addresses inside message text so tapping one
/// opens the maps/GPS app. flutter_linkify ships URL/email/phone linkifiers but
/// none for addresses, so this fills the gap.
///
/// Heuristic (deliberately conservative to avoid false positives): a street
/// number followed by a street-type keyword (rue, avenue, bd…), optionally up to
/// a 5-digit postal code + city. Produces a `geo:0,0?q=<address>` link, which
/// Android routes to the default maps app.
class MapAddressLinkifier extends Linkifier {
  const MapAddressLinkifier();

  // <number> <street-type> <street name…> [<5-digit zip> <city…>]
  static final RegExp _addressRegex = RegExp(
    r'\b\d{1,4}(?:\s?(?:bis|ter))?\s+'
    r'(?:rue|avenue|av\.?|boulevard|bd\.?|impasse|allée|allee|place|pl\.?|'
    r'chemin|route|rte\.?|quai|cours|passage|square|résidence|residence|'
    r'lotissement|voie|sentier)\s+'
    r"[A-Za-zÀ-ÿ0-9'’\-\s]{2,60}?"
    r'(?:,?\s+\d{5}\s+[A-Za-zÀ-ÿ\-\s]{2,40})?'
    r'(?=[.,;!?\n]|$)',
    caseSensitive: false,
    multiLine: true,
  );

  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    final list = <LinkifyElement>[];
    for (final element in elements) {
      if (element is TextElement) {
        final text = element.text;
        final matches = _addressRegex.allMatches(text).toList();
        // Aucune adresse : on garde l'élément tel quel. (Avant, les deux blocs
        // ci-dessous ajoutaient TOUS LES DEUX le texte complet → chaque message
        // sans adresse s'affichait en double, ex « cs089xncs089xn ».)
        if (matches.isEmpty) {
          list.add(element);
          continue;
        }
        var lastEnd = 0;
        for (final match in matches) {
          if (match.start > lastEnd) {
            list.add(TextElement(text.substring(lastEnd, match.start)));
          }
          final raw = match.group(0)!.trim();
          list.add(MapAddressElement(raw));
          lastEnd = match.end;
        }
        if (lastEnd < text.length) {
          list.add(TextElement(text.substring(lastEnd)));
        }
      } else {
        list.add(element);
      }
    }
    return list;
  }
}

/// A detected postal address. Its [url] is a `geo:` query the OS opens in maps.
class MapAddressElement extends LinkableElement {
  MapAddressElement(String address)
      : super(address, 'geo:0,0?q=${Uri.encodeComponent(address)}');

  @override
  String toString() => 'MapAddressElement: $text -> $url';

  @override
  // ignore: avoid_annotating_with_dynamic
  bool equals(dynamic other) =>
      other is MapAddressElement && other.url == url && other.text == text;
}
