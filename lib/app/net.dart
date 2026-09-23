import 'dart:async';
import 'package:http/http.dart' as http;

/// The central Qash domain every device activates against. Override per
/// build with `--dart-define=CENTRAL_URL=https://withqash-demo.tech` for
/// demo/staging builds; production doesn't need to pass anything.
const centralUrl = String.fromEnvironment('CENTRAL_URL', defaultValue: 'https://qash.id');

/// ponytail: no redirects — every URL these services call comes from the
/// server itself (activation response), so a 3xx means misconfiguration.
/// `package:http`'s convenience methods follow redirects by default, and
/// dart:io downgrades a redirected POST to GET while dropping the body and
/// the Authorization header on a cross-host hop — that's how a routing
/// mistake once turned into a silent, unfalsifiable "offline" instead of an
/// error. Fail loudly instead: callers already treat non-200 as an error.
Future<http.Response> sendNoRedirect(http.BaseRequest req) async {
  req.followRedirects = false;
  final res = await http.Response.fromStream(await req.send());
  if (res.statusCode == 401 && req.headers.containsKey('Authorization')) {
    deviceUnauthorized.add(null);
  }
  return res;
}

/// Fires when the server rejects this device's token: revoked in the
/// backoffice, or the station was re-activated on another phone. Without it
/// every caller just saw "offline, will retry" forever. StationScreen listens.
final deviceUnauthorized = StreamController<void>.broadcast();
