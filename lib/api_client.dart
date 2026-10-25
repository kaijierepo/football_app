import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Thin HTTP client over the `web_app.py` JSON API.
///
/// Every request (read and write) carries `Authorization: Bearer <token>` when
/// a token is configured. Responses are decoded as JSON, with a clear
/// [ApiException] surfaced to the UI on non-2xx / network failures.
class ApiClient {
  ApiClient(this.config);

  final AppConfig config;

  Future<Map<String, dynamic>> get(String path) async {
    final uri = Uri.parse('${config.baseUrl}$path');
    final resp = await http
        .get(uri, headers: config.authHeaders)
        .timeout(const Duration(seconds: 30));
    return _decode(resp);
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('${config.baseUrl}$path');
    final headers = {
      'Content-Type': 'application/json',
      ...config.authHeaders,
    };
    // LLM generation prefetches injuries/lineups/predictions/standings first,
    // so a cold generation can take a few minutes.
    final resp = await http
        .post(uri, headers: headers, body: body == null ? null : jsonEncode(body))
        .timeout(const Duration(seconds: 240));
    return _decode(resp);
  }

  Map<String, dynamic> _decode(http.Response resp) {
    final dynamic data = resp.body.isEmpty ? null : jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }
    final msg = data is Map<String, dynamic> ? data['error'] : null;
    throw ApiException(resp.statusCode, msg?.toString() ?? 'HTTP ${resp.statusCode}');
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}
