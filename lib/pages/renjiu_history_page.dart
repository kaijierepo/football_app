import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets.dart';
import 'plan_detail_page.dart';

/// 「任九」历史：我的任九方案 + 官方往期开奖。
class RenjiuHistoryPage extends StatefulWidget {
  const RenjiuHistoryPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<RenjiuHistoryPage> createState() => _RenjiuHistoryPageState();
}

class _RenjiuHistoryPageState extends State<RenjiuHistoryPage> {
  bool _loading = true;
  String? _error;
  List<Plan> _plans = [];
  List<Map<String, dynamic>> _history = [];

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
        widget.client.get('/api/renjiu?refresh=1'),
        widget.client.get('/api/plans'),
      ]);
      final renjiu = results[0];
      final plansData = results[1];
      if (!mounted) return;
      setState(() {
        _history = (renjiu['history'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _plans = (plansData['plans'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
            .where((p) => p.isRenjiu)
            .toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任九历史'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
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
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  _sectionTitle('我的任九方案', Icons.receipt_long, green),
                  const SizedBox(height: 8),
                  if (_plans.isEmpty)
                    const EmptyBox('还没有保存的任九方案。')
                  else
                    ..._plans.map(_planCard),
                  const SizedBox(height: 18),
                  _sectionTitle('往期开奖', Icons.emoji_events, gold),
                  const SizedBox(height: 8),
                  if (_history.isEmpty)
                    const EmptyBox(
                      '暂无往期开奖数据。\n'
                      '服务器无法直连竞彩官网，请在可访问竞彩的电脑上运行 '
                      'sync_to_server.py 同步往期数据。',
                    )
                  else
                    ..._history.map(_issueCard),
                ],
              ),
            ),
    );
  }

  Widget _sectionTitle(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _planCard(Plan p) {
    final statusLabel = switch (p.status) {
      'won' => '已中奖',
      'lost' => '未中奖',
      _ => '待开奖',
    };
    final po = p.payout;
    final bets = po.bets > 0 ? po.bets : 0;
    return Card(
      key: ValueKey(p.id),
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlanDetailPage(client: widget.client, plan: p),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  VerdictBadge(statusLabel),
                  const Icon(Icons.chevron_right, size: 18, color: muted),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${p.createdAt} · ${p.matchCount} 场'
                '${bets > 0 ? ' · 共 $bets 注' : ''}'
                '${p.multiple > 1 ? ' · ${p.multiple} 倍' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                _payoutText(p),
                style: TextStyle(
                  color: po.returnAmount != null || po.floating
                      ? green
                      : (po.potential != null ? gold : muted),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _payoutText(Plan p) {
    final po = p.payout;
    if (po.returnAmount != null) {
      final profit = po.profit;
      return '中奖 ${_money(po.returnAmount)} 元'
          '${profit != null ? '（利润 ${_money(profit)} 元）' : ''}';
    }
    if (po.floating) return '已中奖 · 任九浮动奖，奖金以官方开奖为准';
    if (po.potential != null) return '理论最多中奖 ${_money(po.potential)} 元';
    return po.reason.isNotEmpty ? po.reason : '待开奖';
  }

  Widget _issueCard(Map<String, dynamic> issue) {
    final matches = (issue['matches'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final pending = issue['pending'] == true;
    final prize = issue['prize'];
    final sale = issue['sale'];
    final results = issue['results'];
    return Card(
      key: ValueKey(issue['issue']?.toString() ?? ''),
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '第${issue['issue'] ?? '-'}期',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '开奖 ${_dateText(issue['draw_time'])}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (pending ? orange : green).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    pending ? '待开奖' : '已开奖',
                    style: TextStyle(
                      color: pending ? orange : green,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (prize is num || sale is num)
              Text(
                [
                  if (prize is num) '单注奖金 ${_intText(prize)} 元',
                  if (issue['winners'] is num && (issue['winners'] as num) > 0)
                    '${_intText(issue['winners'])} 注中奖',
                  if (sale is num) '销量 ${_intText(sale)} 元',
                ].join(' · '),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            const SizedBox(height: 8),
            if (matches.isEmpty && results is List)
              Text(
                (results).map(_resultLabel).join('  '),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              )
            else
              _resultGrid(matches),
          ],
        ),
      ),
    );
  }

  Widget _resultGrid(List<Map<String, dynamic>> matches) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: matches.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        mainAxisExtent: 42,
      ),
      itemBuilder: (_, i) {
        final m = matches[i];
        final result = m['result']?.toString() ?? '';
        final score = m['score']?.toString() ?? '';
        final color = switch (result) {
          '3' => green,
          '1' => gold,
          '0' => red,
          _ => muted,
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8F5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${m['num'] ?? '-'} ${m['home_team'] ?? ''} vs ${m['away_team'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: muted),
              ),
              Text(
                [if (result.isNotEmpty) _resultLabel(result), if (score.isNotEmpty) score]
                    .join(' '),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _resultLabel(Object? value) => switch (value?.toString()) {
    '3' => '主胜',
    '1' => '平局',
    '0' => '客胜',
    _ => '待定',
  };

  String _dateText(Object? value) {
    final s = value?.toString() ?? '';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  String _money(double? value) =>
      value == null ? '-' : value.toStringAsFixed(2);

  String _intText(Object? value) {
    final n = value is num ? value.toInt() : null;
    if (n == null) return '-';
    final digits = n.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}
