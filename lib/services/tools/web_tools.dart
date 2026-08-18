import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The two tools that need the network: search the web, and read one page.
///
/// Both talk to the site directly from the device — no API key, no third-party
/// proxy — which keeps the query on the phone but also means we are parsing
/// someone else's HTML. Expect the parsers to rot and treat an empty result as
/// normal, never as a crash.

/// Browsers get served the rich page; a bare client gets a consent wall. This
/// is the smallest lie that reliably gets HTML back.
const _userAgent = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

const _searchTimeout = Duration(seconds: 12);
const _readTimeout = Duration(seconds: 20);

/// Cap on what one page may inject into the prompt. A model with a 4k context
/// and a 200k page is a wasted turn, so truncate before the model ever sees it.
const maxPageChars = 4000;

class SearchHit {
  final String title;
  final String snippet;
  final String url;
  const SearchHit(this.title, this.snippet, this.url);
}

/// Is this URL something we refuse to fetch on the model's behalf?
///
/// A model that reads "http://192.168.0.1/admin" out of a page and calls
/// read_url on it would be scanning the user's own LAN. Loopback, link-local,
/// the three RFC1918 ranges and non-http schemes are all refused.
bool isBlockedUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme) return true;
  if (uri.scheme != 'http' && uri.scheme != 'https') return true;

  final host = uri.host.toLowerCase();
  if (host.isEmpty) return true;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local') || host.endsWith('.internal')) return true;
  if (host == '::1' || host == '[::1]') return true;

  final octets = host.split('.');
  if (octets.length == 4 && octets.every((o) => int.tryParse(o) != null)) {
    final a = int.parse(octets[0]);
    final b = int.parse(octets[1]);
    if (a == 127 || a == 10 || a == 0) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true;
  }
  return false;
}

/// Everything a model can usefully read out of an HTML page, and nothing else.
///
/// Not a parser: a scanner that drops `<script>`/`<style>` bodies, turns tags
/// into whitespace and collapses the result. Character-by-character on purpose —
/// a regex over hostile HTML is how you get catastrophic backtracking.
String htmlToText(String html) {
  final out = StringBuffer();
  var i = 0;

  while (i < html.length) {
    if (html[i] != '<') {
      out.write(html[i]);
      i++;
      continue;
    }

    final tagEnd = html.indexOf('>', i);
    if (tagEnd < 0) break; // Unclosed tag: the rest is not text.
    final tag = html.substring(i + 1, tagEnd).toLowerCase();
    final name = tag.split(RegExp(r'[\s/>]')).first;

    if (name == 'script' || name == 'style' || name == 'noscript') {
      final close = html.toLowerCase().indexOf('</$name', tagEnd);
      i = close < 0 ? html.length : (html.indexOf('>', close) + 1);
      continue;
    }

    // Block-level tags become a line break so paragraphs survive; the rest
    // become a space so words do not run together.
    const breaks = {
      'p', 'br', 'div', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'section', 'article', 'header', 'footer', 'blockquote', 'pre',
    };
    out.write(breaks.contains(name) ? '\n' : ' ');
    i = tagEnd + 1;
  }

  return _collapse(decodeEntities(out.toString()));
}

String _collapse(String text) => text
    .replaceAll('\r', '')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r' ?\n ?'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// The handful of entities that actually show up in body text. Numeric refs are
/// handled generically; the long named list is not worth carrying.
String decodeEntities(String text) {
  const named = {
    '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'",
    '&nbsp;': ' ', '&#39;': "'", '&mdash;': '—', '&ndash;': '–',
    '&hellip;': '…', '&rsquo;': '’', '&lsquo;': '‘', '&ldquo;': '“',
    '&rdquo;': '”',
  };
  var out = text;
  named.forEach((k, v) => out = out.replaceAll(k, v));
  return out.replaceAllMapped(RegExp(r'&#(\d{1,6});'), (m) {
    final code = int.tryParse(m[1]!);
    return code == null ? m[0]! : String.fromCharCode(code);
  });
}

