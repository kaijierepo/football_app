import 'package:flutter/material.dart';

import '../api_client.dart';
import '../config.dart';
import '../models.dart';
import '../update.dart';
import '../widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.client,
    required this.onSaved,
  });

  final AppConfig config;
  final ApiClient client;
  final VoidCallback onSaved;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _PnlCalendar(client: widget.client),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text(
              '服务器与 API Token',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              widget.config.server,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _ServerConfigPage(
                    config: widget.config,
                    onSaved: widget.onSaved,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
        ),
        const SizedBox(height: 16),
        const _UpdateCard(),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFEEF4F1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '说明：\n'
            '· 服务端启动命令：.venv\\Scripts\\python.exe web_app.py\n'
            '· 局域网地址见服务端启动日志（绑定 0.0.0.0）。\n'
            '· 读和写请求（赛事/历史/方案/预测）都会带上 token。\n'
            '· 浏览器端可用 http://服务器地址:端口/?token=你的token 自动登录。',
            style: TextStyle(color: muted, fontSize: 12, height: 1.6),
          ),
        ),
      ],
    );
  }
}

/// 按月统计每天的方案盈亏：红色=盈利（已扣除购票成本），绿色=亏损。
class _PnlCalendar extends StatefulWidget {
  const _PnlCalendar({required this.client});

  final ApiClient client;

  @override
  State<_PnlCalendar> createState() => _PnlCalendarState();
}

class _PnlCalendarState extends State<_PnlCalendar> {
  bool _loading = true;
  String? _error;
  List<Plan> _plans = [];
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.client.get('/api/plans');
      final plans = (data['plans'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Plan.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _dayKey(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _amount(double v) {
    final a = v.abs();
    final text = a >= 100 || a == a.roundToDouble()
        ? a.round().toString()
        : a.toStringAsFixed(1);
    return '${v >= 0 ? '+' : '-'}$text';
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final byDay = <String, double>{};
    for (final p in _plans) {
      final profit = p.payout.profit;
      if (profit == null) continue;
      final dt = DateTime.tryParse(p.createdAt.replaceFirst(' ', 'T'));
      if (dt == null) continue;
      final key = _dayKey(dt);
      byDay[key] = (byDay[key] ?? 0) + profit;
    }
    final prefix = '${_month.year}-${_two(_month.month)}';
    var monthTotal = 0.0;
    byDay.forEach((key, value) {
      if (key.startsWith(prefix)) monthTotal += value;
    });

    final first = DateTime(_month.year, _month.month, 1);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = first.weekday - 1;
    final cells = <Widget>[
      for (var i = 0; i < lead; i++) const SizedBox(),
      for (var d = 1; d <= days; d++)
        _dayCell(d, byDay[_dayKey(DateTime(_month.year, _month.month, d))]),
    ];
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox());
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD8E1D7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month, size: 18),
              const SizedBox(width: 6),
              const Text(
                '盈亏日历',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${_month.year}年${_month.month}月',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '加载失败：$_error',
                style: const TextStyle(color: red, fontSize: 12),
              ),
            )
          else ...[
            Row(
              children: [
                for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            for (var r = 0; r < cells.length; r += 7)
              Row(
                children: [
                  for (var i = r; i < r + 7; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(1.5),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: cells[i],
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text(
                  '本月盈亏',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const Spacer(),
                Text(
                  '${monthTotal >= 0 ? '+' : '-'}'
                  '${monthTotal.abs().toStringAsFixed(2)} 元',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: monthTotal > 0
                        ? red
                        : monthTotal < 0
                        ? green
                        : muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '红色=盈利（已扣除购票成本），绿色=亏损；待开奖方案不计入。',
              style: TextStyle(color: muted, fontSize: 11, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dayCell(int day, double? profit) {
    final positive = profit != null && profit > 0.005;
    final negative = profit != null && profit < -0.005;
    final color = positive ? red : negative ? green : muted;
    final bg = positive
        ? red.withValues(alpha: 0.14)
        : negative
        ? green.withValues(alpha: 0.14)
        : const Color(0xFFF7F9F6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE3E9E3), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$day', style: const TextStyle(color: muted, fontSize: 10)),
          const Spacer(),
          if (positive || negative)
            Text(
              _amount(profit),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

/// 服务器地址 / API Token 的编辑页，从设置列表进入。
class _ServerConfigPage extends StatefulWidget {
  const _ServerConfigPage({required this.config, required this.onSaved});

  final AppConfig config;
  final VoidCallback onSaved;

  @override
  State<_ServerConfigPage> createState() => _ServerConfigPageState();
}

class _ServerConfigPageState extends State<_ServerConfigPage> {
  late final TextEditingController _serverCtrl;
  late final TextEditingController _tokenCtrl;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.config.server);
    _tokenCtrl = TextEditingController(text: widget.config.token);
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    widget.config.server = _serverCtrl.text.trim();
    widget.config.token = _tokenCtrl.text.trim();
    await widget.config.save();
    widget.onSaved();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '服务器地址',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _serverCtrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'http://192.168.1.100:8000',
              helperText: '手机需与电脑在同一 Wi-Fi；部署公网后填公网域名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'API Token（读写鉴权）',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _tokenCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              hintText: '服务端 data/config.json 里的 api_token',
              helperText: '留空表示服务端未启用鉴权',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存设置'),
          ),
        ],
      ),
    );
  }
}

/// Shows the installed version and lets the user pull updates from the
/// GitHub release published by CI.
class _UpdateCard extends StatefulWidget {
  const _UpdateCard();

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  AppVersion? _current;
  UpdateInfo? _update;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    UpdateService.currentVersion().then((v) {
      if (mounted) setState(() => _current = v);
    });
    _check(silent: true);
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking || _downloading) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final info = await UpdateService.check();
      if (!mounted) return;
      setState(() => _update = info);
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(info == null ? '已是最新版本' : '发现新版本 ${info.display}'),
        ));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '检查更新失败，请检查网络（需要能访问 GitHub）');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    final info = _update;
    if (info == null || _downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await UpdateService.download(
        info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      final error = await UpdateService.install(file);
      if (!mounted) return;
      if (error != null) {
        setState(() => _error = '安装未完成：$error\n如未弹出安装界面，请在系统设置里允许本应用「安装未知应用」。');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '下载失败：$e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final update = _update;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD8E1D7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt, size: 18),
              const SizedBox(width: 6),
              Text('应用版本',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(_current?.display ?? '读取中…',
                  style: const TextStyle(color: muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 10),
          if (update != null) ...[
            Text('发现新版本 ${update.display}',
                style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            if (update.notes.trim().isNotEmpty)
              Text(
                update.notes.trim().split('\n').take(6).join('\n'),
                style: const TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
            const SizedBox(height: 10),
            if (_downloading) ...[
              LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null),
              const SizedBox(height: 4),
              Text('正在下载 ${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: muted, fontSize: 12)),
            ] else
              FilledButton.icon(
                onPressed: _downloadAndInstall,
                icon: const Icon(Icons.download),
                label: Text('下载并安装 ${update.display}'),
              ),
          ] else
            OutlinedButton.icon(
              onPressed: _checking ? null : () => _check(),
              icon: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: Text(_checking ? '检查中…' : '检查更新'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(
                    color: Color(0xFFC0392B), fontSize: 12, height: 1.5)),
          ],
        ],
      ),
    );
  }
}
