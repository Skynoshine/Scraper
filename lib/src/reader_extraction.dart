import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;

/// Ordered image references and evidence about unresolved reader content.
final class ReaderExtractionResult {
  /// Unique image URLs in observed document order.
  final List<Uri> pages;
  /// Reader strategy selected during extraction.
  final String strategy;
  /// Extraction rules available for reuse in the same source.
  final Map<String, String> selectors;
  /// Unresolved content and extraction diagnostics.
  final List<String> warnings;

  /// False means no missing-page signal was found, not proven completeness.
  final bool mayHaveMore;

  ReaderExtractionResult({
    Iterable<Uri> pages = const [],
    required this.strategy,
    Map<String, String> selectors = const {},
    Iterable<String> warnings = const [],
    this.mayHaveMore = false,
  })  : pages = List.unmodifiable(pages),
        selectors = Map.unmodifiable(selectors),
        warnings = List.unmodifiable(warnings);

  /// Serializes image references and extraction diagnostics.
  Map<String, Object> toJson() => {
        'pages': pages.map((page) => page.toString()).toList(),
        'strategy': strategy,
        'selectors': selectors,
        'warnings': warnings,
        'mayHaveMore': mayHaveMore,
      };
}

/// Reads one chapter's HTML without fetching images or executing JavaScript.
ReaderExtractionResult extractReaderPages({
  required Document doc,
  required Uri pageUri,
  Map<String, String>? selectors,
}) {
  if (!_webUri(pageUri)) {
    throw ArgumentError.value(pageUri, 'pageUri', 'Use an HTTP(S) URL.');
  }
  final warnings = <String>[];
  final base =
      _resolve(pageUri, doc.querySelector('base[href]')?.attributes['href']) ??
          pageUri;
  final candidates = <_ReaderCandidate>[];
  final profile = selectors ?? const <String, String>{};

  if (profile.isNotEmpty) {
    final container = profile['container'];
    final mode = profile['mode'] ?? 'images';
    if (container != null &&
        container.trim().isNotEmpty &&
        const {'images', 'noscript', 'numbered'}.contains(mode)) {
      final plan = _ReaderPlan(
        container,
        profile['image'] ?? 'img',
        profile['strategy'] ?? 'profile',
        mode: mode,
        attributes: profile['attributes'] ?? _attributes,
        srcset: profile['srcset'] ?? _srcset,
      );
      for (final scope in _select(doc, container, warnings)) {
        if (!_secondary(scope)) {
          candidates.add(_readScope(scope, plan, base));
        }
      }
    }
    if (!candidates.any((candidate) => candidate.images.pages.isNotEmpty)) {
      candidates.clear();
      warnings.add('Stored reader selectors were not usable; rediscovering.');
    }
  }

  if (candidates.isEmpty) {
    final scopes = <Element, _ReaderPlan>{};
    for (final plan in _plans) {
      for (final scope in _select(doc, plan.container, warnings)) {
        if (!_secondary(scope)) scopes.putIfAbsent(scope, () => plan);
      }
    }
    // A nested reader is more specific than its outer layout wrapper.
    final leaves = scopes.keys.where((scope) => !scopes.keys.any(
          (other) => other != scope && _inside(other, scope),
        ));
    for (final scope in leaves) {
      candidates.add(_readScope(scope, scopes[scope]!, base));
    }
    if (!candidates.any((candidate) => candidate.images.pages.isNotEmpty)) {
      candidates.addAll(_numberedReaders(doc, base));
    }
  }

  final usable = candidates
      .where((candidate) => candidate.images.pages.isNotEmpty)
      .toList();
  if (usable.isEmpty) {
    for (final candidate in candidates) {
      warnings.addAll(candidate.warnings);
    }
    warnings.add('No supported image sequence was found in this HTML.');
    warnings
        .add('The reader may require JavaScript or a source-specific rule.');
    return ReaderExtractionResult(
      strategy: 'unresolved',
      warnings: warnings.toSet(),
      mayHaveMore: true,
    );
  }

  // Separate regions are accepted only when one contains the other sequence.
  var selected = usable.first;
  for (final candidate in usable.skip(1)) {
    if (_subsequence(selected.images.pages, candidate.images.pages)) {
      selected = candidate;
    } else if (!_subsequence(candidate.images.pages, selected.images.pages)) {
      return ReaderExtractionResult(
        strategy: 'ambiguous',
        warnings: [
          ...warnings,
          'Multiple independent reader sequences were found; none was merged.',
        ],
        mayHaveMore: true,
      );
    }
  }

  warnings.addAll(selected.warnings);
  var partial = selected.partial || selected.images.unresolved > 0;
  if (selected.images.unresolved > 0) {
    warnings.add('Some reader images had no usable HTTP(S) source.');
  }
  final numbers = selected.images.numbers;
  if (numbers.length > 1 &&
      (numbers.first > 1 ||
          List.generate(numbers.length - 1, (i) => i)
              .any((i) => numbers[i + 1] != numbers[i] + 1))) {
    partial = true;
    warnings
        .add('Page labels have a gap or unusual order; DOM order was kept.');
  }
  final scopeTotal = _declaredTotal(selected.scope) ?? 0;
  final imageTotal = selected.images.declaredTotal;
  final total = scopeTotal > imageTotal ? scopeTotal : imageTotal;
  if (total > selected.images.pages.length) {
    partial = true;
    warnings.add(
      'The reader declares $total pages; '
      '${selected.images.pages.length} unique references were found.',
    );
  }
  if (_hasContinuation(selected.scope, selected.images.pages.length)) {
    partial = true;
    warnings.add('A page continuation control was found and was not followed.');
  }
  return ReaderExtractionResult(
    pages: selected.images.pages,
    strategy: selected.plan.strategy,
    selectors: {
      'container': _selectorFor(selected.scope),
      'image': selected.plan.image,
      'mode': selected.mode,
      'attributes': selected.plan.attributes,
      'srcset': selected.plan.srcset,
      'order': 'document',
      'strategy': selected.plan.strategy,
    },
    warnings: warnings.toSet(),
    mayHaveMore: partial,
  );
}

