import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../widgets.dart';
import 'renjiu_history_page.dart';

/// 「任九」tab: the current 胜负彩 14-match issue, official 主/平/客 odds,
/// the Poisson model's 1X2 probabilities when the fixture is also on the 竞彩
/// board, and a selector that enforces 任选九场 semantics (pick 9+ matches;
/// multi-outcome matches are 复式).
class RenjiuPage extends StatefulWidget {
  const RenjiuPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<RenjiuPage> createState() => _RenjiuPageState();
}

class _RenjiuPageState extends State<RenjiuPage> {
  bool _loading = true;
  String? _error;
  String? _notice;
  List<Map<String, dynamic>> _issues = [];
  Map<String, dynamic> _lastDraw = const {};
  int _updatedAt = 0;
  int _sourceUpdatedAt = 0;
  int _issueIndex = 0;
  int _multiple = 1;
  bool _saving = false;
  final Map<String, Map<int, Set<String>>> _selections = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _issueKey =>
      _issues.isEmpty ? '' : (_issues[_issueIndex]['issue']?.toString() ?? '');

  Map<String, dynamic>? get _issue =>
      _issues.isEmpty ? null : _issues[_issueIndex];

  List<Map<String, dynamic>> get _matches {
    final issue = _issue;
    if (issue == null) return const [];
    return (issue['matches'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<int, Set<String>> get _selected =>
      _selections[_issueKey] ?? const <int, Set<String>>{};

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.client.get(
        '/api/renjiu${force ? '?refresh=1' : ''}',
      );
      if (!mounted) return;
      final issues = (data['issues'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _issues = issues;
        _lastDraw = data['last_draw'] is Map
            ? Map<String, dynamic>.from(data['last_draw'] as Map)
            : const {};
        _updatedAt = (data['updated_at'] as num?)?.toInt() ?? 0;
        _sourceUpdatedAt = (data['source_updated_at'] as num?)?.toInt() ?? 0;
        _notice = data['stale'] == true
            ? '接口暂不可用，显示缓存数据：${data['error'] ?? ''}'
            : data['error']?.toString();
        if (_issueIndex >= _issues.length) _issueIndex = 0;
        _error = issues.isEmpty ? (_notice ?? '暂无在售的任九期次') : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// True when the on-sale window has ended (the phone clock is 北京时间).
  bool get _expired {
    final end = _parseDateTime(_issue?['sale_end']);
    return end != null && DateTime.now().isAfter(end);
  }

  static DateTime? _parseDateTime(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final iso = text.replaceFirst(' ', 'T');
    // Official times are Beijing wall-clock; attach +08:00 so the comparison
    // is correct even when the phone is in another timezone.
    return DateTime.tryParse(iso.contains('+') ? iso : '$iso+08:00');
  }

  String _clockText(int ts) {
    if (ts <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  void _toggle(int num, String pick) {
    setState(() {
      final sel = _selections.putIfAbsent(_issueKey, () => {});
      final set = sel.putIfAbsent(num, () => <String>{});
      if (!set.add(pick)) set.remove(pick);
      if (set.isEmpty) sel.remove(num);
    });
  }

  void _clear() {
    setState(() => _selections[_issueKey] = {});
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RenjiuHistoryPage(client: widget.client),
      ),
    );
  }

  String _issueStatusLabel(Map issue) => switch (issue['status']) {
    'on_sale' => ' · 在售',
    'upcoming' => ' · 未开售',
    'closed' => ' · 已截止',
    _ => issue['current'] == true ? ' · 在售' : '',
  };

  /// Pick 9 matches, preferring the models' 稳胆 then 复式, and take the
  /// advised outcomes (one for 稳胆, both for 复式). Weak matches only fill
  /// the remaining slots.
  void _recommend() {
    final entries = <({double score, int num, List<String> picks})>[];
    for (final m in _matches) {
      final matchNum = (m['num'] as num?)?.toInt();
      if (matchNum == null) continue;
      final advice = _adviceOf(m);
      final probs = _probabilities(m);
      var best = '';
      var bestProb = -1.0;
      probs.forEach((key, value) {
        if (value > bestProb) {
          bestProb = value;
          best = key;
        }
      });
      final picks = <String>[...?advice?.picks];
      if (picks.isEmpty && best.isNotEmpty) picks.add(best);
      if (picks.isEmpty) {
        final odds = m['odds'];
        if (odds is Map) picks.add(_lowestOddsPick(odds));
      }
      if (picks.isEmpty) continue;
      final base = switch (advice?.style) {
        'banker' => 30.0,
        'double' => 20.0,
        _ => 10.0,
      };
      final confidence = advice?.confidence ?? bestProb.clamp(0.0, 1.0);
      entries.add((
        score: base + confidence,
        num: matchNum,
        picks: picks.toSet().toList(),
      ));
    }
    entries.sort((a, b) => b.score.compareTo(a.score));
    final sel = <int, Set<String>>{};
    for (final entry in entries) {
      if (sel.length >= 9) break;
      sel[entry.num] = entry.picks.toSet();
    }
    setState(() => _selections[_issueKey] = sel);
  }

  _Advice? _adviceOf(Map<String, dynamic> m) => _Advice.parse(m['advice']);

  Map<String, dynamic> _llmOf(Map<String, dynamic> m) {
    final value = m['llm'];
    return value is Map ? Map<String, dynamic>.from(value) : const {};
  }

  static const List<String> _llmModels = ['deepseek', 'kimi', 'gpt'];
  static const Color _doubleBlue = Color(0xFF3B6FB6);

  Color _adviceColor(String? style) => switch (style) {
    'banker' => gold,
    'double' => _doubleBlue,
    _ => muted,
  };

  String _modelName(String model) => switch (model) {
    'deepseek' => 'DeepSeek',
    'kimi' => 'Kimi',
    'gpt' => 'GPT',
    _ => model,
  };

  String _shortPick(String pick) => switch (pick) {
    'home' => '主',
    'draw' => '平',
    'away' => '客',
    _ => '-',
  };

  String _dateOnly(Object? value) {
    final s = value?.toString() ?? '';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  String _timeOnly(Object? value) {
    final s = value?.toString() ?? '';
    final i = s.indexOf(' ');
    return i >= 0 ? s.substring(i + 1) : '';
  }

  Future<void> _savePlan() async {
    final matches = _matches;
    final issue = _issue;
    if (issue == null) return;
    if (_expired || issue['status'] == 'closed') {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本期已截止，已为你刷新在售期次')));
      }
      await _load(force: true);
      return;
    }
    final selected = _selected;
    final legs = <Map<String, dynamic>>[];
    for (final m in matches) {
      final matchNum = (m['num'] as num?)?.toInt();
      final picks = selected[matchNum] ?? const <String>{};
      if (picks.isEmpty) continue;
      final home = m['home_team']?.toString() ?? '';
      final away = m['away_team']?.toString() ?? '';
      final league = m['league']?.toString() ?? '';
      final date = _dateOnly(m['date']);
      final model = m['model'];
      final modelTime = model is Map
          ? (model['match_time']?.toString() ?? '')
          : '';
      // The 传统足彩 feed only has the date; the 竞彩 board knows the kickoff.
      final time = modelTime.isNotEmpty ? modelTime : _timeOnly(m['date']);
      final modelId = model is Map ? (model['match_id']?.toString() ?? '') : '';
      final matchId = modelId.isNotEmpty
          ? modelId
          : 'local|$date|$league|$home|$away';
      final odds = m['odds'] is Map ? m['odds'] as Map : const {};
      for (final pick in picks) {
        legs.add({
          'match_id': matchId,
          'home_team': home,
          'away_team': away,
          'market': 'wdw',
          'pick': pick,
          'line': '',
          'odds': odds[pick]?.toString() ?? '',
          'label': pickLabel[pick] ?? pick,
          'match_date': date,
          'match_time': time,
          'league': league,
        });
      }
    }
    if (legs.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.client.post('/api/plans', {
        'title': '任九 第$_issueKey期',
        'play_type': 'renjiu',
        'stake': 2,
        'unit': 9,
        'multiple': _multiple,
        'legs': legs,
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已加入方案，可在「方案」页查看')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加入方案失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _lowestOddsPick(Map odds) {
    var pick = 'home';
    double? best;
    for (final key in const ['home', 'draw', 'away']) {
      final value = odds[key];
      final oddsValue = value is num ? value.toDouble() : null;
      if (oddsValue == null || oddsValue <= 0) continue;
      if (best == null || oddsValue < best) {
        best = oddsValue;
        pick = key;
      }
    }
    return pick;
  }

  /// Model probabilities when available, otherwise the odds-implied ones.
  Map<String, double> _probabilities(Map<String, dynamic> m) {
    final model = m['model'];
    if (model is Map) {
      final home = model['home_win'];
      final draw = model['draw'];
      final away = model['away_win'];
      if (home is num && draw is num && away is num) {
        return {
          'home': home.toDouble(),
          'draw': draw.toDouble(),
          'away': away.toDouble(),
        };
      }
    }
    final implied = m['implied'];
    if (implied is Map) {
      final out = <String, double>{};
      for (final key in const ['home', 'draw', 'away']) {
        final value = implied[key];
        if (value is num) out[key] = value.toDouble();
      }
      if (out.length == 3) return out;
    }
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _issues.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _issues.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => _load(force: true),
                    child: const Text('刷新'),
                  ),
                  OutlinedButton(
                    onPressed: _openHistory,
                    child: const Text('查看往期'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final matches = _matches;
    return Column(
      children: [
        _summaryCard(matches),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(force: true),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: [
                if (_notice != null && _notice!.isNotEmpty) _noticeBox(),
                ...matches.map(_matchCard),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryCard(List<Map<String, dynamic>> matches) {
    final issue = _issue;
    if (issue == null) return const SizedBox.shrink();
    final selected = _selected;
    final counts = [
      for (final m in matches)
        (selected[(m['num'] as num?)?.toInt()] ?? const <String>{}).length,
    ];
    final groupCount = counts.where((c) => c > 0).length;
    final bets = renjiuBets(counts);
    final amount = bets * 2 * _multiple;
    final prize = _lastDraw['prize'];
    final winners = _lastDraw['winners'];
    final bankers = matches
        .where((m) => _adviceOf(m)?.style == 'banker')
        .length;
    final doubles = matches
        .where((m) => _adviceOf(m)?.style == 'double')
        .length;
    final skips = matches.where((m) => _adviceOf(m)?.style == 'skip').length;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _issues.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          '第${_issues[i]['issue']}期'
                          '${_issueStatusLabel(_issues[i])}',
                        ),
                        selected: i == _issueIndex,
                        onSelected: (_) => setState(() => _issueIndex = i),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '截止 ${_when(issue['sale_end'])} · 开奖 ${_when(issue['draw_time'])}'
              '${_expired ? ' · 已截止' : ''}',
              style: TextStyle(
                color: _expired ? orange : muted,
                fontSize: 12,
                fontWeight: _expired ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
            Text(
              '数据更新于 ${_clockText(_sourceUpdatedAt > 0 ? _sourceUpdatedAt : _updatedAt)}',
              style: const TextStyle(color: muted, fontSize: 11),
            ),
            if (prize is num)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '上期 ${_lastDraw['issue'] ?? ''} 任九单注奖金 '
                  '${_intText(prize)} 元'
                  '${winners is num ? ' · ${_intText(winners)} 注中奖' : ''}',
                  style: const TextStyle(
                    color: gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const Divider(height: 18),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '已选 $groupCount 场',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (bankers + doubles + skips > 0) ...[
                  Text(
                    '稳胆 $bankers',
                    style: const TextStyle(
                      color: gold,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '复式 $doubles',
                    style: const TextStyle(
                      color: _doubleBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '不入流 $skips',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
                if (groupCount < 9)
                  Text(
                    '还需 ${9 - groupCount} 场',
                    style: const TextStyle(
                      color: orange,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  Text(
                    '共 $bets 注',
                    style: TextStyle(
                      color: bets > 0 ? green : muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text('金额 ${_intText(amount)} 元'),
                _multipleStepper(),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _recommend,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('按建议选 9 场'),
                ),
                FilledButton.icon(
                  onPressed: (bets > 0 && !_saving && !_expired)
                      ? _savePlan
                      : null,
                  icon: const Icon(Icons.playlist_add_check, size: 18),
                  label: Text(
                    _expired ? '已截止' : (_saving ? '保存中…' : '加入方案'),
                  ),
                ),
                TextButton.icon(
                  onPressed: groupCount == 0 ? null : _clear,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('清空'),
                ),
                TextButton.icon(
                  onPressed: () => _load(force: true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新'),
                ),
                TextButton.icon(
                  onPressed: _openHistory,
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('往期'),
                ),
              ],
            ),
            const Text(
              '任选 9 场，每场至少选一个结果；同场多选为复式，注数自动计算。'
              '稳胆/复式/不入流来自泊松与 DeepSeek、Kimi、GPT 的投票；'
              '任九为浮动奖，奖金以官方开奖为准（2 元/注）。',
              style: TextStyle(color: muted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _multipleStepper() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: _multiple > 1 ? () => setState(() => _multiple--) : null,
          icon: const Icon(Icons.remove_circle_outline, size: 20),
        ),
        Text(
          '$_multiple 倍',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: _multiple < 99 ? () => setState(() => _multiple++) : null,
          icon: const Icon(Icons.add_circle_outline, size: 20),
        ),
      ],
    );
  }

  Widget _noticeBox() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _notice!,
        style: const TextStyle(color: orange, fontSize: 12),
      ),
    );
  }

  Widget _matchCard(Map<String, dynamic> m) {
    final matchNum = (m['num'] as num?)?.toInt() ?? 0;
    final selected = _selected[matchNum] ?? const <String>{};
    final odds = m['odds'] is Map ? m['odds'] as Map : const {};
    final probs = _probabilities(m);
    final result = m['result']?.toString() ?? '';
    final score = m['score']?.toString() ?? '';
    final resultLabel = switch (result) {
      '3' => '主胜',
      '1' => '平局',
      '0' => '客胜',
      _ => '',
    };
    var maxProb = -1.0;
    for (final value in probs.values) {
      if (value > maxProb) maxProb = value;
    }
    final model = m['model'];
    final advice = _adviceOf(m);
    final llm = _llmOf(m);
    final adviceColor = _adviceColor(advice?.style);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: advice != null && advice.style != 'skip'
            ? BorderSide(color: adviceColor.withValues(alpha: 0.55), width: 1.2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEF4F1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$matchNum',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${m['league'] ?? ''} · ${m['date'] ?? ''}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ),
                if (advice != null)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: adviceColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      advice.available > 0
                          ? '${advice.label} · ${advice.available}源'
                          : advice.label,
                      style: TextStyle(
                        color: adviceColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (resultLabel.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '赛果 ${score.isNotEmpty ? '$score ' : ''}$resultLabel',
                      style: const TextStyle(
                        color: green,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${m['home_team'] ?? ''}  vs  ${m['away_team'] ?? ''}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (probs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${model is Map ? '泊松模型' : '赔率隐含'} '
                  '主 ${pct(probs['home']!)} · '
                  '平 ${pct(probs['draw']!)} · 客 ${pct(probs['away']!)}'
                  '${model is Map && model['market_blended'] == true ? '（市场校准）' : ''}',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ),
            if (probs.isNotEmpty || llm.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (probs.isNotEmpty)
                      _sourceChip(model is Map ? '泊松' : '赔率', _topPick(probs)),
                    for (final name in _llmModels)
                      _sourceChip(_modelName(name), _llmPick(llm, name)),
                  ],
                ),
              ),
            if (advice != null && advice.reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  advice.reason,
                  style: TextStyle(color: adviceColor, fontSize: 10),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                _optionCell(
                  label: '主胜',
                  odds: _odds(odds['home']),
                  prob: probs['home'],
                  favorite: probs['home'] != null && probs['home'] == maxProb,
                  advised: advice?.picks.contains('home') ?? false,
                  adviceColor: adviceColor,
                  selected: selected.contains('home'),
                  onTap: () => _toggle(matchNum, 'home'),
                ),
                const SizedBox(width: 6),
                _optionCell(
                  label: '平局',
                  odds: _odds(odds['draw']),
                  prob: probs['draw'],
                  favorite: probs['draw'] != null && probs['draw'] == maxProb,
                  advised: advice?.picks.contains('draw') ?? false,
                  adviceColor: adviceColor,
                  selected: selected.contains('draw'),
                  onTap: () => _toggle(matchNum, 'draw'),
                ),
                const SizedBox(width: 6),
                _optionCell(
                  label: '客胜',
                  odds: _odds(odds['away']),
                  prob: probs['away'],
                  favorite: probs['away'] != null && probs['away'] == maxProb,
                  advised: advice?.picks.contains('away') ?? false,
                  adviceColor: adviceColor,
                  selected: selected.contains('away'),
                  onTap: () => _toggle(matchNum, 'away'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _topPick(Map<String, double> probs) {
    var pick = '';
    var best = -1.0;
    probs.forEach((key, value) {
      if (value > best) {
        best = value;
        pick = key;
      }
    });
    return pick;
  }

  String? _llmPick(Map<String, dynamic> llm, String model) {
    final entry = llm[model];
    if (entry is! Map) return null;
    final pick = entry['pick']?.toString() ?? '';
    return const {'home', 'draw', 'away'}.contains(pick) ? pick : null;
  }

  Widget _sourceChip(String name, String? pick) {
    final hasPick = pick != null && pick.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$name ${hasPick ? _shortPick(pick) : '-'}',
        style: TextStyle(
          fontSize: 10,
          color: hasPick ? const Color(0xFF17211F) : muted,
          fontWeight: hasPick ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
  }

  Widget _optionCell({
    required String label,
    required double? odds,
    double? prob,
    required bool favorite,
    required bool advised,
    required Color adviceColor,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = selected
        ? red
        : (advised ? adviceColor : (favorite ? gold : const Color(0xFFE3E9E3)));
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? red
                : (advised
                      ? adviceColor.withValues(alpha: 0.12)
                      : (favorite
                            ? gold.withValues(alpha: 0.10)
                            : Colors.white)),
            border: Border.all(
              color: accent,
              width: (selected || advised) ? 1.4 : 0.8,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : const Color(0xFF17211F),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                odds == null ? '-' : odds.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : muted,
                ),
              ),
              if (prob != null)
                Text(
                  pct(prob),
                  style: TextStyle(
                    fontSize: 10,
                    color: selected ? Colors.white70 : muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  double? _odds(dynamic value) => value is num ? value.toDouble() : null;

  String _when(Object? value) {
    final s = value?.toString() ?? '';
    return s.length >= 16 ? s.substring(5, 16) : s;
  }

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

/// 稳胆 / 复式 / 不入流 recommendation from 泊松 + DeepSeek / Kimi / GPT votes.
class _Advice {
  const _Advice({
    required this.style,
    required this.label,
    required this.picks,
    required this.reason,
    required this.available,
    required this.confidence,
  });

  final String style, label, reason;
  final List<String> picks;
  final int available;
  final double confidence;

  static _Advice? parse(dynamic value) {
    if (value is! Map) return null;
    final style = value['style']?.toString() ?? '';
    if (style.isEmpty) return null;
    final picks = value['picks'] is List
        ? (value['picks'] as List)
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    return _Advice(
      style: style,
      label: value['label']?.toString() ?? '',
      picks: picks,
      reason: value['reason']?.toString() ?? '',
      available: value['available'] is num
          ? (value['available'] as num).toInt()
          : 0,
      confidence: value['confidence'] is num
          ? (value['confidence'] as num).toDouble()
          : 0.0,
    );
  }
}
