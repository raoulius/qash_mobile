import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The central Qash domain every device activates against. Override per
/// build with `--dart-define=CENTRAL_URL=https://withqash-demo.tech` for
/// demo/staging builds; production doesn't need to pass anything.
const centralUrl = String.fromEnvironment('CENTRAL_URL', defaultValue: 'https://qash.id');

/// One client for every call, so polls reuse the open TLS connection instead
/// of a handshake each time (a bare `request.send()` builds and closes a
/// client per request). idleTimeout outlives the 30 s poll cadence, else the
/// socket closes between polls. Cookies: dart:io keeps no jar and nothing here
/// sets a Cookie header, so the Set-Cookie the tenant `web` middleware returns
/// is dropped. Tests swap this for a MockClient.
http.Client httpClient = IOClient(HttpClient()..idleTimeout = const Duration(seconds: 45));

/// ponytail: no redirects — every URL these services call comes from the
/// server itself (activation response), so a 3xx means misconfiguration.
/// `package:http`'s convenience methods follow redirects by default, and
/// dart:io downgrades a redirected POST to GET while dropping the body and
/// the Authorization header on a cross-host hop — that's how a routing
/// mistake once turned into a silent, unfalsifiable "offline" instead of an
/// error. Fail loudly instead: callers already treat non-200 as an error.
Future<http.Response> sendNoRedirect(http.BaseRequest req) async {
  req.followRedirects = false;
  final res = await http.Response.fromStream(await httpClient.send(req));
  if (res.statusCode == 401 && req.headers.containsKey('Authorization')) {
    deviceUnauthorized.add(null);
  }
  return res;
}

/// Fires when the server rejects this device's token: revoked in the
/// backoffice, or the station was re-activated on another phone. Without it
/// every caller just saw "offline, will retry" forever. StationScreen listens.
final deviceUnauthorized = StreamController<void>.broadcast();
