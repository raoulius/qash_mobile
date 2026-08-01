class DeviceConfig {
  /// Absolute tenant API root from the server, e.g.
  /// 'https://demo-cafe.withqash-demo.tech/api'. Never assembled client-side.
  final String apiBaseUrl;
  final String tenantId;
  final int outletId;
  final String stationId;
  final String stationType;
  final String apiToken;
  final String reverbAppKey;
  final String reverbHost;
  final int reverbPort;
  final bool reverbSecure;

  const DeviceConfig({
    required this.apiBaseUrl,
    required this.tenantId,
    required this.outletId,
    required this.stationId,
    required this.stationType,
    required this.apiToken,
    required this.reverbAppKey,
    required this.reverbHost,
    required this.reverbPort,
    required this.reverbSecure,
  });
}
