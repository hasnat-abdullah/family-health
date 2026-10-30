import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';
import 'common.dart';

double _x(DateTime d) => d.millisecondsSinceEpoch / Duration.millisecondsPerDay;
DateTime _date(double x) => DateTime.fromMillisecondsSinceEpoch((x * Duration.millisecondsPerDay).round());

/// One test over time: 2px line, dots (out-of-range dots in the status colour
/// with a surface ring), the reference range as a soft band, and a hover/tap tooltip.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.results, this.compact = false});

  /// Numeric results for a single test, oldest first.
  final List<TestResult> results;

  /// Sparkline mode: no axes, no tooltip.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final points = results.where((r) => r.value != null).toList();
    if (points.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colors = ChartColors.of(context);
    final surface = compact ? theme.colorScheme.surfaceContainerLow : theme.colorScheme.surface;
    final latest = points.last;
    final low = latest.refLow, high = latest.refHigh;

    // Y extent covers the data and the reference band, with headroom.
    final values = [for (final p in points) p.value!, ?low, ?high];
    var minY = values.reduce(math.min), maxY = values.reduce(math.max);
    final pad = (maxY - minY).abs() < 1e-9 ? (maxY.abs() * 0.1 + 1) : (maxY - minY) * 0.15;
    minY = minY - pad;
    maxY = maxY + pad;
    if (points.every((p) => p.value! >= 0) && minY < 0) minY = 0;

    var minX = _x(points.first.date), maxX = _x(points.last.date);
    if (maxX - minX < 1) {
      minX -= 15;
      maxX += 15;
    }
    final xPad = (maxX - minX) * (compact ? 0.04 : 0.03);

    final spots = [for (final p in points) FlSpot(_x(p.date), p.value!)];

    final axisStyle = theme.textTheme.labelSmall?.copyWith(color: colors.axisText);

    return LineChart(
      LineChartData(
        minX: minX - xPad,
        maxX: maxX + xPad,
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            if (low != null || high != null)
              HorizontalRangeAnnotation(y1: low ?? minY, y2: high ?? maxY, color: colors.band),
          ],
        ),
        gridData: FlGridData(
          show: !compact,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: colors.grid, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: compact
            ? const FlTitlesData(show: false)
            : FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (v, meta) => (v == meta.min || v == meta.max)
                        ? const SizedBox.shrink()
                        : SideTitleWidget(meta: meta, child: Text(formatNumber(v), style: axisStyle)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: _dateInterval(maxX - minX),
                    getTitlesWidget: (v, meta) => (v == meta.min || v == meta.max)
                        ? const SizedBox.shrink()
                        : SideTitleWidget(meta: meta, child: Text(shortDateFmt.format(_date(v)), style: axisStyle)),
                  ),
                ),
              ),
        lineTouchData: compact
            ? const LineTouchData(enabled: false)
            : LineTouchData(
                handleBuiltInTouches: true,
                getTouchedSpotIndicator: (bar, indexes) => [
                  for (final _ in indexes)
                    TouchedSpotIndicatorData(
                      FlLine(color: colors.axisText.withValues(alpha: 0.4), strokeWidth: 1, dashArray: [4, 4]),
                      FlDotData(
                        getDotPainter: (s, _, _, _) => FlDotCirclePainter(
                          radius: 6, color: colors.line, strokeWidth: 2, strokeColor: surface,
                        ),
                      ),
                    ),
                ],
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                  tooltipBorderRadius: BorderRadius.circular(8),
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        '${formatNumber(points[s.spotIndex].value!)} ${points[s.spotIndex].unit ?? ''}\n',
                        TextStyle(color: theme.colorScheme.onInverseSurface, fontWeight: FontWeight.w600),
                        children: [
                          TextSpan(
                            text: dateFmt.format(points[s.spotIndex].date),
                            style: TextStyle(color: theme.colorScheme.onInverseSurface.withValues(alpha: 0.8), fontWeight: FontWeight.w400, fontSize: 12),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: colors.line,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: !compact || points.length <= 12,
              getDotPainter: (spot, _, _, index) {
                final flagged = points[index].flag == ResultFlag.low || points[index].flag == ResultFlag.high;
                return FlDotCirclePainter(
                  radius: compact ? 2.5 : 4.5,
                  color: flagged ? StatusColors.critical : colors.line,
                  strokeWidth: compact ? 1 : 2,
                  strokeColor: surface,
                );
              },
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }

  static double _dateInterval(double spanDays) {
    // Aim for ~5 labels.
    final raw = spanDays / 5;
    for (final step in const <double>[7, 14, 30.4, 61, 91.3, 182.6, 365.25, 730.5]) {
      if (raw <= step) return step;
    }
    return 365.25 * math.max(2, (raw / 365.25).ceil());
  }
}
