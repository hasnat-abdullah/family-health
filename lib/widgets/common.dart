import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../data/storage.dart';
import '../theme.dart';

final dateFmt = DateFormat.yMMMd();
final shortDateFmt = DateFormat('MMM yy');

String formatNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e6) return v.toInt().toString();
  final s = v.toStringAsPrecision(4);
  return s.contains('.') && !s.contains('e') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

String formatValue(TestResult r) => r.value != null ? formatNumber(r.value!) : (r.valueText ?? '—');

String formatRange(double? low, double? high) {
  if (low != null && high != null) return '${formatNumber(low)} – ${formatNumber(high)}';
  if (high != null) return '< ${formatNumber(high)}';
  if (low != null) return '> ${formatNumber(low)}';
  return '';
}

/// Re-runs [load] whenever the database changes and builds with the result.
class DbBuilder<T> extends StatefulWidget {
  const DbBuilder({super.key, required this.load, required this.builder});
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;

  @override
  State<DbBuilder<T>> createState() => _DbBuilderState<T>();
}

class _DbBuilderState<T> extends State<DbBuilder<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
    AppDb.instance.revision.addListener(_reload);
  }

  @override
  void dispose() {
    AppDb.instance.revision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = widget.load();
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _future,
    builder: (context, snap) {
      if (snap.hasError) return Center(child: Text('Something went wrong: ${snap.error}'));
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      return widget.builder(context, snap.data as T);
    },
  );
}

/// Profile picture, or coloured initials when there is none or it can't be read.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar(this.member, {super.key, this.radius = 24, this.preview});
  final Member member;
  final double radius;

  /// Photo not saved yet, shown in place of the stored one.
  final Uint8List? preview;

  // Decrypted once per file: avatars are small and appear on many screens.
  static final _photos = <String, Future<Uint8List>>{};

  Widget _circle(Uint8List? photo) => CircleAvatar(
    radius: radius,
    backgroundColor: Color(member.colorValue),
    foregroundImage: photo == null ? null : MemoryImage(photo),
    onForegroundImageError: photo == null ? null : (_, _) {},
    child: Text(
      member.initials,
      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: radius * 0.75),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final file = member.photoFile;
    if (preview != null || file == null) return _circle(preview);
    return FutureBuilder<Uint8List>(
      future: _photos.putIfAbsent(file, () => FileStore.instance.readPlain(file)),
      builder: (context, snap) => _circle(snap.data),
    );
  }
}

/// In-range / High / Low badge. Always icon + label, never colour alone.
class FlagBadge extends StatelessWidget {
  const FlagBadge(this.flag, {super.key, this.compact = false});
  final ResultFlag flag;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (flag == ResultFlag.unknown) return const SizedBox.shrink();
    final color = StatusColors.forFlag(flag, Theme.of(context).brightness);
    final (icon, label) = switch (flag) {
      ResultFlag.high => (Icons.arrow_upward_rounded, 'High'),
      ResultFlag.low => (Icons.arrow_downward_rounded, 'Low'),
      _ => (Icons.check_circle_outline_rounded, 'Normal'),
    };
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          if (!compact) ...[
            const SizedBox(width: 2),
            Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
          ],
        ],
      ),
    );
  }
}

/// Value + unit with its High/Low/Normal badge underneath, right-aligned.
/// Stacking (rather than a fixed-width column) keeps it readable at large text sizes.
class ValueWithFlag extends StatelessWidget {
  const ValueWithFlag(this.result, {super.key, this.base});
  final TestResult result;
  final TextStyle? base;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(text: formatValue(result), style: valueStyle(context, result.flag, base: base ?? theme.textTheme.titleMedium)),
            if (result.unit != null) TextSpan(text: ' ${result.unit}', style: theme.textTheme.bodySmall),
          ]),
        ),
        FlagBadge(result.flag),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 24), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Centres content and caps its width so phone layouts don't stretch on Mac/iPad.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 900});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
  );
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<bool> confirm(BuildContext context, {required String title, required String message, String action = 'Delete'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ??
    false;

bool isAbnormal(ResultFlag f) => f == ResultFlag.low || f == ResultFlag.high;

/// Background tint for rows holding an out-of-range value (paired with [FlagBadge]).
Color? abnormalTint(BuildContext context, ResultFlag f) =>
    isAbnormal(f) ? StatusColors.critical.withValues(alpha: Theme.of(context).brightness == Brightness.light ? 0.08 : 0.16) : null;

/// Value text: bold, and in the status colour when out of range.
TextStyle? valueStyle(BuildContext context, ResultFlag f, {TextStyle? base}) {
  final theme = Theme.of(context);
  final style = (base ?? theme.textTheme.titleMedium)?.copyWith(fontWeight: FontWeight.w600);
  return isAbnormal(f) ? style?.copyWith(color: StatusColors.forFlag(f, theme.brightness)) : style;
}

/// Lists out-of-range latest results. [onTap] opens the trend for a result.
class AttentionCard extends StatelessWidget {
  const AttentionCard({super.key, required this.items, required this.onTap, this.title = 'Needs attention', this.leading, this.onHeaderTap});
  final List<TestResult> items;
  final void Function(TestResult) onTap;
  final VoidCallback? onHeaderTap;
  final String title;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: abnormalTint(context, ResultFlag.high),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: onHeaderTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                leading ?? const Icon(Icons.error_outline_rounded, color: StatusColors.critical, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                Text('${items.length} out of range', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (onHeaderTap != null) const Icon(Icons.chevron_right_rounded, size: 20),
              ]),
            ),
          ),
          for (final r in items)
            ResultTile(
              result: r,
              title: r.testName,
              subtitle: [
                dateFmt.format(r.date),
                if (formatRange(r.refLow, r.refHigh).isNotEmpty) 'range ${formatRange(r.refLow, r.refHigh)}',
              ].join(' · '),
              base: theme.textTheme.bodyLarge,
              onTap: () => onTap(r),
            ),
        ]),
      ),
    );
  }
}

String formatTime(BuildContext context, int minutes) =>
    TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

IconData docIcon(DocType t) => switch (t) {
  DocType.lab => Icons.biotech_outlined,
  DocType.prescription => Icons.receipt_long_outlined,
  DocType.imaging => Icons.monitor_heart_outlined,
  DocType.discharge => Icons.local_hospital_outlined,
  DocType.vaccination => Icons.vaccines_outlined,
  DocType.other => Icons.description_outlined,
};

/// A test result row: name and details on the left, value + flag on the right.
/// Grows with its content (unlike ListTile's fixed-height trailing slot), so it
/// stays readable at large text sizes. Out-of-range rows are tinted.
class ResultTile extends StatelessWidget {
  const ResultTile({super.key, required this.result, required this.title, this.subtitle, this.onTap, this.base});
  final TestResult result;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final TextStyle? base;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Material(
        color: abnormalTint(context, result.flag) ?? Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    if (subtitle != null)
                      Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(width: 12),
                ValueWithFlag(result, base: base),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
