// dashboard_models.dart
//
// Plain data classes for the GET /dashboard/stats response. No codegen —
// this is a single fixed shape, not worth a build_runner dependency.

import 'package:flutter/material.dart';

class KpiTrend {
  final String label;
  final String state; // 'up' | 'down' | 'flat'

  KpiTrend({required this.label, required this.state});

  factory KpiTrend.fromJson(Map<String, dynamic> json) => KpiTrend(
        label: json['label'] as String? ?? '',
        state: json['state'] as String? ?? 'flat',
      );

  Color get color => switch (state) {
        'up' => Colors.green,
        'down' => Colors.red,
        _ => Colors.grey,
      };

  IconData get icon => switch (state) {
        'up' => Icons.trending_up,
        'down' => Icons.trending_down,
        _ => Icons.trending_flat,
      };
}

class KpiCard {
  final String label;
  final String value;
  final Color iconBackground;
  final Color iconColor;
  final KpiTrend trend;

  KpiCard({
    required this.label,
    required this.value,
    required this.iconBackground,
    required this.iconColor,
    required this.trend,
  });

  factory KpiCard.fromJson(Map<String, dynamic> json) => KpiCard(
        label: json['label'] as String? ?? '',
        value: json['value']?.toString() ?? '',
        iconBackground: _colorFromHex(json['icon_background'] as String?),
        iconColor: _colorFromHex(json['icon_color'] as String?),
        trend: KpiTrend.fromJson(
            (json['trend'] as Map<String, dynamic>?) ?? const {}),
      );

  /// Fixed set of 6 labels from DashboardMetricsService — map by label
  /// since the web-only Bootstrap icon slugs (e.g. 'bi-cash-coin') have no
  /// Flutter equivalent.
  IconData get icon => switch (label) {
        'Total Sales' => Icons.payments,
        'Total Orders' => Icons.shopping_basket,
        'Active Orders' => Icons.receipt_long,
        'Avg Order Value' => Icons.trending_up,
        'Customers' => Icons.people,
        'Out of Stock' => Icons.error_outline,
        _ => Icons.analytics,
      };
}

class OrderBreakdown {
  final int completed;
  final int pending;
  final int cancelled;

  OrderBreakdown({
    required this.completed,
    required this.pending,
    required this.cancelled,
  });

  factory OrderBreakdown.fromJson(Map<String, dynamic> json) => OrderBreakdown(
        completed: (json['completed'] as num?)?.toInt() ?? 0,
        pending: (json['pending'] as num?)?.toInt() ?? 0,
        cancelled: (json['cancelled'] as num?)?.toInt() ?? 0,
      );

  int get total => completed + pending + cancelled;
}

class RevenueTrend {
  final List<String> labels;
  final List<double> series;

  RevenueTrend({required this.labels, required this.series});

  factory RevenueTrend.fromJson(Map<String, dynamic> json) => RevenueTrend(
        labels: (json['labels'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        series: (json['series'] as List<dynamic>? ?? [])
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}

class DashboardStats {
  final List<KpiCard> kpiCards;
  final OrderBreakdown orderBreakdown;
  final RevenueTrend revenueTrend;

  DashboardStats({
    required this.kpiCards,
    required this.orderBreakdown,
    required this.revenueTrend,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> json) => DashboardStats(
        kpiCards: (json['kpi_cards'] as List<dynamic>? ?? [])
            .map((e) => KpiCard.fromJson(e as Map<String, dynamic>))
            .toList(),
        orderBreakdown: OrderBreakdown.fromJson(
            (json['order_breakdown'] as Map<String, dynamic>?) ?? const {}),
        revenueTrend: RevenueTrend.fromJson(
            (json['revenue_trend'] as Map<String, dynamic>?) ?? const {}),
      );
}

Color _colorFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return Colors.grey;
  // One malformed colour must not fail the whole dashboard.
  final rgb = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return rgb == null ? Colors.grey : Color(0xFF000000 | rgb);
}
