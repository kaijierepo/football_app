import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'config.dart';
import 'draft.dart';
import 'models.dart';
import 'pages/draft_page.dart';
import 'pages/history_page.dart';
import 'pages/llm_page.dart';
import 'pages/plans_page.dart';
import 'pages/predict_page.dart';
import 'pages/renjiu_page.dart';
import 'pages/settings_page.dart';
import 'update.dart';
import 'widgets.dart';

void main() {
  runApp(const FootballApp());
}

class FootballApp extends StatelessWidget {
  const FootballApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '竞彩足球',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: green),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF3F6EF),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF17211F),
          elevation: 0,
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _seenWinsKey = 'seen_won_plan_ids';

  AppConfig? _config;
  ApiClient? _client;
  int _index = 0;
  Timer? _winsTimer;
  List<Plan> _wonPlans = [];
  Set<String> _seenWins = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _winsTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final config = await AppConfig.load();
    setState(() {
      _config = config;
      _client = ApiClient(config);
    });
    _loadSeenWins();
    _refreshWins();
    _winsTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _refreshWins(),
    );
    // Silent update check on launch; tapping the action opens Settings.
    UpdateService.check().then<void>((info) {
      if (!mounted || info == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('发现新版本 ${info.display}'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: '去更新',
          onPressed: () {
            if (mounted) setState(() => _index = 5);
          },
        ),
      ));
    }).catchError((Object _) {});
  }

  Future<void> _loadSeenWins() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _seenWins = (prefs.getStringList(_seenWinsKey) ?? const []).toSet();
    });
  }

  Future<void> _saveSeenWins() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_seenWinsKey, _seenWins.toList());
  }

  /// Won plans feed the bell badge; read state is device-local and pruned to
  /// the plans that still exist.
  Future<void> _refreshWins() async {
    final client = _client;
    if (client == null) return;
    try {
      final data = await client.get('/api/plans');
      final won = (data['plans'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
          .where((p) => p.status == 'won')
          .toList();
      if (!mounted) return;
      final ids = won.map((p) => p.id).toSet();
      final before = _seenWins.length;
      setState(() {
        _wonPlans = won;
        _seenWins.removeWhere((id) => !ids.contains(id));
      });
      if (_seenWins.length != before) await _saveSeenWins();
    } catch (_) {
      // Offline: keep the last known badge instead of clearing it.
    }
  }

  int get _unreadWins =>
      _wonPlans.where((p) => !_seenWins.contains(p.id)).length;

  void _openWins() {
    final unread = _wonPlans
        .where((p) => !_seenWins.contains(p.id))
        .map((p) => p.id)
        .toSet();
    if (_wonPlans.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂无中奖方案')));
      return;
    }
    // Opening the sheet marks everything read.
    if (unread.isNotEmpty) {
      setState(() => _seenWins.addAll(unread));
      _saveSeenWins();
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _WinsSheet(
        plans: _wonPlans,
        unreadIds: unread,
        onOpenPlans: () {
          Navigator.of(context).pop();
          setState(() => _index = 3);
        },
      ),
    );
  }

  Future<void> _reloadConfig() async {
    final config = await AppConfig.load();
    setState(() {
      _config = config;
      _client = ApiClient(config);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_config == null || _client == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final pages = [
      PredictPage(client: _client!),
      RenjiuPage(client: _client!),
      HistoryPage(client: _client!),
      PlansPage(client: _client!),
      LlmPage(client: _client!),
      SettingsPage(
        config: _config!,
        client: _client!,
        onSaved: _reloadConfig,
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          ListenableBuilder(
            listenable: draft,
            builder: (_, _) => Badge(
              isLabelVisible: draft.count > 0,
              label: Text('${draft.count}'),
              child: IconButton(
                onPressed: () async {
                  final saved = await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DraftPage(client: _client!)));
                  if (saved == true && mounted) setState(() => _index = 3);
                },
                icon: const Icon(Icons.receipt_long),
              ),
            ),
          ),
          IconButton(
            tooltip: '中奖通知',
            onPressed: _openWins,
            icon: Badge(
              isLabelVisible: _unreadWins > 0,
              label: Text('$_unreadWins'),
              child: Icon(
                _unreadWins > 0
                    ? Icons.notifications_active
                    : Icons.notifications_outlined,
                color: _unreadWins > 0 ? red : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.insights), label: '预测'),
          NavigationDestination(icon: Icon(Icons.grid_view), label: '任九'),
          NavigationDestination(icon: Icon(Icons.history), label: '历史'),
          NavigationDestination(icon: Icon(Icons.receipt_long), label: '方案'),
          NavigationDestination(icon: Icon(Icons.smart_toy), label: '模型'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

const List<String> _titles = ['今日预测', '任九选场', '历史记录', '我的方案', '模型推荐', '设置'];

/// Bottom sheet behind the bell: one row per won plan, unread ones highlighted.
class _WinsSheet extends StatelessWidget {
  const _WinsSheet({
    required this.plans,
    required this.unreadIds,
    required this.onOpenPlans,
  });

  final List<Plan> plans;
  final Set<String> unreadIds;
  final VoidCallback onOpenPlans;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emoji_events, color: gold, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '中奖通知',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${plans.length} 个',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: plans.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = plans[i];
                  final unread = unreadIds.contains(p.id);
                  final amount = p.payout.returnAmount;
                  final text = amount != null
                      ? '中奖 ${amount.toStringAsFixed(2)} 元'
                      : (p.payout.floating ? '任九浮动奖，以官方开奖为准' : '已中奖');
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.emoji_events,
                      size: 20,
                      color: unread ? red : muted,
                    ),
                    title: Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight:
                            unread ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      '${p.createdAt} · $text',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: unread
                        ? Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: red,
                              shape: BoxShape.circle,
                            ),
                          )
                        : null,
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onOpenPlans,
                child: const Text('查看全部方案'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
