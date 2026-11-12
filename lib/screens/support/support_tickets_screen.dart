import 'financial_support_screen.dart';
import 'package:flutter/material.dart';
import '../../core/auth/financial_support_service.dart';

class SupportTicketsScreen extends StatefulWidget {
  final FinancialSupportService service;
  const SupportTicketsScreen({super.key, required this.service});
  @override
  State<SupportTicketsScreen> createState() => _SupportTicketsScreenState();
}

class _SupportTicketsScreenState extends State<SupportTicketsScreen> {
  final _business = TextEditingController(),
      _employee = TextEditingController(),
      _message = TextEditingController();
  int? _selected;
  bool _busy = false;
  String? _status, _cursor, _error;
  List<dynamic> _items = [], _events = [];
  Map<String, dynamic>? _view, _financial;
  Map<String, dynamic>? _pending;
  String? _pendingId;
  String _nextStatus = 'IN_PROGRESS';
  @override
  void dispose() {
    _business.dispose();
    _employee.dispose();
    _message.dispose();
    super.dispose();
  }

  void _clear() {
    _items = [];
    _events = [];
    _view = null;
    _financial = null;
    _cursor = null;
    _pending = null;
    _pendingId = null;
    _message.clear();
    _employee.clear();
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
                  ['COMPANY_PERMISSION_REQUIRED', 'SUPPORT_ASSIGNMENT_REQUIRED']
                      .contains(e.code)
              ? 'Current scoped ticket permission and eligible assignment are required. Ticket access does not grant financial authority.'
              : 'Support operation unavailable or uncertain. Preserve and retry the original command; refresh stale revisions.';
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
        final p = await widget.service
            .tickets(id, status: _status, cursor: more ? _cursor : null);
        if (mounted) {
          setState(() {
            _items = [if (more) ..._items, ...p['items']];
            _cursor = p['nextCursor'];
            _view = null;
            _financial = null;
          });
        }
      });
  Future<void> _open(String id, {bool more = false}) => _run(() async {
        final r = await widget.service.ticket(_selected!, id,
            after: more ? (_view?['nextAfter'] as int?) : null);
        if (mounted) {
          setState(() {
            _view = r;
            _events = [if (more) ..._events, ...r['events']];
            _financial = null;
          });
        }
      });
  Future<void> _action(String action) => _run(() async {
        final ticket = _view!['ticket'];
        if (_pendingId != null && _pendingId != ticket['id']) {
          throw const FinancialSupportFailure('PENDING_ORIGINAL_COMMAND');
        }
        _pending ??= {
          'commandId': widget.service.commandId(),
          'action': action,
          'expectedRevision': ticket['revision'],
          if (action == 'ASSIGNED') 'employeeId': int.tryParse(_employee.text),
          if (action == 'STATUS') 'status': _nextStatus,
          if (action == 'REPLY' || action == 'NOTE') 'text': _message.text
        };
        _pendingId = ticket['id'];
        await widget.service.ticketAction(_selected!, _pendingId!, _pending!);
        _pending = null;
        _pendingId = null;
        final v = await widget.service.ticket(_selected!, ticket['id']);
        if (mounted) {
          setState(() {
            _view = v;
            _events = v['events'];
            _message.clear();
            _financial = null;
          });
        }
      });
  Future<void> _investigate({bool reconcile = false}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FinancialSupportScreen(
            service: widget.service,
            ticketBusinessId: _selected,
            ticketId: _view!['ticket']['id'])));
    if (mounted && !widget.service.signedIn) {
      setState(() {
        _clear();
        _selected = null;
        _business.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Subscription support inbox')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: ListView(padding: const EdgeInsets.all(24), children: [
                const Text(
                    'Exact business authority is required. Internal notes are never customer replies. Resolving a ticket never marks a payment captured or activates a subscription.'),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(_error!, key: const Key('support-inbox-error')),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  SizedBox(
                      width: 220,
                      child: TextField(
                          controller: _business,
                          decoration: const InputDecoration(
                              labelText: 'Authorized business ID'))),
                  FilledButton(
                      onPressed: _busy ? null : () => _load(),
                      child: const Text('Open business inbox'))
                ]),
                DropdownButtonFormField<String>(
                    initialValue: _status,
                    items: [
                      const DropdownMenuItem<String>(
                          value: null, child: Text('All statuses')),
                      ...const [
                        'OPEN',
                        'IN_PROGRESS',
                        'WAITING_FOR_CUSTOMER',
                        'RESOLVED',
                        'CLOSED'
                      ].map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    ],
                    onChanged:
                        _busy ? null : (v) => setState(() => _status = v)),
                Text('Selected business: ${_selected ?? 'none'}'),
                if (_view == null) ...[
                  if (!_busy &&
                      _selected != null &&
                      _items.isEmpty &&
                      _error == null)
                    const Text('No authorized tickets match this filter.'),
                  ..._items.map((t) => Card(
                      child: ListTile(
                          title: Text('${t['reference']} · ${t['subject']}'),
                          subtitle: Text(t['status']),
                          onTap: _busy ? null : () => _open(t['id'])))),
                  if (_cursor != null)
                    TextButton(
                        onPressed: _busy ? null : () => _load(more: true),
                        child: const Text('Load more tickets'))
                ] else ...[
                  Text(
                      '${_view!['ticket']['reference']} · ${_view!['ticket']['status']}',
                      style: Theme.of(context).textTheme.titleLarge),
                  Text(_view!['ticket']['subject']),
                  Text(_view!['ticket']['description']),
                  Text(
                      'Assigned employee: ${_view!['ticket']['assignedEmployeeId'] ?? 'unassigned'}'),
                  ..._events.map((e) => Card(
                      child: ListTile(
                          title: Text(
                              '${e['visible'] ? 'Customer-visible' : 'INTERNAL'} · ${e['kind']}'),
                          subtitle: Text(
                              '${e['text'] ?? e['detail']} · ${e['createdAt']}')))),
                  if (_view!['nextAfter'] != null)
                    TextButton(
                        onPressed: _busy
                            ? null
                            : () => _open(_view!['ticket']['id'], more: true),
                        child: const Text('Load next activity page')),
                  TextField(
                      controller: _employee,
                      decoration: const InputDecoration(
                          labelText: 'Eligible company employee ID')),
                  TextButton(
                      onPressed: _busy ? null : () => _action('ASSIGNED'),
                      child: const Text('Assign verified eligible employee')),
                  TextField(
                      controller: _message,
                      maxLength: 4000,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText:
                              'Reply or internal note (no credentials)')),
                  Wrap(spacing: 12, children: [
                    FilledButton(
                        onPressed: _busy ? null : () => _action('REPLY'),
                        child: const Text('Send customer-visible reply')),
                    OutlinedButton(
                        onPressed: _busy ? null : () => _action('NOTE'),
                        child: const Text('Append internal note'))
                  ]),
                  DropdownButtonFormField<String>(
                      initialValue: _nextStatus,
                      items: const [
                        'IN_PROGRESS',
                        'WAITING_FOR_CUSTOMER',
                        'RESOLVED',
                        'CLOSED'
                      ]
                          .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)))
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _nextStatus = v!)),
                  TextButton(
                      onPressed: _busy ? null : () => _action('STATUS'),
                      child: const Text('Apply controlled status transition')),
                  if (_pending != null)
                    TextButton(
                        onPressed:
                            _busy ? null : () => _action(_pending!['action']),
                        child: const Text(
                            'Retry original uncertain ticket command')),
                  if (_view!['ticket']['intentId'] != null)
                    OutlinedButton(
                        onPressed: _busy ? null : () => _investigate(),
                        child: const Text(
                            'Investigate original payment through Q13')),
                  if (_financial != null) ...[
                    Text('Q13 capture: ${_financial!['paymentStatus']}'),
                    Text('Q13 activation: ${_financial!['activationStatus']}'),
                    Text('Q13 state: ${_financial!['state']}'),
                    SelectableText(
                        'Financial audit: ${_financial!['attemptId']}'),
                    if (_financial!['canReconcile'] == true)
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (c) => AlertDialog(
                                              title: const Text(
                                                  'Check original payment only?'),
                                              content: const Text(
                                                  'Q13 independently checks financial permission and preserves uncertain outcomes. No replacement order or manual grant is available.'),
                                              actions: [
                                                TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(c, false),
                                                    child:
                                                        const Text('Cancel')),
                                                FilledButton(
                                                    onPressed: () =>
                                                        Navigator.pop(c, true),
                                                    child: const Text(
                                                        'Confirm original reconciliation'))
                                              ]));
                                  if (ok == true && mounted) {
                                    await _investigate(reconcile: true);
                                  }
                                },
                          child: const Text(
                              'Reconcile original payment through Q13'))
                  ]
                ]
              ]))));
}
