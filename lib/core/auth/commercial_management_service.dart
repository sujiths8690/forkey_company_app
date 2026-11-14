import 'dart:convert';
import 'package:http/http.dart' as http;

class CommercialManagementFailure implements Exception {
  final String code;
  const CommercialManagementFailure(this.code);
  @override
  String toString() => code;
}

class CommercialManagementService {
  CommercialManagementService({required this.baseUrl, required this.token, http.Client? client}) : client = client ?? http.Client();
  final String baseUrl, token;
  final http.Client client;

  Future<dynamic> _request(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$baseUrl/api/company/subscriptions$path');
    final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
    final response = method == 'GET'
        ? await client.get(uri, headers: headers)
        : method == 'PATCH'
            ? await client.patch(uri, headers: headers, body: jsonEncode(body ?? const {}))
            : await client.post(uri, headers: headers, body: jsonEncode(body ?? const {}));
    Map<String, dynamic> json;
    try { json = Map<String, dynamic>.from(jsonDecode(response.body) as Map); } catch (_) { throw const CommercialManagementFailure('COMMERCIAL_UNAVAILABLE'); }
    if (response.statusCode < 200 || response.statusCode >= 300 || json['success'] != true) {
      final error = json['error'];
      throw CommercialManagementFailure(error is Map ? error['code']?.toString() ?? 'COMMERCIAL_UNAVAILABLE' : 'COMMERCIAL_UNAVAILABLE');
    }
    return json['data'];
  }

  Future<List<Map<String, dynamic>>> plans() async => ((await _request('GET', '/commercial/plans')) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Future<List<Map<String, dynamic>>> promotions() async => ((await _request('GET', '/commercial/promotions')) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Future<List<Map<String, dynamic>>> approvals({String state = 'ALL'}) async => ((await _request('GET', '/commercial/approvals?state=$state')) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Future<Map<String, dynamic>> createPlanDraft({required String planId, required int pricePaise, String taxTreatment = 'PENDING_REVIEW', String termsVersion = 'DRAFT'}) async => Map<String, dynamic>.from(await _request('POST', '/commercial/plans/drafts', body: {'planId': planId, 'pricePaise': pricePaise, 'taxTreatment': taxTreatment, 'termsVersion': termsVersion}) as Map);
  Future<Map<String, dynamic>> createPromotionDraft({required String code, required Map<String, dynamic> terms, required String audience}) async => Map<String, dynamic>.from(await _request('POST', '/commercial/promotions/drafts', body: {'code': code, 'audience': audience, 'termsSnapshot': terms}) as Map);
  Future<Map<String, dynamic>> editDraft(String kind, String id, Map<String, dynamic> body) async => Map<String, dynamic>.from(await _request('PATCH', '/commercial/$kind/$id/draft', body: body) as Map);
  Future<Map<String, dynamic>> requestApproval(String kind, String id, {required String commandId, required String reason, Map<String, dynamic>? targetScope}) async => Map<String, dynamic>.from(await _request('POST', '/commercial/$kind/$id/approval', body: {'commandId': commandId, 'reason': reason, 'targetScope': targetScope ?? {'kind': 'GLOBAL'}}) as Map);
  Future<Map<String, dynamic>> decide(String id, String decision, String commandId) async => Map<String, dynamic>.from(await _request('POST', '/commercial/approvals/$id/decision', body: {'decision': decision, 'commandId': commandId}) as Map);
  Future<Map<String, dynamic>> publish(String kind, String id, String approvalId, {Map<String, dynamic>? targetScope}) async => Map<String, dynamic>.from(await _request('POST', '/commercial/$kind/$id/publish-approved', body: {'approvalId': approvalId, 'targetScope': targetScope ?? {'kind': 'GLOBAL'}}) as Map);
  Future<Map<String, dynamic>> retire(String kind, String id, {Map<String, dynamic>? targetScope}) async => Map<String, dynamic>.from(await _request('POST', '/commercial/$kind/$id/retire', body: {'targetScope': targetScope ?? {'kind': 'GLOBAL'}}) as Map);
  Future<Map<String, dynamic>> preview(int basePaise, Map<String, dynamic> benefit) async => Map<String, dynamic>.from(await _request('POST', '/commercial/preview-discount', body: {'basePaise': basePaise, 'benefit': benefit}) as Map);
  void close() => client.close();
}
