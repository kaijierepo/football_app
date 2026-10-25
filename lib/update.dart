import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// GitHub release-based self-update.
///
/// CI publishes every build as a release tagged `v<version>-<buildNumber>`
/// (e.g. `v1.0.1-2`), matching `version:` in pubspec.yaml. The app compares
/// the release's build number with its own `versionCode` and downloads the
/// APK asset when a newer build exists.
const String appRepo = 'kaijierepo/football_app';
const String _latestReleaseApi =
    'https://api.github.com/repos/$appRepo/releases/latest';
const String _userAgent = 'football-app-android';

class AppVersion {
  const AppVersion(this.version, this.buildNumber);

  final String version;
  final int buildNumber;

  String get display => 'v$version ($buildNumber)';
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.tag,
    required this.apkUrl,
    required this.notes,
  });

  final String version;
  final int buildNumber;
  final String tag;
  final String apkUrl;
  final String notes;

  String get display => 'v$version';
}

class UpdateService {
  static PackageInfo? _info;

  static Future<AppVersion> currentVersion() async {
    final info = _info ??= await PackageInfo.fromPlatform();
    return AppVersion(info.version, int.tryParse(info.buildNumber) ?? 0);
  }

  /// Latest release newer than this build, or null when up to date / offline.
  static Future<UpdateInfo?> check() async {
    final current = await currentVersion();
    final resp = await http.get(
      Uri.parse(_latestReleaseApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': _userAgent,
      },
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;

    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final tag = (data['tag_name'] ?? '').toString();
    final match = RegExp(r'^v?(\d+\.\d+\.\d+)(?:[-+](\d+))?$').firstMatch(tag);
    if (match == null) return null;

    final remote = AppVersion(
      match.group(1)!,
      int.tryParse(match.group(2) ?? '') ?? 0,
    );
    if (remote.buildNumber <= current.buildNumber) return null;

    String? apkUrl;
    for (final asset in (data['assets'] as List? ?? const [])) {
      if (asset is! Map) continue;
      final name = (asset['name'] ?? '').toString().toLowerCase();
      if (name.endsWith('.apk')) {
        apkUrl = (asset['browser_download_url'] ?? '').toString();
        break;
      }
    }
    if (apkUrl == null || apkUrl.isEmpty) return null;

    return UpdateInfo(
      version: remote.version,
      buildNumber: remote.buildNumber,
      tag: tag,
      apkUrl: apkUrl,
      notes: (data['body'] ?? '').toString(),
    );
  }

  /// Streams the APK into the cache dir, reporting 0..1 progress.
  static Future<File> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/football-${info.tag}.apk');
    if (await file.exists()) await file.delete();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(info.apkUrl))
        ..headers['User-Agent'] = _userAgent;
      final resp = await client.send(request);
      if (resp.statusCode != 200) {
        throw HttpException('下载失败 HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }
    return file;
  }

  /// Opens the system installer. Returns an error message on failure, null on
  /// success (the user still has to confirm in the installer dialog).
  static Future<String?> install(File apk) async {
    final result = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type == ResultType.done) return null;
    return result.message;
  }
}
