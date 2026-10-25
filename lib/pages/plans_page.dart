import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../models.dart';
import '../widgets.dart';
import 'draft_page.dart';
import 'plan_detail_page.dart';

class PlansPage extends StatefulWidget {
  const PlansPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  bool _loading = true;
  String? _error;
  List<Plan> _plans = [];
  Timer? _pollTimer;
  int _pollTicks = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.client.get('/api/plans');
      final plans = (data['plans'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _error = null;
      });
      _schedulePoll(data['syncing'] == true);
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e.toString());
      _schedulePoll(false);
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
    }
  }

  /// The server settles finished plans in a background thread; keep polling
  /// briefly so 待开奖 turns into 中奖/未中奖 without a manual refresh.
  void _schedulePoll(bool syncing) {
    _pollTimer?.cancel();
    if (!syncing) {
      _pollTicks = 0;
      return;
    }
    if (_pollTicks >= 12) return;
    _pollTicks++;
    _pollTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _load(silent: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('加载失败：$_error'))
          : RefreshIndicator(
              onRefresh: _load,
              child: _plans.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 200),
                        EmptyBox('还没有方案。点右下角「＋」新建。'),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: _plans.map(_planCard).toList(),
                    ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DraftPage(client: widget.client)),
          );
          _load();
        },
        icon: const Icon(Icons.receipt_long),
        label: const Text('新建方案'),
      ),
    );
  }

  Future<void> _deletePlan(Plan p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除方案'),
        content: Text('确定删除「${p.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.client.post('/api/plans/delete', {'id': p.id});
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  Widget _planCard(Plan p) {
    final statusLabel = switch (p.status) {
      'won' => p.isRenjiu ? '已中奖' : '已命中',
      'lost' => '未命中',
      _ => '待开奖',
    };
    final n = p.matchCount;
    final u = p.effectiveUnit;
    final groups = groupLegs(p.legs);
    final bets = p.payout.bets > 0
        ? p.payout.bets
        : (p.isRenjiu
              ? renjiuBets(groups.map((g) => g.legs.length).toList())
              : betsForGroups(groups, u));
    final mode = p.isRenjiu ? '任选9场' : (n <= 1 ? '单关' : '$u串1');
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: () async {
          final changed = await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlanDetailPage(client: widget.client, plan: p),
            ),
          );
          if (changed == true) _load();
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  VerdictBadge(statusLabel),
                  if (p.isLlm)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEF4F1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        p.model.isEmpty ? '模型' : p.model,
                        style: const TextStyle(color: green, fontSize: 12),
                      ),
                    ),
                  IconButton(
                    onPressed: () => _deletePlan(p),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: red,
                    ),
                    tooltip: '删除',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${p.createdAt} · $n 场 · $mode · 共 $bets 注'
                '${p.multiple > 1 ? ' · ${p.multiple} 倍' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 6),
              _payoutLine(p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _payoutLine(Plan p) {
    final po = p.payout;
    if (po.returnAmount != null) {
      return Text(
        '中奖 ${po.returnAmount!.toStringAsFixed(2)} 元'
        '（利润 ${po.profit!.toStringAsFixed(2)} 元）',
        style: const TextStyle(
          color: green,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      );
    }
    if (po.floating) {
      return const Text(
        '已中奖 · 任九浮动奖，奖金以官方开奖为准',
        style: TextStyle(
          color: green,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      );
    }
    if (po.potential != null) {
      return Text(
        '理论最多中奖 ${po.potential!.toStringAsFixed(2)} 元'
        '${po.totalCost != null && po.totalCost! > 0 ? ' · 购买金额 ${po.totalCost!.toStringAsFixed(2)} 元' : ''}',
        style: const TextStyle(
          color: gold,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      );
    }
    if (po.reason.isNotEmpty) {
      return Text(
        po.reason,
        style: const TextStyle(color: muted, fontSize: 12),
      );
    }
    return const SizedBox.shrink();
  }
}
