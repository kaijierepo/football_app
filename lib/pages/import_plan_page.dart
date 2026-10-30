import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api_client.dart';
import '../draft.dart';
import '../widgets.dart';

/// 竞彩截图导入：相册选图 -> 服务端 OCR 识别 -> 可编辑预览 -> 保存方案。
///
/// 识别、解析、按场次号匹配赛程都在服务端完成（`POST /api/plans/scan`），
/// 这里只负责选图、展示识别结果和落库（`POST /api/plans`）。
class ImportPlanPage extends StatefulWidget {
  const ImportPlanPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<ImportPlanPage> createState() => _ImportPlanPageState();
}

/// 识别结果中的一项：DraftLeg + 场次号 + 是否匹配到赛程。
class _ScanLeg {
  _ScanLeg({
    required this.matchNum,
    required this.leg,
    required this.matched,
  });

  final String matchNum;
  final DraftLeg leg;
  final bool matched;

  /// 分组键：匹配到赛程用 match_id，否则退回场次号。
  String get groupKey =>
      leg.matchId.isEmpty ? 'num:$matchNum' : 'mid:${leg.matchId}';
}

class _ImportPlanPageState extends State<ImportPlanPage> {
  bool _scanning = false;
  bool _saving = false;
  String? _error;
  List<_ScanLeg> _legs = [];
  List<String> _warnings = [];
  Set<int> _units = {};
  int _multiple = 1;
  String _autoTitle = '';
  final TextEditingController _titleCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _scanning = true;
      _error = null;
      _legs = [];
      _warnings = [];
    });
    try {
      final bytes = await picked.readAsBytes();
      final data = await widget.client.post('/api/plans/scan', {
        'image_b64': base64Encode(bytes),
      });
      final legs = <_ScanLeg>[];
      for (final raw in (data['legs'] as List? ?? const []).whereType<Map>()) {
        final j = Map<String, dynamic>.from(raw);
        legs.add(
          _ScanLeg(
            matchNum: '${j['match_num'] ?? ''}',
            matched: j['matched'] == true,
            leg: DraftLeg(
              matchId: '${j['match_id'] ?? ''}',
              homeTeam: '${j['home_team'] ?? ''}',
              awayTeam: '${j['away_team'] ?? ''}',
              market: '${j['market'] ?? ''}',
              pick: '${j['pick'] ?? ''}',
              line: '${j['line'] ?? ''}',
              odds: '${j['odds'] ?? ''}',
              label: '${j['label'] ?? ''}',
            ),
          ),
        );
      }
      final n = legs.map((e) => e.groupKey).toSet().length;
      final units = (data['units'] as List? ?? const [])
          .map((u) => int.tryParse('$u') ?? 0)
          .where((u) => u >= 1 && u <= n)
          .toSet();
      if (units.isEmpty && n > 0) units.add(n);
      if (!mounted) return;
      setState(() {
        _legs = legs;
        _warnings = (data['warnings'] as List? ?? const [])
            .map((w) => '$w')
            .toList();
        _units = units;
        _multiple = ((data['multiple'] as num?)?.toInt() ?? 1).clamp(1, 99);
        _autoTitle = '${data['title'] ?? ''}';
        _titleCtrl.text = _autoTitle;
        if (legs.isEmpty) {
          _error = _warnings.isNotEmpty ? _warnings.join('\n') : '没有识别到选项';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  int get _matchCount => _legs.map((e) => e.groupKey).toSet().length;

  List<DraftLeg> get _draftLegs => _legs.map((e) => e.leg).toList();

  Set<int> get _validUnits {
    final n = _matchCount;
    final units = _units.where((u) => u >= 1 && u <= n).toSet();
    if (units.isEmpty && n > 0) units.add(n);
    return units;
  }

  void _removeLeg(int index) {
    setState(() {
      _legs.removeAt(index);
      if (_titleCtrl.text == _autoTitle) {
        _autoTitle = _buildTitle();
        _titleCtrl.text = _autoTitle;
      }
    });
  }

  /// 与后端 `plan_import.build_title` 一致：每场「主队-客队 玩法」用 + 连接。
  String _buildTitle() {
    final order = <String>[];
    final markets = <String, List<String>>{};
    final names = <String, (String, String)>{};
    for (final e in _legs) {
      final key = e.groupKey;
      if (!names.containsKey(key)) {
        order.add(key);
        markets[key] = [];
        names[key] = (e.leg.homeTeam, e.leg.awayTeam);
      }
      final name = marketShort[e.leg.market] ?? e.leg.market;
      final list = markets[key]!;
      if (!list.contains(name)) list.add(name);
    }
    return order
        .map((key) {
          final (home, away) = names[key]!;
          return '${_abbr(home)}-${_abbr(away)} ${markets[key]!.join('/')}';
        })
        .join('+');
  }

  static String _abbr(String name) {
    final s = name.replaceAll(RegExp(r'\s+'), '');
    return s.length >= 3 ? s.substring(0, 2) : s;
  }

  Future<void> _save() async {
    final legs = _draftLegs;
    if (legs.isEmpty) return;
    final units = _validUnits.toList()..sort();
    setState(() => _saving = true);
    try {
      await widget.client.post('/api/plans', {
        'title': _titleCtrl.text.trim().isEmpty
            ? _autoTitle
            : _titleCtrl.text.trim(),
        'play_type': units.length == 1 && units.first == 1
            ? 'single'
            : 'parlay',
        'unit': units.isEmpty ? null : units.last,
        'units': units,
        'multiple': _multiple,
        'stake': 2,
        'legs': legs
            .map(
              (l) => {
                'match_id': l.matchId,
                'home_team': l.homeTeam,
                'away_team': l.awayTeam,
                'market': l.market,
                'pick': l.pick,
                'line': l.line,
                'odds': l.odds,
                'label': l.label,
              },
            )
            .toList(),
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
    return Scaffold(
      appBar: AppBar(title: const Text('截图导入')),
      body: _scanning
          ? const _ScanningView()
          : _legs.isEmpty
          ? _startView()
          : _previewView(),
    );
  }

  Widget _startView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner, size: 64, color: muted),
            const SizedBox(height: 14),
            const Text(
              '选择一张竞彩「已选」截图，\n自动识别场次、玩法、选项和赔率。',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, height: 1.5),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: red, fontSize: 13),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(_error == null ? '选择截图' : '重新选择'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewView() {
    final n = _matchCount;
    final units = _validUnits.toList()..sort();
    final legs = _draftLegs;
    final bets = units.fold<int>(0, (sum, u) => sum + betsFor(legs, u));
    final total = bets * 2 * _multiple;
    final pots = units.map((u) => potentialFor(legs, u, 2, _multiple)).toList();
    final pot = pots.any((p) => p == null)
        ? null
        : pots.fold<double>(0.0, (sum, p) => sum + p!);
    final unmatched = _legs.where((e) => !e.matched).length;
    final groups = <String, List<int>>{};
    for (var i = 0; i < _legs.length; i++) {
      groups.putIfAbsent(_legs[i].groupKey, () => []).add(i);
    }
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '识别到 $n 场 · ${legs.length} 个选项'
                '${unmatched > 0 ? ' · $unmatched 项未匹配赛程' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ),
            TextButton(onPressed: _pick, child: const Text('重新选择')),
          ],
        ),
        for (final warning in _warnings)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              warning,
              style: const TextStyle(color: gold, fontSize: 12),
            ),
          ),
        for (final indexes in groups.values) _matchGroup(indexes),
        const Divider(height: 24),
        const Text(
          '过关方式（可多选）',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var m = 1; m <= n; m++)
              FilterChip(
                label: Text(m == 1 ? '单关' : '$m串1'),
                selected: units.contains(m),
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
        const SizedBox(height: 8),
        Text(
          '共 $n 场比赛 · ${units.map((u) => u <= 1 ? '单关' : '$u串1').join('+')}'
          ' · $bets 注 × $_multiple 倍',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          '购买金额 ${total.toStringAsFixed(2)} 元',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        const SizedBox(height: 2),
        if (pot != null)
          Text(
            '理论最多中奖 ${pot.toStringAsFixed(2)} 元',
            style: const TextStyle(
              color: gold,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(
            labelText: '方案标题',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
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
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              color: green,
              onPressed: () => setState(() => _multiple++),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (unmatched > 0)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '有选项没匹配到当天赛程（红色标记），删除后才能保存。',
              style: TextStyle(color: red, fontSize: 12),
            ),
          ),
        FilledButton(
          onPressed: _saving || unmatched > 0 ? null : _save,
          child: Text(_saving ? '保存中…' : '保存方案（$n 场 · $bets 注）'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _matchGroup(List<int> indexes) {
    final first = _legs[indexes.first];
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
                  child: Text(
                    '${first.matchNum} ${first.leg.homeTeam} vs ${first.leg.awayTeam}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!first.matched)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '未匹配赛程',
                      style: TextStyle(
                        color: red,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final i in indexes) _legRow(i),
          ],
        ),
      ),
    );
  }

  Widget _legRow(int index) {
    final l = _legs[index].leg;
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
          Text(
            l.odds.isEmpty ? '-' : l.odds,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: red),
            onPressed: () => _removeLeg(index),
          ),
        ],
      ),
    );
  }
}

class _ScanningView extends StatelessWidget {
  const _ScanningView();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('正在识别截图…通常需要 10 秒左右', style: TextStyle(color: muted)),
      ],
    ),
  );
}
