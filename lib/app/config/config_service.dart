import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../net.dart';
import 'device_config.dart';

const _kConfigKey = 'device_config_v2';

class ConfigService {
  static Future<DeviceConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConfigKey);
    if (raw == null) {
      // ponytail: v1 blob has no api_base_url (it built '/t/{tenant}/api'
      // client-side, which the server no longer serves) — re-activate instead
      // of guessing a URL from it.
      await prefs.remove('device_config_v1');
      return null;
    }
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return _fromMap(map);
  }

  static Future<void> save(DeviceConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConfigKey, jsonEncode(_toMap(config)));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kConfigKey);
  }

  /// Exchanges an activation token for a full DeviceConfig against [centralUrl].
  static Future<DeviceConfig> activate(String token) async {
    final uri = Uri.parse('$centralUrl/api/device/activate');
    final req = http.Request('POST', uri)
      ..headers.addAll({'Accept': 'application/json', 'Content-Type': 'application/json'})
      ..body = jsonEncode({
        'activation_token': token.trim().toUpperCase(),
        // Shown on the backoffice Print Stations page next to the station.
        'device_name': await _deviceName(),
      });
    final http.Response res;
    try {
      res = await sendNoRedirect(req).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw Exception('Server tidak merespons. Periksa koneksi lalu coba lagi.');
    } on Exception {
      // SocketException / ClientException / HandshakeException: no route to it.
      throw Exception('Tidak dapat terhubung ke server. Periksa koneksi internet.');
    }

    if (res.statusCode != 200) throw Exception(_activationError(res));

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final config = DeviceConfig(
      apiBaseUrl: data['api_base_url'] as String,
      tenantId: data['tenant_id'] as String,
      outletId: (data['outlet_id'] as num).toInt(),
      stationId: data['station_id'] as String,
      stationType: data['station_type'] as String,
      apiToken: data['api_token'] as String,
      reverbAppKey: data['reverb_app_key'] as String,
      reverbHost: data['reverb_host'] as String,
      reverbPort: (data['reverb_port'] as num).toInt(),
      reverbSecure: data['reverb_secure'] as bool? ?? false,
    );
    await save(config);
    return config;
  }

  /// The body may not be JSON at all (a Cloudflare 5xx is HTML), so never
  /// let a FormatException reach the cashier.
  static String _activationError(http.Response res) {
    Map<String, dynamic> body = const {};
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    return switch (res.statusCode) {
      401 || 422 => 'Token aktivasi salah atau sudah dicabut.',
      429 => 'Terlalu banyak percobaan. Coba lagi dalam '
          '${((body['retry_after'] as num?) ?? 300) ~/ 60 + 1} menit.',
      _ => 'Aktivasi gagal (server ${res.statusCode}). Coba lagi nanti.',
    };
  }

  static Future<String?> _deviceName() async {
    try {
      if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        return '${a.manufacturer} ${a.model}'.trim();
      }
      if (Platform.isIOS) return (await DeviceInfoPlugin().iosInfo).name;
    } catch (_) {}
    return null;
  }

  static DeviceConfig _fromMap(Map<String, dynamic> m) => DeviceConfig(
        apiBaseUrl: m['apiBaseUrl'] as String,
        tenantId: m['tenantId'] as String,
        outletId: (m['outletId'] as num).toInt(),
        stationId: m['stationId'] as String,
        stationType: m['stationType'] as String,
        apiToken: m['apiToken'] as String,
        reverbAppKey: m['reverbAppKey'] as String,
        reverbHost: m['reverbHost'] as String,
        reverbPort: (m['reverbPort'] as num).toInt(),
        reverbSecure: m['reverbSecure'] as bool? ?? false,
      );

  static Map<String, dynamic> _toMap(DeviceConfig c) => {
        'apiBaseUrl': c.apiBaseUrl,
        'tenantId': c.tenantId,
        'outletId': c.outletId,
        'stationId': c.stationId,
        'stationType': c.stationType,
        'apiToken': c.apiToken,
        'reverbAppKey': c.reverbAppKey,
        'reverbHost': c.reverbHost,
        'reverbPort': c.reverbPort,
        'reverbSecure': c.reverbSecure,
      };
}
