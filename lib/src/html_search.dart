import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;

import 'search_discovery.dart';

enum HtmlSearchStatus {
  candidatesFound,
  formNotFound,
  noCandidates,
  requiresInspection,
  requestFailed,
}

/// A work candidate inferred from one image card.
class HtmlWorkCandidate {
  final String title;
  final Uri url;
  final Uri cover;
  final bool matchesQuery;

  const HtmlWorkCandidate({
    required this.title,
    required this.url,
    required this.cover,
    required this.matchesQuery,
  });

  Map<String, Object> toJson() => {
        'title': title,
        'url': url.toString(),
        'cover': cover.toString(),
        'matchesQuery': matchesQuery,
      };
}

/// Keeps discovery failures distinct from an empty catalogue.
class HtmlSearchResult {
  final HtmlSearchStatus status;
  final Uri entryUri;
  final Uri? searchUri;
  final SearchForm? form;
  final List<HtmlWorkCandidate> works;
  final List<Uri> visited;
  final String message;

  HtmlSearchResult({
    required this.status,
    required this.entryUri,
    this.searchUri,
    this.form,
    Iterable<HtmlWorkCandidate> works = const [],
    Iterable<Uri> visited = const [],
    required this.message,
  })  : works = List.unmodifiable(works),
        visited = List.unmodifiable(visited);

  Map<String, Object?> toJson() => {
        'status': status.name,
        'entryUrl': entryUri.toString(),
        'searchUrl': searchUri?.toString(),
        'form': form == null
            ? null
            : {
                'action': form!.action.toString(),
                'queryField': form!.queryField
              },
        'works': works.map((work) => work.toJson()).toList(),
        'visited': visited.map((uri) => uri.toString()).toList(),
        'message': message,
      };
}

/// Discovers a GET search form and extracts image-card candidates.
Future<HtmlSearchResult> searchHtml({
  required Uri entryUri,
  required String query,
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
  int maxResults = 30,
}) async {
  if (!_isWebUri(entryUri) || query.trim().isEmpty || maxResults < 1) {
    throw ArgumentError('Use an HTTP(S) URL, a query and maxResults > 0.');
  }
  final transport = client ?? http.Client();
  final visited = <Uri>[];
  SearchForm? selected;
  Uri? searchUri;

  HtmlSearchResult result(HtmlSearchStatus status, String message,
          [List<HtmlWorkCandidate> works = const []]) =>
      HtmlSearchResult(
        status: status,
        entryUri: entryUri,
        searchUri: searchUri,
        form: selected,
        works: works,
        visited: visited,
        message: message,
      );

  try {
    var page = await _fetchHtml(transport, entryUri, timeout, visited);
    var forms = discoverSearchForms(doc: page.doc, pageUri: page.uri);
    if (forms.isEmpty) {
      final searchLink = _searchPageLink(page.doc, page.uri);
      if (searchLink != null) {
        page = await _fetchHtml(transport, searchLink, timeout, visited);
        forms = discoverSearchForms(doc: page.doc, pageUri: page.uri);
      }
    }
    if (forms.isEmpty) {
      return result(HtmlSearchStatus.formNotFound,
          'No supported GET search form found in the inspected HTML.');
    }
    final sameOrigin =
        forms.where((form) => form.action.origin == page.uri.origin).toList();
    if (sameOrigin.isEmpty) {
      return result(HtmlSearchStatus.requiresInspection,
          'The discovered form submits to another origin.');
    }
    if (sameOrigin.length > 1) {
      return result(HtmlSearchStatus.requiresInspection,
          'Several distinct search forms were found; choose an entry page.');
    }
    selected = sameOrigin.first;
    if (selected.evidence
        .any((note) => note.startsWith('Submit-button overrides'))) {
      return result(HtmlSearchStatus.requiresInspection,
          'A submit button overrides the form; its behavior needs inspection.');
    }
    searchUri = selected.buildUri(query.trim());
    final response = await _fetchHtml(transport, searchUri, timeout, visited);
    if (response.uri.origin != page.uri.origin) {
      return result(HtmlSearchStatus.requiresInspection,
          'The search redirected to another origin.');
    }
    final works = extractWorkCandidates(
      doc: response.doc,
      pageUri: response.uri,
      query: query,
      maxResults: maxResults,
    );
    return works.isEmpty
        ? result(HtmlSearchStatus.noCandidates,
            'No image cards recognized; this does not prove an empty search.')
        : result(
            HtmlSearchStatus.candidatesFound,
            'Candidates inferred from image cards; verify before saving rules.',
            works);
  } on _PageFailure catch (error) {
    return result(HtmlSearchStatus.requestFailed, error.message);
  } on TimeoutException {
    return result(
        HtmlSearchStatus.requestFailed, 'The HTML request timed out.');
  } on http.ClientException catch (error) {
    return result(HtmlSearchStatus.requestFailed, error.message);
  } finally {
    if (client == null) transport.close();
  }
}