// Prefer lazy-loading sources before the regular src fallback.
const _attributes = 'data-src,data-lazy-src,data-original,data-url,src';
const _srcset = 'data-srcset,srcset';
// Detect reader structures without matching site domains.
const _plans = [
  _ReaderPlan('#readerarea', 'img', 'mangareader'),
  _ReaderPlan('.reading-content', 'img.wp-manga-chapter-img', 'madara'),
  _ReaderPlan('.pictures', 'img.lazyload_img', 'mangatoon'),
  _ReaderPlan(
    '#reader, #chapter-content, #chapter-images, #manga-reader, '
        '.chapter-content, .chapter-images, .reader-content, .manga-reader, '
        '[data-reader]',
    'img',
    'generic-reader',
  ),
];

/// Selector rules and image attributes for a reader structure.
final class _ReaderPlan {
  final String container, image, strategy, mode, attributes, srcset;
  const _ReaderPlan(
    this.container,
    this.image,
    this.strategy, {
    this.mode = 'auto',
    this.attributes = _attributes,
    this.srcset = _srcset,
  });
}

/// Collected image URLs and evidence of missing pages.
final class _ImageSequence {
  final List<Uri> pages = [];
  final List<int> numbers = [];
  int unresolved = 0;
  int declaredTotal = 0;
}

/// One reader region and its extraction evidence.
final class _ReaderCandidate {
  final Element scope;
  final _ReaderPlan plan;
  final _ImageSequence images;
  final String mode;
  final List<String> warnings;
  final bool partial;
  _ReaderCandidate(this.scope, this.plan, this.images, this.mode, this.warnings,
      {this.partial = false});
}

