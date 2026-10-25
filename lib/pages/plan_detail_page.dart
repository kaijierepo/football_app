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
      appBar: AppBar(title: const Text('方案详情')),
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
            '${p.createdAt} · $n 场 · $mode · 共 $bets 注'
            '${p.stake > 0 ? ' · 每注 ${_money(p.stake)} 元' : ''}'
            '${p.multiple > 1 ? ' · ${p.multiple} 倍' : ''}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _amountCard(p),
          const SizedBox(height: 20),
          const Text(
            '投注明细（按比赛场次）',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 4),
          if (n > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                p.isRenjiu
                    ? '任选9场：从所选场次中任取 9 场，每场命中一个选项即中奖；'
                          '同场多选为复式，注数自动计算。'
                    : '同一场比赛的多个选项是复式备选，一注最多取其中一个。',
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            ),
          ...groups.map(_matchGroup),
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
    final pick = legPickLabel(l.market, l.pick, l.label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
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
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
    );
  }
}

String _money(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
