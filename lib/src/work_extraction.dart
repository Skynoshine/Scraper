import 'package:html/dom.dart';

/// One chapter link observed inside a work's chapter list.
final class ChapterReference {
  final String title;
  final Uri url;
  final String? number;

  const ChapterReference({required this.title, required this.url, this.number});

  Map<String, Object?> toJson() => {
        'title': title,
        'url': url.toString(),
        'number': number,
      };
}

/// Extracted work data and evidence about unresolved chapter continuation.
final class WorkExtractionResult {
  final String? title;
  final String? synopsis;
  final Uri? cover;
  final List<ChapterReference> chapters;
  final List<Uri> continuationUrls;
  final String strategy;
  final Map<String, String> selectors;
  final List<String> warnings;

  /// False means no continuation signal was detected, not proven completeness.
  final bool mayHaveMore;

  WorkExtractionResult({
    this.title,
    this.synopsis,
    this.cover,
    Iterable<ChapterReference> chapters = const [],
    Iterable<Uri> continuationUrls = const [],
    this.mayHaveMore = false,
    required this.strategy,
    Map<String, String> selectors = const {},
    Iterable<String> warnings = const [],
  })  : chapters = List.unmodifiable(chapters),
        continuationUrls = List.unmodifiable(continuationUrls),
        selectors = Map.unmodifiable(selectors),
        warnings = List.unmodifiable(warnings);

  Map<String, Object?> toJson() => {
        'title': title,
        'synopsis': synopsis,
        'cover': cover?.toString(),
        'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
        'continuationUrls':
            continuationUrls.map((url) => url.toString()).toList(),
        'mayHaveMore': mayHaveMore,
        'strategy': strategy,
        'selectors': selectors,
        'warnings': warnings,
      };
}