/// Pull result blocks out of a Brave results page.
///
/// Brave is the one big engine that still serves parseable HTML to a plain
/// client without a key or a captcha. When the markup changes this returns
/// nothing, which surfaces as "no results" rather than an exception.
List<SearchHit> parseBraveResults(String html, {int limit = 5}) {
  final hits = <SearchHit>[];
  // Split on the result container's own class, not on anything containing
  // "snippet": Brave's description div is class="snippet-description", and
  // splitting there would cut every block off from its own text.
  final blocks = html.split(RegExp(r'class="snippet(?![\w-])'));

  for (final block in blocks.skip(1)) {
    if (hits.length >= limit) break;
    final url = RegExp(r'href="(https?://[^"]+)"').firstMatch(block)?[1];
    if (url == null || url.contains('brave.com')) continue;

    final title = RegExp(r'<(?:span|div)[^>]*class="[^"]*title[^"]*"[^>]*>([\s\S]{1,300}?)<')
            .firstMatch(block)?[1] ??
        RegExp(r'>([^<>]{10,200})<').firstMatch(block)?[1];
    // Live markup keeps the description in a "content" div inside
    // "generic-snippet"; the older class names are kept as fallbacks. Lazily
    // matching to </div> is safe: inline tags inside close with their own name.
    final snippet = RegExp(r'class="content [^"]*"[^>]*>([\s\S]{1,800}?)</div>')
                .firstMatch(block)?[1] ??
            RegExp(r'class="[^"]*(?:snippet-description|snippet-content)[^"]*"[^>]*>([\s\S]{1,600}?)</')
                .firstMatch(block)?[1] ??
            '';

    final cleanTitle = htmlToText(title ?? '');
    if (cleanTitle.isEmpty) continue;
    hits.add(SearchHit(cleanTitle, htmlToText(snippet), unwrapUrl(url)));
  }
  return hits;
}

/// Read results out of any search API that answers with a `results` array.
///
/// The only rung in the chain that is not a scrape, and the shape is shared by
/// the two services worth pointing it at: SearXNG and Tavily both return
/// `{"results": [{"title", "url", "content"}]}`. Other keys are accepted for
/// the text because every vendor names it differently.
List<SearchHit> parseJsonResults(String body, {int limit = 5}) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map || decoded['results'] is! List) return const [];
  final hits = <SearchHit>[];
  for (final r in decoded['results'] as List) {
    if (hits.length >= limit) break;
    if (r is! Map || r['url'] is! String) continue;
    final text = r['content'] ?? r['snippet'] ?? r['description'] ?? '';
    hits.add(SearchHit(
      (r['title'] as String?)?.trim().isNotEmpty == true
          ? (r['title'] as String).trim()
          : '(no title)',
      text is String ? text.trim() : '',
      r['url'] as String,
    ));
  }
  return hits;
}

/// Pull results out of a Startpage results page.
///
/// Startpage proxies Google's index, which is why it sits ahead of DDG: when it
/// answers, the results are the best of the three scrapes. It is also the
/// heaviest (~280KB a query) and the quickest to start challenging a
/// non-browser client, so it is a fallback and not the default.
///
/// The emotion CSS class names (`css-1bggj8v`) change on every build; the
/// stable anchor is `class="result-title result-link"`, so match on that.
List<SearchHit> parseStartpageResults(String html, {int limit = 5}) {
  final hits = <SearchHit>[];
  final pattern = RegExp(
      r'<a class="result-title result-link[^"]*" href="([^"]+)"[\s\S]{0,400}?'
      r'<h2[^>]*>([\s\S]{1,300}?)</h2></a>'
      // Startpage injects an emotion <style> block between arbitrary elements,
      // so the description paragraph is not always adjacent to the title.
      r'(?:\s*(?:<style[\s\S]{0,4000}?</style>\s*)?<p[^>]*>([\s\S]{1,900}?)</p>)?');

  for (final m in pattern.allMatches(html)) {
    if (hits.length >= limit) break;
    final title = htmlToText(m[2] ?? '');
    if (title.isEmpty) continue;
    hits.add(SearchHit(title, htmlToText(m[3] ?? ''), decodeEntities(m[1]!)));
  }
  return hits;
}

