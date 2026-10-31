import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../models.dart';
import '../widgets.dart';
import 'plan_detail_page.dart';

/// 模型推荐 tab: each LLM's 过关方案 for matches that have not kicked off —
/// mixed parlays, 胜负平, 比分 and 冷门高赔. The old per-market prediction list
/// lives on the match detail page instead.
class LlmPage extends StatefulWidget {
  const LlmPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<LlmPage> createState() => _LlmPageState();
}

class _LlmPageState extends State<LlmPage> {
  static const Map<String, String> _kindLabels = {
    'mixed': '混合过关',
    'wdw': '胜负平',
    'handicap': '让球',
    'total_goals': '总进球',
    'correct_score': '比分',
    'high_odds': '冷门高赔',
    'single': '单关',
  };

  static const Map<String, int> _kindOrder = {
    'mixed': 0,
    'wdw': 1,
    'handicap': 2,
    'total_goals': 3,
    'correct_score': 4,
    'high_odds': 5,
    'single': 6,
  };

  bool _loading = true;
  String? _error;
  List<Plan> _plans = [];
  bool _predicting = false;
  bool _generating = false;
  bool _pollScheduled = false;
  int _pollAttempts = 0;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
      _pollAttempts = 0;
    }
    try {
      final data = await widget.client.get('/api/llm/plans?pending=1');
      final plans = (data['plans'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final generating = data['generating'] == true;
      setState(() {
        _plans = plans;
        _generating = generating;
      });
      // The server generates today's plans in the background on first open;
      // poll a few times so the tab fills itself instead of needing a pull.
      if (plans.isEmpty && generating) _schedulePoll();
    } catch (e) {
      if (!silent) setState(() => _error = e.toString());
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
    }
  }

  void _schedulePoll() {
    if (_pollScheduled || _pollAttempts >= 20) return;
    _pollScheduled = true;
    _pollAttempts++;
    Timer(const Duration(seconds: 15), () {
      _pollScheduled = false;
      if (mounted && _plans.isEmpty) _load(silent: true);
    });
  }

  Future<void> _triggerPredict() async {
    setState(() => _predicting = true);
    try {
      final data = await widget.client.post('/api/predict/llm');
      final runs = (data['runs'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final msg = runs
          .map(
            (r) =>
                '${r['model']}: ${r['ok'] == true ? '成功(${r['predictions_n']}预测/${r['plans_n']}方案)' : '失败(${r['error']})'}',
          )
          .join('\n');
      if (mounted) _toast('预测完成\n$msg');
    } catch (e) {
      if (mounted) _toast('触发失败：$e');
    } finally {
      if (mounted) {
        setState(() => _predicting = false);
        await _load();
      }
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg, maxLines: 10)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败：$_error'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final byModel = <String, List<Plan>>{};
    for (final p in _plans) {
      byModel.putIfAbsent(p.model.isEmpty ? '未知模型' : p.model, () => []).add(p);
    }
    for (final plans in byModel.values) {
      plans.sort(
        (a, b) =>
            (_kindOrder[a.kind] ?? 99).compareTo(_kindOrder[b.kind] ?? 99),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          FilledButton.icon(
            onPressed: _predicting ? null : _triggerPredict,
            icon: _predicting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_predicting ? '预测中…' : '生成模型预测'),
          ),
          const SizedBox(height: 10),
          const Text(
            '各大模型对未开赛比赛的过关方案：混合、胜负平、比分，以及冷门高赔博冷。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (byModel.isEmpty)
            EmptyBox(_generating
                ? '模型方案生成中…（通常 1–2 分钟，完成后本页会自动刷新）'
                : '暂无模型过关方案。点上方按钮生成（需先配置 llm_providers）。')
          else
            ...byModel.entries.map((e) => _modelSection(e.key, e.value)),
        ],
      ),
    );
  }

  Widget _modelSection(String model, List<Plan> plans) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smart_toy, color: green, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    model,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${plans.length} 个方案',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < plans.length; i++) ...[
              if (i > 0) const Divider(height: 16),
              _planTile(plans[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _planTile(Plan p) {
    final statusLabel = switch (p.status) {
      'won' => '已命中',
      'lost' => '未命中',
      _ => '待开奖',
    };
    final n = p.matchCount;
    final bets = p.payout.bets;
    final reasons = <(Leg, String)>[
      for (final l in p.legs)
        if (legReason(l.market, l.pick, l.label).isNotEmpty)
          (l, legReason(l.market, l.pick, l.label)),
    ];
    final expanded = _expanded.contains(p.id);
    return InkWell(
      onTap: () async {
        final changed = await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlanDetailPage(client: widget.client, plan: p),
          ),
        );
        if (changed == true) _load();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _kindChip(p.kind),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                VerdictBadge(statusLabel),
                const Icon(Icons.chevron_right, size: 18, color: muted),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              '${p.modeLabel} · $n 场${bets > 0 ? ' · $bets 注' : ''}',
              style: const TextStyle(color: muted, fontSize: 11),
            ),
            const SizedBox(height: 2),
            Text(
              p.legs.map(_legLine).join(' / '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF3A4643),
                fontSize: 11,
                height: 1.5,
              ),
            ),
            if (p.payout.potential != null && p.payout.potential! > 0)
              Text(
                '最多中奖 ${p.payout.potential!.toStringAsFixed(2)} 元',
                style: const TextStyle(
                  color: gold,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: 2),
            Row(
              children: [
                if (reasons.isNotEmpty)
                  TextButton.icon(
                    style: _tileButtonStyle,
                    onPressed: () => setState(() {
                      if (expanded) {
                        _expanded.remove(p.id);
                      } else {
                        _expanded.add(p.id);
                      }
                    }),
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                    ),
                    label: Text(expanded ? '收起说明' : '说明（${reasons.length}）'),
                  ),
                const Spacer(),
                TextButton.icon(
                  style: _tileButtonStyle,
                  onPressed: () => _addToPlan(p),
                  icon: const Icon(Icons.add_circle_outline, size: 16),
                  label: const Text('加入方案'),
                ),
              ],
            ),
            if (expanded && reasons.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F6EF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (leg, reason) in reasons)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          '${_legLine(leg)}：$reason',
                          softWrap: true,
                          style: const TextStyle(
                            color: Color(0xFF3A4643),
                            fontSize: 12,
                            height: 1.55,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static final ButtonStyle _tileButtonStyle = TextButton.styleFrom(
    minimumSize: Size.zero,
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(fontSize: 12),
  );

  /// 一行推荐结果：场次号 + 对阵 + 选项 + 赔率。
  String _legLine(Leg l) {
    final num = l.matchNum.isEmpty ? '' : '${l.matchNum} ';
    final odds = l.odds.isEmpty ? '' : ' @${l.odds}';
    return '$num${l.homeTeam}vs${l.awayTeam} '
        '${selectionLabel(l.market, l.pick, l.line)}$odds';
  }

  Future<void> _addToPlan(Plan p) async {
    if (p.legs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _AddPlanDialog(client: widget.client, plan: p),
    );
    if (ok == true && mounted) _toast('已加入我的方案');
  }

  Widget _kindChip(String kind) {
    final label = _kindLabels[kind] ?? '方案';
    final color = _kindColor(kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Color _kindColor(String kind) {
    return switch (kind) {
      'mixed' => green,
      'wdw' => gold,
      'correct_score' => orange,
      'high_odds' => red,
      'total_goals' => const Color(0xFF3A6EA5),
      _ => muted,
    };
  }
}

/// 把模型方案按可选倍数 / 过关方式复制进「我的方案」。
class _AddPlanDialog extends StatefulWidget {
  const _AddPlanDialog({required this.client, required this.plan});

  final ApiClient client;
  final Plan plan;

  @override
  State<_AddPlanDialog> createState() => _AddPlanDialogState();
}

class _AddPlanDialogState extends State<_AddPlanDialog> {
  late final List<LegGroup> _groups;
  late final Set<int> _units;
  late int _multiple;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _groups = groupLegs(widget.plan.legs);
    final n = _groups.length;
    _units = widget.plan.effectiveUnits.where((u) => u >= 1 && u <= n).toSet();
    if (_units.isEmpty && n > 0) _units.add(n);
    _multiple = widget.plan.multiple > 0 ? widget.plan.multiple : 1;
  }

  int get _n => _groups.length;

  List<int> get _sortedUnits => _units.toList()..sort();

  int get _bets =>
      _sortedUnits.fold(0, (sum, u) => sum + betsForGroups(_groups, u));

  String get _modeLabel => _sortedUnits
      .map((u) => u <= 1 ? '单关' : '$u串1')
      .join('+');

  Future<void> _save() async {
    final units = _sortedUnits;
    if (units.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.client.post('/api/plans', {
        'title': widget.plan.title,
        'play_type': units.length == 1 && units.first == 1
            ? 'single'
            : 'parlay',
        'unit': units.last,
        'units': units,
        'multiple': _multiple,
        'stake': 2,
        'legs': widget.plan.legs
            .map(
              (l) => {
                'match_id': l.matchId,
                'home_team': l.homeTeam,
                'away_team': l.awayTeam,
                'market': l.market,
                'pick': l.pick,
                'line': l.line ?? '',
                'odds': l.odds,
                'label': l.label,
              },
            )
            .toList(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加入失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _bets * 2 * _multiple;
    return AlertDialog(
      title: const Text('加入我的方案'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.plan.title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '$_n 场可选，按需调整过关方式和倍数',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              '过关方式（可多选）',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var m = 1; m <= _n; m++)
                  FilterChip(
                    label: Text(m <= 1 ? '单关' : '$m串1'),
                    selected: _units.contains(m),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _units.add(m);
                      } else if (_units.length > 1) {
                        _units.remove(m);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  '倍数',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  color: _multiple > 1 ? green : muted,
                  onPressed: _multiple > 1
                      ? () => setState(() => _multiple--)
                      : null,
                ),
                Text(
                  '$_multiple',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  color: green,
                  onPressed: () => setState(() => _multiple++),
                ),
              ],
            ),
            Text(
              '共 $_n 场 · $_modeLabel · $_bets 注',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            Text(
              '购买金额 ${total.toStringAsFixed(2)} 元',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving || _units.isEmpty ? null : _save,
          child: Text(_saving ? '加入中…' : '确认加入'),
        ),
      ],
    );
  }
}
