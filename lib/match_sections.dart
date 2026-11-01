import 'package:flutter/material.dart';

import 'api_client.dart';
import 'models.dart';
import 'widgets.dart';

/// A lazily fetched block for one of the newer `/api/matches/<id>/…`
/// endpoints. The detail page keeps its fast path (predictions render at once)
/// and only spends an API-Football call when the user actually opens the tab
/// or scrolls to the section.
class LazySection<T> extends StatefulWidget {
  const LazySection({
    super.key,
    required this.client,
    required this.path,
    required this.parse,
    required this.builder,
    this.emptyText = '暂无数据',
  });

  final ApiClient client;
  final String path;
  final T Function(Map<String, dynamic>) parse;
  final Widget? Function(T data) builder;
  final String emptyText;

  @override
  State<LazySection<T>> createState() => _LazySectionState<T>();
}

class _LazySectionState<T> extends State<LazySection<T>> {
  bool _loading = true;
  String? _error;
  T? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.client.get(widget.path);
      if (!mounted) return;
      setState(() => _data = widget.parse(data));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) return EmptyBox('加载失败：$_error');
    final data = _data;
    final widgetData = data == null ? null : widget.builder(data);
    return widgetData ?? EmptyBox(widget.emptyText);
  }
}

// --------------------------------------------------------------------------- //
// Section builders
// --------------------------------------------------------------------------- //
Widget sectionTitle(String title, IconData icon, Color color, {double size = 17}) {
  return Row(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Text(title,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w700)),
    ],
  );
}

Widget sectionCard(List<Widget> children) {
  return Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    )),
  );
}

/// 赛季数据 — both teams' full-season aggregates.
Widget teamStatsBlock(MatchTeamStats stats) {
  Widget block(String team, TeamStatsBlock? s) {
    if (s == null) return Text('$team：暂无赛季数据', style: const TextStyle(color: muted, fontSize: 12));
    final avgHome = s.avgHomeFor;
    final avgAway = s.avgAwayFor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(team, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _chip('场次', '${s.played}'),
            _chip('胜/平/负', '${s.wins}/${s.draws}/${s.loses}'),
            _chip('场均进', s.avgFor.toStringAsFixed(2)),
            _chip('场均失', s.avgAgainst.toStringAsFixed(2)),
            if (avgHome != null) _chip('主场均进', avgHome.toStringAsFixed(2)),
            if (avgAway != null) _chip('客场均进', avgAway.toStringAsFixed(2)),
            _chip('零封', '${s.cleanSheets}'),
            _chip('未进球', '${s.failedToScore}'),
          ],
        ),
        if (s.form.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('近况 ${s.form.split('').join(' ')}',
              style: const TextStyle(fontSize: 12, color: muted)),
        ],
      ],
    );
  }

  return sectionCard([
    block(stats.homeTeam, stats.home),
    const SizedBox(height: 12),
    block(stats.awayTeam, stats.away),
  ]);
}

/// 交锋记录 — previous meetings, oldest last.
Widget h2hBlock(MatchH2H h2h) {
  if (h2h.rows.isEmpty) return EmptyBox(h2h.error.isNotEmpty ? h2h.error : '暂无交锋记录');
  return sectionCard(
    h2h.rows.map((r) {
      final homeWin = r.homeGoals > r.awayGoals;
      final draw = r.homeGoals == r.awayGoals;
      final color = draw ? gold : (homeWin ? green : orange);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(r.date.length >= 5 ? r.date.substring(5) : r.date,
                  style: const TextStyle(fontSize: 11, color: muted)),
            ),
            Expanded(
              child: Text(r.homeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12.5)),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('${r.homeGoals}-${r.awayGoals}',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: color)),
            ),
            Expanded(
              child: Text(r.awayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      );
    }).toList(),
  );
}

/// 关键球员 + 教练 — season aggregates per team.
Widget squadBlock(MatchSquad squad) {
  Widget teamBlock(TeamSquad? s) {
    if (s == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(s.team, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          if (s.coachName.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text('主教练 ${s.coachName}', style: const TextStyle(fontSize: 11, color: muted)),
          ],
        ]),
        const SizedBox(height: 4),
        if (s.players.isEmpty)
          const Text('暂无球员数据', style: TextStyle(fontSize: 12, color: muted))
        else
          ...s.players.map((p) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(
                    child: Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text('${p.appearances}场',
                        style: const TextStyle(fontSize: 11, color: muted)),
                  ),
                  SizedBox(
                    width: 58,
                    child: Text('${p.goals}球 ${p.assists}助',
                        style: const TextStyle(fontSize: 11)),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(p.rating?.toStringAsFixed(2) ?? '-',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ),
                ]),
              )),
        const SizedBox(height: 10),
      ],
    );
  }

  final children = [
    teamBlock(squad.home),
    teamBlock(squad.away),
  ].where((w) => w is! SizedBox).toList();
  if (children.isEmpty) return const SizedBox.shrink();
  return sectionCard(children);
}

