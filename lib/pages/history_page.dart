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
  bool _syncing = false;
  String? _error;
  Map<String, dynamic> _data = {};
  String? _selectedDate;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _today {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final mo = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$mo-$d';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.client.get('/api/history');
      setState(() {
        _data = data;
        _selectedDate = _pickDefault(data['dates'] as List? ?? const []);
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
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

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      await widget.client.post('/api/history/sync');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('同步失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _load();
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
    final dates = (_data['dates'] as List? ?? const []).whereType<Map>().toList();
    final sync = _data['sync'] as Map<String, dynamic>? ?? const {};
    final current = dates.firstWhere(
      (d) => d['date'] == _selectedDate,
      orElse: () => dates.isEmpty ? {} : dates.first,
    );
    final matches = (current['matches'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '已检查 ${sync['checked'] ?? 0} 场 · 同步 ${sync['updated'] ?? 0} 场',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
              FilledButton.tonal(
                onPressed: _syncing ? null : _sync,
                child: Text(_syncing ? '同步中…' : '同步赛果'),
              ),
            ],
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
    final String statusText = finished ? '已结束' : (started ? '进行中' : '未开赛');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => HistoryDetailPage(
                client: widget.client, match: Match.fromJson(m)))),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(statusText,
                        style: TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
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
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(
                      child:
                          _centerScore(m, finished, started, home, away, hh, ah)),
                  Expanded(
                    child: Text(
                      m['away_team']?.toString() ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
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

  Widget _centerScore(Map<String, dynamic> m, bool finished, bool started,
      int? home, int? away, int? hh, int? ah) {
    if ((finished || started) && home != null && away != null) {
      final Color color = finished ? green : orange;
      return Column(
        children: [
          Text('$home - $away',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: color)),
          if (hh != null && ah != null)
            Text('半场 $hh - $ah',
                style: const TextStyle(color: muted, fontSize: 11)),
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
}