/// Extracts an observed work page without making requests or running scripts.
WorkExtractionResult extractWorkDetails({
  required Document doc,
  required Uri pageUri,
  String? expectedTitle,
  Map<String, String>? selectors,
}) {
  if (!_webUri(pageUri)) {
    throw ArgumentError.value(pageUri, 'pageUri', 'Use an HTTP(S) URL.');
  }
  final profile = selectors ?? const <String, String>{};
  final warnings = <String>[];
  final base =
      _resolve(pageUri, doc.querySelector('base[href]')?.attributes['href']) ??
          pageUri;
  final rules = _detectRules(doc);
  final applied = <String, String>{};

  String? readText(String key, List<String> defaults) {
    for (final selector in [
      if (profile[key] != null) profile[key]!,
      ...defaults,
    ]) {
      final nodes = _select(
        doc,
        selector,
        warnings,
      ).where((node) => !_secondary(node));
      final values =
          nodes.map(_text).where((value) => value.isNotEmpty).toList();
      if (values.isNotEmpty) {
        applied[key] = selector;
        if (key == 'title' && expectedTitle != null) {
          for (final value in values) {
            if (_fold(value) == _fold(expectedTitle)) return value;
          }
        }
        return values.first;
      }
      if (selector == profile[key]) {
        warnings.add(
          'Stored $key selector was not usable; trying structural discovery.',
        );
      }
    }
    return null;
  }

  final title = readText('title', [
    rules.title,
    'main h1',
    'article h1',
    'h1',
    'meta[property="og:title"]',
  ]);
  final synopsis = readText('synopsis', [
    rules.synopsis,
    '[itemprop="description"]',
    '.synopsis',
    'meta[property="og:description"]',
    'meta[name="description"]',
  ]);
  Uri? cover;
  for (final selector in [
    if (profile['cover'] != null) profile['cover']!,
    rules.cover,
    '.manga-cover img',
    '.book-cover img',
    '.cover img',
    'meta[property="og:image"]',
  ]) {
    for (final element in _select(doc, selector, warnings)) {
      if (_secondary(element)) continue;
      cover = _coverUri(element, base);
      if (cover != null) break;
    }
    if (cover != null) {
      applied['cover'] = selector;
      break;
    }
    if (selector == profile['cover']) {
      warnings.add(
        'Stored cover selector was not usable; trying structural discovery.',
      );
    }
  }

  final scopeSelector = profile['chapterScope'] ?? rules.scope;
  final chapterSelector = profile['chapters'] ?? rules.chapters;
  final labelSelector = profile['chapterTitle'] ?? rules.label;
  final numberSelector = profile['chapterNumber'] ?? '.episode-number';
  var scopes = scopeSelector.isEmpty
      ? _genericScopes(doc)
      : _select(
          doc,
          scopeSelector,
          warnings,
        ).where((node) => !_secondary(node)).toList();
  // Generic wrappers must not merge distinct inner chapter lists.
  scopes = scopes
      .where(
        (node) => !scopes.any((other) =>
            other != node &&
            (rules.name == 'generic'
                ? _within(other, node)
                : _within(node, other))),
      )
      .toList();
  final anchors = _select(
    doc,
    chapterSelector,
    warnings,
  ).where((node) => node.localName == 'a' && !_secondary(node)).toList();
  final groups = <_ChapterGroup>[];
  for (final scope in scopes) {
    if (scope.localName == 'body' || scope.localName == 'html') continue;
    final chapters = <Uri, ChapterReference>{};
    var missing = false;
    for (final anchor in anchors.where((node) => _within(node, scope))) {
      if (_navigationControl(anchor) || _moreControl(anchor)) continue;
      final titleNode = _select(anchor, labelSelector, warnings);
      final label = _clean(
        titleNode.isEmpty
            ? anchor.attributes['title'] ?? anchor.text
            : _text(titleNode.first),
      );
      if (label.isEmpty || _noiseLabel(label)) continue;
      final url = _resolve(base, anchor.attributes['href']);
      if (url == null ||
          url.removeFragment() == pageUri.removeFragment() ||
          _asset(url)) {
        missing |= _chapterNumber(label) != null;
        continue;
      }
      final numberNodes = _select(anchor, numberSelector, warnings);
      final number =
          _chapterNumber(numberNodes.isEmpty ? '' : _text(numberNodes.first)) ??
              _chapterNumber(anchor.attributes['data-number'] ?? '') ??
              _chapterNumber(label);
      final key = url.removeFragment();
      chapters.putIfAbsent(
        key,
        () => ChapterReference(title: label, url: key, number: number),
      );
    }
    if (chapters.isNotEmpty) {
      groups.add(_ChapterGroup(scope, chapters, missing));
    }
  }

  _ChapterGroup? chosen;
  var ambiguous = false;
  if (groups.isNotEmpty) {
    chosen = groups.first;
    for (final group in groups.skip(1)) {
      final previous = chosen!.chapters.keys.toSet();
      final current = group.chapters.keys.toSet();
      if (current.containsAll(previous) && current.length > previous.length) {
        chosen = group;
      } else if (!previous.containsAll(current)) {
        ambiguous = true;
      }
    }
    if (ambiguous) {
      chosen = null;
      warnings.add(
        'Different chapter regions were found; supply a chapterScope selector to disambiguate.',
      );
    }
  } else if (scopes.length == 1 &&
      !['body', 'html'].contains(scopes.single.localName)) {
    chosen = _ChapterGroup(scopes.single, {}, false);
  }

  if (profile.isNotEmpty && (chosen == null || chosen.chapters.isEmpty)) {
    final fallback = extractWorkDetails(
      doc: doc,
      pageUri: pageUri,
      expectedTitle: expectedTitle,
    );
    return WorkExtractionResult(
      title: fallback.title,
      synopsis: fallback.synopsis,
      cover: fallback.cover,
      chapters: fallback.chapters,
      continuationUrls: fallback.continuationUrls,
      mayHaveMore: fallback.mayHaveMore,
      strategy: '${fallback.strategy}-profile-fallback',
      selectors: fallback.selectors,
      warnings: {
        'Stored chapter selectors were not usable; structural discovery was retried.',
        ...warnings,
        ...fallback.warnings,
      },
    );
  }

  final chapters = chosen?.chapters.values.toList() ?? <ChapterReference>[];
  final continuations = <Uri>{};
  var mayHaveMore = chosen == null || chosen.missing || chapters.isEmpty;
  if (chosen != null) {
    applied.addAll({
      'chapterScope':
          scopeSelector.isEmpty ? _selectorFor(chosen.scope) : scopeSelector,
      'chapters': chapterSelector,
      'chapterTitle': labelSelector,
      'chapterNumber': numberSelector,
    });
    for (final control in doc.querySelectorAll(
      'a[href], button, [role="button"], link[rel="next"]',
    )) {
      if (_secondary(control, allowNavigation: true) ||
          _disabled(control) ||
          _rel(control, 'prev') ||
          control.attributes.containsKey('aria-current')) {
        continue;
      }
      final isNext = _rel(control, 'next');
      if (!(_near(control, chosen.scope) ||
          (control.localName == 'link' && isNext))) {
        continue;
      }
      if (!_moreControl(control) &&
          !isNext &&
          !_nextControl(control) &&
          !_paginationControl(control)) {
        continue;
      }
      mayHaveMore = true;
      final next = _resolve(base, control.attributes['href']);
      if (next != null &&
          next.removeFragment() != pageUri.removeFragment() &&
          _sameWorkRoute(pageUri, next) &&
          !chosen.chapters.containsKey(next.removeFragment())) {
        continuations.add(next.removeFragment());
      }
    }
    final total = _declaredCount(doc, chosen.scope);
    if (total != null && total > chapters.length) {
      mayHaveMore = true;
      warnings.add(
        'The page declares $total chapters; ${chapters.length} unique chapter links were observed.',
      );
    }
  }
  if (chapters.isEmpty) {
    warnings.add('No associated chapter list was recognized in this HTML.');
  }
  if (mayHaveMore && continuations.isEmpty) {
    warnings.add(
      'The chapter list may be partial; no navigable continuation was identified.',
    );
  }
  if (chapters.any((chapter) => chapter.url.origin != pageUri.origin)) {
    warnings.add('Some chapter references use another origin and need review.');
  }
  if (title == null) warnings.add('The work title was not found.');
  if (synopsis == null) warnings.add('The synopsis was not found.');
  if (cover == null) warnings.add('The cover URL was not found.');
  if (title != null &&
      expectedTitle != null &&
      _fold(title) != _fold(expectedTitle)) {
    warnings.add(
      'The detected title differs from expectedTitle; verify the work or its aliases.',
    );
  }
  if (rules.name == 'generic' && profile.isEmpty) {
    warnings.add(
      'Generic chapter scope inferred; review the extracted links before reusing its selectors.',
    );
  }
  return WorkExtractionResult(
    title: title,
    synopsis: synopsis,
    cover: cover,
    chapters: chapters,
    continuationUrls: continuations,
    mayHaveMore: mayHaveMore,
    strategy: profile.isEmpty ? rules.name : 'profile',
    selectors: applied,
    warnings: warnings.toSet(),
  );
}

