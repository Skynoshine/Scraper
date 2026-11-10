import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;

import 'html_search.dart';
import 'reader_extraction.dart';
import 'search_discovery.dart';
import 'work_extraction.dart';

/// Reusable HTML rules bound to one source origin.
final class SourceProfile {
  final Uri sourceUri;
  final SearchForm? searchForm;
  final Map<String, String> workSelectors;
  final Map<String, String> readerSelectors;
  final String workStrategy;
  final String readerStrategy;

  SourceProfile({
    required this.sourceUri,
    this.searchForm,
    Map<String, String> workSelectors = const {},
    Map<String, String> readerSelectors = const {},
    this.workStrategy = 'unresolved',
    this.readerStrategy = 'unresolved',
  })  : workSelectors = Map.unmodifiable(workSelectors),
        readerSelectors = Map.unmodifiable(readerSelectors) {
    if (!_web(sourceUri) ||
        (searchForm != null && searchForm!.action.origin != sourceUri.origin)) {
      throw ArgumentError('Profile URLs must belong to the source origin.');
    }
  }

  /// Serializes extraction rules and form fields, not response bodies.
  Map<String, Object?> toJson() => {
        'version': 1,
        'sourceUrl': sourceUri.toString(),
        'searchForm': searchForm?.toJson(),
        'workSelectors': workSelectors,
        'readerSelectors': readerSelectors,
        'workStrategy': workStrategy,
        'readerStrategy': readerStrategy,
      };

  /// Rejects malformed or unsupported profiles before making requests.
  factory SourceProfile.fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] != 1) {
        throw const FormatException('Unsupported source profile version.');
      }
      return SourceProfile(
        sourceUri: Uri.parse(json['sourceUrl'] as String),
        searchForm: json['searchForm'] == null
            ? null
            : SearchForm.fromJson(
                Map<String, dynamic>.from(json['searchForm'] as Map)),
        workSelectors: Map<String, String>.from(json['workSelectors'] as Map),
        readerSelectors:
            Map<String, String>.from(json['readerSelectors'] as Map),
        workStrategy: json['workStrategy'] as String,
        readerStrategy: json['readerStrategy'] as String,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Malformed source profile.');
    }
  }
}

/// One observed HTTP request; headers and response bodies are not retained.
final class SourceRequest {
  final String role;
  final String method;
  final Uri url;
  int? statusCode;
  String? contentType;
  String? failure;

  SourceRequest._(this.role, this.method, this.url);

  Map<String, Object?> toJson() => {
        'role': role,
        'method': method,
        'url': url.toString(),
        'status': statusCode,
        'contentType': contentType,
        'failure': failure,
      };
}

/// Results for one work and one sample chapter, not a complete source audit.
final class SourceInspection {
  final Uri sourceUri;
  final String? query;
  final HtmlSearchResult? search;
  final Uri? workUri;
  final Uri? chapterUri;
  final WorkExtractionResult? work;
  final ReaderExtractionResult? reader;
  final SourceProfile? profile;
  final List<SourceRequest> endpoints;
  final List<String> warnings;
  final int? imageProbeStatus;
  final String? imageProbeContentType;

  SourceInspection({
    required this.sourceUri,
    this.query,
    this.search,
    this.workUri,
    this.chapterUri,
    this.work,
    this.reader,
    this.profile,
    Iterable<SourceRequest> endpoints = const [],
    Iterable<String> warnings = const [],
    this.imageProbeStatus,
    this.imageProbeContentType,
  })  : endpoints = List.unmodifiable(endpoints),
        warnings = List.unmodifiable(warnings);

  /// Image references were extracted; image downloads were not verified.
  bool get sampleFlowExtracted =>
      work != null &&
      work!.chapters.isNotEmpty &&
      reader != null &&
      reader!.pages.isNotEmpty;

  Map<String, Object?> toJson() => {
        'sourceUrl': sourceUri.toString(),
        'query': query,
        'search': search?.toJson(),
        'workUrl': workUri?.toString(),
        'chapterUrl': chapterUri?.toString(),
        'work': work?.toJson(),
        'reader': reader?.toJson(),
        'profile': profile?.toJson(),
        'endpoints': endpoints.map((item) => item.toJson()).toList(),
        'warnings': warnings,
        'sampleFlowExtracted': sampleFlowExtracted,
        'imageProbeStatus': imageProbeStatus,
        'imageProbeContentType': imageProbeContentType,
      };
}

