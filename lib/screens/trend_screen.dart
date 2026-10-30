import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../widgets/common.dart';
import '../widgets/trend_chart.dart';
import 'report_detail_screen.dart';

enum _Span {
  m6('6M', 182),
  y1('1Y', 365),
  y3('3Y', 365 * 3),
  all('All', null);

  const _Span(this.label, this.days);
  final String label;
  final int? days;
}

class TrendScreen extends StatefulWidget {
  const TrendScreen({super.key, required this.member, required this.testKey, required this.testName});
  final Member member;
  final String testKey;
  final String testName;

  @override
  State<TrendScreen> createState() => _TrendScreenState();
}

class _TrendScreenState extends State<TrendScreen> {
  _Span _span = _Span.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.testName)),
      body: DbBuilder<List<TestResult>>(
        load: () => AppDb.instance.resultsForMember(widget.member.id, testKey: widget.testKey),
        builder: (context, all) {
          final cutoff = _span.days == null ? null : DateTime.now().subtract(Duration(days: _span.days!));
          final results = cutoff == null ? all : all.where((r) => !r.date.isBefore(cutoff)).toList();
          final numeric = results.where((r) => r.value != null).toList();
          final latest = all.isEmpty ? null : all.last;
          final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

          return ContentWidth(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
              children: [
                Text(widget.member.name, style: muted),
                if (latest != null) ...[
                  const SizedBox(height: 4),
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Text(formatValue(latest), style: valueStyle(context, latest.flag, base: theme.textTheme.displaySmall)),
                    const SizedBox(width: 6),
                    Text(latest.unit ?? '', style: theme.textTheme.titleMedium),
                    const SizedBox(width: 12),
                    FlagBadge(latest.flag),
                  ]),
                  Text(
                    'Latest · ${dateFmt.format(latest.date)}'
                    '${formatRange(latest.refLow, latest.refHigh).isEmpty ? '' : ' · reference ${formatRange(latest.refLow, latest.refHigh)}'}',
                    style: muted,
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<_Span>(
                    showSelectedIcon: false,
                    segments: [for (final s in _Span.values) ButtonSegment(value: s, label: Text(s.label))],
                    selected: {_span},
                    onSelectionChanged: (s) => setState(() => _span = s.first),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 280,
                  child: numeric.isEmpty
                      ? Center(child: Text('No numeric results in this period.', style: muted))
                      : Padding(padding: const EdgeInsets.only(right: 12), child: TrendChart(results: numeric)),
                ),
                const SizedBox(height: 8),
                _Legend(),
                if (numeric.length >= 2) ...[
                  const SizedBox(height: 20),
                  _Stats(results: numeric),
                ],
                const SizedBox(height: 24),
                Text('All results', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Card(
                  child: Column(children: [
                    for (final r in results.reversed)
                      ResultTile(
                        result: r,
                        title: dateFmt.format(r.date),
                        subtitle: formatRange(r.refLow, r.refHigh).isEmpty ? null : 'Range ${formatRange(r.refLow, r.refHigh)}',
                        base: theme.textTheme.bodyLarge,
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReportDetailScreen(reportId: r.reportId))),
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                Text(
                  'Reference ranges come from each report where printed, otherwise typical adult values. Talk to your doctor about what your results mean.',
                  style: muted,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget swatch(Widget mark, String label) => Row(mainAxisSize: MainAxisSize.min, children: [mark, const SizedBox(width: 6), Text(label, style: style)]);
    return Wrap(spacing: 16, runSpacing: 4, children: [
      swatch(Container(width: 14, height: 10, decoration: BoxDecoration(color: const Color(0x330ca30c), borderRadius: BorderRadius.circular(2))), 'Reference range'),
      swatch(const Row(children: [Icon(Icons.circle, size: 10, color: Color(0xffd03b3b)), Icon(Icons.arrow_upward_rounded, size: 12, color: Color(0xffd03b3b))]), 'Out of range'),
    ]);
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.results});
  final List<TestResult> results;

  @override
  Widget build(BuildContext context) {
    final values = results.map((r) => r.value!).toList();
    final unit = results.last.unit ?? '';
    final avg = values.reduce((a, b) => a + b) / values.length;
    final change = values.last - values.first;
    final outOfRange = results.where((r) => r.flag == ResultFlag.low || r.flag == ResultFlag.high).length;
    final tiles = [
      ('Lowest', '${formatNumber(values.reduce(math.min))} $unit'),
      ('Highest', '${formatNumber(values.reduce(math.max))} $unit'),
      ('Average', '${formatNumber(double.parse(avg.toStringAsPrecision(3)))} $unit'),
      ('Change', '${change >= 0 ? '+' : '−'}${formatNumber(change.abs())} $unit'),
      ('Out of range', '$outOfRange of ${results.length}'),
    ];
    final theme = Theme.of(context);
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final (label, value) in tiles)
        Container(
          constraints: const BoxConstraints(minWidth: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(value, style: theme.textTheme.titleMedium),
          ]),
        ),
    ]);
  }
}
