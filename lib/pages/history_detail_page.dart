import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets.dart';

/// History match detail: grade the stored pre-match predictions (Poisson
/// snapshot + every AI model's picks) against the final score.
class HistoryDetailPage extends StatefulWidget {
  const HistoryDetailPage(
      {super.key, required this.client, required this.match});

  final ApiClient client;
  final Match match;

  @override
  State<HistoryDetailPage> createState() => _HistoryDetailPageState();
}

class _HistoryDetailPageState extends State<HistoryDetailPage> {
  static const _marketOrder = [
    'wdw', 'handicap', 'total_goals', 'correct_score', 'over_under',
  ];

  bool _loading = true;
  String? _error;
  List<LlmPrediction> _predictions = [];
  ModelVerdicts? _verdicts;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _verdicts = widget.match.verdicts;
    _finished = widget.match.finished;
    _load();
  }

  Future<void> _load() async {
    try {
      final matchId = Uri.encodeComponent(widget.match.matchId);
      final data = await widget.client.get('/api/matches/$matchId/models');
      if (!mounted) return;
      setState(() {
        _predictions = (data['predictions'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => LlmPrediction.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _verdicts = ModelVerdicts.parse(data['verdicts']) ?? _verdicts;
        _finished = data['finished'] == true || _finished;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.match;
    return Scaffold(
      appBar: AppBar(
        title: Text('${m.homeTeam} vs ${m.awayTeam}'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _header(m),
            const SizedBox(height: 20),
            _sectionTitle('泊松模型 · 赛前预测核对', Icons.insights, gold),
            const SizedBox(height: 8),
            ..._poissonVerdicts(),
            const SizedBox(height: 20),
            _sectionTitle('AI 模型预测核对', Icons.smart_toy, green),
            const SizedBox(height: 8),
            ..._llmPredictionSections(),
          ],
        ),
      ),
    );
  }

  Widget _header(Match m) {
    final finished = m.finished || _finished;
    final score = (m.homeGoals != null && m.awayGoals != null)
        ? '${m.homeGoals} - ${m.awayGoals}'
        : null;
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Text(
              [m.matchNum, m.league].where((s) => s.isNotEmpty).join(' · '),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(m.homeTeam,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    finished && score != null ? score : 'VS',
                    style: TextStyle(
                      fontSize: finished ? 22 : 16,
                      fontWeight: FontWeight.w800,
                      color: finished ? green : muted,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(m.awayTeam,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              [m.matchDate, m.matchTime].where((s) => s.isNotEmpty).join(' '),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _poissonVerdicts() {
    if (!_finished) {
      return const [EmptyBox('比赛尚未结束，开赛后可在历史记录核对赛前预测。')];
    }
    final v = _verdicts;
    if (v == null) {
      return const [EmptyBox('该场没有赛前泊松快照（官方接口只保留在售赛事，无法补算）。')];
    }
    final rows = <Widget>[];
    if (v.outcome != null) {
      rows.add(_verdictRow('胜平负', _outcomeLabel(v.outcome!.pick),
          v.outcome!.prob, v.outcome!.hit));
    }
    if (v.overUnder != null) {
      rows.add(_verdictRow(
          '大小球 2.5',
          v.overUnder!.pick == 'over' ? '大 2.5 球' : '小 2.5 球',
          v.overUnder!.prob,
          v.overUnder!.hit));
    }
    if (v.btts != null) {
      rows.add(_verdictRow('双方进球',
          v.btts!.pick == 'yes' ? '是' : '否', v.btts!.prob, v.btts!.hit));
    }
    final top = v.scoreTop;
    if (top != null) {
      final badge = top.hit
          ? const VerdictBadge('hit')
          : (top.inTop3 ? const VerdictBadge('前3') : const VerdictBadge('miss'));
      rows.add(_verdictRow('热门比分', '比分 ${top.pick}', top.prob, null,
          badge: badge));
      if (top.top3.isNotEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text('模型前 3 比分：${top.top3.join(' / ')}',
              style: const TextStyle(color: muted, fontSize: 12)),
        ));
      }
    }
    if (v.homeXg != null && v.awayXg != null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(left: 4, top: 2),
        child: Text(
          '预期进球：主 ${v.homeXg!.toStringAsFixed(2)} · 客 ${v.awayXg!.toStringAsFixed(2)}',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
      ));
    }
    return [Card(color: Colors.white, child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: rows),
    ))];
  }

  Widget _verdictRow(String label, String pick, double prob, bool? hit,
      {Widget? badge}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(label,
                style: const TextStyle(color: muted, fontSize: 13)),
          ),
          Expanded(
            child: Text(pick,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Text(pct(prob), style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 10),
          badge ??
              VerdictBadge(
                  hit == null ? 'pending' : (hit ? 'hit' : 'miss')),
        ],
      ),
    );
  }

  List<Widget> _llmPredictionSections() {
    if (_loading && _predictions.isEmpty) {
      return const [EmptyBox('AI 模型预测加载中…')];
    }
    if (_error != null && _predictions.isEmpty) {
      return [EmptyBox('AI 模型预测加载失败：$_error')];
    }
    if (_predictions.isEmpty) {
      return const [EmptyBox('该场没有保存的 AI 模型预测。')];
    }
    final byModel = <String, List<LlmPrediction>>{};
    for (final p in _predictions) {
      byModel
          .putIfAbsent(p.model.isEmpty ? '未知模型' : p.model, () => [])
          .add(p);
    }
    return byModel.entries.map((e) {
      final rows = [...e.value]
        ..sort((a, b) => _marketOrder
            .indexOf(a.market)
            .compareTo(_marketOrder.indexOf(b.market)));
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.smart_toy, color: green, size: 18),
                const SizedBox(width: 8),
                Text(e.key,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 8),
              ...rows.map(_predictionRow),
            ],
          ),
        ),
      );
    }).toList();
  }

  Widget _predictionRow(LlmPrediction p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        MarketTag(p.market),
        const SizedBox(width: 8),
        Expanded(
          child: Text(legPickLabel(p.market, p.pick, ''),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        if (p.prob != null)
          Text(pct(p.prob!), style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 10),
        VerdictBadge(p.result),
      ]),
    );
  }

  Widget _sectionTitle(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title,
            style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ],
    );
  }

  String _outcomeLabel(String pick) =>
      {'home': '主胜', 'draw': '平局', 'away': '客胜'}[pick] ?? pick;
}
