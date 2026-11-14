import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/commercial_management_service.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/models.dart';
import '../../providers/admin_auth/admin_auth_provider.dart';

class CommercialManagementScreen extends ConsumerStatefulWidget {
  const CommercialManagementScreen({super.key});
  @override
  ConsumerState<CommercialManagementScreen> createState() => _CommercialManagementScreenState();
}

class _CommercialManagementScreenState extends ConsumerState<CommercialManagementScreen>
    with SingleTickerProviderStateMixin {
  CommercialManagementService? _service;
  List<Map<String, dynamic>> _plans = [], _promotions = [], _approvals = [];
  List<Customer> _businesses = [];
  final Set<int> _selectedBusinesses = {};
  bool _loading = true, _busy = false;
  String? _error;
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void initState() { super.initState(); unawaited(_refresh()); }
  @override
  void dispose() { _tabs.dispose(); _service?.close(); super.dispose(); }

  String _commandId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> _refresh() async {
    final auth = ref.read(adminAuthServiceProvider);
    if (auth.token == null) { setState(() { _loading = false; _error = 'Sign in with a governed company employee session first.'; }); return; }
    try {
      _service ??= CommercialManagementService(baseUrl: AppConfig.orderBaseUrl, token: auth.token!);
      final result = await Future.wait([_service!.plans(), _service!.promotions(), _service!.approvals()]);
      final businesses = await auth.fetchUsers();
      if (!mounted) return;
      setState(() { _plans = result[0]; _promotions = result[1]; _approvals = result[2]; _businesses = businesses.where((b) => int.tryParse(b.businessId ?? '') != null).toList(); _loading = false; _error = null; });
    } catch (e) { if (mounted) setState(() { _loading = false; _error = _friendly(e); }); }
  }

  String _friendly(Object error) {
    final code = error is CommercialManagementFailure ? error.code : '';
    const messages = {
      'COMPANY_PERMISSION_REQUIRED': 'Your employee session lacks the required commercial permission.',
      'STALE_DRAFT': 'The draft changed. Refresh before editing.',
      'STALE_COMMERCIAL_APPROVAL': 'The approved terms changed. Request a new independent review.',
      'SELF_APPROVAL_FORBIDDEN': 'The creator cannot approve their own commercial change.',
      'APPROVAL_REQUIRED': 'This approval is missing, expired or already consumed.',
    };
    return messages[code] ?? 'Commercial management is unavailable. No change was applied.';
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await action(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e)))); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _createPromotion() async {
    final code = TextEditingController(), start = TextEditingController(), end = TextEditingController();
    final percent = TextEditingController(), fixed = TextEditingController(), global = TextEditingController(), per = TextEditingController(text: '1');
    var audience = 'GLOBAL';
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Create promotion draft'),
      content: SingleChildScrollView(child: Column(children: [
        TextField(controller: code, decoration: const InputDecoration(labelText: 'Code')),
        TextField(controller: percent, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Percentage discount (optional)')),
        TextField(controller: fixed, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fixed discount paise (optional)')),
        TextField(controller: start, decoration: const InputDecoration(labelText: 'Starts (ISO UTC)')),
        TextField(controller: end, decoration: const InputDecoration(labelText: 'Ends (ISO UTC)')),
        TextField(controller: global, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Global cap (optional)')),
        TextField(controller: per, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Per-business cap')),
        StatefulBuilder(builder: (context, setDialogState) => Column(children: [DropdownButtonFormField<String>(value: audience, items: const [DropdownMenuItem(value: 'GLOBAL', child: Text('Global audience')), DropdownMenuItem(value: 'BUSINESS_ALLOWLIST', child: Text('Selected businesses'))], onChanged: (value) => setDialogState(() => audience = value ?? 'GLOBAL')), if (audience == 'BUSINESS_ALLOWLIST') ..._businesses.map((business) { final id = int.parse(business.businessId!); return CheckboxListTile(value: _selectedBusinesses.contains(id), title: Text('${business.businessName} ($id)'), onChanged: (checked) => setDialogState(() { if (checked == true) { _selectedBusinesses.add(id); } else { _selectedBusinesses.remove(id); } })); })])),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save draft'))],
    ));
    if (accepted != true) return;
    final p = double.tryParse(percent.text), f = int.tryParse(fixed.text), s = DateTime.tryParse(start.text), e = DateTime.tryParse(end.text), cap = int.tryParse(per.text);
    if (code.text.trim().length < 3 || s == null || e == null || !e.isAfter(s) || cap == null || cap < 1 || (p == null && f == null) || (p != null && f != null)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter one valid discount and a valid UTC interval.')));
      return;
    }
    final selected = _selectedBusinesses.toList()..sort();
    if (audience == 'BUSINESS_ALLOWLIST' && selected.isEmpty) return;
    await _run(() async { await _service!.createPromotionDraft(code: code.text.trim().toUpperCase(), audience: audience, terms: {'automaticPaidConversion': false, 'stacking': 'ONE_PLAN_ONE_BEST_DISCOUNT_ADDITIVE_QUOTA', 'audience': audience, 'eligibility': {'kind': audience, if (selected.isNotEmpty) 'businessIds': selected}, 'operations': ['INITIAL'], 'enrollmentStartsAt': s.toUtc().toIso8601String(), 'enrollmentEndsAt': e.toUtc().toIso8601String(), 'globalCap': int.tryParse(global.text), 'perBusinessCap': cap, 'percentageOff': p, 'fixedPaiseOff': f}); await _refresh(); });
  }

  Future<void> _createPlan() async {
    final plan = TextEditingController(), price = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Create plan-version draft'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: plan, decoration: const InputDecoration(labelText: 'Existing Plan UUID')), TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price in INR paise'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create'))]));
    final paise = int.tryParse(price.text); if (ok != true || plan.text.trim().isEmpty || paise == null || paise < 0) return;
    await _run(() async { await _service!.createPlanDraft(planId: plan.text.trim(), pricePaise: paise); await _refresh(); });
  }

  Future<void> _editPlan(Map<String, dynamic> plan) async {
    final price = TextEditingController(text: plan['pricePaise']?.toString() ?? '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Edit draft terms'), content: TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price in INR paise')), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))]));
    final paise = int.tryParse(price.text); if (ok != true || paise == null || paise < 0) return;
    await _run(() async { await _service!.editDraft('PLAN_VERSION', plan['id'].toString(), {'expectedRevision': plan['draftRevision'] ?? 0, 'pricePaise': paise, 'targetScope': {'kind': 'GLOBAL'}}); await _refresh(); });
  }

  Future<void> _editPromotion(Map<String, dynamic> promotion) async {
    final start = TextEditingController(text: promotion['startsAt']?.toString() ?? ''), end = TextEditingController(text: promotion['endsAt']?.toString() ?? '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Edit promotion validity'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: start, decoration: const InputDecoration(labelText: 'Starts (ISO UTC)')), TextField(controller: end, decoration: const InputDecoration(labelText: 'Ends (ISO UTC)'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))]));
    final s = DateTime.tryParse(start.text), e = DateTime.tryParse(end.text); if (ok != true || s == null || e == null || !e.isAfter(s)) return;
    await _run(() async { await _service!.editDraft('PROMOTION_CAMPAIGN', promotion['id'].toString(), {'expectedRevision': promotion['revision'] ?? 0, 'termsSnapshot': {'automaticPaidConversion': false, 'stacking': 'ONE_PLAN_ONE_BEST_DISCOUNT_ADDITIVE_QUOTA', 'audience': promotion['audience'], 'enrollmentStartsAt': s.toUtc().toIso8601String(), 'enrollmentEndsAt': e.toUtc().toIso8601String(), 'globalCap': promotion['globalCap'], 'perBusinessCap': promotion['perBusinessCap']}}); await _refresh(); });
  }

  Future<void> _decision(Map<String, dynamic> approval, String decision) async {
    final me = ref.read(adminAuthServiceProvider).currentAdmin?.id;
    if (me != null && me == approval['requesterEmployeeId']?.toString()) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Self-approval is unavailable.'))); return; }
    await _run(() async { await _service!.decide(approval['id'].toString(), decision, _commandId()); await _refresh(); });
  }

  Future<void> _requestPromotionApproval(Map<String, dynamic> promotion) async {
    final reason = TextEditingController();
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Submit for independent approval'),
      content: TextField(controller: reason, maxLines: 3, decoration: const InputDecoration(labelText: 'Business reason')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit'))],
    ));
    if (accepted != true || reason.text.trim().isEmpty) return;
    await _run(() async { await _service!.requestApproval('PROMOTION_CAMPAIGN', promotion['id'].toString(), commandId: _commandId(), reason: reason.text.trim()); await _refresh(); });
  }

  Future<void> _retirePromotion(Map<String, dynamic> promotion) async {
    await _run(() async { await _service!.retire('PROMOTION_CAMPAIGN', promotion['id'].toString()); await _refresh(); });
  }

  Future<void> _previewPromotion(Map<String, dynamic> promotion) async {
    final base = TextEditingController(text: '10000');
    final benefit = (promotion['benefits'] is List && (promotion['benefits'] as List).isNotEmpty)
        ? Map<String, dynamic>.from((promotion['benefits'] as List).first as Map)
        : <String, dynamic>{};
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text('Preview ${promotion['code']}'), content: TextField(controller: base, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Base amount (paise)')), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Preview'))]));
    final amount = int.tryParse(base.text); if (ok != true || amount == null || amount < 0) return;
    await _run(() async { final result = await _service!.preview(amount, benefit); if (!mounted) return; await showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: const Text('Server-authoritative preview'), content: Text('Base: ${result['basePaise']} paise\nDiscount: ${result['discountPaise']} paise\nFinal: ${result['finalPaise']} paise\n${promotion['termsSnapshot']?['operations'] ?? ['INITIAL']}'), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))])); });
  }

  Future<void> _publishApproval(Map<String, dynamic> approval) async {
    await _run(() async { await _service!.publish(approval['targetKind'].toString(), approval['targetId'].toString(), approval['id'].toString()); await _refresh(); });
  }

  Widget _state(dynamic state) => Chip(label: Text(state?.toString() ?? 'UNKNOWN'), backgroundColor: state == 'PUBLISHED' || state == 'OPEN' ? AppColors.success.withOpacity(.15) : state == 'DRAFT' ? AppColors.warning.withOpacity(.15) : null);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Commercial management'), actions: [IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))], bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Plans'), Tab(text: 'Promotions'), Tab(text: 'Approvals')])),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _error != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, key: const Key('commercial-error')))) : TabBarView(controller: _tabs, children: [_plansView(), _promotionsView(), _approvalsView()]),
  );

  Widget _plansView() => ListView(padding: const EdgeInsets.all(16), children: [
    FilledButton.icon(onPressed: _busy ? null : _createPlan, icon: const Icon(Icons.add), label: const Text('New plan-version draft')),
    const Text('Published terms are server authoritative. Draft edits require a fresh independent approval.'),
    ..._plans.map((p) => Card(child: ListTile(title: Text('Plan ${p['planId']} • v${p['version']}'), subtitle: Text('${p['pricePaise']} paise ${p['currency']} • ${p['contentHash'] ?? 'Draft terms'}'), trailing: Wrap(children: [_state(p['state']), if (p['state'] == 'DRAFT') IconButton(onPressed: _busy ? null : () => _editPlan(p), icon: const Icon(Icons.edit))])))),
  ]);

  Widget _promotionsView() => ListView(padding: const EdgeInsets.all(16), children: [
    FilledButton.icon(onPressed: _busy ? null : _createPromotion, icon: const Icon(Icons.add), label: const Text('New promotion draft')),
    ..._promotions.map((p) => Card(child: ListTile(title: Text('${p['code']} • v${p['version']}'), subtitle: Text('${p['audience']} • ${p['startsAt']} → ${p['endsAt']}\nGlobal ${p['globalCap'] ?? '∞'} • business ${p['perBusinessCap']}'), isThreeLine: true, trailing: Wrap(spacing: 4, children: [ _state(p['state']), IconButton(tooltip: 'Server preview', onPressed: _busy ? null : () => _previewPromotion(p), icon: const Icon(Icons.calculate)), if (p['state'] == 'DRAFT') ...[IconButton(tooltip: 'Edit draft', onPressed: _busy ? null : () => _editPromotion(p), icon: const Icon(Icons.edit)), IconButton(tooltip: 'Request independent approval', onPressed: _busy ? null : () => _requestPromotionApproval(p), icon: const Icon(Icons.send))], if (p['state'] == 'OPEN') IconButton(tooltip: 'Revoke promotion', onPressed: _busy ? null : () => _retirePromotion(p), icon: const Icon(Icons.block)) ])))),
  ]);

  Widget _approvalsView() => ListView(padding: const EdgeInsets.all(16), children: [
    if (_approvals.isEmpty) const Text('No pending independent approvals.'),
    ..._approvals.map((a) => Card(child: ListTile(title: Text('${a['targetKind']} • ${a['targetId']}'), subtitle: Text('${a['state']} • requested by ${a['requesterEmployeeId']} • expires ${a['expiresAt']}'), isThreeLine: true, trailing: Wrap(spacing: 4, children: [if (a['state'] == 'PENDING') ...[OutlinedButton(onPressed: _busy ? null : () => _decision(a, 'REJECTED'), child: const Text('Reject')), FilledButton(onPressed: _busy ? null : () => _decision(a, 'APPROVED'), child: const Text('Approve'))], if (a['state'] == 'APPROVED') FilledButton(onPressed: _busy ? null : () => _publishApproval(a), child: const Text('Publish'))])))),
  ]);
}
