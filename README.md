O Scraper é uma biblioteca Dart projetada para web scraping. Ele permite obter e analisar documentos HTML de sites, extrair elementos específicos com base em seletores CSS e manipular os dados extraídos. As principais funcionalidades incluem buscar documentos HTML, extrair conteúdo de texto e valores de atributos de elementos HTML, e remover elementos indesejados dos dados extraídos. A biblioteca também oferece suporte para registrar respostas para fins de depuração. É uma ferramenta útil para automatizar a coleta de dados de sites de maneira eficiente e estruturada.

Future<Document> document({required String url, bool? showPageBody})
Busca e analisa um documento HTML a partir da URL fornecida. Opcionalmente, registra o corpo da página se showPageBody for true.

String? elementToString({required List<String> elements})
Converte uma lista de elementos em uma única string.

String? elementSelec({required Element element, required String selector})
Seleciona um único elemento do elemento fornecido com base no seletor CSS e retorna seu conteúdo de texto.

String? elementSelecAttr({required Element element, required String selector, required String attr})
Seleciona um único elemento do elemento fornecido com base no seletor CSS e retorna o valor do atributo especificado.

String? docSelec(Document doc, String query)
Seleciona um único elemento do documento com base no seletor CSS e retorna seu conteúdo de texto.

List<String>? docSelecAll({required Document doc, required String query})
Seleciona todos os elementos do documento com base no seletor CSS e retorna uma lista de seus conteúdos de texto.

List<String?>? docSelecAllAttr({required Document doc, required String query, required String attr})
Seleciona todos os elementos do documento com base no seletor CSS e retorna uma lista dos valores dos atributos especificados.

List<String?>? removeHtmlElementsList(List<String?> content, List<String> elements)
Remove elementos HTML específicos da lista de conteúdos.

String? docSelecAttr({required Document doc, required String query, required String attr})
Seleciona um único elemento do documento com base no seletor CSS e retorna o valor do atributo especificado.

List<String?>? removeHtmlElements(List<String?> content, String element)
Remove um elemento HTML específico da lista de conteúdos.

List<String>? extractImage({required Document doc, required String query, required List<String> tagSelector, required String attr})
Extrai fontes de imagens únicas do documento com base no seletor CSS e no atributo especificado.

List<String>? extractImagesAttr({required Document doc, required String query, required List<String> tagSelector, required String attr})
Extrai valores únicos de atributos do documento com base no seletor CSS e no atributo especificado.

List<String>? extractText({required Document doc, required String query, required Map<String, String> tagToSelector})
Extrai o conteúdo de texto do documento com base no seletor CSS e no mapa de tag-para-seletor especificado.