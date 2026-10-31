import 'package:flutter/material.dart';

import '../api_client.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.client.get('/api/llm/plans?pending=1');
      final plans = (data['plans'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      setState(() => _plans = plans);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
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
            const EmptyBox('暂无模型过关方案。点上方按钮生成（需先配置 llm_providers）。')
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
              p.legs
                  .map(
                    (l) =>
                        '${l.homeTeam}vs${l.awayTeam} ${legPickLabel(l.market, l.pick, l.label)}',
                  )
                  .join(' / '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted, fontSize: 11),
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
          ],
        ),
      ),
    );
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
