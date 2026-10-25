import 'package:flutter/material.dart';

import 'api_client.dart';
import 'config.dart';
import 'draft.dart';
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
  AppConfig? _config;
  ApiClient? _client;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final config = await AppConfig.load();
    setState(() {
      _config = config;
      _client = ApiClient(config);
    });
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
      SettingsPage(config: _config!, onSaved: _reloadConfig),
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
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                _config!.baseUrl,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            ),
          ),
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
