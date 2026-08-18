/// A shunting-yard evaluator for the arithmetic a chat actually asks for.
///
/// Written out rather than pulled from a package because the whole grammar is
/// four operators, parentheses and unary minus — and because an expression
/// evaluator that can reach beyond arithmetic is a liability when the string
/// comes from a language model.
class Calculator {
  static const _precedence = {'+': 1, '-': 1, '*': 2, '/': 2, '%': 2, '^': 3};

  /// Returns null when the input is not a well-formed expression, rather than
  /// throwing or guessing.
  static double? evaluate(String expression) {
    final tokens = _tokenize(expression);
    if (tokens == null || tokens.isEmpty) return null;

    final values = <double>[];
    final operators = <String>[];

    // Returns false when the expression is malformed. The caller must stop on
    // false rather than loop: a failed apply leaves the operator on the stack,
    // so retrying it spins forever (which "2 +" duly did).
    bool apply() {
      if (operators.isEmpty || values.length < 2) return false;
      final op = operators.removeLast();
      final b = values.removeLast();
      final a = values.removeLast();
      values.add(switch (op) {
        '+' => a + b,
        '-' => a - b,
        '*' => a * b,
        '/' => a / b,
        '%' => a % b,
        '^' => _pow(a, b),
        _ => double.nan,
      });
      return true;
    }

    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (token == '(') {
        operators.add(token);
      } else if (token == ')') {
        while (operators.isNotEmpty && operators.last != '(') {
          if (!apply()) return null;
        }
        if (operators.isEmpty) return null; // unbalanced
        operators.removeLast();
      } else if (_precedence.containsKey(token)) {
        // Unary minus/plus: an operator in a value position binds to the number.
        final atValuePosition = i == 0 ||
            tokens[i - 1] == '(' ||
            _precedence.containsKey(tokens[i - 1]);
        if (atValuePosition && (token == '-' || token == '+')) {
          values.add(0);
        }
        while (operators.isNotEmpty &&
            operators.last != '(' &&
            // ^ is right-associative: 2^3^2 is 2^9, not 8^2.
            (_precedence[operators.last]! > _precedence[token]! ||
                (_precedence[operators.last]! == _precedence[token]! && token != '^'))) {
          if (!apply()) return null;
        }
        operators.add(token);
      } else {
        final value = double.tryParse(token);
        if (value == null) return null;
        values.add(value);
      }
    }

    while (operators.isNotEmpty) {
      if (operators.last == '(') return null; // unbalanced
      if (!apply()) return null;
    }

    if (values.length != 1) return null;
    final result = values.single;
    return result.isFinite ? result : null;
  }

  /// Trims the trailing `.0` so "2 + 2" reads as 4, not 4.0.
  static String format(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toStringAsFixed(0);
    }
    return value.toString();
  }

  static double _pow(double a, double b) {
    var result = 1.0;
    if (b == b.roundToDouble() && b.abs() < 1024) {
      final n = b.abs().toInt();
      for (var i = 0; i < n; i++) {
        result *= a;
      }
      return b < 0 ? 1 / result : result;
    }
    // Non-integer exponents are rare enough here to just refuse rather than
    // reach for dart:math and its NaN edge cases.
    return double.nan;
  }

  static List<String>? _tokenize(String expression) {
    final tokens = <String>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
    }

    for (final ch in expression.replaceAll(',', '.').split('')) {
      if (ch.trim().isEmpty) {
        flush();
      } else if (RegExp(r'[0-9.]').hasMatch(ch)) {
        buffer.write(ch);
      } else if (_precedence.containsKey(ch) || ch == '(' || ch == ')') {
        flush();
        tokens.add(ch);
      } else if (ch == 'x' || ch == 'X' || ch == '×') {
        flush();
        tokens.add('*');
      } else if (ch == '÷') {
        flush();
        tokens.add('/');
      } else {
        return null; // anything else is not arithmetic
      }
    }
    flush();
    return tokens;
  }
}
