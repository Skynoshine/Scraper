import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:logger/logger.dart';

class Scraper {
  Future<Document> document({required String url, bool? showPageBody}) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        if (showPageBody ?? false) {
          Logger().i(response.body);
        }

        return parser.parse(response.body);
      } else {
        throw Exception(
          'Failed to load document. \n StatusCode: ${response.statusCode}',
        );
      }
    } catch (e) {
      throw Exception('Error fetching document: $e');
    }
  }

  String? elementToString({required List<String> elements}) {
    try {
      return elements.join('\n');
    } catch (e) {
      Exception('Error in elementToString: $e');
      return null;
    }
  }

  String? elementSelec({required Element element, required String selector}) {
    try {
      return element.querySelector(selector)?.text.trim();
    } catch (e) {
      Exception('Error in elementSelec: $e');
      return null;
    }
  }

  String? elementSelecAttr({
    required Element element,
    required String selector,
    required String attr,
  }) {
    try {
      return element.querySelector(selector)?.attributes[attr];
    } catch (e) {
      Exception('Error in elementSelecAttr: $e');
      return null;
    }
  }

  String? docSelec(Document doc, String query) {
    try {
      return doc.querySelector(query)?.text.trim();
    } catch (e) {
      Exception('Error in docSelec: $e');
      return null;
    }
  }

  List<String>? docSelecAll({required Document doc, required String query}) {
    try {
      return doc.querySelectorAll(query).map((e) => e.text).toList();
    } catch (e) {
      Exception('Error in docSelecAll: $e');
      return null;
    }
  }

  List<String?>? docSelecAllAttr(
      {required Document doc, required String query, required String attr}) {
    try {
      return doc
          .querySelectorAll(query)
          .map((e) => e.attributes[attr])
          .toList();
    } catch (e) {
      Exception('Error in elementSelectAllAttr: $e');
      return null;
    }
  }

  List<String?>? elementSelectAllAttr(
      Element element, String query, String attr) {
    try {
      return element
          .querySelectorAll(query)
          .map((e) => e.attributes[attr])
          .toList();
    } catch (e) {
      Exception('Error in elementSelectAllAttr: $e');
      return null;
    }
  }

  List<String?>? removeHtmlElementsList(
      List<String?> content, List<String> elements) {
    try {
      final updatedContent =
          content.where((c) => !elements.any((e) => c!.contains(e))).toList();
      content.clear();
      content.addAll(updatedContent);
      return content;
    } catch (e) {
      Exception('Error in removeHtmlElementsList: $e');
      return null;
    }
  }

  String? docSelecAttr(
      {required Document doc, required String query, required String attr}) {
    try {
      return doc.querySelector(query)?.attributes[attr];
    } catch (e) {
      Exception('Error in docSelecAttr: $e');
      return null;
    }
  }

  List<String?>? removeHtmlElements(List<String?> content, String element) {
    try {
      final updatedContent =
          content.where((c) => !c!.contains(element)).toList();
      content.clear();
      content.addAll(updatedContent);
      return content;
    } catch (e) {
      Exception('Error in removeHtmlElements: $e');
      return null;
    }
  }

  List<String>? extractImage({
    required Document doc,
    required String query,
    required List<String> tagSelector,
    required String attr,
  }) {
    try {
      final images = docSelecAttr(doc: doc, query: query, attr: attr);
      final imagesElements = doc.querySelectorAll(query);
      final Set<String> uniqueImages = {};

      for (var selector in tagSelector) {
        for (var element in imagesElements) {
          final attrValue = element.attributes[selector];
          if (attrValue != null) {
            uniqueImages.add(attrValue);
          }
        }
      }
      if (images != null) {
        uniqueImages.add(images);
      }
      return uniqueImages.toList();
    } catch (e) {
      Exception('Error in extractImage: $e');
      return null;
    }
  }

  List<String>? extractImagesAttr({
    required Document doc,
    required String query,
    required List<String> tagSelector,
    required String attr,
  }) {
    try {
      final Set<String> uniqueImages = {};
      final imagesElements = doc.querySelectorAll(query);

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
      Exception('Error in Error in extractText: $e: $e');
      return null;
    }
  }

  List<String>? extractText({
    required Document doc,
    required String query,
    required Map<String, String> tagToSelector,
  }) {
    try {
      final List<String> result = [];
      for (var selector in tagToSelector.values) {
        result.addAll(doc
            .querySelectorAll('$query $selector')
            .map((e) => e.text)
            .where((text) => text.isNotEmpty));
      }
      return result;
    } catch (e) {
      Exception('Error in extractText: $e');
      return null;
    }
  }
}
