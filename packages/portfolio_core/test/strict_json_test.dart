import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

void main() {
  test('strict json', () {
    expect(decodeStrictJson('{"a":"1","b":[1,true,null]}'), {
      'a': '1',
      'b': [1, true, null],
    });
    expect(() => decodeStrictJson('{"a":1,"a":2}'), throwsFormatException);
    expect(() => decodeStrictJson('{"a":1} x'), throwsFormatException);
  });
  test('values', () {
    expect(decodeStrictJson(' [ 1 , -2 , 1.5 , 1e2 , -0.5E-1 , 0 ] \n'), [
      1,
      -2,
      1.5,
      100.0,
      -0.05,
      0,
    ]);
    expect(
      decodeStrictJson('"a\\n\\"\\\\\\/\\u00e9\\ud83d\\ude00"'),
      'a\n"\\/é😀',
    );
    expect(decodeStrictJson('{}'), isEmpty);
    expect(decodeStrictJson('[]'), isEmpty);
    expect(decodeStrictJson('{"a":{"b":[{}]}}'), {
      'a': {
        'b': [{}],
      },
    });
    expect(decodeStrictJson('false'), false);
    expect(decodeStrictJson('1'), isA<int>());
  });
  test('rejections', () {
    for (final bad in [
      '',
      ' ',
      '{',
      '[1,]',
      '{"a":1,}',
      '{a:1}',
      "{'a':1}",
      '01',
      '+1',
      '1.',
      '.5',
      '-',
      '1e',
      'tru',
      'nul',
      'NaN',
      'Infinity',
      '"abc',
      '"\\x"',
      '"\\u12"',
      '"\\ud800"',
      '"a\nb"',
      '"a\tb"',
      '[1 2]',
      '{"a" 1}',
      '{"a":1 "b":2}',
      '[1]]',
      '// c\n1',
      '1 2',
      ' 1',
      '"\\udc00"',
    ]) {
      expect(() => decodeStrictJson(bad), throwsFormatException, reason: bad);
    }
  });
  test('depth limit 32', () {
    expect(decodeStrictJson('${'[' * 32}${']' * 32}'), isList);
    expect(
      () => decodeStrictJson('${'[' * 33}${']' * 33}'),
      throwsFormatException,
    );
    expect(
      () => decodeStrictJson('${'{"a":' * 33}1${'}' * 33}'),
      throwsFormatException,
    );
  });
}