/// Extracts regular and noscript images from one reader region.
_ReaderCandidate _readScope(Element scope, _ReaderPlan plan, Uri base) {
  final warnings = <String>[];
  final regular = _select(scope, plan.image, warnings)
      .where((image) =>
          image.localName == 'img' && !_hasAncestor(image, 'noscript'))
      .toList();
  final fallback = <Element>[];
  for (final node in scope.querySelectorAll('noscript')) {
    if (_secondary(node)) continue;
    if (node.querySelector('img') != null) {
      fallback.addAll(_select(node, plan.image, warnings));
    } else {
      // The HTML parser can expose noscript contents as raw text.
      final fragment = parser.parseFragment(node.text);
      fallback.addAll(_select(fragment, plan.image, warnings));
    }
  }
  final mode = plan.mode;
  final main = _images(
    mode == 'numbered'
        ? regular.where((image) => _pageNumber(image) != null)
        : regular,
    plan,
    base,
  );
  final alternate = _images(fallback, plan, base);
  if (mode != 'auto') {
    final chosen = mode == 'noscript' ? alternate : main;
    final other = mode == 'noscript' ? main : alternate;
    var partial =
        other.pages.isNotEmpty && !_subsequence(other.pages, chosen.pages);
    if (partial) {
      warnings.add(
          'The stored representation differs from another reader sequence.');
    }
    if (mode == 'numbered' &&
        regular.any((image) =>
            _pageNumber(image) == null &&
            !_secondary(image) &&
            !_tiny(image) &&
            _imageUrl(image, plan, base) != null)) {
      partial = true;
      warnings
          .add('Unnumbered images were excluded by the numbered-page rule.');
    }
    return _ReaderCandidate(scope, plan, chosen, mode, warnings,
        partial: partial);
  }
  if (main.pages.isEmpty ||
      (alternate.pages.length > main.pages.length &&
          _subsequence(main.pages, alternate.pages))) {
    return _ReaderCandidate(scope, plan, alternate, 'noscript', warnings);
  }
  final differs =
      alternate.pages.isNotEmpty && !_subsequence(alternate.pages, main.pages);
  if (differs) {
    warnings
        .add('Visible and noscript sequences differ; visible order was kept.');
  }
  return _ReaderCandidate(scope, plan, main, 'images', warnings,
      partial: differs);
}

/// Chooses one source per image and keeps the observed element order.
_ImageSequence _images(Iterable<Element> nodes, _ReaderPlan plan, Uri base) {
  final result = _ImageSequence();
  final seen = <Uri>{};
  for (final image in nodes) {
    if (image.localName != 'img' || _secondary(image) || _tiny(image)) continue;
    final total = _pageTotal(image) ?? 0;
    if (total > result.declaredTotal) result.declaredTotal = total;
    final url = _imageUrl(image, plan, base);
    if (url == null) {
      result.unresolved++;
      continue;
    }
    if (seen.add(url)) {
      result.pages.add(url);
      final number = _pageNumber(image);
      if (number != null) result.numbers.add(number);
    }
  }
  return result;
}

/// Chooses a lazy source, a srcset candidate or the regular src.
Uri? _imageUrl(Element image, _ReaderPlan plan, Uri base) {
  if (image.attributes['data-probe-redacted-url'] == 'true') return null;
  final attributes = _names(plan.attributes);
  for (final attr in attributes.where((name) => name != 'src')) {
    final url = _imageReference(base, image.attributes[attr]);
    if (url != null) return url;
  }
  for (final attr in _names(plan.srcset)) {
    final url = _bestSrcset(base, image.attributes[attr]);
    if (url != null) return url;
  }
  return attributes.contains('src')
      ? _imageReference(base, image.attributes['src'])
      : null;
}

/// Splits attribute names separated by commas or whitespace.
List<String> _names(String value) =>
    value.split(RegExp(r'[,\s]+')).where((name) => name.isNotEmpty).toList();

/// Selects one resolution; srcset alternatives are not separate pages.
Uri? _bestSrcset(Uri base, String? value) {
  if (value == null) return null;
  Uri? best;
  var score = -1.0;
  String? unit;
  var position = 0;
  bool space(String char) => const {' ', '\t', '\n', '\r', '\f'}.contains(char);
  while (position < value.length) {
    while (position < value.length &&
        (space(value[position]) || value[position] == ',')) {
      position++;
    }
    final start = position;
    while (position < value.length && !space(value[position])) {
      position++;
    }
    var rawUrl = value.substring(start, position);
    var descriptor = '';
    if (rawUrl.endsWith(',')) {
      rawUrl = rawUrl.replaceFirst(RegExp(r',+$'), '');
    } else {
      final descriptorStart = position;
      var parentheses = 0;
      while (position < value.length) {
        final char = value[position];
        if (char == ',' && parentheses == 0) break;
        if (char == '(') parentheses++;
        if (char == ')' && parentheses > 0) parentheses--;
        position++;
      }
      descriptor = value.substring(descriptorStart, position).trim();
    }
    // URL commas belong to the URL; only descriptor commas split candidates.
    final match =
        RegExp(r'^(\d+(?:\.\d+)?|\.\d+)(w|x)$').firstMatch(descriptor);
    if (descriptor.isNotEmpty && match == null) continue;
    final url = _imageReference(base, rawUrl);
    if (url == null) continue;
    final size = double.tryParse(match?.group(1) ?? '1') ?? 1;
    final kind = match?.group(2) ?? 'x';
    if (kind == 'w' && int.tryParse(match!.group(1)!) == null) continue;
    if (size <= 0 || (unit != null && kind != unit)) continue;
    if (size > score) {
      score = size;
      best = url;
      unit = kind;
    }
  }
  return best;
}

