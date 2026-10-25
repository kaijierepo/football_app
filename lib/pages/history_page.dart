import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets.dart';
import 'history_detail_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = {};
  String? _selectedDate;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // In-play scores and the match clock are refreshed every minute; the
    // backend also settles them on every /api/history read.
    _liveTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  String get _today {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final mo = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$mo-$d';
  }

  Future<void> _load({bool silent = false, bool forceLive = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.client.get(
        '/api/history${forceLive ? '?refresh=1' : ''}',
      );
      if (!mounted) return;
      final dates = (data['dates'] as List? ?? const []).whereType<Map>();
      final available = dates.map((d) => d['date']?.toString()).toSet();
      setState(() {
        _data = data;
        // Keep the user's chosen date across auto/pull refreshes.
        if (_selectedDate == null || !available.contains(_selectedDate)) {
          _selectedDate = _pickDefault(data['dates'] as List? ?? const []);
        }
      });
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e.toString());
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
    }
  }

  String? _pickDefault(List dates) {
    if (dates.isEmpty) return null;
    final today = _today;
    for (final d in dates) {
      if (d is Map && d['date'] == today) return today;
    }
    return dates.first is Map ? (dates.first as Map)['date']?.toString() : null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
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
      );
    }
    final dates = (_data['dates'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final current = dates.firstWhere(
      (d) => d['date'] == _selectedDate,
      orElse: () => dates.isEmpty ? {} : dates.first,
    );
    final matches = (current['matches'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return RefreshIndicator(
      // Pull to refresh also forces an immediate in-play score sync.
      onRefresh: () => _load(silent: true, forceLive: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            '进行中的比赛每 1 分钟自动更新比分和比赛时间，下拉可立即刷新。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (dates.isNotEmpty) _dateChips(dates),
          const SizedBox(height: 8),
          if (matches.isEmpty)
            const EmptyBox('当天暂无赛事。')
          else
            ...matches.map(_matchRow),
        ],
      ),
    );
  }

  Widget _dateChips(List<Map> dates) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: dates.map((d) {
          final date = d['date']?.toString() ?? '';
          final selected = date == _selectedDate;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(date),
              selected: selected,
              onSelected: (_) => setState(() => _selectedDate = date),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _matchRow(Map<String, dynamic> m) {
    final finished = m['finished'] == true;
    final started = m['started'] == true;
    final home = _goal(m['home_goals']);
    final away = _goal(m['away_goals']);
    final hh = _goal(m['home_ht_goals']);
    final ah = _goal(m['away_ht_goals']);

    final Color accent = finished
        ? green
        : started
        ? orange
        : muted;
    final String statusText = finished
        ? '已结束'
        : (started ? _liveLabel(m['live_status'], m['live_elapsed']) : '未开赛');

    return Card(
      // Stable key lets a refresh update this row in place instead of
      // rebuilding the whole list when in-play matches reorder.
      key: ValueKey(
        m['id']?.toString() ?? '${m['match_num']}-${m['home_team']}',
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => HistoryDetailPage(
              client: widget.client,
              match: Match.fromJson(m),
            ),
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
                      '${m['match_num'] ?? '-'} · ${m['league'] ?? ''}',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      statusText,
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: muted),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      m['home_team']?.toString() ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _centerScore(
                      m,
                      finished,
                      started,
                      home,
                      away,
                      hh,
                      ah,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      m['away_team']?.toString() ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      m['match_time']?.toString() ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _centerScore(
    Map<String, dynamic> m,
    bool finished,
    bool started,
    int? home,
    int? away,
    int? hh,
    int? ah,
  ) {
    if ((finished || started) && home != null && away != null) {
      final Color color = finished ? green : orange;
      return Column(
        children: [
          Text(
            '$home - $away',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          if (hh != null && ah != null)
            Text(
              '半场 $hh - $ah',
              style: const TextStyle(color: muted, fontSize: 11),
            ),
        ],
      );
    }
    return const Column(
      children: [
        Text('VS', style: TextStyle(color: muted, fontSize: 14)),
        Text('—', style: TextStyle(color: muted, fontSize: 16)),
      ],
    );
  }

  int? _goal(dynamic v) => v is num ? v.toInt() : null;

  /// Human-readable phase + elapsed minute for an in-play match.
  String _liveLabel(dynamic status, dynamic elapsed) {
    final code = (status ?? '').toString().toUpperCase();
    final minute = elapsed is num ? elapsed.toInt() : null;
    final clock = minute == null ? '' : "$minute'";
    return switch (code) {
      'HT' => '中场',
      'BT' => '加时中场',
      'P' => '点球大战',
      'SUSP' => '暂停',
      'INT' => '中断',
      'ET' => clock.isEmpty ? '加时' : '加时 $clock',
      '1H' => clock.isEmpty ? '上半场' : '上半场 $clock',
      '2H' => clock.isEmpty ? '下半场' : '下半场 $clock',
      _ => clock.isEmpty ? '进行中' : '进行中 $clock',
    };
  }
}
