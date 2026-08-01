// dashboard_stats_service.dart
//
// On-demand fetch of GET {apiBaseUrl}/dashboard/stats from Laravel.
// Call fetch() whenever a screen needs fresh data (e.g. on open, or
// pull-to-refresh) — no background polling, this data isn't time-critical.

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../net.dart';

class DashboardStatsService {
  final String apiBaseUrl;
  final String authToken;

  DashboardStatsService({required this.apiBaseUrl, required this.authToken});

  Future<Map<String, dynamic>> fetch() async {
    final uri = Uri.parse('$apiBaseUrl/dashboard/stats');
    final req = http.Request('GET', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $authToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      });
    final res = await sendNoRedirect(req).timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw Exception('dashboard stats fetch failed: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