/// Connects search, work and reader extraction using bounded HTML requests.
final class SourceInspector {
  final http.Client? client;
  final Duration timeout;
  final int maxRequests;
  final int maxChapterListPages;

  SourceInspector({
    this.client,
    this.timeout = const Duration(seconds: 20),
    this.maxRequests = 16,
    this.maxChapterListPages = 3,
  }) {
    if (timeout <= Duration.zero ||
        maxRequests < 1 ||
        maxChapterListPages < 0) {
      throw ArgumentError(
          'Use positive timeout/request limits and nonnegative pages.');
    }
  }

  /// Inspects an explicit work or a uniquely matched search result.
  Future<SourceInspection> inspect({
    required Uri sourceUri,
    String? query,
    Uri? workUri,
    Uri? chapterUri,
    SourceProfile? profile,
    bool probeFirstImage = false,
  }) async {
    if (!_web(sourceUri) ||
        (workUri != null && !_sameOrigin(sourceUri, workUri)) ||
        (chapterUri != null && !_sameOrigin(sourceUri, chapterUri))) {
      throw ArgumentError('Use HTTP(S) URLs from the same source origin.');
    }
    if (workUri == null && (query == null || query.trim().isEmpty)) {
      throw ArgumentError('Provide a query or an explicit work URL.');
    }
    final transport = _TrackedClient(client ?? http.Client(), sourceUri,
        maxRequests: maxRequests, timeout: timeout);
    final warnings = <String>[];
    HtmlSearchResult? search;
    WorkExtractionResult? work;
    ReaderExtractionResult? reader;
    SearchForm? form;
    int? imageStatus;
    String? imageType;
    var selectedWork = workUri;
    var selectedChapter = chapterUri;
    String? expectedTitle;
    var workIdentityAccepted = false;

    if (profile != null && profile.sourceUri.origin != sourceUri.origin) {
      warnings.add('Profile origin mismatch; saved rules were ignored.');
      profile = null;
    }
    form = profile?.searchForm;

    SourceInspection result() => SourceInspection(
          sourceUri: sourceUri,
          query: query,
          search: search,
          workUri: selectedWork,
          chapterUri: selectedChapter,
          work: work,
          reader: reader,
          profile: work == null || !workIdentityAccepted
              ? null
              : SourceProfile(
                  sourceUri: sourceUri,
                  searchForm: form,
                  workSelectors: work.selectors,
                  readerSelectors: reader?.selectors ?? const {},
                  workStrategy: work.strategy,
                  readerStrategy: reader?.strategy ?? 'unresolved',
                ),
          endpoints: transport.records,
          warnings: warnings.toSet(),
          imageProbeStatus: imageStatus,
          imageProbeContentType: imageType,
        );

    try {
      if (selectedWork == null) {
        final term = query!.trim();
        transport.role = 'search';
        if (form != null) {
          try {
            final page = await _fetchHtml(transport, form.buildUri(term));
            final works = extractWorkCandidates(
                doc: page.doc, pageUri: page.uri, query: term);
            search = HtmlSearchResult(
              status: works.isEmpty
                  ? HtmlSearchStatus.noCandidates
                  : HtmlSearchStatus.candidatesFound,
              entryUri: sourceUri,
              searchUri: page.uri,
              form: form,
              works: works,
              visited: transport.records.map((item) => item.url),
              message:
                  'Saved search form applied; candidates need verification.',
            );
          } on _FetchFailure catch (error) {
            warnings.add('Saved search failed: $error');
          } on http.ClientException catch (error) {
            warnings.add('Saved search failed: ${error.message}');
          } on TimeoutException {
            warnings.add('Saved search timed out.');
          }
        }
        if (search == null || !search.works.any((item) => item.matchesQuery)) {
          if (form != null) {
            warnings
                .add('Saved search was not usable; rediscovering the form.');
          }
          search = await searchHtml(
              entryUri: sourceUri,
              query: term,
              client: transport,
              timeout: timeout);
        }
        form = search.form;
        if (search.status != HtmlSearchStatus.candidatesFound) {
          warnings.add('Search ${search.status.name}: ${search.message}');
          return result();
        }
        final exact = search.works
            .where((item) => _fold(item.title) == _fold(term))
            .toList();
        final matches = exact.isNotEmpty
            ? exact
            : search.works.where((item) => item.matchesQuery).toList();
        if (matches.length != 1) {
          warnings.add(
              'Search selection is ambiguous or unmatched; provide workUri.');
          return result();
        }
        selectedWork = matches.single.url;
        expectedTitle = matches.single.title;
      }

      transport.role = 'work';
      final page = await _fetchHtml(transport, selectedWork);
      selectedWork = page.uri;
      work = extractWorkDetails(
          doc: page.doc,
          pageUri: page.uri,
          expectedTitle: expectedTitle,
          selectors: profile?.workSelectors);
      warnings.addAll(work.warnings);
      if (expectedTitle != null &&
          (work.title == null || _fold(work.title!) != _fold(expectedTitle))) {
        warnings.add(
            'Work identity could not be confirmed; chapter navigation stopped.');
        return result();
      }

      workIdentityAccepted = work.title != null;

      final chapters = <Uri, ChapterReference>{
        for (final chapter in work.chapters) chapter.url: chapter,
      };
      final pending = <Uri>[...work.continuationUrls];
      final visited = <Uri>{page.uri};
      var continuationCount = 0;
      var partial = work.mayHaveMore;
      while (pending.isNotEmpty && continuationCount < maxChapterListPages) {
        final next = pending.removeAt(0);
        if (!visited.add(next)) continue;
        if (!_sameWorkRoute(page.uri, next)) {
          warnings.add('An unrelated chapter-list continuation was skipped.');
          partial = true;
          continue;
        }
        continuationCount++;
        transport.role = 'chapterList';
        try {
          final extraPage = await _fetchHtml(transport, next);
          if (!_sameWorkRoute(page.uri, extraPage.uri)) {
            warnings
                .add('A continuation redirected away from the work; ignored.');
            partial = true;
            continue;
          }
          final extra = extractWorkDetails(
              doc: extraPage.doc,
              pageUri: extraPage.uri,
              selectors: work.selectors);
          if (extra.title != null &&
              work.title != null &&
              _fold(extra.title!) != _fold(work.title!)) {
            warnings.add('A continuation has a different work title; ignored.');
            partial = true;
            continue;
          }
          for (final chapter in extra.chapters) {
            chapters.putIfAbsent(chapter.url, () => chapter);
          }
          warnings.addAll(extra.warnings);
          partial |= extra.mayHaveMore;
          pending.addAll(
              extra.continuationUrls.where((url) => !visited.contains(url)));
        } on _FetchFailure catch (error) {
          warnings.add('Chapter continuation failed: $error');
          partial = true;
        } on http.ClientException catch (error) {
          warnings.add('Chapter continuation failed: ${error.message}');
          partial = true;
          break;
        } on TimeoutException {
          warnings.add('Chapter continuation timed out.');
          partial = true;
        }
      }
      if (pending.isNotEmpty) {
        warnings
            .add('Chapter-list continuation limit reached; some pages remain.');
        partial = true;
      }
      work = WorkExtractionResult(
        title: work.title,
        synopsis: work.synopsis,
        cover: work.cover,
        chapters: chapters.values,
        continuationUrls: pending.toSet(),
        mayHaveMore: partial,
        strategy: work.strategy,
        selectors: work.selectors,
        warnings: work.warnings,
      );
      if (selectedChapter != null && !chapters.containsKey(selectedChapter)) {
        warnings.add(
            'The supplied chapter was not in the observed work list; stopped.');
        return result();
      }
      if (selectedChapter == null) {
        if (chapters.isEmpty) {
          warnings
              .add('No chapter reference is available for a reader sample.');
          return result();
        }
        selectedChapter = chapters.keys.first;
        warnings.add(
            'The first chapter in document order was selected as a sample.');
      }
      if (!_sameOrigin(sourceUri, selectedChapter)) {
        warnings.add('The chapter uses another origin and needs review.');
        return result();
      }
      transport.role = 'reader';
      final readerPage = await _fetchHtml(transport, selectedChapter);
      if (!_sameChapter(selectedChapter, readerPage.uri)) {
        warnings.add(
            'Chapter redirected to another identity; reader needs inspection.');
        return result();
      }
      selectedChapter = readerPage.uri;
      reader = extractReaderPages(
          doc: readerPage.doc,
          pageUri: readerPage.uri,
          selectors: profile?.readerSelectors);
      warnings.addAll(reader.warnings);
      if (reader.pages.isNotEmpty && probeFirstImage) {
        transport.role = 'imageProbe';
        try {
          final response = await transport.send(
              http.Request('HEAD', reader.pages.first)
                ..followRedirects = false);
          imageStatus = response.statusCode;
          imageType = response.headers['content-type'];
          await response.stream.drain<void>();
          if (imageStatus < 200 ||
              imageStatus >= 300 ||
              !(imageType ?? '').toLowerCase().startsWith('image/')) {
            warnings
                .add('The first image HEAD response did not confirm an image.');
          }
        } on http.ClientException catch (error) {
          warnings.add('Image HEAD probe failed: ${error.message}');
        } on TimeoutException {
          warnings.add('Image HEAD probe timed out.');
        }
      }
      return result();
    } on _FetchFailure catch (error) {
      warnings.add(error.toString());
      return result();
    } on http.ClientException catch (error) {
      warnings.add(error.message);
      return result();
    } on TimeoutException {
      warnings.add('The ${transport.role} request timed out.');
      return result();
    } finally {
      if (client == null) transport.inner.close();
    }
  }
}