/// Pull results out of DuckDuckGo's "lite" page.
///
/// Kept as the fallback rather than the primary for a measured reason: DDG
/// answers a plain client with HTTP 202 and a challenge page, while Brave still
/// serves real HTML. What DDG has going for it is markup that has not changed
/// in years — `result-link` / `result-snippet` are semantic names, where Brave's
/// are Svelte build hashes that turn over on every deploy. So: whichever one
/// answers today, one of them is likely to.
List<SearchHit> parseDuckDuckGoResults(String html, {int limit = 5}) {
  final hits = <SearchHit>[];
  final links = RegExp(
          r'class="result-link"[^>]*href="([^"]+)"[^>]*>([\s\S]{1,300}?)</a>')
      .allMatches(html);
  final snippets = RegExp(r'class="result-snippet"[^>]*>([\s\S]{1,800}?)</td>')
      .allMatches(html)
      .map((m) => htmlToText(m[1]!))
      .toList();

  var i = 0;
  for (final m in links) {
    if (hits.length >= limit) break;
    final title = htmlToText(m[2]!);
    if (title.isEmpty) continue;
    final url = unwrapDuckDuckGoRedirect(decodeEntities(m[1]!));
    hits.add(SearchHit(title, i < snippets.length ? snippets[i] : '', url));
    i++;
  }
  return hits;
}

/// DDG wraps outbound links as `//duckduckgo.com/l/?uddg=<encoded>`.
String unwrapDuckDuckGoRedirect(String href) {
  final match = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href);
  if (match != null) return Uri.decodeComponent(match[1]!);
  return href.startsWith('//') ? 'https:$href' : href;
}

/// Brave hands back a Google Translate wrapper for results in another
/// language. read_url on that returns the translator's shell, not the article,
/// so recover the real address from the `u` parameter.
String unwrapUrl(String url) {
  final decoded = decodeEntities(url);
  final uri = Uri.tryParse(decoded);
  if (uri == null || !uri.host.endsWith('translate.google.com')) return decoded;
  final inner = uri.queryParameters['u'];
  return inner == null || inner.isEmpty ? decoded : inner;
}

/// Search the live web. Returns text meant to go straight back to the model.
///
/// Two engines, tried in order, because both are scrapes and either can start
/// answering with a challenge page instead of results. Falling through costs one
/// extra request only in the case that would otherwise have returned nothing.
Future<String> webSearch(
  String query, {
  http.Client? client,
  String customSearchUrl = '',
  String customSearchToken = '',
}) async {
  if (query.trim().isEmpty) return 'Error: empty search query.';
  final own = client == null;
  final c = client ?? http.Client();
  final failures = <String>[];

  try {
    for (final engine in enginesFor(customSearchUrl)) {
      try {
        final response = await _request(c, engine, query, customSearchToken)
            .timeout(_searchTimeout);

        if (response.statusCode != 200) {
          failures.add('${engine.name} HTTP ${response.statusCode}');
          continue;
        }
        final hits = engine.parse(response.body);
        if (hits.isEmpty) {
          failures.add('${engine.name} returned nothing parseable');
          continue;
        }
        return hits
            .mapIndexed((i, h) => '${i + 1}. ${h.title}\n   ${h.url}'
                '${h.snippet.isEmpty ? '' : '\n   ${h.snippet}'}')
            .join('\n\n');
      } on TimeoutException {
        failures.add('${engine.name} timed out');
      } catch (e) {
        failures.add('${engine.name}: $e');
      }
    }
    // Every engine struck out. Say which, so a broken parser is visible in the
    // chat instead of looking like "the web has nothing on this".
    return 'No results for "$query" (${failures.join('; ')}).';
  } finally {
    if (own) c.close();
  }
}

