const _maxDepth = 32;

/// RFC 8259 parser for untrusted (synced) files. Rejects duplicate keys,
/// trailing data and nesting deeper than 32. Throws [FormatException] only.
Object? decodeStrictJson(String text) {
  final p = _Parser(text);
  p.ws();
  final v = p.value(0);
  p.ws();
  if (p.i != text.length) p.fail('Trailing data');
  return v;
}

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  static final _num = RegExp(r'-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?');

  Never fail(String msg) => throw FormatException(msg, s, i);

  void ws() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c != 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) break;
      i++;
    }
  }

  Object? value(int depth) {
    if (i >= s.length) fail('Unexpected end');
    switch (s[i]) {
      case '{':
        return object(depth + 1);
      case '[':
        return array(depth + 1);
      case '"':
        return string();
      case 't':
        return literal('true', true);
      case 'f':
        return literal('false', false);
      case 'n':
        return literal('null', null);
      default:
        return number();
    }
  }

  Object? literal(String word, Object? v) {
    if (!s.startsWith(word, i)) fail('Invalid literal');
    i += word.length;
    return v;
  }

  Object number() {
    final m = _num.matchAsPrefix(s, i);
    if (m == null) fail('Invalid value');
    i = m.end;
    final t = m[0]!;
    if (m[2] == null && m[3] == null) {
      final n = int.tryParse(t);
      if (n != null) return n;
    }
    return double.parse(t);
  }

  List<Object?> array(int depth) {
    if (depth > _maxDepth) fail('Nesting too deep');
    i++;
    final out = <Object?>[];
    ws();
    if (i < s.length && s[i] == ']') {
      i++;
      return out;
    }
    while (true) {
      ws();
      out.add(value(depth));
      ws();
      if (i >= s.length) fail('Unterminated array');
      if (s[i] == ',') {
        i++;
      } else if (s[i] == ']') {
        i++;
        return out;
      } else {
        fail('Expected , or ]');
      }
    }
  }

  Map<String, Object?> object(int depth) {
    if (depth > _maxDepth) fail('Nesting too deep');
    i++;
    final out = <String, Object?>{};
    ws();
    if (i < s.length && s[i] == '}') {
      i++;
      return out;
    }
    while (true) {
      ws();
      if (i >= s.length || s[i] != '"') fail('Expected string key');
      final k = string();
      if (out.containsKey(k)) fail('Duplicate key');
      ws();
      if (i >= s.length || s[i] != ':') fail('Expected :');
      i++;
      ws();
      out[k] = value(depth);
      ws();
      if (i >= s.length) fail('Unterminated object');
      if (s[i] == ',') {
        i++;
      } else if (s[i] == '}') {
        i++;
        return out;
      } else {
        fail('Expected , or }');
      }
    }
  }

  int hex4() {
    if (i + 4 > s.length) fail('Bad \\u escape');
    final n = int.tryParse(s.substring(i, i + 4), radix: 16);
    // tryParse accepts a sign; require four plain hex digits.
    if (n == null ||
        !RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(s.substring(i, i + 4))) {
      fail('Bad \\u escape');
    }
    i += 4;
    return n;
  }

  String string() {
    i++; // opening quote
    final b = StringBuffer();
    while (true) {
      if (i >= s.length) fail('Unterminated string');
      final c = s.codeUnitAt(i++);
      if (c == 0x22) return b.toString();
      if (c < 0x20) fail('Control character in string');
      if (c != 0x5c) {
        b.writeCharCode(c);
        continue;
      }
      if (i >= s.length) fail('Unterminated string');
      switch (s[i++]) {
        case '"':
          b.write('"');
        case '\\':
          b.write('\\');
        case '/':
          b.write('/');
        case 'b':
          b.write('\b');
        case 'f':
          b.write('\f');
        case 'n':
          b.write('\n');
        case 'r':
          b.write('\r');
        case 't':
          b.write('\t');
        case 'u':
          final u = hex4();
          if (u >= 0xdc00 && u <= 0xdfff) fail('Lone low surrogate');
          if (u >= 0xd800 && u <= 0xdbff) {
            if (!s.startsWith('\\u', i)) fail('Lone high surrogate');
            i += 2;
            final lo = hex4();
            if (lo < 0xdc00 || lo > 0xdfff) fail('Bad surrogate pair');
            b.writeCharCode(u);
            b.writeCharCode(lo);
          } else {
            b.writeCharCode(u);
          }
        default:
          fail('Invalid escape');
      }
    }
  }
}
