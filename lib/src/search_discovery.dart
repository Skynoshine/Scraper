import 'dart:convert';

import 'package:html/dom.dart';

/// A static GET search candidate; no submit button or script is executed.
final class SearchForm {
  final Uri action;
  final String queryField;
  final Map<String, List<String>> fields;
  final List<String> evidence;
  final int _queryValueIndex;

  /// For manual construction, the first query-field value is replaced.
  SearchForm({
    required Uri action,
    required String queryField,
    required Map<String, List<String>> fields,
    List<String> evidence = const [],
  }) : this._(
          action: action,
          queryField: queryField,
          fields: fields,
          evidence: evidence,
          queryValueIndex: 0,
        );

  SearchForm._({
    required this.action,
    required this.queryField,
    required Map<String, List<String>> fields,
    required List<String> evidence,
    required int queryValueIndex,
  })  : fields = Map.unmodifiable({
          for (final entry in fields.entries)
            entry.key: List<String>.unmodifiable(entry.value),
        }),
        evidence = List.unmodifiable(evidence),
        _queryValueIndex = queryValueIndex {
    if (!_isHttpUrl(action) || queryField.isEmpty) {
      throw ArgumentError(
          'A search form needs an HTTP(S) URL and a query name.');
    }
  }

  /// Replaces the editable value and the action URL's existing query.
  Uri buildUri(String query) {
    final pairs = <String>[];
    for (final entry in _parameters(query).entries) {
      final name = Uri.encodeQueryComponent(_lineBreaks(entry.key));
      for (final value in entry.value) {
        final encoded = Uri.encodeQueryComponent(_lineBreaks(value));
        pairs.add('$name=$encoded');
      }
    }
    return action.replace(query: pairs.join('&'));
  }

  Map<String, Object> toJson() => {
        'action': action.toString(),
        'queryField': queryField,
        'fields': fields,
        'evidence': evidence,
      };

  Map<String, List<String>> _parameters(String query) {
    final result = {
      for (final entry in fields.entries)
        entry.key: List<String>.of(entry.value),
    };
    final values = result.putIfAbsent(queryField, () => []);
    if (_queryValueIndex < values.length) {
      values[_queryValueIndex] = query;
    } else {
      values.add(query);
    }
    return result;
  }
}

