import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import 'asset_labels.dart';
import 'holding_screen.dart';
import 'privacy.dart';
import 'status_banner.dart';

// Not green or red, so a slice never reads as a gain or loss.
const _colors = {
  AssetClass.bistShare: Color(0xFF3F51B5),
  AssetClass.fund: Color(0xFFEF6C00),
  AssetClass.fx: Color(0xFF00897B),
  AssetClass.gold: Color(0xFFB8860B),
  AssetClass.crypto: Color(0xFF8E24AA),
};

String _share(Decimal part, Decimal total) =>
    '${roundHalfEven(divide(part * Decimal.fromInt(100), total), 1).toStringAsFixed(1)}%';

/// Each asset class's share of priced value; unpriced holdings are listed apart.
class AllocationPie extends StatefulWidget {
  const AllocationPie({
    super.key,
    required this.entries,
    this.measure = Measure.tryNominal,
  });
  final List<HoldingEntry> entries;
  final Measure measure;

  @override
  State<AllocationPie> createState() => _AllocationPieState();
}

class _AllocationPieState extends State<AllocationPie> {
  AssetClass? _selected;

  void _toggle(AssetClass c) =>
      setState(() => _selected = _selected == c ? null : c);

  @override
  Widget build(BuildContext context) {
    final priced = [
      for (final e in widget.entries)
        if (e.value != null && e.value! > Decimal.zero) e,
    ];
    final unpriced = [
      for (final e in widget.entries)
        if (e.value == null) e.position.instrument.code,
    ];
    final byClass = {
      for (final c in AssetClass.values)
        c: priced.where((e) => e.position.instrument.assetClass == c).toList(),
    }..removeWhere((_, v) => v.isEmpty);
    final totals = {
      for (final e in byClass.entries)
        e.key: e.value.fold(Decimal.zero, (s, h) => s + h.value!),
    };
    final total = totals.values.fold(Decimal.zero, (s, v) => s + v);
    final note = unpriced.isEmpty
        ? null
        : Text('Not included (no price): ${unpriced.join(', ')}');
    if (total == Decimal.zero) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [const Text('No priced holdings'), ?note],
      );
    }
    final slices = [
      for (final e in totals.entries)
        (e.key, e.value.toDouble() / total.toDouble()),
    ];
    final selected = byClass[_selected];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: GestureDetector(
            key: const Key('allocation-pie'),
            onTapUp: (d) {
              final hit = _sliceAt(
                d.localPosition,
                const Size.square(200),
                slices,
              );
              if (hit != null) _toggle(slices[hit].$1);
            },
            child: CustomPaint(
              size: const Size.square(200),
              painter: _PiePainter(slices, _selected),
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final e in totals.entries)
          ListTile(
            dense: true,
            selected: e.key == _selected,
            leading: Icon(Icons.circle, color: _colors[e.key]),
            title: Text(assetClassHeading(e.key)),
            trailing: Amount(
              '${_share(e.value, total)} · ${formatMoney(e.value, widget.measure)}',
            ),
            onTap: () => _toggle(e.key),
          ),
        if (selected != null)
          for (final h in selected)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 56, right: 16),
              title: Text(h.position.instrument.code),
              trailing: Amount(_share(h.value!, total)),
            ),
        ?note,
      ],
    );
  }

  int? _sliceAt(Offset p, Size size, List<(AssetClass, double)> slices) {
    final v = p - size.center(Offset.zero);
    if (v.distance > size.shortestSide / 2) return null;
    // Clockwise from 12 o'clock, as painted.
    final turn = (math.atan2(v.dx, -v.dy) / (2 * math.pi)) % 1;
    var end = 0.0;
    for (var i = 0; i < slices.length; i++) {
      end += slices[i].$2;
      if (turn < end) return i;
    }
    return slices.length - 1; // rounding at the last edge
  }
}

class _PiePainter extends CustomPainter {
  _PiePainter(this.slices, this.selected);
  final List<(AssetClass, double)> slices;
  final AssetClass? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    var start = -math.pi / 2;
    for (final (c, f) in slices) {
      final sweep = f * 2 * math.pi;
      final paint = Paint()..color = _colors[c]!;
      final r = c == selected ? rect : rect.deflate(6);
      canvas.drawArc(r, start, sweep, true, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.selected != selected || old.slices.toString() != slices.toString();
}
