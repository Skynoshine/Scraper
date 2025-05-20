import 'package:html/dom.dart';

import '../src/scraper.dart';
import 'books_entity.dart';

/// Exemplo de uso de [elements] usando a classe [Scraper].
/// Este exemplo demonstra como usar a classe [Scraper] para fazer scraping de múltiplos elementos/conteúdo de uma página web.
void main() async {
  final String url = 'https://books.toscrape.com/';

  final Scraper scraper = Scraper();
  final Document doc = await scraper.getDocument(url: url);

  final List<BooksEntity> books = <BooksEntity>[];

  final List<Element> element = doc.querySelectorAll(
    '.col-xs-6.col-sm-4.col-md-3.col-lg-3',
  );

  for (final e in element) {
    final String? title = scraper.elementSelect(
      element: e,
      selector: 'h3 a',
    );

    final String? price = scraper.elementSelect(
      element: e,
      selector: 'p.price_color',
    );

    final String? availability = scraper.elementSelect(
      element: e,
      selector: 'p.availability',
    );
    final String? image = scraper.elementSelectAttr(
      element: e,
      selector: '.image_container img',
      attr: 'src',
    );
    final String? link = scraper.elementSelect(
      element: e,
      selector: 'h3 a',
    );
    books.add(
      BooksEntity(
        title: title ?? '',
        price: price ?? '',
        availability: availability ?? '',
        image: image ?? '',
        link: link ?? '',
      ),
    );
  }
  print('Total de livros: ${books.length}');
  for (final book in books) {
    print('-----------------------------------');
    print(book.toJson());
    print('-----------------------------------');
  }
}