/// How to ask one engine.
///
/// The scrapes are plain GETs. The custom endpoint is shaped by whether a token
/// was given, which is what separates the two services worth configuring:
/// SearXNG takes `GET ?q=&format=json` with no auth, Tavily takes a JSON POST
/// with a bearer token. Sending both `query` and `q` in the body costs nothing
/// and saves the user from guessing which name their endpoint wants.
Future<http.Response> _request(
  http.Client c,
  SearchEngine engine,
  String query,
  String token,
) {
  final url = engine.url(query);
  if (engine.name != 'custom') {
    return c.get(url, headers: {'User-Agent': _userAgent, 'Accept': 'text/html'});
  }
  if (token.isEmpty) {
    return c.get(
      url.replace(queryParameters: {
        ...url.queryParameters,
        'q': query,
        'format': 'json',
      }),
      headers: {'Accept': 'application/json', 'User-Agent': _userAgent},
    );
  }
  return c.post(
    url,
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    },
    body: jsonEncode({'query': query, 'q': query}),
  );
}

/// One rung of the search chain.
class SearchEngine {
  final String name;
  final Uri Function(String query) url;
  final List<SearchHit> Function(String html) parse;
  const SearchEngine(this.name, this.url, this.parse);
}

/// The chain to try, in order.
///
/// A configured endpoint goes first: it is the only rung with a contract, so it
/// cannot break because someone redesigned a results page. The three scrapes
/// stay behind it for when it is unset, down, or out of quota.
List<SearchEngine> enginesFor(String customUrl) {
  final base = customSearchBase(customUrl);
  return [
    if (base != null)
      SearchEngine('custom', (q) => base, parseJsonResults),
    const SearchEngine('brave', _braveUrl, parseBraveResults),
    const SearchEngine('startpage', _startpageUrl, parseStartpageResults),
    const SearchEngine('duckduckgo', _duckDuckGoUrl, parseDuckDuckGoResults),
  ];
}

/// Normalise whatever the user typed in Settings, or null if it is unusable.
/// A bare host gets https:// — nobody types the scheme.
Uri? customSearchBase(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

Uri _braveUrl(String query) =>
    Uri.https('search.brave.com', '/search', {'q': query, 'source': 'web'});

Uri _startpageUrl(String query) =>
    Uri.https('www.startpage.com', '/sp/search', {'query': query});

Uri _duckDuckGoUrl(String query) =>
    Uri.https('lite.duckduckgo.com', '/lite/', {'q': query});

/// Fetch one page and hand back its readable text.
Future<String> readUrl(String rawUrl, {http.Client? client}) async {
  // Models like to wrap URLs in quotes, angle brackets or trailing punctuation.
  var url = rawUrl.trim();
  while (url.isNotEmpty && '"\'<>(),. '.contains(url[0])) {
    url = url.substring(1);
  }
  while (url.isNotEmpty && '"\'<>(),. '.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  if (url.isEmpty) return 'Error: no URL given.';
  if (isBlockedUrl(url)) {
    return 'Error: refused to fetch "$url" — only public http(s) addresses are allowed.';
  }

  final own = client == null;
  final c = client ?? http.Client();
  try {
    final response = await c
        .get(Uri.parse(url), headers: {
          'User-Agent': _userAgent,
          'Accept': 'text/html, text/plain, */*',
        })
        .timeout(_readTimeout);

    if (response.statusCode != 200) {
      return 'Error: $url returned HTTP ${response.statusCode}.';
    }
    final text = htmlToText(response.body);
    if (text.isEmpty) return 'The page at $url has no readable text.';
    return text.length > maxPageChars
        ? '${text.substring(0, maxPageChars)}\n\n[truncated]'
        : text;
  } on TimeoutException {
    return 'Error: $url timed out.';
  } catch (e) {
    return 'Error: could not read $url — $e';
  } finally {
    if (own) c.close();
  }
}

extension _IndexedMap<E> on List<E> {
  Iterable<T> mapIndexed<T>(T Function(int, E) f) =>
      Iterable.generate(length, (i) => f(i, this[i]));
}
