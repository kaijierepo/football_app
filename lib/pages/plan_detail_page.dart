import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../models.dart';
import '../widgets.dart';

/// Full detail for a saved plan: the specific bets, purchase amount, and the
/// theoretical maximum win. Deleting here returns `true` so the list reloads.
class PlanDetailPage extends StatefulWidget {
  const PlanDetailPage({super.key, required this.client, required this.plan});

  final ApiClient client;
  final Plan plan;

  @override
  State<PlanDetailPage> createState() => _PlanDetailPageState();
}

class _PlanDetailPageState extends State<PlanDetailPage> {
  bool _deleting = false;
  bool _saving = false;

  /// 任九要展示整期 14 场（未选的场次显示 "-"），而方案里只存了所选比赛，
  /// 所以从 /api/renjiu 拉回该期赛程。
  List<Map<String, dynamic>> _issueMatches = const [];
  bool _issueLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.plan.isRenjiu) _loadIssue();
  }

  Future<void> _loadIssue() async {
    setState(() => _issueLoading = true);
    try {
      final data = await widget.client.get('/api/renjiu');
      final pools = <Map<String, dynamic>>[
        for (final list in [data['issues'], data['history']])
          if (list is List)
            for (final e in list.whereType<Map>())
              Map<String, dynamic>.from(e),
      ];
      final key =
          RegExp(r'第(\d+)期').firstMatch(widget.plan.title)?.group(1) ?? '';
      Map<String, dynamic>? issue;
      for (final pool in pools) {
        if (key.isNotEmpty && pool['issue']?.toString() == key) {
          issue = pool;
          break;
        }
      }
      if (issue == null) {
        // 期号对不上时，退化为「包含本方案全部对阵」的那一期。
        for (final pool in pools) {
          if (_coversPlan(pool)) {
            issue = pool;
            break;
          }
        }
      }
      final matches = ((issue?['matches'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() => _issueMatches = matches);
    } catch (_) {
      // 拉不到整期数据时，仍用方案内的 legs 渲染。
    } finally {
      if (mounted) setState(() => _issueLoading = false);
    }
  }

  bool _coversPlan(Map<String, dynamic> issue) {
    final teams = <String>{};
    for (final m in ((issue['matches'] as List?) ?? const []).whereType<Map>()) {
      teams.add(_pair(m['home_team'], m['away_team']));
    }
    final legs = widget.plan.legs;
    return legs.isNotEmpty &&
        legs.every((l) => teams.contains(_pair(l.homeTeam, l.awayTeam)));
  }

  static String _pair(Object? home, Object? away) =>
      '${home?.toString().trim() ?? ''}|${away?.toString().trim() ?? ''}';

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      await widget.client.post('/api/plans/delete', {'id': widget.plan.id});
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _edit() async {
    final p = widget.plan;
    final choice = await showDialog<(List<int>, int)>(
      context: context,
      builder: (_) => _EditPlanDialog(plan: p),
    );
    if (choice == null) return;
    setState(() => _saving = true);
    try {
      await widget.client.post('/api/plans/update', {
        'id': p.id,
        'units': choice.$1,
        'multiple': choice.$2,
      });
      if (mounted) Navigator.of(context).pop(true);
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
    final p = widget.plan;
    final groups = groupLegs(p.legs);
    final n = groups.length;
    final units = p.effectiveUnits;
    final bets = p.payout.bets > 0
        ? p.payout.bets
        : (p.isRenjiu
              ? renjiuBets(groups.map((g) => g.legs.length).toList())
              : units.fold<int>(0, (sum, u) => sum + betsForGroups(groups, u)));
    final mode = p.modeLabel;
    final statusLabel = switch (p.status) {
      'won' => p.isRenjiu ? '已中奖' : '已命中',
      'lost' => '未命中',
      _ => '待开奖',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('方案详情'),
        actions: [
          IconButton(
            tooltip: '调整倍数 / 过关方式',
            onPressed: _saving || _deleting ? null : _edit,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              VerdictBadge(statusLabel),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${p.createdAt} · $mode'
            '${p.multiple > 1 ? ' · ${p.multiple} 倍' : ''}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _passCard(p, n, units, bets),
          const SizedBox(height: 12),
          _amountCard(p),
          const SizedBox(height: 20),
          if (p.isRenjiu)
            _renjiuSection(p)
          else ...[
            const Text(
              '投注明细（按比赛场次）',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 4),
            if (n > 1)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '同一场比赛的多个选项是复式备选，一注最多取其中一个。',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
            ...groups.map(_matchGroup),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _deleting ? null : _delete,
            icon: const Icon(Icons.delete, color: red),
            label: Text(
              _deleting ? '删除中…' : '删除方案',
              style: const TextStyle(color: red),
            ),
          ),
        ],
      ),
    );
  }

  /// 过关方式 is the single thing a shop clerk must read off the slip, so it
  /// gets the same treatment as 体彩's own 已选 panel: a dark, high-contrast
  /// header with the 场数 / 注数 / 金额 / 最高奖金 and big 单关·N串1 chips.
  Widget _passCard(Plan p, int n, List<int> units, int bets) {
    final po = p.payout;
    final multiple = p.multiple > 0 ? p.multiple : 1;
    final cost = po.totalCost ?? (p.stake > 0 ? bets * p.stake * multiple : null);
    final labels = p.isRenjiu
        ? const ['任选9场']
        : units.map((u) => u <= 1 ? '单关' : '$u串1').toList();
    Widget chip(String label) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF0B3B34),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        );
    Widget fact(String label, String value, Color color) => Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 17, fontWeight: FontWeight.w800)),
          ],
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B3B34),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: red,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$n 场',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('已选比赛',
                        style: TextStyle(color: Colors.white70, fontSize: 11)),
                    Text(
                      '共 $bets 注'
                      '${cost != null ? ' · ${_money(cost)} 元' : ''}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              if (po.potential != null)
                fact('理论最高奖金', '${_money(po.potential!)} 元', gold),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '过关方式',
            style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: labels.map(chip).toList()),
          if (multiple > 1) ...[
            const SizedBox(height: 8),
            Text('倍数 $multiple',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  /// 任九按体彩单子的写法展示：整期 14 场一行一场，只有 3/1/0，未选的写
  /// "-"，不显示赔率。
  Widget _renjiuSection(Plan p) {
    final groups = groupLegs(p.legs);
    final byPair = <String, List<Leg>>{
      for (final g in groups) _pair(g.homeTeam, g.awayTeam): g.legs,
    };
    final rows = <Widget>[];
    if (_issueMatches.isNotEmpty) {
      for (var i = 0; i < _issueMatches.length; i++) {
        final m = _issueMatches[i];
        final home = m['home_team']?.toString() ?? '';
        final away = m['away_team']?.toString() ?? '';
        rows.add(
          _renjiuRow(
            index: i,
            num: m['num']?.toString() ?? '',
            home: home,
            away: away,
            legs: byPair[_pair(home, away)] ?? const [],
            score: m['score']?.toString() ?? '',
          ),
        );
      }
    } else {
      for (var i = 0; i < groups.length; i++) {
        final g = groups[i];
        rows.add(
          _renjiuRow(
            index: i,
            num: g.legs.first.matchNum,
            home: g.homeTeam,
            away: g.awayTeam,
            legs: g.legs,
            score: '',
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _issueMatches.isEmpty
                    ? p.title
                    : '${p.title} · ${_issueMatches.length} 场',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            if (_issueLoading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: const Color(0xFF0B3B34),
                child: const Row(
                  children: [
                    SizedBox(
                      width: 46,
                      child: Text(
                        '场次',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '对阵',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ),
                    Text(
                      '310',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '暂无赛程数据',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                )
              else
                ...rows,
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '3 = 主胜，1 = 平局，0 = 客胜；"-" 表示该场未选。'
          '任九为浮动奖，奖金以官方开奖为准。',
          style: TextStyle(color: muted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _renjiuRow({
    required int index,
    required String num,
    required String home,
    required String away,
    required List<Leg> legs,
    required String score,
  }) {
    final selected = legs.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: index.isEven ? const Color(0xFFF6F8F7) : Colors.white,
        border: const Border(
          bottom: BorderSide(color: Color(0xFFEDF1EF)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            child: Text(
              num.isEmpty ? '-' : '第$num场',
              style: TextStyle(
                color: selected ? const Color(0xFF17211F) : muted,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '$home VS $away',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? const Color(0xFF17211F) : muted,
                    ),
                  ),
                ),
                if (score.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    score,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _renjiuDigits(legs),
        ],
      ),
    );
  }

  Widget _renjiuDigits(List<Leg> legs) {
    const order = {'home': 0, 'draw': 1, 'away': 2};
    final picks = legs.where((l) => order.containsKey(l.pick)).toList()
      ..sort((a, b) => order[a.pick]!.compareTo(order[b.pick]!));
    if (picks.isEmpty) {
      return const SizedBox(
        width: 40,
        child: Text(
          '-',
          textAlign: TextAlign.right,
          style: TextStyle(
            color: muted,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final l in picks)
            Text(
              renjiuDigit(l.pick),
              style: TextStyle(
                fontSize: 17,
                height: 1.1,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
                color: switch (l.result) {
                  'hit' => green,
                  'miss' => red,
                  _ => const Color(0xFF17211F),
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _amountCard(Plan p) {
    final po = p.payout;
    final rows = <Widget>[];
    if (po.totalCost != null && po.totalCost! > 0) {
      rows.add(
        _amountRow(
          '购买金额',
          '${po.totalCost!.toStringAsFixed(2)} 元',
          const Color(0xFF17211F),
        ),
      );
    }
    if (p.isRenjiu) {
      if (po.returnAmount != null) {
        rows.add(
          _amountRow('中奖金额', '${po.returnAmount!.toStringAsFixed(2)} 元', green),
        );
        rows.add(
          _amountRow(
            '利润',
            '${po.profit!.toStringAsFixed(2)} 元',
            (po.profit! >= 0) ? green : red,
          ),
        );
      } else if (p.status == 'won') {
        rows.add(_amountRow('中奖金额', '任九浮动奖，奖金以官方开奖为准', green));
      } else {
        rows.add(
          _amountRow(
            '奖金说明',
            po.reason.isNotEmpty ? po.reason : '任九为浮动奖，奖金以官方开奖为准',
            muted,
          ),
        );
      }
    } else {
      if (po.potential != null) {
        rows.add(
          _amountRow('理论最多中奖', '${po.potential!.toStringAsFixed(2)} 元', gold),
        );
      } else if (po.reason.isNotEmpty) {
        rows.add(_amountRow('理论最多中奖', po.reason, muted));
      }
      if (po.returnAmount != null) {
        rows.add(
          _amountRow('中奖金额', '${po.returnAmount!.toStringAsFixed(2)} 元', green),
        );
        rows.add(
          _amountRow(
            '利润',
            '${po.profit!.toStringAsFixed(2)} 元',
            (po.profit! >= 0) ? green : red,
          ),
        );
      }
    }
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: rows),
      ),
    );
  }

  Widget _amountRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: muted, fontSize: 13)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _matchGroup(LegGroup g) {
    final score = g.legs
        .map((l) => l.score)
        .firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
    final matchNum = g.legs
        .map((l) => l.matchNum)
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${matchNum.isEmpty ? '' : '$matchNum '}'
                    '${g.homeTeam} vs ${g.awayTeam}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (score != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEF4F1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      score,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            for (final l in g.legs) _optionRow(l),
          ],
        ),
      ),
    );
  }

  Widget _optionRow(Leg l) {
    final color = marketColor(l.market);
    final pick = selectionLabel(l.market, l.pick, l.line);
    final reason = legReason(l.market, l.pick, l.label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              MarketTag(l.market),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pick,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  l.odds.isEmpty ? '-' : l.odds,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              VerdictBadge(l.result),
            ],
          ),
          if (reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 11, top: 3, right: 4),
              child: Text(
                reason,
                softWrap: true,
                style: const TextStyle(
                  color: muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 调整倍数 / 过关方式，返回 `(units, multiple)`。
class _EditPlanDialog extends StatefulWidget {
  const _EditPlanDialog({required this.plan});

  final Plan plan;

  @override
  State<_EditPlanDialog> createState() => _EditPlanDialogState();
}

class _EditPlanDialogState extends State<_EditPlanDialog> {
  late final int _n;
  late Set<int> _units;
  late int _multiple;

  @override
  void initState() {
    super.initState();
    _n = groupLegs(widget.plan.legs).length;
    _units = widget.plan.effectiveUnits.where((u) => u >= 1 && u <= _n).toSet();
    if (_units.isEmpty && _n > 0) _units.add(_n);
    _multiple = widget.plan.multiple > 0 ? widget.plan.multiple : 1;
  }

  List<int> get _sortedUnits => _units.toList()..sort();

  @override
  Widget build(BuildContext context) {
    final renjiu = widget.plan.isRenjiu;
    return AlertDialog(
      title: const Text('调整方案'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!renjiu) ...[
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
            ],
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
              renjiu
                  ? '任选9场 · $_multiple 倍'
                  : '共 $_n 场 · ${_sortedUnits.map((u) => u <= 1 ? '单关' : '$u串1').join('+')}',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _units.isEmpty
              ? null
              : () => Navigator.of(context).pop((_sortedUnits, _multiple)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

String _money(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
