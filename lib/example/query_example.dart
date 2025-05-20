import 'package:html/dom.dart';
import 'package:scraper/scraper.dart';

import 'books_entity.dart';

/// Example of using Query with the [Scraper] class.
/// This example demonstrates how to use the [Scraper] class for scraping.
/// The difference between this example and [elements_example.dart] is that [elements_example.dart] is intended to extract multiple elements, such as several books.
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