class _Rules {
  final String name, scope, chapters, title, synopsis, cover, label;
  const _Rules(
    this.name,
    this.scope,
    this.chapters,
    this.title,
    this.synopsis,
    this.cover, {
    this.label = '.chapternum, .chapter-title',
  });
}

/// Recognizes structural families without relying on hostnames.
_Rules _detectRules(Document doc) {
  if (doc.querySelector('#chapterlist') != null) {
    return const _Rules(
      'mangareader',
      '#chapterlist',
      '#chapterlist a[href]',
      'h1.entry-title',
      '.entry-content[itemprop="description"], .synp .entry-content',
      '.seriestucontent .thumb img, .infox .thumb img, .animefull .thumb img',
    );
  }
  if (doc.querySelector(
        '.listing-chapters_wrap, .listing-chapters-wrap, .manga-chapters-holder',
      ) !=
      null) {
    return const _Rules(
      'madara',
      '.listing-chapters_wrap, .listing-chapters-wrap, .manga-chapters-holder',
      '.wp-manga-chapter a[href], .chapter-box > a[href]',
      '.post-title h1, .profile-manga h1',
      '.description-summary .summary__content, .summary__content',
      '.summary_image img',
    );
  }
  if (doc.querySelector('.episode-item-new') != null) {
    return const _Rules(
      'mangatoon',
      '.episodes-wrap-new, .episode-content',
      'a.episode-item-new[href]',
      'h1.detail-title',
      '.detail-description',
      '.detail-image img, .detail-cover img',
      label: '.episode-title-new:not(.episode-number)',
    );
  }
  return const _Rules(
    'generic',
    '',
    'a[href]',
    'main h1',
    '.synopsis, .description-summary',
    '.manga-cover img',
  );
}

