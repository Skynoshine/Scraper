import 'dart:io';
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;

class Scraper {
  /// This method **must be called** to load and prepare the HTML document
  /// before using any other method from the [Scraper] class.
  ///
  /// Skipping this call may result in exceptions or null data.
  ///
  /// Example:
  /// ```dart
  /// final doc = await scraper.getDocument(url: 'https://example.com');
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

  /// Sends a POST request to the URL and returns the HTML document from the response.
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

  /// Returns the text from a selector inside an element.
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

  /// Returns the value of an attribute from a selector inside an element.
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

  /// Returns the text from a selector inside a document.
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

  /// Returns a list of texts from all matched selectors.
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

  /// Returns the values of a specific attribute from all matched selectors.
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

  /// Returns the values of a specific attribute from all selectors within an element.
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

  /// Removes from the [content] list any items containing any string from the [elements] list.
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

  /// Returns the value of a specific attribute from the first matched selector.
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

  /// Extracts image sources (or other attributes) from an HTML document.
  /// Can include a direct value from the first matched selector if [includeDirectAttr] is true.
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

  /// Extracts text from HTML elements by combining queries with selectors.
  /// Returns as soon as it finds the first elements with text.
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
