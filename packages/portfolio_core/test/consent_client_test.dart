import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

void main() {
  test('denied host never touches the inner client', () {
    final c = ConsentClient(MockClient((_) => fail('network')), () => {});
    expect(
      c.get(Uri.parse('https://query1.finance.yahoo.com/x')),
      throwsA(
        isA<ConsentDeniedException>().having(
          (e) => e.host,
          'host',
          'query1.finance.yahoo.com',
        ),
      ),
    );
  });

  test('allowed host reaches inner once', () async {
    var calls = 0;
    final c = ConsentClient(
      MockClient((_) async {
        calls++;
        return http.Response('ok', 200);
      }),
      () => {'query1.finance.yahoo.com'},
    );
    await c.get(Uri.parse('https://query1.finance.yahoo.com/x'));
    expect(calls, 1);
  });

  test('allowed set is read on every request', () async {
    final allowed = <String>{};
    final c = ConsentClient(
      MockClient((_) async => http.Response('ok', 200)),
      () => allowed,
    );
    final u = Uri.parse('https://a.example/x');
    await expectLater(c.get(u), throwsA(isA<ConsentDeniedException>()));
    allowed.add('a.example');
    expect((await c.get(u)).statusCode, 200);
  });
}
