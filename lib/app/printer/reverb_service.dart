// reverb_service.dart
//
// Push delivery via Laravel Reverb (Pusher-compatible WebSocket protocol).
// Subscribes to the station's private channel and feeds incoming print-job
// events directly into the existing PrintQueue — no polling needed for jobs
// that arrive while the socket is open.
//
// RELATIONSHIP WITH poll_service.dart:
// Both services feed the SAME PrintQueue. Reverb is the fast path (jobs
// print the moment they're created); polling is the fallback that catches
// jobs missed while the socket was down or the app was backgrounded.
// Running both in parallel is safe because PrintQueue's deduplication key
// is the Laravel job id stored in the receipt payload — duplicate enqueues
// for the same id are not a concern here because the server only delivers
// each job once per channel event, and polling only picks up jobs still
// marked 'pending' (already marked printed = not returned).
//
// PUSHER PROTOCOL SUMMARY (what this file implements):
//   1. Connect WS to wss://{host}:{port}/app/{appKey}?protocol=7
//   2. Server → pusher:connection_established  (contains socket_id)
//   3. Client → POST /api/broadcasting/auth to get channel auth token
//   4. Client → pusher:subscribe with auth token
//   5. Server → pusher_internal:subscription_succeeded
//   6. Server → "print-job.created" events on the channel
//   7. Client → pusher:pong when server sends pusher:ping (keep-alive)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../net.dart';
import 'print_queue.dart';

class ReverbService {
  final PrintQueue printQueue;

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

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get status => _statusController.stream;

  String get _channelName =>
      'private-tenant.$tenantId.outlet.$outletId.station.$stationId';

  ReverbService({
    required this.printQueue,
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
    _emit('connecting…');
    try {
      final scheme = secure ? 'wss' : 'ws';
      final uri =
          '$scheme://$reverbHost:$reverbPort/app/$appKey?protocol=7&client=flutter&version=1.0&flash=false';

      // ignore: avoid_print
      print('[Reverb] connecting to $uri');
      _socket = await WebSocket.connect(uri);
      // ignore: avoid_print
      print('[Reverb] socket connected');
      _emit('connected');

      _socket!.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
        cancelOnError: true,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[Reverb] connect failed: $e');
      _emit('ws error: $e');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    // ignore: avoid_print
    print('[Reverb] message: $raw');
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

      case 'print-job.created':
        _handlePrintJob(msg);
    }
  }

  Future<void> _subscribeChannel(String socketId) async {
    _emit('authenticating…');
    try {
      final auth = await _fetchChannelAuth(socketId);
      _send({
        'event': 'pusher:subscribe',
        'data': {'channel': _channelName, 'auth': auth},
      });
      _emit('subscribed');
    } catch (e) {
      // ignore: avoid_print
      print('[Reverb] auth exception: $e');
      _emit('channel auth failed');
      // Close socket so the reconnect loop retries with a fresh connection
      _socket?.close();
    }
  }

  Future<String> _handlePrintJob(Map<String, dynamic> msg) async {
    final rawData = msg['data'];
    final Map<String, dynamic> data;
    try {
      data = rawData is String
          ? jsonDecode(rawData) as Map<String, dynamic>
          : rawData as Map<String, dynamic>;
    } catch (_) {
      return '';
    }

    final payload = data['payload'] as Map<String, dynamic>?;
    if (payload == null) return '';

    // Merge job_type so EscPosBuilder can dispatch to the right template.
    // poll_service owns mark-printed; we just fast-path enqueue here.
    return await printQueue.enqueue({
      '_jobType': data['job_type'] as String? ?? '',
      ...payload,
    });
  }

  Future<String> _fetchChannelAuth(String socketId) async {
    final uri = Uri.parse('$apiBaseUrl/broadcasting/auth');
    // ignore: avoid_print
    print('[Reverb] auth POST to $uri  socket=$socketId  channel=$_channelName');
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

    // ignore: avoid_print
    print('[Reverb] auth response ${res.statusCode}: ${res.body}');
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
    if (!_disposed) {
      _emit('disconnected — reconnecting…');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // ponytail: fixed 5s backoff — add exponential if flapping is an issue
    _reconnectTimer = Timer(const Duration(seconds: 5), _connect);
  }

  void _emit(String s) => _statusController.add(s);

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _socket?.close();
    _statusController.close();
  }
}
