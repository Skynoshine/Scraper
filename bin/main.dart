import 'package:logger/logger.dart';

import '../bin/src/scraper.dart';

void main() async {
  // Examples:
  final scraper = Scraper();
  final String url = 'https://books.toscrape.com/';
  final doc = await scraper.document(url: url);

  final webSiteTitle = scraper.docSelec(doc, 'title');
  //Response: All products | Books to Scrape - Sandbox
  Logger().i('Site title: $webSiteTitle');

  final uniqueCover = scraper.docSelecAttr(
      doc: doc, query: '.image_container img', attr: 'src');
  // Response: media/cache/2c/da/2cdad67c44b002e7ead0cc35693c0e8b.jpg
  Logger().i('Unique Cover: $uniqueCover');

  final allCovers =
      scraper.docSelecAllAttr(doc: doc, query: '.product_pod img', attr: 'src');
  // Response: [media/cache/2c/da/2cdad67c44b002e7ead0cc35693c0e8b.jpg, media/cache/26/0c/260c6ae16bce31c8f8c95daddd9f4a1c.jpg...]
  Logger().i('All covers: $url${allCovers!.join(', ')}');

  final price = scraper.docSelecAll(doc: doc, query: '.price_color');
  // Response: [£51.77, £53.74, £50.10, £47.82, £54.23...]
  Logger().i('Price: $price');

  final href = scraper.docSelecAllAttr(
      doc: doc, query: '.image_container a', attr: 'href');
  // Response: ["catalogue/a-light-in-the-attic_1000/index.html", "catalogue/tipping-the-velvet_999/index.html"...]
  Logger().i('Href: $url${href!.join(', ')}');
}
