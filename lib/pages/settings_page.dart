import 'package:flutter/material.dart';

import '../config.dart';
import '../update.dart';
import '../widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.config, required this.onSaved});

  final AppConfig config;
  final VoidCallback onSaved;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('服务器地址',
            style: TextStyle(fontWeight: FontWeight.w700)),
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
        const Text('API Token（读写鉴权）',
            style: TextStyle(fontWeight: FontWeight.w700)),
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
        const SizedBox(height: 24),
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
