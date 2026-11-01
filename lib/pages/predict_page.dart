import 'dart:async';

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
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Keep the board honest while it stays mounted inside the IndexedStack:
    // a match that kicks off must leave the list without a manual pull.
    _timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
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
      final data = await widget.client.get('/api/matches/today');
      // 展示所有可投注且未开赛的比赛（含今天的后续场次与明天的场次）。
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final upcoming = (data['predictions'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Match.fromJson(Map<String, dynamic>.from(e)))
          .where((m) => !m.finished && !m.started)
          .where((m) => m.kickoffTs <= 0 || m.kickoffTs > now)
          .toList();
      if (!mounted) return;
      setState(() {
        _matches = upcoming;
        _error = null;
        if (!silent) _visibleCount = _pageSize;
      });
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e.toString());
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
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
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Drop anything whose kickoff passed between the 60s refreshes, so the
    // list never shows an already-started match even briefly.
    final upcoming = _matches
        .where((m) => m.kickoffTs <= 0 || m.kickoffTs > now)
        .toList();
    final visible = upcoming.take(_visibleCount).toList();
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(silent: true),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (upcoming.isEmpty)
                  const EmptyBox('暂无可投注的比赛。')
                else ...[
                  ...visible.map(
                    (m) => MatchCard(match: m, client: widget.client),
                  ),
                  if (upcoming.length > _visibleCount)
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _visibleCount += _pageSize),
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: Text(
                        '加载更多（剩余 ${upcoming.length - _visibleCount} 场）',
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        // 已选浮条：点开后是整张选单（可改、可删、可清空），确定即加入方案。
        ListenableBuilder(
          listenable: draft,
          builder: (_, _) => draft.matchCount == 0
              ? const SizedBox.shrink()
              : _DraftBar(
                  onTap: () => _openDraftSheet(upcoming),
                ),
        ),
      ],
    );
  }

  void _openDraftSheet(List<Match> matches) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _DraftSheet(
        client: widget.client,
        matches: {for (final m in matches) m.matchId: m},
        onSaved: () {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已加入方案，可在「方案」页查看')),
          );
        },
      ),
    );
  }
}

/// Totals for the current draft: 注数, 购买金额, 理论最高奖金.
({int bets, double cost, double? potential}) _draftTotals(
  List<int> units, {
  double stake = 2,
  int multiple = 1,
}) {
  final legs = draft.legs;
  final bets = units.fold<int>(0, (sum, u) => sum + betsFor(legs, u));
  final cost = bets * stake * multiple;
  final pots = units
      .map((u) => potentialFor(legs, u, stake, multiple))
      .toList();
  final potential = pots.any((p) => p == null)
      ? null
      : pots.fold<double>(0.0, (sum, p) => sum + p!);
  return (bets: bets, cost: cost, potential: potential);
}