/// Finds catalogue searches, ranked by static evidence, without making requests.
List<SearchForm> discoverSearchForms({
  required Document doc,
  required Uri pageUri,
}) {
  if (!_isHttpUrl(pageUri)) return const [];

  final firstIds = <String, Element>{};
  for (final element in doc.querySelectorAll('[id]')) {
    firstIds.putIfAbsent(element.id, () => element);
  }
  final forms = doc.querySelectorAll('form');
  final owned = {for (final form in forms) form: <Element>[]};
  for (final control
      in doc.querySelectorAll('input, select, textarea, button')) {
    if (_inside(control, 'template') || _inside(control, 'datalist')) continue;
    owned[_owner(control, firstIds)]?.add(control);
  }

  var baseUri = pageUri;
  final baseHref = doc.querySelector('base[href]')?.attributes['href'];
  if (baseHref != null) {
    baseUri = _resolve(pageUri, baseHref) ?? pageUri;
  }
  final labels = doc.querySelectorAll('label');
  final candidates = <_RankedForm>[];

  for (var order = 0; order < forms.length; order++) {
    final form = forms[order];
    if (_inside(form, 'template')) continue;
    final method = (form.attributes['method'] ?? '').trim().toLowerCase();
    if (method.isNotEmpty && method != 'get') continue;
    final rawAction = (form.attributes['action'] ?? '').trim();
    final action = rawAction.isEmpty ? pageUri : _resolve(baseUri, rawAction);
    if (action == null || !_isHttpUrl(action)) continue;

    final controls = owned[form]!;
    final context = _attributes(form, ['id', 'name', 'class', 'aria-label']);
    if (_isLogin(controls, context, action)) continue;

    final queries = <_QueryField>[];
    for (final control in controls) {
      if (!_isEditableText(control) || _disabled(control)) continue;
      if ((control.attributes['name'] ?? '').isEmpty) continue;
      final label = _labelText(control, labels, firstIds);
      final ownHints = _attributes(
        control,
        ['name', 'id', 'placeholder', 'aria-label', 'title'],
      );
      if (_chapterSearch('$ownHints $label $context')) continue;
      final query = _rankField(control, form, label, context);
      if (query.score > 0) queries.add(query);
    }
    if (queries.isEmpty) continue;
    // Keep document order when two fields have equal evidence.
    var chosen = queries.first;
    for (final query in queries.skip(1)) {
      if (query.score > chosen.score) chosen = query;
    }

    final values = _formValues(controls, chosen.control);
    final evidence = <String>[
      ...chosen.evidence,
      method.isEmpty
          ? 'GET is the HTML default method.'
          : 'Explicit GET method.',
      rawAction.isEmpty
          ? 'Empty or missing action uses the current page URL.'
          : 'Action resolved against the document base URL.',
      'Static HTML values only; scripts and browser validation are not run.',
    ];
    if (queries.length > 1) {
      evidence.add('Multiple text fields; strongest hints selected the query.');
    }
    final active = controls.where((control) => !_disabled(control)).toList();
    final submitters = active.where(_isSubmitter).toList();
    if (submitters.any((button) => button.attributes.keys.any(
          (key) => const {
            'formaction',
            'formmethod',
            'formenctype',
            'formtarget',
            'formnovalidate',
          }.contains(key.toString().toLowerCase()),
        ))) {
      evidence
          .add('Submit-button overrides are not applied; no button selected.');
    }
    if (submitters.any((button) => button.attributes.containsKey('name'))) {
      evidence.add('Submit-button names and values are omitted.');
    }
    if ([form, ...active].any(_hasHandler)) {
      evidence.add('Inline event handlers may change the native GET behavior.');
    }
    if (active.any((control) => _inputType(control) == 'file')) {
      evidence.add('File controls are omitted.');
    }
    if (action.scheme != pageUri.scheme ||
        action.host != pageUri.host ||
        action.port != pageUri.port) {
      evidence.add('Cross-origin action requires review before submission.');
    }

    candidates.add(_RankedForm(
      SearchForm._(
        action: action,
        queryField: chosen.control.attributes['name']!,
        fields: values.fields,
        evidence: evidence,
        queryValueIndex: values.queryIndex,
      ),
      chosen.score,
      order,
    ));
  }

  candidates.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore == 0 ? a.order.compareTo(b.order) : byScore;
  });
  final seen = <String>{};
  return List.unmodifiable([
    for (final candidate in candidates)
      if (seen.add(_signature(candidate.form))) candidate.form,
  ]);
}

_QueryField _rankField(
  Element control,
  Element form,
  String label,
  String context,
) {
  var score = 0;
  final evidence = <String>[];
  void add(bool matches, int points, String message) {
    if (matches) {
      score += points;
      evidence.add(message);
    }
  }

  add(_inputType(control) == 'search', 100, 'Input type is search.');
  add(_hasRole(control, 'searchbox'), 80, 'Input role is searchbox.');
  add(_searchLandmark(form), 70, 'Form belongs to a search landmark.');
  final name = _fold(control.attributes['name'] ?? '').trim();
  add(
    _searchWords(name) ||
        const {'q', 's', 'query', 'keyword', 'keywords', 'word', 'term'}
            .contains(name),
    45,
    'Field name suggests a search query.',
  );
  add(_searchWords(control.id), 35, 'Input id suggests search.');
  add(_searchWords(label), 40, 'Associated label suggests search.');
  add(
    _searchWords(_attributes(control, ['aria-label', 'title'])),
    40,
    'Accessible input label suggests search.',
  );
  add(
    _searchWords(control.attributes['placeholder'] ?? ''),
    30,
    'Input placeholder suggests search.',
  );
  add(_searchWords(context), 20, 'Form attributes suggest search.');
  return _QueryField(control, score, evidence);
}

