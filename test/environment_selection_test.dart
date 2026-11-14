import 'package:flutter_test/flutter_test.dart';
import 'package:flexit_admin/core/config/environment.dart';

void main() {
  test('selects only the explicit local environment', () {
    expect(environmentFileFor('local'), '.env.local');
  });

  test('selects production only when explicitly requested', () {
    expect(environmentFileFor('production'), '.env');
  });

  test('rejects missing or unsupported environments', () {
    expect(() => environmentFileFor(''), throwsStateError);
    expect(() => environmentFileFor('staging'), throwsStateError);
  });
}
