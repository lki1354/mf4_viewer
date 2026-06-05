import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/plot_config.dart';

/// Width reserved for a y-axis given the series plotted on that side.
/// Categorical (enum) axes need more room for their text tick labels.
double axisPadFor(Iterable<ChartSeries> sideSeries) {
  if (sideSeries.isEmpty) return 12;
  final single = sideSeries.length == 1;
  if (single && sideSeries.first.isEnum) return 104;
  return 56;
}

/// One renderable series handed to the chart.
class ChartSeries {
  final String name;
  final String unit;
  final Float64List t;
  final Float64List v;
  final Color color;
  final double stroke;
  final bool stepped;
  final AxisSide axis;
  final bool isEnum;

  /// y-level -> text, used to label a categorical axis and the crosshair.
  final Map<int, String>? levelLabels;

  ChartSeries({
    required this.name,
    required this.unit,
    required this.t,
    required this.v,
    required this.color,
    required this.stroke,
    required this.stepped,
    required this.axis,
    required this.isEnum,
    this.levelLabels,
  });
}

/// Time-series chart with independent left/right y-axes, categorical (enum)
/// axis labelling, per-pixel decimation for large logs, pan/zoom and a
/// crosshair value readout.
class TimeSeriesChart extends StatefulWidget {
  final List<ChartSeries> series;
  final double viewMin;
  final double viewMax;
  final void Function(double min, double max) onViewChanged;

  const TimeSeriesChart({
    super.key,
    required this.series,
    required this.viewMin,
    required this.viewMax,
    required this.onViewChanged,
  });

  @override
  State<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

class _TimeSeriesChartState extends State<TimeSeriesChart> {
  // Gesture bookkeeping.
  double _startMin = 0;
  double _startMax = 1;
  double _startFocalX = 0;
  double _lastWidth = 1;
  double _plotLeft = 0;
  double _plotWidth = 1;

  // Crosshair time (data coordinates), null when hidden.
  double? _cursorT;

  static const _padTop = 10.0;
  static const _padBottom = 26.0;

  void _recomputePlotMetrics(double width) {
    final left = widget.series.where((s) => s.axis == AxisSide.left);
    final right = widget.series.where((s) => s.axis == AxisSide.right);
    _plotLeft = axisPadFor(left);
    _plotWidth = math.max(1, width - _plotLeft - axisPadFor(right));
  }

