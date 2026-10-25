import 'package:flutter/material.dart';

import '../api_client.dart';
import '../draft.dart';
import '../widgets.dart';

/// Plan draft (方案草稿) — assemble the selected legs, pick the 过关方式
/// (单关 / M串1 过关), and save. Per-bet stake is fixed at 2 元.
class DraftPage extends StatefulWidget {
  const DraftPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<DraftPage> createState() => _DraftPageState();
}

class _DraftPageState extends State<DraftPage> {
  bool _saving = false;
  late int _unit;
  int _multiple = 1;
  final TextEditingController _titleCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _unit = draft.effectiveUnit > 0 ? draft.effectiveUnit : 1;
    _multiple = draft.multiple;
  }

  Future<void> _save() async {
    if (draft.legs.isEmpty) return;
    setState(() => _saving = true);
    draft.title = _titleCtrl.text;
    draft.stake = 2;
    draft.multiple = _multiple;
    draft.setUnit(_unit);
    try {
      await draft.save(widget.client);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('方案草稿')),
      body: ListenableBuilder(
        listenable: draft,
        builder: (_, _) {
          final legs = draft.legs;
          if (legs.isEmpty) {
            return const EmptyBox('还没有选项，去预测页点选加入。');
          }
          // Same-match picks are alternatives within a ticket, not separate
          // legs, so the unit max is the number of distinct matches.
          final groups = <String, List<int>>{};
          for (var i = 0; i < legs.length; i++) {
            groups.putIfAbsent(legs[i].matchId, () => []).add(i);
          }
          final n = groups.length;
          final u = _unit.clamp(1, n).toInt();
          final bets = betsFor(legs, u);
          final total = bets * 2 * _multiple;
          final pot = potentialFor(legs, u, 2, _multiple);
          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              for (final indexes in groups.values) _matchGroup(legs, indexes),
              const Divider(height: 24),
              const Text('过关方式',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var m = 1; m <= n; m++)
                    ChoiceChip(
                      label: Text(m == 1 ? '单关' : '$m串1'),
                      selected: u == m,
                      onSelected: (_) => setState(() => _unit = m),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '共 $n 场比赛 · $bets 注 × $_multiple 倍'
                '${n > 1 ? '（同一场只能取一个选项串进同一注）' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text('购买金额 ${total.toStringAsFixed(2)} 元',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 2),
              if (pot != null)
                Text('理论最多中奖 ${pot.toStringAsFixed(2)} 元',
                    style: const TextStyle(
                        color: gold, fontWeight: FontWeight.w700, fontSize: 14))
              else
                const Text('理论中奖金额：部分选项无赔率，无法计算',
                    style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                    labelText: '方案标题（可选）', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('倍数',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    color: _multiple > 1 ? green : muted,
                    onPressed: _multiple > 1
                        ? () => setState(() => _multiple--)
                        : null,
                  ),
                  Text('$_multiple',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    color: green,
                    onPressed: () => setState(() => _multiple++),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving
                    ? '保存中…'
                    : '保存方案（$n 场 · $bets 注）'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _matchGroup(List<DraftLeg> legs, List<int> indexes) {
    final first = legs[indexes.first];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${first.homeTeam} vs ${first.awayTeam}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                Text('${indexes.length} 个选项',
                    style: const TextStyle(color: muted, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 4),
            for (final i in indexes) _legRow(i, legs[i]),
          ],
        ),
      ),
    );
  }

  Widget _legRow(int index, DraftLeg l) {
    final color = marketColor(l.market);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 26,
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
              legPickLabel(l.market, l.pick, l.label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Text(l.odds.isEmpty ? '-' : l.odds,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: red),
            onPressed: () => draft.removeAt(index),
          ),
        ],
      ),
    );
  }
}
