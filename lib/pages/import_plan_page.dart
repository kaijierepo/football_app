import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api_client.dart';
import '../widgets.dart';

/// 竞彩截图导入（异步）：相册批量选图 -> 上传 -> 服务端后台 OCR -> 自动生成方案。
///
/// 不再展示可编辑预览，也不等待识别结果：全部图片一次提交后立刻返回，
/// 识别和按场次号匹配赛程都在服务端后台完成，识别完成时方案自动落库。
/// 返回给方案页的是后台任务 id，方案页据此轮询任务状态并刷新列表。
class ImportPlanPage extends StatefulWidget {
  const ImportPlanPage({super.key, required this.client});

  final ApiClient client;

  @override
  State<ImportPlanPage> createState() => _ImportPlanPageState();
}

class _ImportPlanPageState extends State<ImportPlanPage> {
  bool _uploading = false;
  String? _error;

  Future<void> _pick() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final images = <String>[];
      for (final file in picked) {
        images.add(base64Encode(await file.readAsBytes()));
      }
      final data = await widget.client.post('/api/plans/import', {
        'images': images,
      });
      final job = data['job'];
      final jobId = job is Map ? '${job['id'] ?? ''}' : '';
      if (!mounted) return;
      Navigator.of(context).pop(jobId.isEmpty ? null : jobId);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '提交失败：$e');
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('截图导入')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_scanner, size: 64, color: muted),
              const SizedBox(height: 14),
              const Text(
                '选择竞彩「已选」截图（可一次多选），\n提交后在后台自动识别并生成方案，无需等待。',
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
                onPressed: _uploading ? null : _pick,
                icon: _uploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library_outlined),
                label: Text(_uploading ? '上传中…' : '选择截图并提交'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