class _ChapterGroup {
  final Element scope;
  final Map<Uri, ChapterReference> chapters;
  final bool missing;
  const _ChapterGroup(this.scope, this.chapters, this.missing);
}

List<Element> _select(Node root, String selector, List<String> warnings) {
  if (selector.isEmpty) return const [];
  try {
    if (root is Document) return root.querySelectorAll(selector);
    if (root is Element) return root.querySelectorAll(selector);
  } on FormatException {
    warnings.add('Invalid or unsupported CSS selector: $selector');
  }
  return const [];
}

List<Element> _genericScopes(Document doc) {
  final scopes = doc
      .querySelectorAll(
        '#chapters, #chapter-list, .chapters, .chapter-list, .chapter_list, .chapters-list, [data-chapter-list]',
      )
      .where((node) => !_secondary(node))
      .toList();
  if (scopes.isNotEmpty) return scopes;
  for (final heading in doc.querySelectorAll('h2, h3, h4')) {
    if (_secondary(heading) ||
        !RegExp(r'^(?:lista de |\d+ )?(?:capitulos?|chapters?|episodios?)\b')
            .hasMatch(_fold(_text(heading)))) {
      continue;
    }
    var scope = heading.parent;
    for (var depth = 0;
        scope != null && depth < 3 && scope.localName != 'body';
        depth++, scope = scope.parent) {
      if (scope.querySelectorAll('a[href]').any(
            (link) => !_secondary(link) && _chapterNumber(_text(link)) != null,
          )) {
        if (!scopes.contains(scope)) scopes.add(scope);
        break;
      }
    }
  }
  return scopes;
}

/// Uses supported selectors and preserves the selected region when replayed.
String _selectorFor(Element node) {
  final parts = <String>[];
  for (Element? current = node; current != null; current = current.parent) {
    if (current.id.isNotEmpty &&
        RegExp(r'^[a-zA-Z_][\w-]*$').hasMatch(current.id)) {
      parts.insert(0, '#${current.id}');
      break;
    }
    final parent = current.parent;
    parts.insert(
      0,
      parent == null
          ? current.localName!
          : '${current.localName}:nth-child(${parent.children.indexOf(current) + 1})',
    );
  }
  return parts.join(' > ');
}

bool _within(Element node, Element ancestor) {
  for (Element? current = node; current != null; current = current.parent) {
    if (identical(current, ancestor)) return true;
  }
  return false;
}

bool _near(Element node, Element scope) =>
    _within(node, scope) ||
    (scope.parent != null &&
        !['body', 'html'].contains(scope.parent!.localName) &&
        _within(node, scope.parent!));

bool _secondary(Element node, {bool allowNavigation = false}) {
  for (Element? current = node; current != null; current = current.parent) {
    if (['aside', 'footer', 'header'].contains(current.localName) ||
        (!allowNavigation && current.localName == 'nav')) {
      return true;
    }
    if (RegExp(
      r'(^|[\s_-])(related|recommend\w*|suggest\w*|sidebar|comments?)([\s_-]|$)',
      caseSensitive: false,
    ).hasMatch('${current.id} ${current.className}')) {
      return true;
    }
  }
  return false;
}

String _text(Element node) => _clean(
      node.localName == 'meta' ? node.attributes['content'] ?? '' : node.text,
    );
String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();
String _fold(String value) {
  var text = _clean(value).toLowerCase();
  for (final entry in {
    '[áàâãä]': 'a',
    '[éèêë]': 'e',
    '[íìîï]': 'i',
    '[óòôõö]': 'o',
    '[úùûü]': 'u',
    'ç': 'c',
  }.entries) {
    text = text.replaceAll(RegExp(entry.key), entry.value);
  }
  return text;
}

String? _chapterNumber(String value) {
  final text = _fold(value);
  final match = RegExp(
        r'\b(?:chapter|chap|capitulo|cap|episode|episodio)\.?\s*#?\s*(\d+(?:[.,]\d+)?)',
      ).firstMatch(text) ??
      RegExp(r'^\s*(\d+(?:[.,]\d+)?)(?:\b|$)').firstMatch(text);
  return match?.group(1)?.replaceAll(',', '.');
}

bool _rel(Element node, String value) => (node.attributes['rel'] ?? '')
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .contains(value);
bool _disabled(Element node) =>
    node.attributes.containsKey('disabled') ||
    node.attributes['aria-disabled'] == 'true';