  double _xToTime(double x) {
    final frac = ((x - _plotLeft) / _plotWidth).clamp(0.0, 1.0);
    return widget.viewMin + frac * (widget.viewMax - widget.viewMin);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startMin = widget.viewMin;
    _startMax = widget.viewMax;
    _startFocalX = d.localFocalPoint.dx;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _recomputePlotMetrics(_lastWidth);
    final startSpan = _startMax - _startMin;
    // Time under the focal point at gesture start stays anchored there.
    final focalFrac =
        ((_startFocalX - _plotLeft) / _plotWidth).clamp(0.0, 1.0);
    final focalTime = _startMin + focalFrac * startSpan;

    final newSpan = startSpan / d.horizontalScale.clamp(0.01, 100.0);
    // Pan from drag.
    final dragFrac = -d.focalPointDelta.dx / _plotWidth;
    var newMin = focalTime - focalFrac * newSpan + dragFrac * newSpan;
    var newMax = newMin + newSpan;
    // keep focal anchored after rescale
    final anchored = focalTime - focalFrac * newSpan;
    newMin = anchored + dragFrac * newSpan;
    newMax = newMin + newSpan;
    widget.onViewChanged(newMin, newMax);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastWidth = constraints.maxWidth;
        _recomputePlotMetrics(constraints.maxWidth);
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onDoubleTap: () => widget.onViewChanged(
              double.negativeInfinity, double.infinity),
          onTapDown: (d) =>
              setState(() => _cursorT = _xToTime(d.localPosition.dx)),
          child: MouseRegion(
            onHover: (e) =>
                setState(() => _cursorT = _xToTime(e.localPosition.dx)),
            onExit: (_) => setState(() => _cursorT = null),
            child: CustomPaint(
              size: Size.infinite,
              painter: _ChartPainter(
                series: widget.series,
                viewMin: widget.viewMin,
                viewMax: widget.viewMax,
                cursorT: _cursorT,
                theme: theme,
                padTop: _padTop,
                padBottom: _padBottom,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AxisRange {
  double min;
  double max;
  _AxisRange(this.min, this.max);
  double get span => (max - min).abs() < 1e-12 ? 1 : max - min;
}

class _ChartPainter extends CustomPainter {
  final List<ChartSeries> series;
  final double viewMin;
  final double viewMax;
  final double? cursorT;
  final ThemeData theme;
  final double padTop;
  final double padBottom;

  _ChartPainter({
    required this.series,
    required this.viewMin,
    required this.viewMax,
    required this.cursorT,
    required this.theme,
    required this.padTop,
    required this.padBottom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final leftSeries =
        series.where((s) => s.axis == AxisSide.left).toList();
    final rightSeries =
        series.where((s) => s.axis == AxisSide.right).toList();

    final plotLeft = axisPadFor(leftSeries);
    final plotRight = size.width - axisPadFor(rightSeries);
    final plotTop = padTop;
    final plotBottom = size.height - padBottom;
    final rect = Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom);

    final gridColor = theme.dividerColor.withValues(alpha: 0.4);
    final axisColor = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final labelStyle = TextStyle(color: axisColor, fontSize: 10);

    // plot background + border
    final bg = Paint()..color = theme.colorScheme.surface;
    canvas.drawRect(rect, bg);

    final leftRange = _rangeFor(leftSeries);
    final rightRange = _rangeFor(rightSeries);

    // ---- left axis ticks + horizontal grid ----
    if (leftSeries.isNotEmpty) {
      _drawYAxis(canvas, rect, leftRange, leftSeries, labelStyle, gridColor,
          isLeft: true, drawGrid: true);
    }
    if (rightSeries.isNotEmpty) {
      _drawYAxis(canvas, rect, rightRange, rightSeries, labelStyle, gridColor,
          isLeft: false, drawGrid: leftSeries.isEmpty);
    }

    // ---- x (time) axis ----
    _drawXAxis(canvas, rect, labelStyle, gridColor);

    // ---- series ----
    canvas.save();
    canvas.clipRect(rect);
    for (final s in leftSeries) {
      _drawSeries(canvas, rect, s, leftRange);
    }
    for (final s in rightSeries) {
      _drawSeries(canvas, rect, s, rightRange);
    }
    canvas.restore();

    // border
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawRect(rect, border);

    // ---- crosshair ----
    if (cursorT != null && cursorT! >= viewMin && cursorT! <= viewMax) {
      _drawCrosshair(canvas, rect, leftRange, rightRange);
    }
  }

  _AxisRange _rangeFor(List<ChartSeries> list) {
    if (list.isEmpty) return _AxisRange(0, 1);
    // Single enum series -> categorical range based on levels.
    if (list.length == 1 && list.first.isEnum) {
      final lv = list.first.levelLabels;
      final maxLevel =
          (lv == null || lv.isEmpty) ? 1 : lv.keys.reduce(math.max);
      return _AxisRange(-0.5, maxLevel + 0.5);
    }
    var min = double.infinity;
    var max = double.negativeInfinity;
    for (final s in list) {
      final i0 = _lowerBound(s.t, viewMin);
      final i1 = _upperBound(s.t, viewMax);
      for (var i = math.max(0, i0 - 1); i < math.min(s.v.length, i1 + 1); i++) {
        final y = s.v[i];
        if (y.isNaN) continue;
        if (y < min) min = y;
        if (y > max) max = y;
      }
    }
    if (!min.isFinite || !max.isFinite) return _AxisRange(0, 1);
    if ((max - min).abs() < 1e-9) {
      min -= 1;
      max += 1;
    } else {
      final pad = (max - min) * 0.08;
      min -= pad;
      max += pad;
    }
    return _AxisRange(min, max);
  }

  void _drawYAxis(
    Canvas canvas,
    Rect rect,
    _AxisRange range,
    List<ChartSeries> list,
    TextStyle style,
    Color gridColor, {
    required bool isLeft,
    required bool drawGrid,
  }) {
    final enumSingle = list.length == 1 && list.first.isEnum;
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;

    if (enumSingle) {
      final labels = list.first.levelLabels ?? const {};
      labels.forEach((level, text) {
        final y = _mapY(level.toDouble(), rect, range);
        if (drawGrid) {
          canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
        }
        _label(canvas, text, isLeft ? rect.left - 4 : rect.right + 4, y, style,
            alignRight: isLeft);
      });
      return;
    }

    final ticks = _niceTicks(range.min, range.max, 5);
    for (final t in ticks) {
      final y = _mapY(t, rect, range);
      if (y < rect.top - 1 || y > rect.bottom + 1) continue;
      if (drawGrid) {
        canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
      }
      _label(canvas, _fmt(t), isLeft ? rect.left - 4 : rect.right + 4, y, style,
          alignRight: isLeft);
    }
  }

  void _drawXAxis(Canvas canvas, Rect rect, TextStyle style, Color gridColor) {
    final ticks = _niceTicks(viewMin, viewMax, 6);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (final t in ticks) {
      final frac = (t - viewMin) / (viewMax - viewMin);
      final x = rect.left + frac * rect.width;
      if (x < rect.left - 1 || x > rect.right + 1) continue;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      final tp = _textPainter('${_fmt(t)}s', style);
      tp.paint(canvas, Offset(x - tp.width / 2, rect.bottom + 4));
    }
  }

  void _drawSeries(
      Canvas canvas, Rect rect, ChartSeries s, _AxisRange range) {
    final n = s.t.length;
    if (n == 0) return;
    final paint = Paint()
      ..color = s.color
      ..strokeWidth = s.stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final i0 = math.max(0, _lowerBound(s.t, viewMin) - 1);
    final i1 = math.min(n, _upperBound(s.t, viewMax) + 1);
    final visible = i1 - i0;
    if (visible <= 0) return;

    final path = Path();
    final pxPerSpan = rect.width / (viewMax - viewMin);

    if (visible > rect.width * 4) {
      // Per-pixel min/max decimation for very dense data.
      _decimatedPath(path, s, rect, range, i0, i1, pxPerSpan);
    } else {
      var started = false;
      double prevY = 0;
      for (var i = i0; i < i1; i++) {
        final x = rect.left + (s.t[i] - viewMin) * pxPerSpan;
        final y = _mapY(s.v[i], rect, range);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          if (s.stepped) {
            path.lineTo(x, prevY); // sample-and-hold
          }
          path.lineTo(x, y);
        }
        prevY = y;
      }
    }
    canvas.drawPath(path, paint);
  }

  void _decimatedPath(Path path, ChartSeries s, Rect rect, _AxisRange range,
      int i0, int i1, double pxPerSpan) {
    var col = -1;
    double colMin = 0, colMax = 0;
    bool started = false;
    for (var i = i0; i < i1; i++) {
      final x = rect.left + (s.t[i] - viewMin) * pxPerSpan;
      final c = x.floor();
      final y = s.v[i];
      if (c != col) {
        if (col >= 0) {
          final xx = col.toDouble();
          final yMinPx = _mapY(colMin, rect, range);
          final yMaxPx = _mapY(colMax, rect, range);
          if (!started) {
            path.moveTo(xx, yMaxPx);
            started = true;
          } else {
            path.lineTo(xx, yMaxPx);
          }
          path.lineTo(xx, yMinPx);
        }
        col = c;
        colMin = y;
        colMax = y;
      } else {
        if (y < colMin) colMin = y;
        if (y > colMax) colMax = y;
      }
    }
  }

  void _drawCrosshair(
      Canvas canvas, Rect rect, _AxisRange left, _AxisRange right) {
    final frac = (cursorT! - viewMin) / (viewMax - viewMin);
    final x = rect.left + frac * rect.width;
    final cursorPaint = Paint()
      ..color = theme.colorScheme.primary.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), cursorPaint);

    // Readout box for each series at the cursor time.
    final entries = <_Readout>[];
    for (final s in series) {
      if (s.t.isEmpty) continue;
      final idx = _sampleAtOrBefore(s.t, cursorT!);
      if (idx < 0) continue;
      final range = s.axis == AxisSide.left ? left : right;
      final y = _mapY(s.v[idx], rect, range);
      String text;
      if (s.isEnum && s.levelLabels != null) {
        text = s.levelLabels![s.v[idx].round()] ?? s.v[idx].toString();
      } else {
        text = '${_fmt(s.v[idx])}${s.unit.isNotEmpty ? ' ${s.unit}' : ''}';
      }
      entries.add(_Readout(s.name, text, s.color, y));
      // marker dot
      canvas.drawCircle(
          Offset(x, y), 3, Paint()..color = s.color);
    }
    if (entries.isEmpty) return;

    // Draw a compact legend/readout box near the top-left of the plot.
    const pad = 6.0;
    double boxW = 0;
    final painters = <TextPainter>[];
    for (final e in entries) {
      final tp = _textPainter('${e.name}: ${e.value}',
          TextStyle(color: e.color, fontSize: 11, fontWeight: FontWeight.w500));
      painters.add(tp);
      boxW = math.max(boxW, tp.width);
    }
    final lineH = painters.first.height + 2;
    final boxH = lineH * entries.length + pad * 2;
    var bx = x + 8;
    if (bx + boxW + pad * 2 > rect.right) bx = x - boxW - pad * 2 - 8;
    final by = rect.top + 4;
    final boxRect = Rect.fromLTWH(bx, by, boxW + pad * 2, boxH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(4)),
      Paint()..color = theme.colorScheme.surface.withValues(alpha: 0.92),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = theme.dividerColor,
    );
    for (var i = 0; i < painters.length; i++) {
      painters[i].paint(canvas, Offset(bx + pad, by + pad + i * lineH));
    }
  }

  // ---- helpers ----------------------------------------------------------

  double _mapY(double v, Rect rect, _AxisRange r) =>
      rect.bottom - ((v - r.min) / r.span) * rect.height;

  void _label(Canvas canvas, String text, double x, double y, TextStyle style,
      {required bool alignRight}) {
    final tp = _textPainter(text, style);
    final dx = alignRight ? x - tp.width : x;
    tp.paint(canvas, Offset(dx, y - tp.height / 2));
  }

  TextPainter _textPainter(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return tp;
  }

  static int _lowerBound(Float64List a, double key) {
    var lo = 0, hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (a[mid] < key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static int _upperBound(Float64List a, double key) {
    var lo = 0, hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (a[mid] <= key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static int _sampleAtOrBefore(Float64List a, double key) {
    final ub = _upperBound(a, key);
    return ub - 1;
  }

  static List<double> _niceTicks(double min, double max, int count) {
    if (!min.isFinite || !max.isFinite || max <= min) return [min];
    final range = _niceNum(max - min, false);
    final step = _niceNum(range / (count - 1), true);
    final niceMin = (min / step).floor() * step;
    final niceMax = (max / step).ceil() * step;
    final out = <double>[];
    for (var v = niceMin; v <= niceMax + step * 0.5; v += step) {
      if (v >= min - step * 0.5 && v <= max + step * 0.5) out.add(v);
    }
    return out;
  }

  static double _niceNum(double range, bool round) {
    final exp = (math.log(range) / math.ln10).floor();
    final f = range / math.pow(10, exp);
    double nf;
    if (round) {
      if (f < 1.5) {
        nf = 1;
      } else if (f < 3) {
        nf = 2;
      } else if (f < 7) {
        nf = 5;
      } else {
        nf = 10;
      }
    } else {
      if (f <= 1) {
        nf = 1;
      } else if (f <= 2) {
        nf = 2;
      } else if (f <= 5) {
        nf = 5;
      } else {
        nf = 10;
      }
    }
    return nf * math.pow(10, exp);
  }

  static String _fmt(double v) {
    if (v == 0) return '0';
    final a = v.abs();
    if (a >= 1000 || a < 0.01) return v.toStringAsExponential(2);
    if (a >= 100) return v.toStringAsFixed(1);
    if (a >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(3);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.series != series ||
      old.viewMin != viewMin ||
      old.viewMax != viewMax ||
      old.cursorT != cursorT ||
      old.theme != theme;
}

class _Readout {
  final String name;
  final String value;
  final Color color;
  final double y;
  _Readout(this.name, this.value, this.color, this.y);
}
