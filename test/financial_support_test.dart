import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flexit_admin/core/auth/financial_support_service.dart';
import 'package:flexit_admin/screens/support/financial_support_screen.dart';

http.Response ok(Map<String, dynamic> data) =>
    http.Response(jsonEncode({'success': true, 'data': data}), 200);
Map<String, dynamic> purchase({bool pending = false}) => {
      'transactionId': '00000000-0000-4000-8000-000000000042',
      'planCode': 'growth',
      'operation': 'INITIAL',
      'amountPaise': '69900',
      'currency': 'INR',
      'environment': 'test',
      'paymentStatus': pending ? 'NOT_VERIFIED_CAPTURED' : 'CAPTURE_VERIFIED',
      'activationStatus': pending ? 'NOT_REQUESTED' : 'ACTIVATED',
      'state': pending ? 'PAYMENT_PENDING' : 'ACTIVATED',
      'canReconcile': pending
    };
FinancialSupportService service(
        Future<http.Response> Function(http.Request) handler) =>
    FinancialSupportService(
        companyBaseUrl: 'https://company.example.invalid/api/company',
        financialBaseUrl:
            'https://content.example.invalid/api/company/financial-support',
        client: MockClient(handler));
void main() {
  for (final transition in ['business switch', 'logout', 'session loss']) {
    testWidgets(
        'publication review clears case and audit reference on $transition',
        (tester) async {
      var expire = false;
      final s = service((r) async {
        if (r.url.path.endsWith('/login')) {
          return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
        }
        if (r.url.path.endsWith('/logout')) {
          return ok({});
        }
        if (expire) {
          return http.Response(
              jsonEncode({
                'success': false,
                'error': {'code': 'COMPANY_UNAUTHORIZED'}
              }),
              401);
        }
        return ok({
          'items': [],
          'nextCursor': null,
          'attemptId': r.url.path.contains('/43/')
              ? 'business-43-attempt'
              : 'private-42-attempt'
        });
      });
      await s.login('e@example.invalid', 'synthetic');
      await tester
          .pumpWidget(MaterialApp(home: FinancialSupportScreen(service: s)));
      await tester.enterText(find.byType(TextField).first, '42');
      await tester.tap(find.text('Investigate business'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'CASE-BUSINESS-42');
      if (transition == 'business switch') {
        await tester.enterText(find.byType(TextField).first, '43');
        await tester.tap(find.text('Investigate business'));
        await tester.pumpAndSettle();
      } else {
        if (transition == 'logout') {
          await tester.tap(find.text('End company session'));
        } else {
          expire = true;
          await tester.tap(find.text('Investigate business'));
        }
        await tester.pumpAndSettle();
        expire = false;
        await tester.tap(find.text('Start governed company session'));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('private-42-attempt'), findsNothing);
      expect(
          tester
              .widgetList<TextField>(find.byType(TextField))
              .every((f) => f.controller?.text != 'CASE-BUSINESS-42'),
          true);
      if (transition != 'business switch') {
        expect(find.text('Selected business: none'), findsOneWidget);
      }
    });
  }

  test(
      'company session is distinct and financial routes never use owner endpoints',
      () async {
    final calls = <http.Request>[];
    final s = service((r) async {
      calls.add(r);
      if (r.url.path.endsWith('/login')) {
        return ok(
            {'token': 'synthetic-company-session', 'tokenType': 'Bearer'});
      }
      return ok({'items': []});
    });
    await s.login('employee@example.invalid', 'synthetic-input');
    await s.history(42);
    await s.detail(42, 'original');
    await s.reconcile(42, 'original', 'CASE-42');
    await s.audit(42);
    expect(
        calls.skip(1).every((r) =>
            r.headers['authorization'] == 'Bearer synthetic-company-session'),
        true);
    expect(
        calls.skip(1).every((r) =>
            r.url.path.contains('/api/company/financial-support/business/42/')),
        true);
    expect(
        calls.every(
            (r) => !r.url.path.contains('/api/content/business/payments')),
        true);
    expect(jsonDecode(calls[3].body), {'caseReference': 'CASE-42'});
    s.close();
    expect(s.signedIn, false);
  });
  test('401 clears the private company session and 403 stays explicit',
      () async {
    var denied = 403;
    final s = service((r) async => r.url.path.endsWith('/login')
        ? ok({'token': 'synthetic', 'tokenType': 'Bearer'})
        : http.Response(
            jsonEncode({
              'success': false,
              'error': {
                'code': denied == 403
                    ? 'COMPANY_PERMISSION_REQUIRED'
                    : 'COMPANY_UNAUTHORIZED'
              }
            }),
            denied));
    await s.login('e@example.invalid', 'synthetic');
    await expectLater(
        s.history(42),
        throwsA(isA<FinancialSupportFailure>()
            .having((e) => e.code, 'code', 'COMPANY_PERMISSION_REQUIRED')));
    denied = 401;
    await expectLater(s.history(42), throwsA(isA<FinancialSupportFailure>()));
    expect(s.signedIn, false);
  });
  testWidgets(
      'governed login, business investigation and permission error states',
      (tester) async {
    final s = service((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      return http.Response(
          jsonEncode({
            'success': false,
            'error': {'code': 'COMPANY_PERMISSION_REQUIRED'}
          }),
          403);
    });
    await tester
        .pumpWidget(MaterialApp(home: FinancialSupportScreen(service: s)));
    expect(find.text('Start governed company session'), findsOneWidget);
    await tester.tap(find.text('Start governed company session'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Investigate business'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Explicit financial permission'), findsOneWidget);
    expect(find.text('Selected business: 42'), findsOneWidget);
  });
  testWidgets(
      'original detail and guarded reconciliation preserve the selected purchase',
      (tester) async {
    var reconciles = 0;
    final s = service((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      if (r.url.path.endsWith('/reconcile')) {
        reconciles++;
        expect(jsonDecode(r.body), {});
        return ok({'attemptId': 'attempt', ...purchase()});
      }
      if (r.url.path.endsWith('/history')) {
        return ok({
          'items': [purchase(pending: true)],
          'nextCursor': null,
          'attemptId': 'attempt'
        });
      }
      return ok(purchase(pending: true));
    });
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: FinancialSupportScreen(service: s)));
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Investigate business'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Investigate original transaction'));
    await tester.tap(find.text('Investigate original transaction'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('reconcile-original')));
    await tester.tap(find.byKey(const Key('reconcile-original')));
    await tester.pumpAndSettle();
    expect(reconciles, 0);
    await tester.tap(find.text('Check original payment'));
    await tester.pumpAndSettle();
    expect(reconciles, 1);
    expect(find.text('Activation: ACTIVATED'), findsOneWidget);
  });
  testWidgets(
      'audit investigation is separate and business switching clears old records',
      (tester) async {
    final s = service((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      if (r.url.path.endsWith('/audit')) {
        return ok({
          'items': [
            {
              'action': 'HISTORY',
              'decision': 'ALLOWED',
              'outcome': 'SUCCEEDED',
              'employeeId': 7,
              'createdAt': '2026-11-12',
              'attemptId': 'audit'
            }
          ]
        });
      }
      return ok({
        'items': r.url.path.contains('/42/') ? [purchase()] : [],
        'nextCursor': null
      });
    });
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: FinancialSupportScreen(service: s)));
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Investigate business'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View business support audit'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HISTORY · ALLOWED'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '43');
    await tester.tap(find.text('Investigate business'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HISTORY · ALLOWED'), findsNothing);
    expect(find.textContaining('No purchases'), findsOneWidget);
  });
  test('financial transport refuses insecure configuration', () async {
    final s = FinancialSupportService(
        companyBaseUrl: 'http://unsafe.invalid',
        financialBaseUrl: 'http://unsafe.invalid',
        client: MockClient((_) async => throw StateError('must not forward')));
    await expectLater(
        s.login('x', 'x'), throwsA(isA<FinancialSupportFailure>()));
  });
}