/// Resolves an image URL and rejects known placeholder filenames.
Uri? _imageReference(Uri base, String? value) {
  final url = _resolve(base, value);
  if (url == null) return null;
  final name =
      url.pathSegments.isEmpty ? '' : url.pathSegments.last.toLowerCase();
  if (RegExp(
          r'^(?:placeholder|loading|loader|blank|spacer|transparent|logo|avatar|banner)(?:[._-]|$)')
      .hasMatch(name)) {
    return null;
  }
  return url;
}

/// Resolves an HTTP(S) URL and removes its fragment.
Uri? _resolve(Uri base, String? value) {
  final raw = value?.trim();
  if (raw == null ||
      raw.isEmpty ||
      raw.startsWith('#') ||
      RegExp(r'[\x00-\x20]').hasMatch(raw) ||
      raw.toLowerCase().contains('[redacted]')) {
    return null;
  }
  try {
    final uri = base.resolve(raw);
    if (Uri.decodeComponent(uri.toString())
        .toLowerCase()
        .contains('[redacted]')) {
      return null;
    }
    return _webUri(uri) ? uri.removeFragment() : null;
  } on FormatException {
    return null;
  }
}

/// Accepts HTTP(S) URLs with a host and no embedded credentials.
bool _webUri(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

/// Queries a DOM node and records unsupported selector errors.
List<Element> _select(Node root, String selector, List<String> warnings) {
  try {
    return switch (root) {
      Document document => document.querySelectorAll(selector),
      Element element => element.querySelectorAll(selector),
      DocumentFragment fragment => fragment.querySelectorAll(selector),
      _ => <Element>[],
    };
  } catch (_) {
    warnings.add('An unsupported CSS selector was ignored: $selector');
    return [];
  }
}

/// Returns whether the node is a descendant of the container.
bool _inside(Element node, Element container) {
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    if (parent == container) return true;
  }
  return false;
}

/// Checks whether an ancestor has the specified tag.
bool _hasAncestor(Element node, String tag) {
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    if (parent.localName == tag) return true;
  }
  return false;
}

/// Detects secondary layout regions using tags and class names.
bool _secondary(Element node) {
  for (Element? current = node; current != null; current = current.parent) {
    if (const {'aside', 'nav', 'header', 'footer'}
        .contains(current.localName)) {
      return true;
    }
    final label = '${current.id} ${current.className}'.toLowerCase();
    if (RegExp(
            r'(^|[\s_-])(ad|ads|advert|advertisement|advertising|banner|logo|avatar|sidebar|related|recommendations?|comments?)([\s_-]|$)')
        .hasMatch(label)) {
      return true;
    }
  }
  return false;
}

/// Detects images with explicit dimensions of at most two pixels.
bool _tiny(Element image) {
  final width = int.tryParse(image.attributes['width'] ?? '');
  final height = int.tryParse(image.attributes['height'] ?? '');
  return width != null && height != null && width <= 2 && height <= 2;
}

