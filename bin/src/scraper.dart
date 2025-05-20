import 'dart:io';
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;

class Scraper {
  /// Este método **deve ser chamado** para carregar e preparar o documento HTML
  /// antes de usar qualquer outro método da classe [Scraper].
  ///
  /// Ignorar essa chamada pode resultar em exceções ou dados nulos.
  ///
  /// Exemplo:
  /// ```dart
  /// final doc = await scraper.document(url: 'https://exemplo.com');
  /// ```
  ///
  Future<Document> getDocument({
    required String url,
    bool showPageBody = false,
    int statusCode = HttpStatus.ok,
  }) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == statusCode) {
        if (showPageBody) {
          print(response.body);
        }

        return parser.parse(response.body);
      } else {
        throw Exception(
          'Failed to load page: ${response.statusCode} ${response.reasonPhrase}',
        );
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Envia uma requisição POST para a URL e retorna o documento HTML da resposta.
  Future<Document> postDocument({
    required String url,
    Map<String, String>? headers,
    Object? body,
    int statusCode = HttpStatus.ok,
  }) async {
    try {
      final response = await http.post(
        headers: headers,
        Uri.parse(url),
        body: body,
      );
      if (response.statusCode == statusCode) {
        return parser.parse(response.body);
      } else {
        throw Exception(
          'Failed to load page: ${response.statusCode} ${response.reasonPhrase}',
        );
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna o texto de um seletor dentro de um elemento.
  String? elementSelect({
    required Element element,
    required String selector,
  }) {
    try {
      return element.querySelector(selector)?.text.trim();
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna o valor de um atributo de um seletor dentro de um elemento.
  String? elementSelectAttr({
    required Element element,
    required String selector,
    required String attr,
  }) {
    try {
      return element.querySelector(selector)?.attributes[attr];
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna o texto de um seletor dentro de um documento.
  String? querySelector({
    required Document doc,
    required String query,
  }) {
    try {
      return doc.querySelector(query)?.text.trim();
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna uma lista com os textos de todos os seletores encontrados.
  List<String>? querySelectorAll({
    required Document doc,
    required String query,
  }) {
    try {
      return doc.querySelectorAll(query).map((e) => e.text).toList();
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna os valores de um atributo específico de todos os seletores encontrados.
  List<String?>? querySelectAllAttr({
    required Document doc,
    required String query,
    required String attr,
  }) {
    try {
      return doc
          .querySelectorAll(query)
          .map((e) => e.attributes[attr])
          .toList();
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna os valores de um atributo específico de todos os seletores dentro de um elemento.
  List<String?>? elementSelectAllAttr({
    required Element element,
    required String query,
    required String attr,
  }) {
    try {
      return element
          .querySelectorAll(query)
          .map((e) => e.attributes[attr])
          .toList();
    } catch (e) {
      rethrow;
    }
  }

  /// Remove da lista [content] os itens que contenham qualquer string da lista [elements].
  List<String?> removeHtmlElement({
    required List<String?> content,
    required List<String> elements,
  }) {
    try {
      final updatedContent =
          content.where((c) => !elements.any((e) => c!.contains(e))).toList();
      content.clear();
      content.addAll(updatedContent);
      return content;
    } catch (e) {
      rethrow;
    }
  }

  /// Retorna o valor de um atributo específico do primeiro seletor encontrado.
  String? querySelectAttr({
    required Document doc,
    required String query,
    required String attr,
  }) {
    try {
      return doc.querySelector(query)?.attributes[attr];
    } catch (e) {
      rethrow;
    }
  }

  /// Extrai imagens (ou outros atributos) de um documento HTML.
  /// Pode incluir um valor direto do primeiro seletor encontrado, se [includeDirectAttr] for true.
  List<String>? extractImages({
    required Document doc,
    required String query,
    required List<String> tagSelector,
    String? attr,
    bool includeDirectAttr = false,
  }) {
    try {
      final Set<String> uniqueImages = {};
      final imagesElements = doc.querySelectorAll(query);
      if (includeDirectAttr && attr != null) {
        final directAttr = doc.querySelector(query)?.attributes[attr];
        if (directAttr != null) {
          uniqueImages.add(directAttr);
        }
      }
      for (var selector in tagSelector) {
        for (var element in imagesElements) {
          final attrValue = element.attributes[selector];
          if (attrValue != null) {
            uniqueImages.add(attrValue);
          }
        }
      }
      return uniqueImages.toList();
    } catch (e) {
      rethrow;
    }
  }

  /// Extrai textos de elementos HTML combinando queries com seletores.
  /// Retorna assim que encontra os primeiros elementos com texto.
  List<String>? extractText({
    required Document doc,
    required List<String> query,
    required List<String> tagToSelector,
  }) {
    try {
      final List<String> result = [];
      for (var query in query) {
        for (var selector in tagToSelector) {
          final elements = doc.querySelectorAll('$query $selector');
          if (elements.isNotEmpty) {
            result.addAll(
              elements.map((e) => e.text).where((text) => text.isNotEmpty),
            );
            return result;
          }
        }
      }
      return result.isNotEmpty ? result : null;
    } catch (e) {
      rethrow;
    }
  }
}
