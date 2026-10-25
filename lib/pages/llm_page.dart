import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets.dart';
import 'plan_detail_page.dart';

class LlmPage extends StatefulWidget {
  const LlmPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<LlmPage> createState() => _LlmPageState();
}

class _LlmPageState extends State<LlmPage> {
  bool _loading = true;
  String? _error;
  List<LlmPrediction> _predictions = [];
  List<Plan> _plans = [];
  Map<String, String> _matchNames = {};
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
      final results = await Future.wait([
        widget.client.get('/api/llm/predictions'),
        widget.client.get('/api/llm/plans'),
        widget.client.get('/api/dashboard'),
      ]);
      final preds = (results[0]['predictions'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => LlmPrediction.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final plans = (results[1]['plans'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final names = <String, String>{};
      for (final m in (results[2]['predictions'] as List? ?? const [])
          .whereType<Map>()) {
        final j = Map<String, dynamic>.from(m);
        names[j['match_id']?.toString() ?? ''] =
            '${j['home_team']} vs ${j['away_team']}';
      }
      setState(() {
        _predictions = preds;
        _plans = plans;
        _matchNames = names;
      });
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
      final runs = (data['runs'] as List? ?? const []).whereType<Map>().toList();
      final msg = runs
          .map((r) =>
              '${r['model']}: ${r['ok'] == true ? '成功(${r['predictions_n']}预测/${r['plans_n']}方案)' : '失败(${r['error']})'}')
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg, maxLines: 10)));
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

    final byModel = <String, List<LlmPrediction>>{};
    for (final p in _predictions) {
      byModel.putIfAbsent(p.model, () => []).add(p);
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
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_predicting ? '预测中…' : '生成模型预测'),
          ),
          const SizedBox(height: 16),
          const Text('各模型预测', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (byModel.isEmpty)
            const EmptyBox('暂无模型预测。点上方按钮生成（需先配置 llm_providers）。')
          else
            ...byModel.entries.map((e) => _modelSection(e.key, e.value)),
          const SizedBox(height: 16),
          const Text('模型过关方案', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_plans.isEmpty)
            const EmptyBox('暂无模型过关方案。')
          else
            ..._plans.map(_llmPlanCard),
        ],
      ),
    );
  }

  Widget _modelSection(String model, List<LlmPrediction> preds) {
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
                Text(model, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            ...preds.map(_predRow),
          ],
        ),
      ),
    );
  }

  Widget _predRow(LlmPrediction p) {
    final names = _matchNames[p.matchId] ?? p.matchId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(names,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            width: 88,
            child: Text(
              '${marketLabel[p.market] ?? p.market} '
              '${legPickLabel(p.market, p.pick, '')}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              p.prob == null ? '' : pct(p.prob!),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          VerdictBadge(p.result),
        ],
      ),
    );
  }

  Widget _llmPlanCard(Plan p) {
    final statusLabel = switch (p.status) {
      'won' => '已命中',
      'lost' => '未命中',
      _ => '待开奖',
    };
    final n = p.matchCount;
    final bets = p.payout.bets;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final changed = await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  PlanDetailPage(client: widget.client, plan: p)));
          if (changed == true) _load();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(p.title,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  VerdictBadge(statusLabel),
                  const Icon(Icons.chevron_right, size: 18, color: muted),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${p.model} · ${n <= 1 ? '单关' : '${p.effectiveUnit}串1'} · '
                '$n 场${bets > 0 ? ' · $bets 注' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                p.legs
                    .map((l) =>
                        '${l.homeTeam}vs${l.awayTeam} ${legPickLabel(l.market, l.pick, l.label)}')
                    .join(' / '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              if (p.payout.returnAmount != null)
                Text('中奖 ${p.payout.returnAmount!.toStringAsFixed(2)} 元',
                    style: const TextStyle(
                        color: green, fontWeight: FontWeight.w700))
              else if (p.payout.potential != null && p.payout.potential! > 0)
                Text('最多中奖 ${p.payout.potential!.toStringAsFixed(2)} 元',
                    style: const TextStyle(
                        color: gold, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