/// 缺阵历史 — injured players' absence record from /sidelined.
Widget absenceBlock(MatchSquad squad) {
  if (squad.absences.isEmpty) return const SizedBox.shrink();
  return sectionCard(
    squad.absences.map((a) {
      final span = [a.since, a.until].where((s) => s.isNotEmpty).join(' → ');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
            child: Text('${a.player}${a.team.isNotEmpty ? '（${a.team}）' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5)),
          ),
          Text(
            [
              if (span.isNotEmpty) span else a.kind,
              if (a.past > 0) '累计 ${a.past} 次',
            ].join(' · '),
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ]),
      );
    }).toList(),
  );
}

/// 本场评分 — per-player ratings once the match has started.
Widget ratingsBlock(FixturePlayers players) {
  if (players.teams.isEmpty) {
    return EmptyBox(players.error.isNotEmpty
        ? players.error
        : '暂无评分（开赛后才会生成）');
  }
  Widget teamBlock(TeamRatings t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text(t.team,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          if (t.averageRating != null)
            Text('全队均分 ${t.averageRating!.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 11, color: muted)),
        ]),
        const SizedBox(height: 2),
        ...t.players.take(16).map((p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(children: [
                SizedBox(
                  width: 22,
                  child: Text(p.number?.toString() ?? '',
                      style: const TextStyle(fontSize: 11, color: muted)),
                ),
                Expanded(
                  child: Text(
                    '${p.name}${p.goals > 0 ? ' 球${p.goals}' : ''}'
                    '${p.assists > 0 ? ' 助${p.assists}' : ''}'
                    '${p.yellow > 0 ? ' 黄${p.yellow}' : ''}'
                    '${p.red > 0 ? ' 红' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: p.substitute ? muted : null),
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text(p.rating?.toStringAsFixed(1) ?? '-',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _ratingColor(p.rating))),
                ),
              ]),
            )),
        const SizedBox(height: 12),
      ],
    );
  }

  return sectionCard(players.teams.map(teamBlock).toList());
}

Color _ratingColor(double? rating) {
  if (rating == null) return muted;
  if (rating >= 7.5) return green;
  if (rating >= 6.5) return gold;
  return orange;
}

/// 市场参考 — consensus bookmaker probabilities for the extra markets.
Widget marketBlock(MarketOdds o) {
  if (o.isEmpty) return const EmptyBox('暂无外部市场赔率（通常开赛前一天更新）。');
  Widget row(String label, List<double?> values, List<String> names) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 74,
          child: Text(label, style: const TextStyle(fontSize: 12, color: muted)),
        ),
        ...List.generate(values.length, (i) {
          final v = values[i];
          return Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(v == null ? '-' : pct(v),
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700)),
              Text(names[i],
                  style: const TextStyle(fontSize: 10, color: muted)),
            ]),
          );
        }),
      ]),
    );
  }

  return sectionCard([
    Row(children: [
      const Icon(Icons.public, size: 16, color: muted),
      const SizedBox(width: 6),
      Text('博彩公司共识${o.books > 0 ? '（${o.books} 家）' : ''}',
          style: const TextStyle(fontSize: 12, color: muted)),
    ]),
    const SizedBox(height: 4),
    row('胜平负', [o.home, o.draw, o.away], const ['主胜', '平局', '客胜']),
    if (o.bttsYes != null)
      row('双方进球', [o.bttsYes, o.bttsNo], const ['是', '否']),
    if (o.over25 != null)
      row('大小 2.5', [o.over25, o.under25], const ['大球', '小球']),
    if (o.homeDraw != null)
      row('双重机会', [o.homeDraw, o.homeAway, o.drawAway],
          const ['主/平', '主/客', '平/客']),
    if (o.asianHome != null)
      row('亚盘 ${o.asianLine}', [o.asianHome, o.asianAway], const ['主', '客']),
  ]);
}

Widget _chip(String label, String value) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFEEF4F1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text('$label $value', style: const TextStyle(fontSize: 11.5)),
  );
}