_FormValues _formValues(List<Element> controls, Element query) {
  final fields = <String, List<String>>{};
  final lastCheckedRadio = <String, Element>{};
  for (final control in controls) {
    if (_inputType(control) == 'radio' &&
        control.attributes.containsKey('checked')) {
      lastCheckedRadio[control.attributes['name'] ?? ''] = control;
    }
  }
  var queryIndex = 0;
  for (final control in controls) {
    final name = control.attributes['name'] ?? '';
    if (name.isEmpty || _disabled(control)) continue;
    final values = <String>[];
    if (control.localName == 'select') {
      final options = control.querySelectorAll('option');
      var selected = options
          .where((option) => option.attributes.containsKey('selected'))
          .toList();
      if (!control.attributes.containsKey('multiple')) {
        if (selected.isNotEmpty) {
          selected = [selected.last];
        } else if ((int.tryParse(control.attributes['size'] ?? '') ?? 1) <= 1) {
          selected = options
              .where((option) => !_optionDisabled(option))
              .take(1)
              .toList();
        }
      }
      for (final option
          in selected.where((option) => !_optionDisabled(option))) {
        values.add(option.attributes['value'] ?? _optionText(option.text));
      }
    } else if (control.localName == 'textarea') {
      values.add(control.text);
    } else if (control.localName == 'input') {
      final type = _inputType(control);
      if (const {'submit', 'image', 'button', 'reset', 'file'}.contains(type)) {
        continue;
      }
      if (type == 'checkbox' || type == 'radio') {
        if (!control.attributes.containsKey('checked')) continue;
        if (type == 'radio' && lastCheckedRadio[name] != control) continue;
        values.add(control.attributes['value'] ?? 'on');
      } else {
        values.add(control.attributes['value'] ?? '');
      }
    }
    if (values.isEmpty) continue;
    final existing = fields.putIfAbsent(name, () => []);
    if (identical(control, query)) queryIndex = existing.length;
    existing.addAll(values);
  }
  return _FormValues(fields, queryIndex);
}

Element? _owner(Element control, Map<String, Element> firstIds) {
  final explicit = control.attributes['form'];
  if (explicit != null) {
    final owner = firstIds[explicit];
    return owner?.localName == 'form' ? owner : null;
  }
  for (var parent = control.parent; parent != null; parent = parent.parent) {
    if (parent.localName == 'form') return parent;
  }
  return null;
}

bool _disabled(Element control) {
  if (control.attributes.containsKey('disabled')) return true;
  for (var parent = control.parent; parent != null; parent = parent.parent) {
    if (parent.localName != 'fieldset' ||
        !parent.attributes.containsKey('disabled')) {
      continue;
    }
    final legends =
        parent.children.where((child) => child.localName == 'legend');
    if (legends.isEmpty || !_descendantOf(control, legends.first)) return true;
  }
  return false;
}

bool _optionDisabled(Element option) =>
    option.attributes.containsKey('disabled') ||
    (option.parent?.localName == 'optgroup' &&
        option.parent!.attributes.containsKey('disabled'));

bool _descendantOf(Element element, Element ancestor) {
  for (Element? current = element; current != null; current = current.parent) {
    if (identical(current, ancestor)) return true;
  }
  return false;
}

bool _inside(Element element, String tag) {
  for (var parent = element.parent; parent != null; parent = parent.parent) {
    if (parent.localName == tag) return true;
  }
  return false;
}

String _labelText(
  Element control,
  List<Element> labels,
  Map<String, Element> firstIds,
) {
  final texts = <String>[];
  for (final label in labels) {
    if (label.attributes.containsKey('for')) {
      if (identical(firstIds[label.attributes['for']], control)) {
        texts.add(label.text);
      }
    } else if (_descendantOf(control, label)) {
      texts.add(label.text);
    }
  }
  final labelledBy = control.attributes['aria-labelledby'] ?? '';
  for (final id in labelledBy.split(RegExp(r'\s+'))) {
    if (firstIds.containsKey(id)) texts.add(firstIds[id]!.text);
  }
  return texts.join(' ');
}

bool _isLogin(List<Element> controls, String context, Uri action) {
  if (_loginWords('$context ${action.path}')) return true;
  for (final control in controls) {
    if (_inputType(control) == 'password') return true;
    if (RegExp(r'\b(password|passwd|senha)\b').hasMatch(
      _fold(_attributes(control, ['name', 'id', 'autocomplete'])),
    )) {
      return true;
    }
    if (_isSubmitter(control) &&
        _loginWords('${control.text} ${control.attributes['value'] ?? ''}')) {
      return true;
    }
  }
  return false;
}