/// Reads a page number from a recognized image alt label.
int? _pageNumber(Element image) {
  final alt = (image.attributes['alt'] ?? '').trim().toLowerCase();
  final match =
      RegExp(r'^(?:p[aá]gina|page)\s*#?\s*(\d+)(?:\s*(?:/|de|of)\s*\d+)?$')
          .firstMatch(alt);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Reads the total page count from a recognized image alt label.
int? _pageTotal(Element image) {
  final match = RegExp(
    r'^(?:p[aá]gina|page)\s*#?\s*\d+\s*(?:/|de|of)\s*(\d+)\s*$',
    caseSensitive: false,
  ).firstMatch(image.attributes['alt'] ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Finds fallback reader regions using numbered image labels.
List<_ReaderCandidate> _numberedReaders(Document doc, Uri base) {
  final images = doc
      .querySelectorAll('img')
      .where((image) => !_secondary(image) && _pageNumber(image) != null)
      .toList();
  if (images.length < 2) return [];
  final scopes = <Element>{};
  for (final image in images) {
    var scope = image.parent;
    while (scope != null && !const {'body', 'html'}.contains(scope.localName)) {
      final current = scope;
      if (images.where((item) => _inside(item, current)).length >= 2) break;
      scope = scope.parent;
    }
    if (scope != null && !const {'body', 'html'}.contains(scope.localName)) {
      scopes.add(scope);
    }
  }
  return [
    for (final scope in scopes.where((scope) =>
        !scopes.any((other) => other != scope && _inside(other, scope))))
      _readScope(
          scope,
          const _ReaderPlan('', 'img', 'numbered-images', mode: 'numbered'),
          base),
  ];
}

/// Checks whether one URL sequence occurs in another in the same order.
bool _subsequence(List<Uri> smaller, List<Uri> larger) {
  var index = 0;
  for (final url in larger) {
    if (index < smaller.length && smaller[index] == url) index++;
  }
  return index == smaller.length;
}

/// Reads the largest page count declared within the reader region.
int? _declaredTotal(Element scope) {
  var total = 0;
  final nodes = [
    scope,
    ...scope.querySelectorAll('[data-page-count], [data-total-pages]')
  ];
  for (final node in nodes) {
    for (final name in ['data-page-count', 'data-total-pages']) {
      final count = int.tryParse(node.attributes[name] ?? '');
      if (count != null && count > total) total = count;
    }
  }
  for (final image in scope.querySelectorAll('img[alt]')) {
    final count = _pageTotal(image);
    if (count != null && count > total) total = count;
  }
  return total == 0 ? null : total;
}

/// Detects page continuation controls while excluding chapter navigation.
bool _hasContinuation(Element scope, int pageCount) {
  final parent = scope.parent;
  final region =
      parent != null && !const {'body', 'html'}.contains(parent.localName)
          ? parent
          : scope;
  for (final node
      in region.querySelectorAll('a, button, [role="button"], select')) {
    if (node.attributes.containsKey('disabled') ||
        node.attributes['aria-disabled'] == 'true') {
      continue;
    }
    final labels = [
      node.text,
      node.attributes['aria-label'] ?? '',
      node.attributes['title'] ?? '',
      node.attributes['name'] ?? '',
      node.id,
      node.className,
    ].map((label) => label.toLowerCase()).toList();
    if (labels.any(
        RegExp(r'cap[ií]tulo|chapter|episode|epis[oó]dio|ch-(?:next|prev)')
            .hasMatch)) {
      continue;
    }
    if (node.localName == 'select') {
      // A selector can navigate images already present in the same HTML.
      if (labels.skip(1).any(RegExp(r'page|p[aá]gina').hasMatch)) {
        for (final option in node.querySelectorAll('option')) {
          final number = int.tryParse(option.attributes['value'] ?? '') ??
              int.tryParse(option.text.trim());
          if (number != null && number > pageCount) return true;
        }
      }
      continue;
    }
    if (labels.any(RegExp(
            r'(?:next|more|pr[oó]xima|mais|carregar|load)[\s_-]*(?:p[aá]gina|page)|load[\s_-]*more|carregar[\s_-]*mais|page[\s_-]*next')
        .hasMatch)) {
      return true;
    }
  }
  return false;
}

/// Uses supported CSS syntax and keeps selectors scoped to one reader.
String _selectorFor(Element element) {
  final parts = <String>[];
  for (Element? current = element; current != null; current = current.parent) {
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(current.id)) {
      parts.insert(0, '#${current.id}');
      break;
    }
    final tag = current.localName ?? 'div';
    final parent = current.parent;
    final index = parent == null ? 1 : parent.children.indexOf(current) + 1;
    parts.insert(0, parent == null ? tag : '$tag:nth-child($index)');
  }
  return parts.join(' > ');
}
