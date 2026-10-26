import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../draft.dart';
import '../models.dart';
import '../widgets.dart';
import 'match_info_page.dart';

class PredictPage extends StatefulWidget {
  const PredictPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<PredictPage> createState() => _PredictPageState();
}

class _PredictPageState extends State<PredictPage> {
  static const _pageSize = 10;

  bool _loading = true;
  String? _error;
  List<Match> _matches = [];
  int _visibleCount = _pageSize;

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
      final data = await widget.client.get('/api/matches/today');
      // 展示所有可投注且未开赛的比赛（含今天的后续场次与明天的场次）。
      final upcoming = (data['predictions'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Match.fromJson(Map<String, dynamic>.from(e)))
          .where((m) => !m.finished && !m.started)
          .toList();
      setState(() {
        _matches = upcoming;
        _visibleCount = _pageSize;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }
    final visible = _matches.take(_visibleCount).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_matches.isEmpty)
            const EmptyBox('暂无可投注的比赛。')
          else ...[
            ...visible.map((m) => MatchCard(match: m, client: widget.client)),
            if (_matches.length > _visibleCount)
              TextButton.icon(
                onPressed: () =>
                    setState(() => _visibleCount += _pageSize),
                icon: const Icon(Icons.expand_more, size: 18),
                label: Text('加载更多（剩余 ${_matches.length - _visibleCount} 场）'),
              ),
          ],
        ],
      ),
    );
  }
}

class MatchCard extends StatelessWidget {
  const MatchCard({super.key, required this.match, required this.client});

  final Match match;
  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    final m = match;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => MatchInfoPage(client: client, match: m))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${m.matchNum.isEmpty ? '' : '${m.matchNum} · '}'
                      '${m.matchDate} ${m.matchTime} · ${m.league}',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: muted),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                      child: Text(m.homeTeam,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700))),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('VS',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: muted)),
                  ),
                  Expanded(
                      child: Text(m.awayTeam,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700))),
                ],
              ),
              const SizedBox(height: 12),
              _quickRow(m, '胜平负', 'wdw'),
              if (m.hhad.isNotEmpty) ...[
                const SizedBox(height: 8),
                _quickRow(m, '让球 ${lineShort(m.hhad['line'])}', 'handicap'),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickRow(Match m, String title, String market) {
    final opts = optionsFor(m, market);
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(title, style: const TextStyle(fontSize: 11, color: muted)),
        ),
        Expanded(
          child: Row(
            children: opts.map((o) {
              final leg = DraftLeg(
                matchId: m.matchId,
                homeTeam: m.homeTeam,
                awayTeam: m.awayTeam,
                market: market,
                pick: o.value,
                line: o.line ?? '',
                odds: o.odds,
                label: o.label,
              );
              return Expanded(
                child: ListenableBuilder(
                  listenable: draft,
                  builder: (_, _) {
                    final selected = draft.contains(leg);
                    return InkWell(
                      onTap: () => draft.toggle(leg),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: selected ? red : Colors.white,
                          border: Border.all(
                            color: selected ? red : const Color(0xFFE3E9E3),
                            width: 0.6,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          children: [
                            Text(pickLabel[o.value] ?? o.label,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? Colors.white
                                        : const Color(0xFF17211F))),
                            const SizedBox(height: 1),
                            Text(o.odds.isEmpty ? '-' : o.odds,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: selected ? Colors.white70 : muted)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: muted),
              const SizedBox(height: 12),
              Text('加载失败：$message', textAlign: TextAlign.center),
              const SizedBox(height: 4),
              const Text('请确认服务端已启动，且在「设置」里填对了服务器地址。',
                  style: TextStyle(color: muted, fontSize: 12), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      );
}
