import 'support_tickets_screen.dart';
import 'governed_access_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../../core/auth/financial_support_service.dart';

class FinancialSupportScreen extends StatefulWidget {
  final FinancialSupportService? service;
  final int? ticketBusinessId;
  final String? ticketId;
  const FinancialSupportScreen(
      {super.key, this.service, this.ticketBusinessId, this.ticketId});
  @override
  State<FinancialSupportScreen> createState() => _FinancialSupportScreenState();
}

class _FinancialSupportScreenState extends State<FinancialSupportScreen> {
  FinancialSupportService? _service;
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _business = TextEditingController(),
      _case = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _detail;
  List<dynamic>? _audit;
  String? _cursor, _error, _attempt;
  int? _selectedBusiness;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _service = widget.service;
    if (widget.ticketId != null) {
      _selectedBusiness = widget.ticketBusinessId;
      Future.microtask(() => _inspect(widget.ticketId!));
    }
    if (_service == null) {
      final company = dotenv.env['COMPANY_SESSION_BASE_URL'],
          financial = dotenv.env['FINANCIAL_SUPPORT_BASE_URL'];
      if (company != null && financial != null) {
        _service = FinancialSupportService(
            companyBaseUrl: company.replaceFirst(RegExp(r'/$'), ''),
            financialBaseUrl: financial.replaceFirst(RegExp(r'/$'), ''));
      } else {
        _error =
            'Financial support is disabled: approved company-session and financial-support URLs are not configured.';
      }
    }
  }

  @override
  void dispose() {
    if (widget.service == null) {
      _service?.close();
    }
    _email.dispose();
    _password.dispose();
    _business.dispose();
    _case.dispose();
    super.dispose();
  }

  // Clear all account-scoped references, not only the visible transaction list.
  void _clearSessionData() {
    _items = [];
    _detail = null;
    _audit = null;
    _cursor = null;
    _attempt = null;
    _selectedBusiness = null;
    _business.clear();
    _case.clear();
    _email.clear();
    _password.clear();
  }

  String _message(Object e) {
    if (e is FinancialSupportFailure) {
      switch (e.code) {
        case 'COMPANY_UNAUTHORIZED':
          return 'Company session expired or unavailable. Sign in with your platform employee account.';
        case 'COMPANY_PERMISSION_REQUIRED':
          return 'Explicit financial permission for this business is required. No payment action was authorized.';
        case 'FINANCIAL_RECORD_INCONSISTENT':
          return 'Financial evidence is inconsistent. Preserve the original purchase for reviewed resolution.';
        case 'PAYMENT_RESOLUTION_REQUIRED':
          return 'The original purchase requires resolution. Do not create another charge.';
        case 'FINANCIAL_RECORD_NOT_FOUND':
          return 'Original transaction is unavailable in this business and environment.';
      }
    }
    return 'Financial support is unavailable. An interrupted action may remain pending in the audit. Recheck only the original transaction.';
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy || _service == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          if (!_service!.signedIn ||
              e is FinancialSupportFailure &&
                  e.code == 'COMPANY_PERMISSION_REQUIRED') {
            _clearSessionData();
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() => _run(() async {
        try {
          await _service!.login(_email.text, _password.text);
        } finally {
          if (mounted) {
            _password.clear();
          }
        }
      });
  Future<void> _load({bool more = false}) => widget.ticketId != null
      ? _inspect(widget.ticketId!)
      : _run(() async {
          final id =
              more ? _selectedBusiness : int.tryParse(_business.text.trim());
          if (id == null || id < 1 || id > 2147483647) {
            setState(() => _error = 'Enter an authorized business ID.');
            return;
          }
          if (!more) {
            setState(() {
              _items = [];
              _detail = null;
              _audit = null;
              if (_selectedBusiness != null && _selectedBusiness != id) {
                _case.clear();
              }
              _selectedBusiness = id;
              _cursor = null;
              _attempt = null;
            });
          }
          final page = await _service!.history(id,
              cursor: more ? _cursor : null, caseReference: _case.text.trim());
          if (mounted) {
            setState(() {
              _items = [
                if (more) ..._items,
                ...(page['items'] as List)
                    .map((e) => Map<String, dynamic>.from(e))
              ];
              _cursor = page['nextCursor'];
              _attempt = page['attemptId'];
            });
          }
        });
  Future<void> _inspect(String id, {bool reconcile = false}) => _run(() async {
        final result = widget.ticketId != null
            ? await _service!.ticketFinancial(
                widget.ticketBusinessId!, widget.ticketId!,
                reconcile: reconcile)
            : reconcile
                ? await _service!
                    .reconcile(_selectedBusiness!, id, _case.text.trim())
                : await _service!.detail(_selectedBusiness!, id,
                    caseReference: _case.text.trim());
        if (mounted) {
          setState(() {
            _detail = result;
            _audit = null;
            _attempt = result['attemptId'];
          });
        }
      });
  Widget _purchase(Map<String, dynamic> row, {bool detail = false}) => Card(
      child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${row['planCode']} • ${row['operation']}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
                'Agreed: ${row['amountPaise']} paise ${row['currency']} · ${row['environment']}'),
            Text('Capture: ${row['paymentStatus']}'),
            Text('Activation: ${row['activationStatus']}'),
            Text('State: ${row['state']}'),
            if (row['billingCycle'] is Map)
              Text(
                  'Original period: ${row['billingCycle']['startsAt']} — ${row['billingCycle']['endsAt']}'),
            if (detail) ...[
              SelectableText('Transaction: ${row['transactionId']}'),
              const Text(
                  'Historical verification; current refunds and disputes are not tracked.'),
              if (row['canReconcile'] == true)
                FilledButton.icon(
                    key: const Key('reconcile-original'),
                    onPressed: _busy
                        ? null
                        : () async {
                            final approved = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                        title: const Text(
                                            'Reconcile original payment?'),
                                        content: const Text(
                                            'Checks only this original purchase. No replacement order, manual paid grant or refund is available.'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Cancel')),
                                          FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text(
                                                  'Check original payment'))
                                        ]));
                            if (approved == true && mounted) {
                              await _inspect(row['transactionId'],
                                  reconcile: true);
                            }
                          },
                    icon: const Icon(Icons.sync),
                    label: const Text('Reconcile original payment'))
            ] else
              TextButton(
                  onPressed:
                      _busy ? null : () => _inspect(row['transactionId']),
                  child: const Text('Investigate original transaction'))
          ])));
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar:
          AppBar(title: const Text('Subscription financial support'), actions: [
        if (_service?.signedIn == true)
          TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await _service!.logout();
                        if (mounted) {
                          setState(_clearSessionData);
                        }
                      }),
              child: const Text('End company session'))
      ]),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: ListView(padding: const EdgeInsets.all(24), children: [
                const Text('Audited payment investigation',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                    'Each request is checked against current employee/session authority for one business. Unknown outcomes never establish activation.'),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_error!,
                          key: const Key('financial-support-error'))),
                if (_service?.signedIn != true) ...[
                  TextField(
                      controller: _email,
                      decoration: const InputDecoration(
                          labelText: 'Platform employee email')),
                  TextField(
                      controller: _password,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                          labelText: 'Company-session password')),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: _busy || _service == null ? null : _login,
                      child: const Text('Start governed company session'))
                ] else ...[
                  Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                            width: 240,
                            child: TextField(
                                controller: _business,
                                readOnly: widget.ticketId != null,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'Authorized business ID'))),
                        FilledButton(
                            onPressed: _busy ? null : () => _load(),
                            child: const Text('Investigate business')),
                        OutlinedButton(
                            onPressed: _busy || _selectedBusiness == null
                                ? null
                                : () => _run(() async {
                                      final a = await _service!.audit(
                                          _selectedBusiness!,
                                          caseReference: _case.text.trim());
                                      setState(() {
                                        _audit = a['items'];
                                        _detail = null;
                                        _attempt = a['attemptId'];
                                      });
                                    }),
                            child: const Text('View business support audit'))
                      ]),
                  Wrap(spacing: 12, children: [
                    TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                await Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                        builder: (_) => SupportTicketsScreen(
                                            service: _service!)));
                                if (mounted) {
                                  setState(() {
                                    if (!_service!.signedIn) {
                                      _clearSessionData();
                                    }
                                  });
                                }
                              },
                        child: const Text('Subscription support inbox')),
                    TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                await Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                        builder: (_) => GovernedAccessScreen(
                                            service: _service!)));
                                if (mounted) {
                                  setState(() {
                                    if (!_service!.signedIn) {
                                      _clearSessionData();
                                    }
                                  });
                                }
                              },
                        child: const Text('Governed financial access'))
                  ]),
                  Text('Selected business: ${_selectedBusiness ?? 'none'}'),
                  TextField(
                      controller: _case,
                      maxLength: 80,
                      decoration: const InputDecoration(
                          labelText:
                              'Support case reference (optional, identifiers only)')),
                  if (_attempt != null)
                    SelectableText('Audit attempt: $_attempt'),
                  if (_audit != null)
                    ..._audit!.map((a) => Card(
                        child: ListTile(
                            title: Text(
                                '${a['action']} · ${a['decision']} · ${a['outcome']}'),
                            subtitle: Text(
                                'Employee ${a['employeeId'] ?? 'unverified'} · ${a['createdAt']} · ${a['attemptId']}'))))
                  else if (_detail != null) ...[
                    _purchase(_detail!, detail: true),
                    TextButton(
                        onPressed: _busy ? null : () => _load(),
                        child: const Text('Back to business history'))
                  ] else ...[
                    if (!_busy && _selectedBusiness != null && _items.isEmpty)
                      const Text(
                          'No purchases in the configured provider environment.'),
                    ..._items.map((r) => _purchase(r)),
                    if (_cursor != null)
                      TextButton(
                          onPressed: _busy ? null : () => _load(more: true),
                          child: const Text('Load more'))
                  ]
                ]
              ]))));
}
