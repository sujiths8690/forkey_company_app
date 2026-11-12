import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;

class FinancialSupportFailure implements Exception {
  final String code;
  const FinancialSupportFailure(this.code);
  @override
  String toString() => code;
}

// Separate governed company session. Legacy admin and restaurant tokens are never exchanged.
class FinancialSupportService {
  final String companyBaseUrl, financialBaseUrl;
  final http.Client client;
  String? _token;
  FinancialSupportService(
      {required this.companyBaseUrl,
      required this.financialBaseUrl,
      http.Client? client})
      : client = client ?? http.Client();
  bool get signedIn => _token != null;
  Future<Map<String, dynamic>> _request(String base, String route,
      {Map<String, dynamic>? body, bool authenticated = true}) async {
    final uri = Uri.parse('$base$route');
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty && !route.contains('?')) {
      throw const FinancialSupportFailure('SECURE_CONFIGURATION_REQUIRED');
    }
    final headers = {
      'Content-Type': 'application/json',
      if (authenticated && _token != null) 'Authorization': 'Bearer $_token'
    };
    final response = await (body == null
            ? client.get(uri, headers: headers)
            : client.post(uri, headers: headers, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode == 401) {
      _token = null;
      throw const FinancialSupportFailure('COMPANY_UNAUTHORIZED');
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const FinancialSupportFailure('FINANCIAL_SUPPORT_UNAVAILABLE');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        json['success'] != true) {
      throw FinancialSupportFailure(json['error'] is Map
          ? json['error']['code']?.toString() ?? 'FINANCIAL_SUPPORT_UNAVAILABLE'
          : 'FINANCIAL_SUPPORT_UNAVAILABLE');
    }
    return Map<String, dynamic>.from(json['data'] as Map);
  }

  Future<void> login(String email, String password) async {
    _token = null;
    final data = await _request(companyBaseUrl, '/session/login',
        body: {'email': email.trim(), 'password': password},
        authenticated: false);
    if (data['token'] is! String || data['tokenType'] != 'Bearer') {
      throw const FinancialSupportFailure('COMPANY_UNAUTHORIZED');
    }
    _token = data['token'];
  }

  Future<Map<String, dynamic>> history(int business,
          {String? cursor, String? caseReference}) =>
      _request(financialBaseUrl,
          '/business/$business/history?limit=20${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}${caseReference == null || caseReference.isEmpty ? '' : '&caseReference=${Uri.encodeQueryComponent(caseReference)}'}');
  Future<Map<String, dynamic>> detail(int business, String id,
          {String? caseReference}) =>
      _request(financialBaseUrl,
          '/business/$business/history/${Uri.encodeComponent(id)}${caseReference == null || caseReference.isEmpty ? '' : '?caseReference=${Uri.encodeQueryComponent(caseReference)}'}');
  Future<Map<String, dynamic>> reconcile(
          int business, String id, String caseReference) =>
      _request(financialBaseUrl,
          '/business/$business/history/${Uri.encodeComponent(id)}/reconcile',
          body: {if (caseReference.isNotEmpty) 'caseReference': caseReference});
  Future<
      Map<String,
          dynamic>> audit(int business, {String? caseReference}) => _request(
      financialBaseUrl,
      '/business/$business/audit${caseReference == null || caseReference.isEmpty ? '' : '?caseReference=${Uri.encodeQueryComponent(caseReference)}'}');
  Future<void> logout() async {
    try {
      if (_token != null) {
        await _request(companyBaseUrl, '/session/logout', body: {});
      }
    } finally {
      _token = null;
    }
  }

  String commandId() {
    final b = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  String get supportBase {
    if (!financialBaseUrl.endsWith('/financial-support')) {
      throw const FinancialSupportFailure('SECURE_CONFIGURATION_REQUIRED');
    }
    return financialBaseUrl.replaceFirst(
        RegExp(r'/financial-support$'), '/subscription-support');
  }

  Future<Map<String, dynamic>> tickets(int business,
          {String? status, String? cursor}) =>
      _request(
          supportBase,
          '/business/$business/tickets?${[
            if (status != null) 'status=${Uri.encodeQueryComponent(status)}',
            if (cursor != null) 'cursor=${Uri.encodeQueryComponent(cursor)}'
          ].join('&')}');
  Future<
      Map<String,
          dynamic>> ticket(int business, String id, {int? after}) => _request(
      supportBase,
      '/business/$business/tickets/${Uri.encodeComponent(id)}${after == null ? '' : '?after=$after'}');
  Future<Map<String, dynamic>> ticketAction(
          int business, String id, Map<String, dynamic> body) =>
      _request(supportBase,
          '/business/$business/tickets/${Uri.encodeComponent(id)}/actions',
          body: body);
  Future<Map<String, dynamic>> ticketFinancial(int business, String id,
          {bool reconcile = false}) =>
      _request(supportBase,
          '/business/$business/tickets/${Uri.encodeComponent(id)}/financial',
          body: {'operation': reconcile ? 'RECONCILE' : 'DETAIL'});
  Future<Map<String, dynamic>> accessView(String kind, int business,
          {int? target, String? cursor}) =>
      _request(companyBaseUrl,
          '/access/$kind?scopeKey=BUSINESS:$business${target == null ? '' : '&targetEmployeeId=$target'}${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}');
  Future<Map<String, dynamic>> accessMutation(
          String kind, Map<String, dynamic> body) =>
      _request(companyBaseUrl, '/access/$kind', body: body);

  void close() {
    _token = null;
    client.close();
  }
}