String _money(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// Compact dark bar pinned above the bottom navigation while a draft exists.
class _DraftBar extends StatelessWidget {
  const _DraftBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = draft.matchCount;
    final totals = _draftTotals(
      draft.effectiveUnits,
      stake: draft.stake,
      multiple: draft.multiple,
    );
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: const Color(0xFF0B3B34),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: red,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$n',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Text(
                        '已选',
                        style: TextStyle(color: Colors.white, fontSize: 9),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '共计: ${totals.bets}注 ${_money(totals.cost)}元',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        totals.potential != null
                            ? '理论最高奖金: ${_money(totals.potential!)}元'
                            : '理论最高奖金: -',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Column(
                  children: [
                    Text(
                      '查看',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '明细',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Icon(
                          Icons.keyboard_arrow_up,
                          color: Colors.white,
                          size: 16,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The 已选 sheet: edit/remove picks, choose 过关方式 and 倍数, then save the
/// plan. Mirrors 体彩's cart so the slip can be checked at a glance.
class _DraftSheet extends StatefulWidget {
  const _DraftSheet({
    required this.client,
    required this.matches,
    required this.onSaved,
  });

  final ApiClient client;

  /// Board matches by id, used to re-open a match's full option list (修改).
  final Map<String, Match> matches;
  final VoidCallback onSaved;

  @override
  State<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<_DraftSheet> {
  late Set<int> _units;
  late int _multiple;
  final Set<String> _editing = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _units = draft.effectiveUnits.toSet();
    _multiple = draft.multiple > 0 ? draft.multiple : 1;
  }

  List<int> get _sortedUnits =>
      _units.where((u) => u >= 1 && u <= draft.matchCount).toList()..sort();

  String _unitLabel(int u) => u <= 1 ? '单关' : '$u关';

  void _setUnits(Set<int> next) {
    setState(() => _units = next);
    draft.setUnits(next);
  }

  Future<void> _save() async {
    final legs = draft.legs;
    final n = draft.matchCount;
    if (legs.isEmpty || n == 0) return;
    setState(() => _saving = true);
    final units = _sortedUnits.isEmpty ? [n] : _sortedUnits;
    draft
      ..stake = 2
      ..multiple = _multiple
      ..setUnits(units);
    if (draft.title.trim().isEmpty) {
      draft.title = '竞彩 $n场 ${units.map(_unitLabel).join('+')}';
    }
    try {
      await draft.save(widget.client);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: draft,
        builder: (_, _) {
          final legs = draft.legs;
          final n = draft.matchCount;
          final groups = <String, List<DraftLeg>>{};
          for (final l in legs) {
            groups.putIfAbsent(l.matchId, () => []).add(l);
          }
          final units = _sortedUnits;
          final totals = _draftTotals(units, multiple: _multiple);
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.9,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 6, 0),
                  child: Row(
                    children: [
                      Text(
                        '已选 ($n)',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: legs.isEmpty ? null : draft.clear,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('清空'),
                        style: TextButton.styleFrom(foregroundColor: muted),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, color: muted),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: legs.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Text(
                            '还没有选项，点比赛下方的赔率即可加入。',
                            style: TextStyle(color: muted, fontSize: 13),
                          ),
                        )
                      : ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(6, 4, 12, 8),
                          children: [
                            for (final entry in groups.entries)
                              _matchGroup(entry.key, entry.value),
                          ],
                        ),
                ),
                if (n > 0) _unitsRow(),
                _footer(totals),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _matchGroup(String matchId, List<DraftLeg> legs) {
    final first = legs.first;
    final match = widget.matches[matchId];
    final editing = _editing.contains(matchId);
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除这场',
                onPressed: () => draft.removeMatch(matchId),
                icon: const Icon(Icons.close, size: 18, color: muted),
              ),
              Expanded(
                child: Text(
                  '${first.matchNum.isEmpty ? '' : '${first.matchNum} '}'
                  '${first.homeTeam} VS ${first.awayTeam}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (match != null)
                TextButton(
                  onPressed: () => setState(() {
                    if (!_editing.remove(matchId)) _editing.add(matchId);
                  }),
                  style: TextButton.styleFrom(foregroundColor: muted),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('修改', style: TextStyle(fontSize: 12)),
                      Icon(
                        editing ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 34, top: 2),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (match != null && editing)
                  for (final leg in _optionsFor(match))
                    _optionChip(leg, selected: draft.contains(leg))
                else
                  for (final leg in legs) _pickCard(leg),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Every bettable option of a board match (胜平负 + 让球), as the 修改 list.
  List<DraftLeg> _optionsFor(Match m) {
    final out = <DraftLeg>[];
    for (final market in [
      'wdw',
      if (m.hhad.isNotEmpty) 'handicap',
    ]) {
      for (final o in optionsFor(m, market)) {
        out.add(
          DraftLeg(
            matchId: m.matchId,
            matchNum: m.matchNum,
            homeTeam: m.homeTeam,
            awayTeam: m.awayTeam,
            market: market,
            pick: o.value,
            line: o.line ?? '',
            odds: o.odds,
            label: o.label,
          ),
        );
      }
    }
    return out;
  }

  Widget _optionChip(DraftLeg leg, {required bool selected}) {
    return InkWell(
      onTap: () => draft.toggle(leg),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? red : Colors.white,
          border: Border.all(
            color: selected ? red : const Color(0xFFE3E9E3),
            width: 0.8,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '${legPickLabel(leg.market, leg.pick, leg.label)}'
          '${leg.odds.isEmpty ? '' : ' ${leg.odds}'}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : const Color(0xFF17211F),
          ),
        ),
      ),
    );
  }

  /// One selected pick, drawn like the 体彩 slip: a vertical 玩法 tab plus
  /// the pick in red and its odds under it. Tapping removes it.
  Widget _pickCard(DraftLeg leg) {
    final label = marketShort[leg.market] ?? leg.market;
    return InkWell(
      onTap: () => draft.toggle(leg),
      borderRadius: BorderRadius.circular(6),
      child: IntrinsicHeight(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFE3E9E3)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: marketColor(leg.market),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(5),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final ch in label.split(''))
                      Text(
                        ch,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      legPickLabel(leg.market, leg.pick, leg.label),
                      style: const TextStyle(
                        color: red,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      leg.odds.isEmpty ? '-' : leg.odds,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unitsRow() {
    final n = draft.matchCount;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          const Center(
            child: Text(
              '过关方式',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
          const SizedBox(width: 8),
          for (var m = 1; m <= n; m++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_unitLabel(m), style: const TextStyle(fontSize: 12)),
                  selected: _units.contains(m),
                  onSelected: (selected) {
                    final next = Set<int>.of(_units);
                    if (selected) {
                      next.add(m);
                    } else if (next.length > 1) {
                      next.remove(m); // keep at least one 过关方式
                    }
                    _setUnits(next);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _footer(({int bets, double cost, double? potential}) totals) {
    final canSave = draft.legs.isNotEmpty && !_saving;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B3B34),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '共计: ${totals.bets}注 ${_money(totals.cost)}元',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  totals.potential != null
                      ? '理论最高奖金: ${_money(totals.potential!)}元'
                      : '理论最高奖金: -',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text(
                '倍数',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _multiple > 1
                    ? () => setState(() => _multiple--)
                    : null,
                icon: Icon(
                  Icons.remove_circle_outline,
                  size: 20,
                  color: _multiple > 1 ? Colors.white : Colors.white38,
                ),
              ),
              Text(
                '$_multiple',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _multiple++),
                icon: const Icon(
                  Icons.add_circle_outline,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: canSave ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: red,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                ),
                child: Text(_saving ? '保存中…' : '确定'),
              ),
            ],
          ),
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
                matchNum: m.matchNum,
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
