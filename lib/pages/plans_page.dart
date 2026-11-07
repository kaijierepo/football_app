import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../models.dart';
import '../widgets.dart';
import 'draft_page.dart';
import 'import_plan_page.dart';
import 'plan_detail_page.dart';

class PlansPage extends StatefulWidget {
  const PlansPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  static const List<String> _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  bool _loading = true;
  String? _error;
  List<Plan> _plans = [];
  DateTime _selectedDay = DateUtils.dateOnly(DateTime.now());
  Timer? _pollTimer;
  int _pollTicks = 0;
  Timer? _importTimer;
  int _importTicks = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _importTimer?.cancel();
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

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 截图导入在服务端后台识别；这里轮询任务状态，完成后刷新方案列表。
  void _watchImport(String jobId) {
    _importTimer?.cancel();
    _importTicks = 0;

    Future<void> check() async {
      _importTicks++;
      String status = '';
      try {
        final data = await widget.client.get('/api/plans/import/$jobId');
        status = '${data['status'] ?? ''}';
        if (!mounted) return;
        if (status == 'done') {
          await _load(silent: true);
          _snack('截图方案已生成');
          return;
        }
        if (status == 'failed') {
          await _load(silent: true);
          _snack('截图识别失败：${data['error'] ?? '未知错误'}');
          return;
        }
      } catch (_) {
        // 网络抖动或服务重启：继续等下一次轮询。
      }
      if (!mounted) return;
      if (_importTicks >= 75) {
        await _load(silent: true);
        return;
      }
      _importTimer = Timer(const Duration(seconds: 4), check);
    }

    _importTimer = Timer(const Duration(seconds: 2), check);
  }

  @override
  Widget build(BuildContext context) {
    final dayPlans = _plansForDay(_selectedDay);
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('加载失败：$_error'))
          : RefreshIndicator(
              // Refresh without swapping in a full-screen spinner: the
              // RefreshIndicator must stay mounted for the pull gesture to
              // finish, and a short list cannot be pulled unless the physics
              // always allow overscroll.
              onRefresh: () => _load(silent: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  _daySelector(),
                  if (dayPlans.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 120),
                      child: EmptyBox('这天还没有方案'),
                    )
                  else ...[
                    _dayHeader(dayPlans),
                    ...dayPlans.map(_planCard),
                  ],
                ],
              ),
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'importPlan',
            tooltip: '截图导入',
            onPressed: () async {
              final jobId = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => ImportPlanPage(client: widget.client),
                ),
              );
              if (!mounted) return;
              if (jobId == null || jobId.isEmpty) {
                _load();
                return;
              }
              _snack('已提交后台识别，完成后自动生成方案');
              _watchImport(jobId);
            },
            child: const Icon(Icons.qr_code_scanner),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'newPlan',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DraftPage(client: widget.client),
                ),
              );
              _load();
            },
            icon: const Icon(Icons.receipt_long),
            label: const Text('新建方案'),
          ),
        ],
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

  static String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Plans are created on the day they are bought, so "today" is the natural
  /// default. Older days stay reachable through the arrows or the calendar.
  List<Plan> _plansForDay(DateTime day) {
    final key = _dayKey(day);
    return _plans
        .where(
          (p) => p.createdAt.length >= 10 && p.createdAt.substring(0, 10) == key,
        )
        .toList();
  }

  void _shiftDay(int delta) {
    final today = DateUtils.dateOnly(DateTime.now());
    final next = DateUtils.dateOnly(_selectedDay.add(Duration(days: delta)));
    if (next.isAfter(today)) return;
    setState(() => _selectedDay = next);
  }

  Future<void> _pickDay() async {
    final today = DateUtils.dateOnly(DateTime.now());
    var first = today.subtract(const Duration(days: 365));
    for (final p in _plans) {
      final day = p.createdAt.length >= 10
          ? DateTime.tryParse(p.createdAt.substring(0, 10))
          : null;
      if (day != null && day.isBefore(first)) first = DateUtils.dateOnly(day);
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay.isAfter(today) ? today : _selectedDay,
      firstDate: first,
      lastDate: today,
      helpText: '选择方案日期',
    );
    if (picked != null && mounted) {
      setState(() => _selectedDay = DateUtils.dateOnly(picked));
    }
  }

  /// 日期选择条：左右切换，中间点开日历，默认停在今天。
  Widget _daySelector() {
    final today = DateUtils.dateOnly(DateTime.now());
    final isToday = DateUtils.isSameDay(_selectedDay, today);
    return Row(
      children: [
        IconButton(
          tooltip: '前一天',
          onPressed: () => _shiftDay(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _pickDay,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${_dayKey(_selectedDay)} ${_weekdays[_selectedDay.weekday - 1]}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.calendar_month, size: 18, color: muted),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '后一天',
          onPressed: isToday ? null : () => _shiftDay(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  Widget _dayHeader(List<Plan> plans) {
    var net = 0.0;
    var settled = 0;
    for (final p in plans) {
      final profit = p.payout.profit;
      if (profit == null) continue;
      net += profit;
      settled++;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Row(
        children: [
          Text(
            '${plans.length} 个方案',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const Spacer(),
          if (settled > 0)
            Text(
              '${net >= 0 ? '+' : '-'}${net.abs().toStringAsFixed(2)} 元',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: net > 0
                    ? red
                    : net < 0
                    ? green
                    : muted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _planCard(Plan p) {
    final statusLabel = switch (p.status) {
      'won' => p.isRenjiu ? '已中奖' : '已命中',
      'lost' => '未命中',
      _ => '待开奖',
    };
    final n = p.matchCount;
    final units = p.effectiveUnits;
    final groups = groupLegs(p.legs);
    final bets = p.payout.bets > 0
        ? p.payout.bets
        : (p.isRenjiu
              ? renjiuBets(groups.map((g) => g.legs.length).toList())
              : units.fold<int>(0, (sum, u) => sum + betsForGroups(groups, u)));
    final mode = p.modeLabel;
    final matchNums = <String>[];
    for (final l in p.legs) {
      if (l.matchNum.isNotEmpty && !matchNums.contains(l.matchNum)) {
        matchNums.add(l.matchNum);
      }
    }
    return Card(
      key: ValueKey(p.id),
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
              if (matchNums.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    matchNums.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
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
