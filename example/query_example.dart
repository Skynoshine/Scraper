import 'package:html/dom.dart';

import '../bin/src/scraper.dart';
import 'books_entity.dart';

/// Exemplo de uso de Query usando a classe [Scraper].
/// Este exemplo demonstra como usar a classe [Scraper] para fazer scraping
/// A diferença entre este exemplo e o exemplo de [elements_example.dart] é que, [elements_example.dart] tem a finalidade de obter diversos elementos, como diversos livros.
Future<void> main() async {
  final Scraper scraper = Scraper();
  final String url = 'https://books.toscrape.com/';

  final Document doc = await scraper.getDocument(url: url);
  final String? title = scraper.querySelector(
    doc: doc,
    query: '.col-xs-6.col-sm-4.col-md-3.col-lg-3 h3 a',
  );
  final String? price = scraper.querySelector(
    doc: doc,
    query: '.col-xs-6.col-sm-4.col-md-3.col-lg-3 p.price_color',
  );
  final String? availability = scraper.querySelector(
    doc: doc,
    query: '.col-xs-6.col-sm-4.col-md-3.col-lg-3 p.availability',
  );
  final String? image = scraper.querySelectAttr(
    doc: doc,
    query: '.col-xs-6.col-sm-4.col-md-3.col-lg-3 .image_container img',
    attr: 'src',
  );
  final String? link = scraper.querySelectAttr(
    doc: doc,
    query: '.col-xs-6.col-sm-4.col-md-3.col-lg-3 h3 a',
    attr: 'href',
  );

  final books = BooksEntity(
    title: title ?? '',
    price: price ?? '',
    availability: availability ?? '',
    image: image ?? '',
    link: link ?? '',
  );
  print('-----------------------------------');
  print(books.toJson());
  print('-----------------------------------');
}
