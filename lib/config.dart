import 'package:shared_preferences/shared_preferences.dart';

/// Persistent app settings: server address + API token.
///
/// The server address defaults to a LAN address placeholder; the user should
/// fill in the actual host:port of the running `web_app.py` on the same Wi-Fi.
class AppConfig {
  static const String _kServer = 'server_address';
  static const String _kToken = 'api_token';

  static const String defaultServer = 'http://45.205.20.212:8000';

  String server;
  String token;

  AppConfig({required this.server, required this.token});

  /// Base URL with any trailing slash trimmed and scheme defaulted to http.
  String get baseUrl {
    var s = server.trim();
    if (s.isEmpty) s = defaultServer;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Map<String, String> get authHeaders => token.trim().isEmpty
      ? const {}
      : {'Authorization': 'Bearer ${token.trim()}'};

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig(
      server: prefs.getString(_kServer) ?? defaultServer,
      token: prefs.getString(_kToken) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServer, server.trim());
    await prefs.setString(_kToken, token.trim());
  }
}