/// Associates title, URL and cover within the same small card.
List<HtmlWorkCandidate> extractWorkCandidates({
  required Document doc,
  required Uri pageUri,
  String query = '',
  int maxResults = 30,
}) {
  if (maxResults < 1) throw ArgumentError.value(maxResults, 'maxResults');
  final base = _documentBase(doc, pageUri);
  final found = <String, HtmlWorkCandidate>{};
  for (final anchor in doc.querySelectorAll('a[href]')) {
    if (_inNavigation(anchor)) continue;
    final img = anchor.querySelector('img');
    if (img == null) continue;
    final url = _resolveWeb(base, anchor.attributes['href']);
    if (url == null ||
        url.origin != pageUri.origin ||
        url.removeFragment() == pageUri.removeFragment()) {
      continue;
    }
    final cover = _coverUri(img, base);
    if (cover == null) continue;
    final title = _cardTitle(anchor, img, url, base);
    if (title == null) continue;
    final key = url.removeFragment().toString();
    found.putIfAbsent(
        key,
        () => HtmlWorkCandidate(
              title: title,
              url: url.removeFragment(),
              cover: cover,
              matchesQuery: _matchesQuery(title, query),
            ));
  }
  final ordered = found.values.toList();
  ordered.sort((a, b) => (b.matchesQuery ? 1 : 0) - (a.matchesQuery ? 1 : 0));
  return ordered.take(maxResults).toList();
}

String? _cardTitle(Element anchor, Element img, Uri url, Uri base) {
  final explicit = _titleText(anchor.attributes['title'] ?? '');
  if (explicit != null) return explicit;
  final imageTitle = _titleText((img.attributes['alt'] ?? '').replaceFirst(
      RegExp(
          r'^(thumbnail|cover|image|poster)\s+(for|of)\s+|^capa\s+(de|do|da)\s+',
          caseSensitive: false),
      ''));
  Element? scope = anchor;
  for (var depth = 0; scope != null && depth < 4; depth++) {
    if (_inNavigation(scope) ||
        scope.localName == 'body' ||
        scope.localName == 'main') {
      break;
    }
    final imageTargets = scope
        .querySelectorAll('a[href]')
        .where((a) => a.querySelector('img') != null)
        .map((a) => _resolveWeb(base, a.attributes['href'])?.removeFragment())
        .whereType<Uri>()
        .toSet();
    if (imageTargets.length > 1) break;
    for (final link in scope.querySelectorAll('a[href]')) {
      if (_resolveWeb(base, link.attributes['href'])?.removeFragment() !=
          url.removeFragment()) {
        continue;
      }
      final title = _titleText(link.attributes['title'] ?? link.text);
      if (title != null) return title;
    }
    if (depth > 0 && imageTitle != null) return imageTitle;
    for (final titleNode in scope.querySelectorAll(
        'h1, h2, h3, h4, h5, h6, [itemprop="name"], [class*="title"]')) {
      final title = _titleText(titleNode.text);
      if (title != null) return title;
    }
    scope = scope.parent;
  }
  return _titleText(anchor.text) ?? imageTitle;
}

String? _titleText(String text) {
  final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.length < 2 || value.length > 180) return null;
  if (RegExp(
          r'^(logo|cover|capa|poster|image|imagem|thumbnail|read|ler|leia|'
          r'home|início|inicio|login|entrar|próximo|anterior|preview|prévia|'
          r'resultados|search results|recomendações|recommendations)$',
          caseSensitive: false)
      .hasMatch(value)) {
    return null;
  }
  if (RegExp(r'^(cap[.íitulo\s]*|chapter\s*)\d', caseSensitive: false)
      .hasMatch(value)) {
    return null;
  }
  return value;
}

