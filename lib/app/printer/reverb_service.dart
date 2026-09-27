// reverb_service.dart
//
// Wake-up channel via Laravel Reverb (Pusher-compatible WebSocket protocol).
// Subscribes to the station's private channel and tells PollService when to
// fetch. It NEVER prints: `print.jobs-waiting` carries only {station_id}, and
// the job itself always comes from GET /print-jobs/pending. Printing a pushed
// payload as well as the polled copy is what printed a job twice (2026-09-15).
//
// PUSHER PROTOCOL SUMMARY (what this file implements):
//   1. Connect WS to wss://{host}:{port}/app/{appKey}?protocol=7
//   2. Server → pusher:connection_established  (contains socket_id)
//   3. Client → POST /api/broadcasting/auth to get channel auth token
//   4. Client → pusher:subscribe with auth token
//   5. Server → pusher_internal:subscription_succeeded  → onSubscription(true)
//   6. Server → "print.jobs-waiting" on the channel     → onJobsWaiting()
//   7. Client → pusher:pong when server sends pusher:ping (keep-alive)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../net.dart';

class ReverbService {
  /// Subscription came up (true) or the socket went away (false).
  final void Function(bool subscribed) onSubscription;

  /// `print.jobs-waiting` arrived: jobs are pending, go fetch them.
  final void Function() onJobsWaiting;

  /// Absolute tenant API root from the server, e.g.
  /// 'https://demo-cafe.withqash-demo.tech/api'. Never assembled client-side.
  final String apiBaseUrl;

  /// The tenant id this station belongs to (e.g. 'tenant-abc').
  final String tenantId;

  /// Outlet id for this station.
  final int outletId;

  /// The station_id string for this physical device (e.g. 'counter-1').
  final String stationId;

  /// API token for the authenticated user (same token used by poll_service).
  final String apiToken;

  /// Reverb app key (REVERB_APP_KEY from .env).
  final String appKey;

  /// WebSocket host (REVERB_HOST from .env, e.g. 'your-domain.com').
  final String reverbHost;

  /// WebSocket port (REVERB_PORT from .env, usually 8080 or 443).
  final int reverbPort;

  /// Use wss (true) or ws (false).
  final bool secure;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _subscribed = false;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get status => _statusController.stream;

  String get _channelName =>
      'private-tenant.$tenantId.outlet.$outletId.station.$stationId';

  ReverbService({
    required this.onSubscription,
    required this.onJobsWaiting,
    required this.apiBaseUrl,
    required this.tenantId,
    required this.outletId,
    required this.stationId,
    required this.apiToken,
    required this.appKey,
    required this.reverbHost,
    required this.reverbPort,
    this.secure = true,
  });

  void start() {
    _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _emit('Menghubungkan…');
    try {
      final scheme = secure ? 'wss' : 'ws';
      final uri =
          '$scheme://$reverbHost:$reverbPort/app/$appKey?protocol=7&client=flutter&version=1.0&flash=false';

      _socket = await WebSocket.connect(uri);
      if (_disposed) {
        await _socket!.close(); // reset while connecting
        return;
      }
      // A silently dead link (Wi-Fi gone, no FIN) otherwise looks open until
      // TCP gives up, and polling would stay at 30 s all that time.
      _socket!.pingInterval = const Duration(seconds: 25);
      _emit('Terhubung');

      _socket!.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
        cancelOnError: true,
      );
    } catch (e) {
      _emit('Gagal terhubung — mencoba lagi');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final event = msg['event'] as String? ?? '';

    switch (event) {
      case 'pusher:connection_established':
        final data = jsonDecode(msg['data'] as String) as Map<String, dynamic>;
        final socketId = data['socket_id'] as String;
        _subscribeChannel(socketId);

      case 'pusher:ping':
        _send({'event': 'pusher:pong', 'data': {}});

      case 'pusher_internal:subscription_succeeded':
        _emit('Aktif');
        _subscribed = true;
        onSubscription(true);

      case 'pusher:subscription_error':
        _socket?.close(); // reconnect loop retries with a fresh auth

      case 'print.jobs-waiting':
        onJobsWaiting();
    }
  }

  Future<void> _subscribeChannel(String socketId) async {
    _emit('Autentikasi…');
    try {
      final auth = await _fetchChannelAuth(socketId);
      _send({
        'event': 'pusher:subscribe',
        'data': {'channel': _channelName, 'auth': auth},
      });
    } catch (e) {
      _emit('Autentikasi gagal — mencoba lagi');
      // Close socket so the reconnect loop retries with a fresh connection
      _socket?.close();
    }
  }

  Future<String> _fetchChannelAuth(String socketId) async {
    final uri = Uri.parse('$apiBaseUrl/broadcasting/auth');
    final req = http.Request('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $apiToken',
        'Accept': 'application/json',
      })
      ..bodyFields = {
        'socket_id': socketId,
        'channel_name': _channelName,
      };
    final res = await sendNoRedirect(req).timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw Exception('broadcasting auth failed: ${res.statusCode}');
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['auth'] as String;
  }

  void _send(Map<String, dynamic> msg) {
    if (_socket?.readyState == WebSocket.open) {
      _socket!.add(jsonEncode(msg));
    }
  }

  void _onDisconnect() {
    _socket = null;
    if (_subscribed) {
      _subscribed = false;
      if (!_disposed) onSubscription(false);
    }
    if (!_disposed) {
      _emit('Terputus — menyambung ulang…');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // ponytail: fixed 5s backoff — add exponential if flapping is an issue
    _reconnectTimer = Timer(const Duration(seconds: 5), _connect);
  }

  void _emit(String s) {
    if (!_disposed) _statusController.add(s);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _socket?.close();
    _statusController.close();
  }
}
