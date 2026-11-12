import 'package:flutter/material.dart';
import '../../core/auth/financial_support_service.dart';

class GovernedAccessScreen extends StatefulWidget {
  final FinancialSupportService service;
  const GovernedAccessScreen({super.key, required this.service});
  @override
  State<GovernedAccessScreen> createState() => _GovernedAccessScreenState();
}

class _GovernedAccessScreenState extends State<GovernedAccessScreen> {
  final _business = TextEditingController(),
      _target = TextEditingController(),
      _hours = TextEditingController(text: '8'),
      _reason = TextEditingController();
  String _kind = 'requests', _permission = 'subscription.payment.read';
  String? _error, _cursor, _result;
  List<dynamic> _items = [];
  int? _selected;
  int? _targetEpoch;
  bool _busy = false;
  Map<String, dynamic>? _pending;
  String? _pendingKind;
  final _permissions = const [
    'subscription.payment.read',
    'subscription.payment.reconcile',
    'subscription.support.audit.read',
    'subscription.support.ticket.read',
    'subscription.support.ticket.respond',
    'subscription.support.ticket.assign',
    'subscription.support.ticket.manage'
  ];
  @override
  void dispose() {
    _business.dispose();
    _target.dispose();
    _hours.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _clear() {
    _items = [];
    _cursor = null;
    _targetEpoch = null;
    _pending = null;
    _pendingKind = null;
    _result = null;
    _target.clear();
    _reason.clear();
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is FinancialSupportFailure &&
                  e.code == 'COMPANY_PERMISSION_REQUIRED'
              ? 'Governance permission denied. No financial privilege is implied.'
              : 'Governance unavailable or command uncertain. Retry the displayed original command; never insert a grant manually.';
          if (!widget.service.signedIn ||
              e is FinancialSupportFailure &&
                  e.code == 'COMPANY_PERMISSION_REQUIRED') {
            _clear();
            _selected = null;
            _business.clear();
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load({bool more = false}) => _run(() async {
        final id = more ? _selected : int.tryParse(_business.text);
        if (id == null || id < 1) {
          throw const FinancialSupportFailure('INVALID_BUSINESS');
        }
        if (_selected != null && _selected != id) {
          _clear();
        }
        _selected = id;
        final target = _kind == 'grants' ? int.tryParse(_target.text) : null;
        final r = await widget.service.accessView(_kind, id,
            target: target, cursor: more ? _cursor : null);
        if (mounted) {
          setState(() {
            _items = [if (more) ..._items, ...r['items'] ?? []];
            _cursor = r['nextCursor'];
            _targetEpoch = r['target']?['revision'];
          });
        }
      });
  Future<void> _send(String kind, Map<String, dynamic> body) => _run(() async {
        if (_pending != null && _pendingKind != kind) {
          throw const FinancialSupportFailure('PENDING_ORIGINAL_COMMAND');
        }
        _pending ??= body;
        _pendingKind ??= kind;
        final r = await widget.service.accessMutation(_pendingKind!, _pending!);
        if (mounted) {
          setState(() {
            _result =
                '${r['status']} · ${r['requestId'] ?? r['grantId'] ?? r['commandId']}';
            _pending = null;
            _pendingKind = null;
          });
        }
      });
  Future<void> _request() async {
    if (_selected == null ||
        _targetEpoch == null ||
        int.tryParse(_target.text) == null) {
      setState(() => _error =
          'Inspect grants for the target employee first to obtain the current server epoch.');
      return;
    }
    final hours = int.tryParse(_hours.text);
    if (hours == null || hours < 1 || hours > 720) {
      setState(() => _error =
          'Choose a bounded grant duration, subject to server approval.');
      return;
    }
    final now = DateTime.now().toUtc();
    await _send('requests', {
      'commandId': widget.service.commandId(),
      'scopeKey': 'BUSINESS:$_selected',
      'intendedCommandId': widget.service.commandId(),
      'targetEmployeeId': int.parse(_target.text),
      'targetEpoch': _targetEpoch,
      'permission': _permission,
      'startsAt': now.toIso8601String(),
      'endsAt': now.add(Duration(hours: hours)).toIso8601String(),
      'approvalExpiresAt':
          now.add(const Duration(minutes: 10)).toIso8601String(),
      'reason': _reason.text
    });
  }

  Future<void> _review(Map row, String decision) async {
    final approved = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text('$decision scoped access?'),
                content: Text(
                    'Business $_selected\nEmployee ${row['targetEmployeeId']}\n${row['permission']}\n${row['startsAt']} to ${row['endsAt']}\n${row['reason']}\nIndependent review is required.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Confirm reviewed request'))
                ]));
    if (approved == true) {
      await _send('decisions', {
        'commandId': widget.service.commandId(),
        'scopeKey': 'BUSINESS:$_selected',
        'requestId': row['id'],
        'expectedPayloadHash': row['payloadHash'],
        'expectedTargetEpoch': row['targetEpoch'],
        'decision': decision,
        'reason': _reason.text
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar:
          AppBar(title: const Text('Governed financial and support access')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: ListView(padding: const EdgeInsets.all(24), children: [
                const Text(
                    'No automatic grants. Current access.request / access.review / access.execute / access.revoke authority is required for the exact business. Reviewer must be independent of requester and target.'),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(_error!, key: const Key('governance-error')),
                if (_result != null) SelectableText(_result!),
                TextField(
                    controller: _business,
                    decoration:
                        const InputDecoration(labelText: 'Business ID')),
                TextField(
                    controller: _target,
                    decoration:
                        const InputDecoration(labelText: 'Target employee ID')),
                DropdownButtonFormField<String>(
                    initialValue: _kind,
                    items: const ['requests', 'grants', 'audit']
                        .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                              _kind = v!;
                              _items = [];
                              _cursor = null;
                            })),
                FilledButton(
                    onPressed: _busy ? null : () => _load(),
                    child: const Text('Inspect scoped access')),
                if (_selected != null) ...[
                  Text('Selected business: $_selected'),
                  DropdownButtonFormField<String>(
                      initialValue: _permission,
                      items: _permissions
                          .map(
                              (p) => DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _permission = v!)),
                  TextField(
                      controller: _hours,
                      decoration: const InputDecoration(
                          labelText: 'Requested hours (server limits apply)')),
                  TextField(
                      controller: _reason,
                      maxLength: 500,
                      decoration:
                          const InputDecoration(labelText: 'Review reason')),
                  FilledButton(
                      onPressed: _busy ? null : _request,
                      child: const Text('Request reviewed access')),
                  if (_pending != null)
                    OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _send(_pendingKind!, _pending!),
                        child: const Text(
                            'Retry original uncertain governance command')),
                  ..._items.map((r) => Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                    '${r['permission'] ?? r['action']} · ${r['id']}'),
                                Text(
                                    'Employee ${r['targetEmployeeId'] ?? r['employeeId']} · ${r['decision'] ?? r['revokedAt'] ?? 'current record'}'),
                                if (_kind == 'requests') ...[
                                  Text('${r['startsAt']} to ${r['endsAt']}'),
                                  Text('${r['reason']}'),
                                  Wrap(spacing: 8, children: [
                                    TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _review(r, 'APPROVED'),
                                        child: const Text(
                                            'Approve independently')),
                                    TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _review(r, 'REJECTED'),
                                        child: const Text('Reject')),
                                    TextButton(
                                        onPressed: _busy ||
                                                r['decision']?['decision'] !=
                                                    'APPROVED' ||
                                                r['grantId'] != null
                                            ? null
                                            : () => _send('issuances', {
                                                  'commandId':
                                                      r['intendedCommandId'],
                                                  'scopeKey':
                                                      'BUSINESS:$_selected',
                                                  'requestId': r['id'],
                                                  'expectedPayloadHash':
                                                      r['payloadHash'],
                                                  'expectedTargetEpoch':
                                                      r['targetEpoch']
                                                }),
                                        child:
                                            const Text('Issue approved grant'))
                                  ])
                                ],
                                if (_kind == 'grants' && r['revokedAt'] == null)
                                  TextButton(
                                      onPressed: _busy || _targetEpoch == null
                                          ? null
                                          : () => _send('revocations', {
                                                'commandId':
                                                    widget.service.commandId(),
                                                'scopeKey':
                                                    'BUSINESS:$_selected',
                                                'grantId': r['id'],
                                                'expectedTargetEpoch':
                                                    _targetEpoch,
                                                'reason': _reason.text
                                              }),
                                      child: const Text('Revoke scoped grant'))
                              ])))),
                  if (_cursor != null)
                    TextButton(
                        onPressed: _busy ? null : () => _load(more: true),
                        child: const Text('Load more access records'))
                ]
              ]))));
}