/// Counts every network request, including search redirects and image probes.
final class _TrackedClient extends http.BaseClient {
  final http.Client inner;
  final Uri source;
  final int maxRequests;
  final Duration timeout;
  final List<SourceRequest> records = [];
  String role = 'search';
  _TrackedClient(this.inner, this.source,
      {required this.maxRequests, required this.timeout});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_web(request.url) ||
        (role != 'imageProbe' && !_sameOrigin(source, request.url))) {
      throw http.ClientException(
          'Request outside the source origin was blocked.', request.url);
    }
    if (records.length >= maxRequests) {
      throw http.ClientException(
          'The inspection request limit was reached.', request.url);
    }
    final record = SourceRequest._(role, request.method, request.url);
    records.add(record);
    final clock = Stopwatch()..start();
    try {
      var headersTimedOut = false;
      final pending = inner.send(request);
      // A late response must release its stream without closing a shared client.
      unawaited(pending.then<void>((lateResponse) {
        if (headersTimedOut) {
          unawaited(lateResponse.stream.listen((_) {}).cancel());
        }
      }, onError: (Object _, StackTrace __) {}));
      final response = await pending.timeout(timeout, onTimeout: () {
        headersTimedOut = true;
        throw TimeoutException(
            'Response headers exceeded the request deadline.', timeout);
      });
      record.statusCode = response.statusCode;
      record.contentType = response.headers['content-type'];
      final body = _deadlineBody(
          response.stream, timeout - clock.elapsed, request.url, record);

      return http.StreamedResponse(body, response.statusCode,
          headers: response.headers,
          request: request,
          reasonPhrase: response.reasonPhrase);
    } on Object catch (error) {
      record.failure = error.toString();
      rethrow;
    }
  }
}

