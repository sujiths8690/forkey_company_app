import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flexit_admin/core/auth/financial_support_service.dart';
import 'package:flexit_admin/screens/support/support_tickets_screen.dart';
import 'package:flexit_admin/screens/support/governed_access_screen.dart';

http.Response ok(Map<String, dynamic> data) =>
    http.Response(jsonEncode({'success': true, 'data': data}), 200);
FinancialSupportService client(
        Future<http.Response> Function(http.Request) fn) =>
    FinancialSupportService(
        companyBaseUrl: 'https://company.invalid/api/company',
        financialBaseUrl:
            'https://content.invalid/api/company/financial-support',
        client: MockClient(fn));
Map<String, dynamic> ticket() => {
      'ticket': {
        'id': 'original-ticket',
        'reference': 'FS-ORIGINAL',
        'subject': 'Original issue',
        'description': 'Original description',
        'status': 'OPEN',
        'revision': 2,
        'assignedEmployeeId': 7,
        'intentId': 'original-intent'
      },
      'events': [
        {
          'visible': false,
          'kind': 'NOTE',
          'text': 'Internal investigation note',
          'createdAt': '2026-11-12'
        }
      ],
      'nextAfter': null
    };
void main() {
  test(
      'ticket and grant clients use privileged company boundaries, never owner routes',
      () async {
    final calls = <http.Request>[];
    final s = client((r) async {
      calls.add(r);
      return ok(r.url.path.endsWith('/login')
          ? {'token': 'synthetic', 'tokenType': 'Bearer'}
          : {});
    });
    await s.login('e@example.invalid', 'synthetic');
    await s.tickets(42, status: 'OPEN');
    await s.ticket(42, 'original');
    await s.ticketAction(
        42, 'original', {'action': 'NOTE', 'commandId': 'stable'});
    await s.ticketFinancial(42, 'original');
    await s.accessView('requests', 42);
    await s.accessMutation(
        'decisions', {'scopeKey': 'BUSINESS:42', 'decision': 'APPROVED'});
    expect(calls.every((r) => !r.url.path.contains('/api/content/business')),
        true);
    expect(
        calls[4].url.path, endsWith('/business/42/tickets/original/financial'));
    expect(jsonDecode(calls[4].body), {'operation': 'DETAIL'});
    expect(calls[5].url.queryParameters['scopeKey'], 'BUSINESS:42');
  });
  testWidgets(
      'inbox detail keeps notes distinct and opens existing Q13 independent investigation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var financialReads = 0;
    final s = client((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      if (r.url.path.endsWith('/financial')) {
        financialReads++;
        return http.Response(
            jsonEncode({
              'success': false,
              'error': {'code': 'COMPANY_PERMISSION_REQUIRED'}
            }),
            403);
      }
      if (r.url.path.endsWith('/original-ticket')) {
        return ok(ticket());
      }
      return ok({
        'items': [
          {
            'id': 'original-ticket',
            'reference': 'FS-ORIGINAL',
            'subject': 'Original issue',
            'status': 'OPEN'
          }
        ],
        'nextCursor': null
      });
    });
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: SupportTicketsScreen(service: s)));
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Open business inbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FS-ORIGINAL · Original issue'));
    await tester.pumpAndSettle();
    expect(find.text('INTERNAL · NOTE'), findsOneWidget);
    expect(financialReads, 0);
    await tester
        .ensureVisible(find.text('Investigate original payment through Q13'));
    await tester.tap(find.text('Investigate original payment through Q13'));
    await tester.pumpAndSettle();
    expect(financialReads, 1);
    expect(
        find.textContaining('Explicit financial permission'), findsOneWidget);
    expect(find.text('Q13 state: ACTIVATED'), findsNothing);
  });
  testWidgets('business switch and revoked authority clear confidential inbox',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var denied = false;
    final s = client((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      if (denied) {
        return http.Response(
            jsonEncode({
              'success': false,
              'error': {'code': 'COMPANY_PERMISSION_REQUIRED'}
            }),
            403);
      }
      return ok({
        'items': r.url.path.contains('/42/')
            ? [
                {
                  'id': 'original-ticket',
                  'reference': 'PRIVATE-42',
                  'subject': 'Original issue',
                  'status': 'OPEN'
                }
              ]
            : [],
        'nextCursor': null
      });
    });
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: SupportTicketsScreen(service: s)));
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Open business inbox'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PRIVATE-42'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '43');
    await tester.tap(find.text('Open business inbox'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PRIVATE-42'), findsNothing);
    denied = true;
    await tester.tap(find.text('Open business inbox'));
    await tester.pumpAndSettle();
    expect(find.text('Selected business: none'), findsOneWidget);
  });
  testWidgets('uncertain ticket action retries the original UUID and payload',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map>[];
    final s = client((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      if (r.url.path.endsWith('/actions')) {
        sent.add(jsonDecode(r.body));
        if (sent.length == 1) {
          throw Exception('SYNTHETIC_LOST_RESPONSE');
        }
        return ok({});
      }
      if (r.url.path.endsWith('/original-ticket')) {
        return ok(ticket());
      }
      return ok({
        'items': [
          {
            'id': 'original-ticket',
            'reference': 'FS-ORIGINAL',
            'subject': 'Original issue',
            'status': 'OPEN'
          }
        ],
        'nextCursor': null
      });
    });
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: SupportTicketsScreen(service: s)));
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Open business inbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FS-ORIGINAL · Original issue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Internal work');
    await tester.ensureVisible(find.text('Append internal note'));
    await tester.tap(find.text('Append internal note'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.text('Retry original uncertain ticket command'));
    await tester.tap(find.text('Retry original uncertain ticket command'));
    await tester.pumpAndSettle();
    expect(sent.length, 2);
    expect(sent[0], sent[1]);
  });
  testWidgets(
      'governance requests use inspected server epoch and show review status',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Map? requested;
    final s = client((r) async {
      if (r.url.path.endsWith('/login')) {
        return ok({'token': 'synthetic', 'tokenType': 'Bearer'});
      }
      if (r.method == 'POST') {
        requested = jsonDecode(r.body);
        return ok(
            {'status': 'ACCESS_REQUESTED', 'requestId': 'original-request'});
      }
      return ok({
        'items': [],
        'target': {'employeeId': 9, 'revision': 12},
        'nextCursor': null
      });
    });
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: GovernedAccessScreen(service: s)));
    await tester.enterText(find.byType(TextField).at(0), '42');
    await tester.enterText(find.byType(TextField).at(1), '9');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('grants').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inspect scoped access'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).last, 'Reviewed financial support access');
    await tester.ensureVisible(find.text('Request reviewed access'));
    await tester.tap(find.text('Request reviewed access'));
    await tester.pumpAndSettle();
    expect(requested?['scopeKey'], 'BUSINESS:42');
    expect(requested?['targetEpoch'], 12);
    expect(requested?['permission'], 'subscription.payment.read');
    expect(find.textContaining('ACCESS_REQUESTED'), findsOneWidget);
  });
  testWidgets('governed onboarding denied state never grants privilege locally',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = client((r) async => r.url.path.endsWith('/login')
        ? ok({'token': 'synthetic', 'tokenType': 'Bearer'})
        : http.Response(
            jsonEncode({
              'success': false,
              'error': {'code': 'COMPANY_PERMISSION_REQUIRED'}
            }),
            403));
    await s.login('e@example.invalid', 'synthetic');
    await tester
        .pumpWidget(MaterialApp(home: GovernedAccessScreen(service: s)));
    await tester.enterText(find.byType(TextField).first, '42');
    await tester.tap(find.text('Inspect scoped access'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Governance permission denied'), findsOneWidget);
    expect(
        (tester.widget<TextField>(find.byType(TextField).first).controller!)
            .text,
        isEmpty);
  });
}
