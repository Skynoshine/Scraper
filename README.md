# Scraper

Scraper is a Dart library designed for web scraping. It allows you to fetch and parse HTML documents from websites, extract specific elements using CSS selectors, and manipulate the extracted data. The main features include:

* Fetching HTML documents
* Extracting text content and attribute values from HTML elements
* Removing unwanted elements from the extracted data

The library also supports logging responses for debugging purposes. It's a useful tool for automating data collection from websites in an efficient and structured manner.

## Example

```dart
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
```

## Features

### Fetch and Parse HTML Document

* Fetches and parses an HTML document from the provided URL. Optionally logs the page body if `showPageBody` is `true`.

* Converts a list of elements into a single string.

* Selects a single element from the provided element based on the CSS selector and returns its text content.

* Selects a single element from the provided element based on the CSS selector and returns the value of the specified attribute.

* Selects a single element from the document based on the CSS selector and returns its text content.

* Selects all elements from the document based on the CSS selector and returns a list of their text contents.

* Selects all elements from the document based on the CSS selector and returns a list of the specified attribute values.

* Removes specific HTML elements from the list of contents.

* Extracts unique image sources from the document based on the CSS selector and specified attribute.

* Extracts unique attribute values from the document based on the CSS selector and specified attribute.

* Extracts text content from the document based on the CSS selector and the specified tag-to-selector map.