bool _isEditableText(Element control) =>
    !control.attributes.containsKey('readonly') &&
    (control.localName == 'textarea' ||
        (control.localName == 'input' &&
            const {'text', 'search'}.contains(_inputType(control))));

String _inputType(Element control) {
  if (control.localName != 'input') return '';
  final type = (control.attributes['type'] ?? 'text').trim().toLowerCase();
  const types = {
    'button',
    'checkbox',
    'color',
    'date',
    'datetime-local',
    'email',
    'file',
    'hidden',
    'image',
    'month',
    'number',
    'password',
    'radio',
    'range',
    'reset',
    'search',
    'submit',
    'tel',
    'text',
    'time',
    'url',
    'week',
  };
  return types.contains(type) ? type : 'text';
}

bool _isSubmitter(Element control) {
  if (control.localName == 'button') {
    final type = (control.attributes['type'] ?? '').trim().toLowerCase();
    return type != 'button' && type != 'reset';
  }
  return const {'submit', 'image'}.contains(_inputType(control));
}

bool _hasRole(Element element, String role) =>
    (element.attributes['role'] ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .contains(role);

bool _searchLandmark(Element form) {
  for (Element? current = form; current != null; current = current.parent) {
    if (current.localName == 'search' || _hasRole(current, 'search')) {
      return true;
    }
  }
  return false;
}

bool _hasHandler(Element element) => element.attributes.keys.any(
      (key) => RegExp(r'^on(submit|click|input|change|keydown|keyup|keypress)$')
          .hasMatch(key.toString().toLowerCase()),
    );

String _attributes(Element element, List<String> names) =>
    names.map((name) => element.attributes[name] ?? '').join(' ');

String _fold(String text) {
  var result = text
      .replaceAllMapped(
        RegExp(r'([a-z])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .toLowerCase();
  const accents = {
    '[áàâãä]': 'a',
    '[éèêë]': 'e',
    '[íìîï]': 'i',
    '[óòôõö]': 'o',
    '[úùûü]': 'u',
    'ç': 'c'
  };
  for (final entry in accents.entries) {
    result = result.replaceAll(RegExp(entry.key), entry.value);
  }
  return result.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
}

bool _searchWords(String text) => RegExp(
      r'\b(search|searchbox|query|buscar|busca|busqueda|pesquisa|pesquisar|procura|procurar)\b',
    ).hasMatch(_fold(text));

bool _loginWords(String text) => RegExp(
      r'\b(login|log in|signin|sign in|signon|logon|entrar|autenticar)\b',
    ).hasMatch(_fold(text));

bool _chapterSearch(String text) => RegExp(
      r'\b(chapter|chapters|capitulo|capitulos)\b',
    ).hasMatch(_fold(text));

Uri? _resolve(Uri base, String value) {
  final text = value.trim();
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) return null;
  try {
    return base.resolve(text);
  } on FormatException {
    return null;
  }
}

bool _isHttpUrl(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.authority.contains('@');

String _lineBreaks(String value) =>
    value.replaceAll(RegExp(r'\r\n|\r|\n'), '\r\n');

String _optionText(String value) => value
    .replaceAll(RegExp(r'^[\t\n\f\r ]+|[\t\n\f\r ]+$'), '')
    .replaceAll(RegExp(r'[\t\n\f\r ]+'), ' ');

String _signature(SearchForm form) {
  final values = form._parameters('');
  final keys = values.keys.toList()..sort();
  return jsonEncode([
    form.action.scheme,
    form.action.host,
    form.action.port,
    form.action.path,
    form.queryField,
    form._queryValueIndex,
    for (final key in keys) [key, values[key]],
  ]);
}

final class _QueryField {
  final Element control;
  final int score;
  final List<String> evidence;
  _QueryField(this.control, this.score, this.evidence);
}

final class _FormValues {
  final Map<String, List<String>> fields;
  final int queryIndex;
  _FormValues(this.fields, this.queryIndex);
}

final class _RankedForm {
  final SearchForm form;
  final int score;
  final int order;
  _RankedForm(this.form, this.score, this.order);
}
