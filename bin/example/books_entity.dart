class BooksEntity {
  final String title;
  final String price;
  final String availability;
  final String image;
  final String link;
  BooksEntity({
    required this.title,
    required this.price,
    required this.availability,
    required this.image,
    required this.link,
  });

  Map<String, String> toJson() {
    return {
      'title': title,
      'price': price,
      'availability': availability,
      'image': image,
      'link': link,
    };
  }
}