/// Enforces one body deadline and cancels the source subscription on failure.
Stream<List<int>> _deadlineBody(Stream<List<int>> source, Duration remaining,
    Uri url, SourceRequest record) {
  final clock = Stopwatch()..start();
  StreamSubscription<List<int>>? subscription;
  Timer? timer;
  var finished = false;
  var bytes = 0;
  final output = StreamController<List<int>>();

  void fail(Object error, StackTrace stack) {
    if (finished) return;
    finished = true;
    timer?.cancel();
    record.failure = error.toString();
    output.addError(error, stack);
    unawaited(subscription?.cancel() ?? Future<void>.value());
    unawaited(output.close());
  }

  output.onListen = () {
    final budget = remaining - clock.elapsed;
    timer = Timer(budget > Duration.zero ? budget : Duration.zero, () {
      fail(TimeoutException('Response body exceeded the request deadline.'),
          StackTrace.current);
    });
    subscription = source.listen((chunk) {
      if (finished) return;
      bytes += chunk.length;
      if (bytes > 5 * 1024 * 1024) {
        fail(
            http.ClientException('HTML response exceeds the 5 MiB limit.', url),
            StackTrace.current);
      } else {
        output.add(chunk);
      }
    }, onError: (Object error, StackTrace stack) {
      fail(error, stack);
    }, onDone: () {
      if (finished) return;
      finished = true;
      timer?.cancel();
      unawaited(output.close());
    });
  };
  output.onCancel = () {
    finished = true;
    timer?.cancel();
    return subscription?.cancel();
  };
  return output.stream;
}