Uri? _coverUri(Element img, Uri base) {
  for (final key in ['data-src', 'data-lazy-src', 'data-original', 'src']) {
    final raw = img.attributes[key]?.trim();
    if (raw == null ||
        raw.isEmpty ||
        RegExp(r'(placeholder|content_cover_default|blank\.(gif|png))',
                caseSensitive: false)
            .hasMatch(raw)) {
      continue;
    }
    final uri = _resolveWeb(base, raw);
    if (uri == null) continue;
    final fileName = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (RegExp(r'^logo(?:[-_].*)?\.(svg|png|jpg|jpeg|gif|webp)$',
            caseSensitive: false)
        .hasMatch(fileName)) {
      continue;
    }
    return uri;
  }
  return null;
}

bool _inNavigation(Element element) {
  Element? node = element;
  while (node != null) {
    if (['nav', 'header', 'footer', 'aside'].contains(node.localName) ||
        ['navigation', 'banner', 'contentinfo']
            .contains(node.attributes['role'])) {
      return true;
    }
    node = node.parent;
  }
  return false;
}

bool _matchesQuery(String title, String query) {
  String fold(String text) {
    const accented = 'áàâãäéèêëíìîïóòôõöúùûüç';
    const plain = 'aaaaaeeeeiiiiooooouuuuc';
    var value = text.toLowerCase();
    for (var i = 0; i < accented.length; i++) {
      value = value.replaceAll(accented[i], plain[i]);
    }
    return value.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  final terms =
      fold(query).split(' ').where((word) => word.isNotEmpty).toList();
  final name = fold(title);
  return terms.isNotEmpty && terms.every(name.contains);
}

Uri? _searchPageLink(Document doc, Uri pageUri) {
  final base = _documentBase(doc, pageUri);
  for (final link in doc.querySelectorAll('a[href]')) {
    final uri = _resolveWeb(base, link.attributes['href']);
    if (uri == null ||
        uri.origin != pageUri.origin ||
        uri.removeFragment() == pageUri.removeFragment()) {
      continue;
    }
    final label = '${link.text} ${link.attributes['aria-label'] ?? ''} '
        '${link.attributes['title'] ?? ''}';
    if (RegExp(r'(^|/)(search|busca|buscar|pesquisa|pesquisar)/?$',
                caseSensitive: false)
            .hasMatch(uri.path) ||
        RegExp(r'^\s*(search|buscas?|buscar|pesquisar)\s*$',
                caseSensitive: false)
            .hasMatch(label.trim())) {
      return uri;
    }
  }
  return null;
}

Uri _documentBase(Document doc, Uri pageUri) =>
    _resolveWeb(pageUri, doc.querySelector('base[href]')?.attributes['href']) ??
    pageUri;

Uri? _resolveWeb(Uri base, String? value) {
  if (value == null || value.trim().isEmpty || value.trim().startsWith('#')) {
    return null;
  }
  try {
    final uri = base.resolve(value.trim());
    return _isWebUri(uri) ? uri : null;
  } on FormatException {
    return null;
  }
}

bool _isWebUri(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

class _HtmlPage {
  final Uri uri;
  final Document doc;
  const _HtmlPage(this.uri, this.doc);
}

class _PageFailure implements Exception {
  final String message;
  const _PageFailure(this.message);
}

Future<_HtmlPage> _fetchHtml(
    http.Client client, Uri uri, Duration timeout, List<Uri> visited) async {
  var current = uri;
  for (var redirects = 0; redirects <= 5; redirects++) {
    visited.add(current);
    final request = http.Request('GET', current)
      ..followRedirects = false
      ..headers['accept'] = 'text/html,application/xhtml+xml';
    final streamed = await client.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed).timeout(timeout);
    if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
      final target = _resolveWeb(current, response.headers['location']);
      if (target == null) throw const _PageFailure('Invalid HTML redirect.');
      current = target;
      continue;
    }
    if (response.statusCode != 200) {
      throw _PageFailure('HTTP ${response.statusCode} while loading $current');
    }
    final type = response.headers['content-type']?.toLowerCase() ?? '';
    if (type.isNotEmpty &&
        !type.contains('text/html') &&
        !type.contains('application/xhtml+xml')) {
      throw _PageFailure('Expected HTML, received $type.');
    }
    late final String html;
    try {
      html = type.contains('charset=')
          ? response.body
          : utf8.decode(response.bodyBytes, allowMalformed: true);
    } on FormatException {
      throw const _PageFailure('Invalid text encoding in the HTML response.');
    }
    return _HtmlPage(current, parser.parse(html));
  }
  throw const _PageFailure('Too many HTML redirects.');
}
