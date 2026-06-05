import 'dart:typed_data';

/// A decoded time series for a single signal.
///
/// [timestamps] and [values] are parallel arrays.  For enumerated signals
/// [enumLabels] holds the textual representation per sample and [enumLevels]
/// maps the distinct labels to the integer y-levels used for plotting.
class SignalSeries {
  final String name;
  final String unit;
  final Float64List timestamps;

  /// Physical (scaled) values. For enum signals these are the raw integer
  /// codes promoted to double.
  final Float64List values;

  /// Per-sample enum text (only for enumerated signals), else `null`.
  final List<String>? enumLabels;

  /// Stable label -> y-level mapping for enumerated signals.
  final Map<String, int>? enumLevels;

  SignalSeries({
    required this.name,
    required this.unit,
    required this.timestamps,
    required this.values,
    this.enumLabels,
    this.enumLevels,
  });

  bool get isEnum => enumLevels != null;

  int get length => timestamps.length;

  double get tMin => timestamps.isEmpty ? 0 : timestamps.first;
  double get tMax => timestamps.isEmpty ? 0 : timestamps.last;

  /// Inverse of [enumLevels]: y-level -> label.
  Map<int, String> get levelLabels {
    final out = <int, String>{};
    if (enumLevels != null) {
      enumLevels!.forEach((k, v) => out[v] = k);
    }
    return out;
  }
}
