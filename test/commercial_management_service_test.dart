import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flexit_admin/core/auth/commercial_management_service.dart';

void main() {
  test('commercial client uses governed Order routes and bearer token', () async {
    late http.Request seen;
    final client = MockClient((request) async {
      seen = request;
      return http.Response(jsonEncode({'success': true, 'data': []}), 200);
    });
    final service = CommercialManagementService(
      baseUrl: 'https://order.example',
      token: 'company-token',
      client: client,
    );
    expect(await service.plans(), isEmpty);
    expect(seen.url.path, '/api/company/subscriptions/commercial/plans');
    expect(seen.headers['authorization'], 'Bearer company-token');
    service.close();
  });

  test('permission denial is surfaced without treating it as success', () async {
    final service = CommercialManagementService(
      baseUrl: 'https://order.example',
      token: 'company-token',
      client: MockClient((_) async => http.Response(
            jsonEncode({'success': false, 'error': {'code': 'COMPANY_PERMISSION_REQUIRED'}}),
            403,
          )),
    );
    await expectLater(service.promotions(), throwsA(isA<CommercialManagementFailure>()));
    service.close();
  });
}