bool _moreControl(Element node) => RegExp(
      r'\b(load more|show more|view all|more chapters|carregar mais|ver mais|mostrar mais|todos os capitulos|ver todos)\b',
    ).hasMatch(_fold(_text(node)));
bool _nextControl(Element node) =>
    RegExp(r'^(next|proxim[oa]|seguinte)(\s+page|\s+pagina)?\s*[»›>]*$')
        .hasMatch(_fold(_text(node)));
bool _navigationControl(Element node) =>
    _rel(node, 'next') ||
    _rel(node, 'prev') ||
    node.attributes.containsKey('aria-current') ||
    _nextControl(node) ||
    RegExp(r'^(previous|prev|anterior)(\s+page|\s+pagina)?$')
        .hasMatch(_fold(_text(node))) ||
    _paginationControl(node);
bool _paginationControl(Element node) {
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    if (RegExp(
      r'pagination|paginacao|pager|page-numbers',
      caseSensitive: false,
    ).hasMatch('${parent.id} ${parent.className}')) {
      return true;
    }
  }
  return false;
}

bool _noiseLabel(String value) => RegExp(
      r'^(download|baixar|login|entrar|favoritar|bookmark|report|denunciar|share|compartilhar)$',
    ).hasMatch(_fold(value));

Uri? _resolve(Uri base, String? value) {
  if (value == null ||
      value.trim().isEmpty ||
      value.trim().startsWith('#') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  try {
    final uri = base.resolve(value.trim());
    return _webUri(uri) ? uri : null;
  } on FormatException {
    return null;
  }
}

bool _webUri(Uri uri) =>
    ['https', 'http'].contains(uri.scheme) &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;
bool _asset(Uri uri) => RegExp(
      r'\.(jpg|jpeg|png|gif|webp|avif|pdf|zip|cbz)$',
      caseSensitive: false,
    ).hasMatch(uri.path);

Uri? _coverUri(Element node, Uri base) {
  for (final attr in [
    'content',
    'data-src',
    'data-lazy-src',
    'data-original',
    'src',
  ]) {
    final uri = _resolve(base, node.attributes[attr]);
    if (uri != null &&
        !RegExp(
          r'placeholder|loading|blank|no[-_]image|no[-_]cover',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
      return uri;
    }
  }
  return null;
}

bool _sameWorkRoute(Uri work, Uri next) {
  if (work.origin != next.origin) return false;
  // Preserves p when it identifies a work.
  const paginationKeys = {
    'page',
    'paged',
    'offset',
    'cursor',
    'after',
    'before',
    'start',
    'limit',
    'per_page',
    'pagesize',
    'page_size',
  };
  
  for (final entry in work.queryParametersAll.entries) {
    if (paginationKeys.contains(entry.key.toLowerCase())) continue;
    final values = next.queryParametersAll[entry.key];
    if (values == null || values.length != entry.value.length) return false;
    for (var i = 0; i < values.length; i++) {
      if (values[i] != entry.value[i]) return false;
    }
  }
  if (work.path == next.path) return true;
  final prefix = work.path
      .replaceFirst(RegExp(r'\.html?$'), '')
      .replaceFirst(RegExp(r'/$'), '');
  if (!next.path.startsWith('$prefix/')) return false;
  return RegExp(r'^(chapters|capitulos|page)(?:/|\.|$)')
      .hasMatch(next.path.substring(prefix.length + 1));
}

int? _declaredCount(Document doc, Element scope) {
  int? total;
  for (final node in doc.querySelectorAll(
    'h2, h3, h4, [data-chapter-count], [data-total-chapters]',
  )) {
    if (_secondary(node) || !_near(node, scope)) continue;
    final text = _fold(_text(node));
    final match = RegExp(r'\b(\d+)\s+(?:chapters|capitulos|episodios)\b')
            .firstMatch(text) ??
        RegExp(r'\b(?:chapters|capitulos|episodios)\s*[:(]\s*(\d+)')
            .firstMatch(text);
    final number = int.tryParse(
      node.attributes['data-chapter-count'] ??
          node.attributes['data-total-chapters'] ??
          match?.group(1) ??
          '',
    );
    if (number != null && (total == null || number > total)) total = number;
  }
  return total;
}
