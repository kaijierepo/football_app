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

  void _toggle(int num, String pick) {
    setState(() {
      final sel = _selections.putIfAbsent(_issueKey, () => {});
      final set = sel.putIfAbsent(num, () => <String>{});
      if (!set.add(pick)) set.remove(pick);
      if (set.isEmpty) sel.remove(num);
    });
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

  /// 顶部只保留三件事：选期、智能选择、加入方案，留出更多高度给 14 场列表。
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
    final canSave =
        bets > 0 && !_saving && !_expired && issue['status'] != 'closed';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < _issues.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                '第${_issues[i]['issue']}期'
                                '${_issueStatusLabel(_issues[i])}',
                              ),
                              selected: i == _issueIndex,
                              onSelected: (_) =>
                                  setState(() => _issueIndex = i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '往期开奖',
                  onPressed: _openHistory,
                  icon: const Icon(Icons.history, size: 20),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: _recommend,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('智能选择', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: canSave ? _saveFlow : null,
                      icon: const Icon(Icons.playlist_add_check, size: 16),
                      label: Text(
                        _expired || issue['status'] == 'closed'
                            ? '已截止'
                            : (_saving ? '保存中…' : '加入方案'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (groupCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  groupCount < 9
                      ? '已选 $groupCount 场 · 还需 ${9 - groupCount} 场'
                      : '已选 $groupCount 场 · $bets 注 · ${_intText(amount)} 元'
                            '${_multiple > 1 ? '（$_multiple 倍）' : ''}',
                  style: TextStyle(
                    color: groupCount < 9 ? orange : green,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 加入方案前确认倍数（倍数不再常驻首屏）。
  Future<void> _saveFlow() async {
    final selected = _selected;
    final counts = [
      for (final m in _matches)
        (selected[(m['num'] as num?)?.toInt()] ?? const <String>{}).length,
    ];
    final bets = renjiuBets(counts);
    var multiple = _multiple;
    final ok = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('加入方案'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共 $bets 注 · 单倍 ${_intText(bets * 2)} 元',
                style: const TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: multiple > 1
                        ? () => setDialogState(() => multiple--)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text(
                    '$multiple 倍',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  IconButton(
                    onPressed: multiple < 99
                        ? () => setDialogState(() => multiple++)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '合计 ${_intText(bets * 2 * multiple)} 元',
                style: const TextStyle(
                  color: red,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(multiple),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (ok == null) return;
    setState(() => _multiple = ok);
    await _savePlan();
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

  /// 紧凑一场：场次 + 对阵 + 稳胆/复式/不入流 + 三个选项；点卡片看 AI 详情。
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
    final advice = _adviceOf(m);
    final adviceColor = _adviceColor(advice?.style);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: advice != null && advice.style != 'skip'
            ? BorderSide(color: adviceColor.withValues(alpha: 0.55), width: 1.2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () => _openMatchDetail(m),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _numBadge(matchNum),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${m['home_team'] ?? ''}  vs  ${m['away_team'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (advice != null) _advicePill(advice, adviceColor),
                  if (resultLabel.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _resultPill(score, resultLabel),
                  ],
                  const Icon(Icons.chevron_right, size: 16, color: muted),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _miniOptionCell(
                    label: '主胜',
                    odds: _odds(odds['home']),
                    favorite: probs['home'] != null && probs['home'] == maxProb,
                    advised: advice?.picks.contains('home') ?? false,
                    adviceColor: adviceColor,
                    selected: selected.contains('home'),
                    onTap: () => _toggle(matchNum, 'home'),
                  ),
                  const SizedBox(width: 6),
                  _miniOptionCell(
                    label: '平局',
                    odds: _odds(odds['draw']),
                    favorite: probs['draw'] != null && probs['draw'] == maxProb,
                    advised: advice?.picks.contains('draw') ?? false,
                    adviceColor: adviceColor,
                    selected: selected.contains('draw'),
                    onTap: () => _toggle(matchNum, 'draw'),
                  ),
                  const SizedBox(width: 6),
                  _miniOptionCell(
                    label: '客胜',
                    odds: _odds(odds['away']),
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
      ),
    );
  }

  Widget _numBadge(int matchNum) => Container(
    width: 22,
    height: 22,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFFEEF4F1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      '$matchNum',
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
    ),
  );

  Widget _advicePill(_Advice advice, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      advice.label,
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _resultPill(String score, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: green.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      '赛果 ${score.isNotEmpty ? '$score ' : ''}$label',
      style: const TextStyle(
        color: green,
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  /// 列表里的短选项格：只有「主胜 2.10」，高度固定。
  Widget _miniOptionCell({
    required String label,
    required double? odds,
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
        borderRadius: BorderRadius.circular(7),
        child: Container(
          height: 34,
          alignment: Alignment.center,
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
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : const Color(0xFF17211F),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                odds == null ? '-' : odds.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单场详情：被收起的 AI 推荐（概率、各家模型、理由）和解说放这里。
  void _openMatchDetail(Map<String, dynamic> m) {
    final matchNum = (m['num'] as num?)?.toInt() ?? 0;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final selected = _selected[matchNum] ?? const <String>{};
          final odds = m['odds'] is Map ? m['odds'] as Map : const {};
          final probs = _probabilities(m);
          final model = m['model'];
          final advice = _adviceOf(m);
          final llm = _llmOf(m);
          final adviceColor = _adviceColor(advice?.style);
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
          void pick(String value) {
            _toggle(matchNum, value);
            setSheetState(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD8E1D7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _numBadge(matchNum),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${m['league'] ?? ''} · ${m['date'] ?? ''}',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ),
                      if (resultLabel.isNotEmpty)
                        _resultPill(score, resultLabel),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${m['home_team'] ?? ''}  vs  ${m['away_team'] ?? ''}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (advice != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _advicePill(advice, adviceColor),
                        if (advice.available > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              '${advice.available} 个来源同意',
                              style: const TextStyle(color: muted, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                    if (advice.reason.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          advice.reason,
                          style: TextStyle(color: adviceColor, fontSize: 12),
                        ),
                      ),
                  ],
                  if (probs.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '${model is Map ? '泊松模型' : '赔率隐含'} '
                      '主 ${pct(probs['home']!)} · '
                      '平 ${pct(probs['draw']!)} · 客 ${pct(probs['away']!)}'
                      '${model is Map && model['market_blended'] == true ? '（市场校准）' : ''}',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                  if (probs.isNotEmpty || llm.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (probs.isNotEmpty)
                          _sourceChip(
                            model is Map ? '泊松' : '赔率',
                            _topPick(probs),
                          ),
                        for (final name in _llmModels)
                          _sourceChip(_modelName(name), _llmPick(llm, name)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _optionCell(
                        label: '主胜',
                        odds: _odds(odds['home']),
                        prob: probs['home'],
                        favorite:
                            probs['home'] != null && probs['home'] == maxProb,
                        advised: advice?.picks.contains('home') ?? false,
                        adviceColor: adviceColor,
                        selected: selected.contains('home'),
                        onTap: () => pick('home'),
                      ),
                      const SizedBox(width: 6),
                      _optionCell(
                        label: '平局',
                        odds: _odds(odds['draw']),
                        prob: probs['draw'],
                        favorite:
                            probs['draw'] != null && probs['draw'] == maxProb,
                        advised: advice?.picks.contains('draw') ?? false,
                        adviceColor: adviceColor,
                        selected: selected.contains('draw'),
                        onTap: () => pick('draw'),
                      ),
                      const SizedBox(width: 6),
                      _optionCell(
                        label: '客胜',
                        odds: _odds(odds['away']),
                        prob: probs['away'],
                        favorite:
                            probs['away'] != null && probs['away'] == maxProb,
                        advised: advice?.picks.contains('away') ?? false,
                        adviceColor: adviceColor,
                        selected: selected.contains('away'),
                        onTap: () => pick('away'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '点击选项选中或取消；同场多选为复式。',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
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
