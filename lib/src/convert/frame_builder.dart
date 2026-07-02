import 'dart:typed_data';

import '../mdf/mdf4_reader.dart';

/// Incrementally assembles CAN frames read from any input format into the
/// columnar [CanFrameTable] used throughout the engine.
///
/// All input readers (BLF, TRC, CSV, MDF) funnel their frames through this
/// builder so the rest of the pipeline — and the MF4 writer in particular —
/// only ever deals with one canonical representation.
class FrameBuilder {
  final List<double> _time = [];
  final List<int> _id = [];
  final List<int> _ide = [];
  final List<int> _len = [];
  final List<Uint8List> _data = [];

  int get length => _time.length;

  /// Append one frame.
  ///
  /// [time] is in seconds, [id] the arbitration id (the extended-frame flag is
  /// carried separately in [extended]), [data] the payload (only the first
  /// `dlc` bytes are considered valid; if [dlc] is omitted it defaults to
  /// `data.length`).
  void add({
    required double time,
    required int id,
    required bool extended,
    required List<int> data,
    int? dlc,
  }) {
    final len = dlc ?? data.length;
    _time.add(time);
    _id.add(id & 0x1FFFFFFF);
    _ide.add(extended ? 1 : 0);
    _len.add(len);
    _data.add(Uint8List.fromList(data));
  }

  /// Materialise the accumulated frames.
  ///
  /// Frames are sorted by timestamp (a requirement for a well-formed MDF master
  /// channel) unless [sort] is `false`. The payload stride is sized to the
  /// largest frame seen (8 for classic CAN, up to 64 for CAN-FD).
  CanFrameTable build({bool sort = true}) {
    final n = _time.length;
    final order = List<int>.generate(n, (i) => i);
    if (sort) {
      // Tie-break on the original index so frames sharing a timestamp keep
      // their log order (List.sort is not stable).
      order.sort((a, b) {
        final byTime = _time[a].compareTo(_time[b]);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    }

    var stride = 8;
    for (final l in _len) {
      if (l > stride) stride = l;
    }

    final time = Float64List(n);
    final id = Int32List(n);
    final ide = Uint8List(n);
    final length = Uint8List(n);
    final payload = Uint8List(n * stride);

    for (var i = 0; i < n; i++) {
      final src = order[i];
      time[i] = _time[src];
      id[i] = _id[src];
      ide[i] = _ide[src];
      final l = _len[src];
      length[i] = l;
      final bytes = _data[src];
      final copy = l < bytes.length ? l : bytes.length;
      payload.setRange(i * stride, i * stride + copy, bytes);
    }

    return CanFrameTable(
      count: n,
      time: time,
      id: id,
      ide: ide,
      length: length,
      dataBytes: payload,
      stride: stride,
    );
  }
}