final class _HtmlPage {
  final Document doc;
  final Uri uri;
  const _HtmlPage(this.doc, this.uri);
}

final class _FetchFailure implements Exception {
  final String code;
  final Uri url;
  const _FetchFailure(this.code, this.url);
  @override
  String toString() => '$code: $url';
}

/// Follows bounded same-origin redirects and preserves the final document URL.
Future<_HtmlPage> _fetchHtml(_TrackedClient client, Uri uri) async {
  var current = uri;
  for (var redirects = 0; redirects <= 5; redirects++) {
    final streamed = await client.send(http.Request('GET', current)
      ..followRedirects = false
      ..headers['accept'] = 'text/html,application/xhtml+xml');
    final response = await http.Response.fromStream(streamed);
    if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = response.headers['location'];
      if (location == null) throw _FetchFailure('invalidRedirect', current);
      try {
        current = current.resolve(location).removeFragment();
      } on FormatException {
        throw _FetchFailure('invalidRedirect', current);
      }
      continue;
    }
    if (response.statusCode != 200) {
      throw _FetchFailure('http${response.statusCode}', current);
    }
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    if (type.isNotEmpty &&
        !type.contains('text/html') &&
        !type.contains('application/xhtml+xml')) {
      throw _FetchFailure('nonHtmlResponse', current);
    }
    try {
      final body = type.contains('charset=')
          ? response.body
          : utf8.decode(response.bodyBytes, allowMalformed: true);
      return _HtmlPage(parser.parse(body), current);
    } on FormatException {
      throw _FetchFailure('invalidHtmlEncoding', current);
    }
  }
  throw _FetchFailure('redirectLimit', current);
}

bool _web(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

bool _sameOrigin(Uri source, Uri other) =>
    _web(other) && source.origin == other.origin;

/// Allows canonical trailing-slash changes without changing chapter identifiers.
bool _sameChapter(Uri original, Uri target) {
  if (!_sameOrigin(original, target) ||
      original.path.replaceFirst(RegExp(r'/$'), '') !=
          target.path.replaceFirst(RegExp(r'/$'), '')) {
    return false;
  }
  final oldQuery = original.queryParametersAll;
  final newQuery = target.queryParametersAll;
  if (oldQuery.length != newQuery.length) return false;
  for (final entry in oldQuery.entries) {
    final values = newQuery[entry.key];
    if (values == null || values.length != entry.value.length) return false;
    for (var i = 0; i < values.length; i++) {
      if (values[i] != entry.value[i]) return false;
    }
  }
  return true;
}

String _fold(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// Preserves work identifiers while allowing observed pagination parameters.
bool _sameWorkRoute(Uri work, Uri next) {
  if (!_sameOrigin(work, next)) return false;
  const pagination = {
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
    'page_size'
  };
  for (final key in next.queryParametersAll.keys) {
    if (!work.queryParametersAll.containsKey(key) &&
        !pagination.contains(key.toLowerCase())) {
      return false;
    }
  }
  for (final entry in work.queryParametersAll.entries) {
    if (pagination.contains(entry.key.toLowerCase())) continue;
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
