import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:privatelm/services/tools/web_tools.dart';

void main() {
  group('isBlockedUrl', () {
    test('allows public http and https', () {
      expect(isBlockedUrl('https://example.com/a?b=c'), isFalse);
      expect(isBlockedUrl('http://8.8.8.8/'), isFalse);
    });

    test('blocks the local network and loopback', () {
      for (final url in [
        'http://localhost:8080',
        'http://127.0.0.1/admin',
        'http://192.168.0.1',
        'http://10.1.2.3',
        'http://172.16.5.4',
        'http://169.254.1.1',
        'http://router.local',
      ]) {
        expect(isBlockedUrl(url), isTrue, reason: url);
      }
    });

    test('blocks non-http schemes and junk', () {
      expect(isBlockedUrl('file:///etc/passwd'), isTrue);
      expect(isBlockedUrl('javascript:alert(1)'), isTrue);
      expect(isBlockedUrl('not a url'), isTrue);
    });

    test('lets 172.32 through — only 16..31 is private', () {
      expect(isBlockedUrl('http://172.32.0.1'), isFalse);
    });
  });

  group('htmlToText', () {
    test('drops script and style bodies entirely', () {
      const html = '<p>keep</p><script>var x = "drop";</script>'
          '<style>.a{color:red}</style><p>this</p>';
      expect(htmlToText(html), 'keep\nthis');
    });

    test('keeps paragraphs apart and collapses runs of space', () {
      expect(htmlToText('<h1>Title</h1><p>a    b</p>'), 'Title\na b');
    });

    test('decodes the entities that show up in body text', () {
      expect(htmlToText('<p>Tom &amp; Jerry &#8212; 5 &lt; 6</p>'),
          'Tom & Jerry — 5 < 6');
    });

    test('survives an unclosed tag instead of looping', () {
      expect(htmlToText('<p>text<div'), 'text');
    });
  });

  group('parseBraveResults', () {
    test('returns nothing when the markup does not match', () {
      expect(parseBraveResults('<html><body>redesigned</body></html>'), isEmpty);
    });

    test('pulls title, url and snippet out of a result block', () {
      const html = '''
        <div class="snippet result">
          <a href="https://dart.dev/guides"><span class="title">Dart guides</span></a>
          <div class="snippet-description">Learn the language.</div>
        </div>''';
      final hits = parseBraveResults(html);
      expect(hits, hasLength(1));
      expect(hits.first.url, 'https://dart.dev/guides');
      expect(hits.first.title, 'Dart guides');
      expect(hits.first.snippet, 'Learn the language.');
    });

    test('reads the live markup shape: content div inside generic-snippet', () {
      const html = '''
        <div class="snippet svelte-jmfu5f" data-pos="2">
          <a href="https://nanoreview.net/x">
            <div class="title search-snippet-title">Dimensity 7300 specs</div></a>
          <div class="generic-snippet svelte-1cwdgg3">
            <div class="content desktop-default-regular t-primary">
              An <strong>8-core chipset</strong> on 4 nm.</div></div>
        </div>''';
      final hits = parseBraveResults(html);
      expect(hits, hasLength(1));
      expect(hits.first.title, 'Dimensity 7300 specs');
      expect(hits.first.snippet, 'An 8-core chipset on 4 nm.');
    });
  });

  group('parseDuckDuckGoResults', () {
    test('pairs each link with its snippet and unwraps the redirect', () {
      const html = '''
        <tr><td><a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdart.dev%2Fx&amp;rut=9">Dart X</a></td></tr>
        <tr><td class="result-snippet">The X page.</td></tr>
        <tr><td><a class="result-link" href="https://flutter.dev/y">Flutter Y</a></td></tr>
        <tr><td class="result-snippet">The Y page.</td></tr>''';
      final hits = parseDuckDuckGoResults(html);
      expect(hits, hasLength(2));
      expect(hits[0].url, 'https://dart.dev/x');
      expect(hits[0].title, 'Dart X');
      expect(hits[0].snippet, 'The X page.');
      expect(hits[1].url, 'https://flutter.dev/y');
      expect(hits[1].snippet, 'The Y page.');
    });

    test('returns nothing for the challenge page DDG serves bare clients', () {
      expect(parseDuckDuckGoResults('<html><body>anomaly</body></html>'), isEmpty);
    });
  });

  group('parseStartpageResults', () {
    test('reads title, url and the description that follows a style block', () {
      const html = '''
        <a class="result-title result-link css-1bggj8v" href="https://nanoreview.net/x"
           data-testid="bg-title-link"><h2 class="css-m6zr0j">Dimensity 7300 specs</h2></a>
        <style data-emotion="css 1mj150e">.css-1mj150e{color:#000}</style>
        <p class="css-1mj150e"><b>An 8-core 5G chipset</b> on 4 nm.</p>''';
      final hits = parseStartpageResults(html);
      expect(hits, hasLength(1));
      expect(hits.first.url, 'https://nanoreview.net/x');
      expect(hits.first.title, 'Dimensity 7300 specs');
      expect(hits.first.snippet, 'An 8-core 5G chipset on 4 nm.');
    });

    test('returns nothing for the challenge page', () {
      expect(parseStartpageResults('<html>captcha</html>'), isEmpty);
    });
  });

  group('unwrapUrl', () {
    test('recovers the real address from a Translate wrapper', () {
      expect(
          unwrapUrl(
              'https://translate.google.com/translate?u=https%3A%2F%2Fnanoreview.net%2Fen%2Fsoc%2Fx&amp;hl=pt'),
          'https://nanoreview.net/en/soc/x');
    });

    test('leaves an ordinary URL alone', () {
      expect(unwrapUrl('https://dart.dev/a?b=c'), 'https://dart.dev/a?b=c');
    });
  });

  group('readUrl', () {
    test('refuses a private address without making a request', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      final out = await readUrl('http://192.168.1.1', client: client);
      expect(called, isFalse);
      expect(out, contains('refused'));
    });

    test('strips the punctuation models wrap URLs in', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response('<p>hello</p>', 200);
      });
      final out = await readUrl('<https://example.com/x>.', client: client);
      expect(seen.toString(), 'https://example.com/x');
      expect(out, 'hello');
    });

    test('reports the status code instead of returning error markup', () async {
      final client =
          MockClient((_) async => http.Response('<h1>Not Found</h1>', 404));
      expect(await readUrl('https://example.com', client: client),
          contains('HTTP 404'));
    });

    test('truncates a page that would swamp the context', () async {
      final client = MockClient(
          (_) async => http.Response('<p>${'x' * (maxPageChars + 500)}</p>', 200));
      final out = await readUrl('https://example.com', client: client);
      expect(out.endsWith('[truncated]'), isTrue);
      expect(out.length, lessThan(maxPageChars + 100));
    });
  });

  group('webSearch', () {
    test('names every engine it tried when all of them strike out', () async {
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        return http.Response('<html>anomaly</html>', 202);
      });
      final out = await webSearch('nothing', client: client);
      expect(hosts, [
        'search.brave.com',
        'www.startpage.com',
        'lite.duckduckgo.com',
      ]);
      expect(out, contains('brave HTTP 202'));
      expect(out, contains('startpage HTTP 202'));
      expect(out, contains('duckduckgo HTTP 202'));
    });

    test('a configured endpoint goes in front of the scrapes, GET without a token',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((req) async {
        requests.add(req);
        return http.Response(
            '{"results":[{"url":"https://a.dev/1","title":"From the API",'
            '"content":"JSON, not scraped."}]}',
            200);
      });
      final out = await webSearch('x',
          client: client, customSearchUrl: 'searx.example.org/search');
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.host, 'searx.example.org');
      expect(requests.single.url.queryParameters['q'], 'x');
      expect(requests.single.url.queryParameters['format'], 'json');
      expect(out, contains('1. From the API'));
      expect(out, contains('JSON, not scraped.'));
    });

    test('a token turns the custom call into an authenticated JSON POST',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((req) async {
        requests.add(req);
        return http.Response(
            '{"results":[{"url":"https://a.dev/1","title":"Tavily",'
            '"content":"Answered."}]}',
            200);
      });
      await webSearch('dimensity 7300',
          client: client,
          customSearchUrl: 'https://api.tavily.com/search',
          customSearchToken: 'tvly-secret');
      expect(requests.single.method, 'POST');
      expect(requests.single.headers['Authorization'], 'Bearer tvly-secret');
      expect(requests.single.body, contains('"query":"dimensity 7300"'));
    });

    test('a broken custom endpoint falls through to the scrapes', () async {
      final names = <String>[];
      final client = MockClient((req) async {
        names.add(req.url.host);
        if (req.url.host == 'dead.example') {
          return http.Response('gateway down', 502);
        }
        return http.Response(
            '<div class="snippet x"><a href="https://a.example/1">'
            '<div class="title">Brave saved it</div></a></div>',
            200);
      });
      final out = await webSearch('x',
          client: client, customSearchUrl: 'https://dead.example/api');
      expect(names, ['dead.example', 'search.brave.com']);
      expect(out, contains('Brave saved it'));
    });

    test('falls through to DuckDuckGo when the two before it fail', () async {
      final client = MockClient((req) async {
        if (req.url.host.contains('brave') ||
            req.url.host.contains('startpage')) {
          return http.Response('<html>redesigned</html>', 200);
        }
        return http.Response(
            '<a class="result-link" href="https://dart.dev/z">From DDG</a>'
            '<td class="result-snippet">Fallback worked.</td>',
            200);
      });
      final out = await webSearch('x', client: client);
      expect(out, contains('1. From DDG'));
      expect(out, contains('Fallback worked.'));
    });

    test('does not call the fallback when the first engine answers', () async {
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        return http.Response(
            '<div class="snippet x"><a href="https://a.example/1">'
            '<div class="title">Only Brave</div></a></div>',
            200);
      });
      await webSearch('x', client: client);
      expect(hosts, ['search.brave.com']);
    });

    test('numbers the hits it found', () async {
      const html = '''
        <div class="snippet"><a href="https://a.example/1"><span class="title">First</span></a>
          <div class="snippet-description">One.</div></div>
        <div class="snippet"><a href="https://b.example/2"><span class="title">Second</span></a>
          <div class="snippet-description">Two.</div></div>''';
      final client = MockClient((_) async => http.Response(html, 200));
      final out = await webSearch('x', client: client);
      expect(out, contains('1. First'));
      expect(out, contains('2. Second'));
      expect(out, contains('https://b.example/2'));
    });

    test('rejects an empty query before hitting the network', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      expect(await webSearch('   ', client: client), contains('empty'));
      expect(called, isFalse);
    });
  });
}
