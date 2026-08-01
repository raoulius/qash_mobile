// dashboard_screen.dart
//
// Replicates the web backoffice dashboard: KPI stat cards, a revenue trend
// line chart, and an order breakdown donut chart. Fetches on open and via
// pull-to-refresh.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dashboard_models.dart';
import 'dashboard_stats_service.dart';

class DashboardScreen extends StatefulWidget {
  final DashboardStatsService statsService;

  const DashboardScreen({super.key, required this.statsService});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardStats? _stats;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.statsService.fetch();
      setState(() => _stats = DashboardStats.fromJson(json));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _stats == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 100),
          Center(child: Text('Failed to load: $_error')),
        ],
      );
    }
    final stats = _stats!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.4,
          children: [for (final card in stats.kpiCards) _KpiCardTile(card)],
        ),
        const SizedBox(height: 16),
        _RevenueTrendCard(trend: stats.revenueTrend),
        const SizedBox(height: 16),
        _OrderBreakdownCard(breakdown: stats.orderBreakdown),
      ],
    );
  }
}

class _KpiCardTile extends StatelessWidget {
  final KpiCard card;

  const _KpiCardTile(this.card);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    card.label.toUpperCase(),
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.grey),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: card.iconBackground,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(card.icon, color: card.iconColor, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              card.value,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Row(
              children: [
                Icon(card.trend.icon, color: card.trend.color, size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    card.trend.label,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: card.trend.color),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RevenueTrendCard extends StatelessWidget {
  final RevenueTrend trend;

  const _RevenueTrendCard({required this.trend});

  @override
  Widget build(BuildContext context) {
    final maxY = trend.series.isEmpty
        ? 1.0
        : trend.series.reduce((a, b) => a > b ? a : b) * 1.2;
    final labelStep = (trend.labels.length / 5).ceil().clamp(1, 1000);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Revenue Trend', style: Theme.of(context).textTheme.titleMedium),
            const Text('Paid and pay-after revenue by day',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              child: trend.series.isEmpty
                  ? const Center(child: Text('No data'))
                  : LineChart(
                      LineChartData(
                        minY: 0,
                        maxY: maxY == 0 ? 1 : maxY,
                        gridData: const FlGridData(drawVerticalLine: false),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                          ),
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 28,
                              interval: labelStep.toDouble(),
                              getTitlesWidget: (value, meta) {
                                final i = value.toInt();
                                if (i < 0 || i >= trend.labels.length) {
                                  return const SizedBox.shrink();
                                }
                                if (i % labelStep != 0) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(trend.labels[i],
                                      style: const TextStyle(fontSize: 10)),
                                );
                              },
                            ),
                          ),
                        ),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < trend.series.length; i++)
                                FlSpot(i.toDouble(), trend.series[i]),
                            ],
                            isCurved: true,
                            color: Colors.orange,
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.orange.withValues(alpha: 0.15),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderBreakdownCard extends StatelessWidget {
  final OrderBreakdown breakdown;

  const _OrderBreakdownCard({required this.breakdown});

  static const _completedColor = Colors.green;
  static const _pendingColor = Colors.amber;
  static const _cancelledColor = Colors.red;

  @override
  Widget build(BuildContext context) {
    final total = breakdown.total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Order Breakdown', style: Theme.of(context).textTheme.titleMedium),
            const Text('Completed, pending, and cancelled payments',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: total == 0
                  ? const Center(child: Text('No data'))
                  : PieChart(
                      PieChartData(
                        centerSpaceRadius: 50,
                        sectionsSpace: 2,
                        sections: [
                          if (breakdown.completed > 0)
                            PieChartSectionData(
                              value: breakdown.completed.toDouble(),
                              color: _completedColor,
                              showTitle: false,
                              radius: 40,
                            ),
                          if (breakdown.pending > 0)
                            PieChartSectionData(
                              value: breakdown.pending.toDouble(),
                              color: _pendingColor,
                              showTitle: false,
                              radius: 40,
                            ),
                          if (breakdown.cancelled > 0)
                            PieChartSectionData(
                              value: breakdown.cancelled.toDouble(),
                              color: _cancelledColor,
                              showTitle: false,
                              radius: 40,
                            ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            _legendRow('Completed', _completedColor, breakdown.completed),
            _legendRow('Pending', _pendingColor, breakdown.pending),
            _legendRow('Cancelled', _cancelledColor, breakdown.cancelled),
          ],
        ),
      ),
    );
  }

  Widget _legendRow(String label, Color color, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(width: 12, height: 12, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text('$count', style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
