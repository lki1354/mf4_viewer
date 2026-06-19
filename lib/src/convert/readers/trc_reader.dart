import 'dart:typed_data';

import '../../mdf/mdf4_reader.dart';
import '../frame_builder.dart';

/// Reads CAN frames from a PEAK PCAN-View trace (`.trc`) file.
///
/// The various PEAK layouts differ in where the direction (`Rx`/`Tx`) and the
/// frame type (`DT`/`FD`/…) columns sit relative to the ID. A single tolerant
/// tokeniser handles all of them:
///
///   `<msg#>)  <time-ms>  [Rx|Tx|type…]  <id-hex>  [Rx|Tx|type…]  [-]  <dlc>  <b0 b1 …>`
///
/// In particular:
///   * 2.x:                 `… DT  <id>  Rx -  <dlc> …`  (type before, dir after)
///   * 1.1 (DENS Kano etc): `… Rx  <id>  <dlc> …`        (dir in the type column,
///                                                         i.e. *before* the ID)
///   * plain 1.x:           `… <id>  <dlc> …`            (no type/dir column)
///
/// Only data frames (`DT`/`FD`, or rows without an explicit type) yield frames;
/// remote/error/status rows are skipped. Timestamps are the PEAK millisecond
/// offset, converted to seconds.
class TrcReader {
  static final _typeRe = RegExp(r'^(DT|FD|RR|ER|ST|EC|BS|MC)$', caseSensitive: false);
  static const _dataTypes = {'DT', 'FD'};

  /// Consumes any consecutive direction (`Rx`/`Tx`) or frame-type tokens at
  /// [idx]. Returns the new index, and whether a *non-data* frame type was seen
  /// (in which case the caller should skip the whole row).
  static (int, bool) _consumeTypeDir(List<String> tokens, int idx) {
    var skip = false;
    while (idx < tokens.length) {
      final t = tokens[idx];
      final lower = t.toLowerCase();
      if (lower == 'rx' || lower == 'tx') {
        idx++;
        continue;
      }
      if (_typeRe.hasMatch(t)) {
        if (!_dataTypes.contains(t.toUpperCase())) skip = true;
        idx++;
        continue;
      }
      break;
    }
    return (idx, skip);
  }

  static CanFrameTable read(String text) {
    final fb = FrameBuilder();

    for (final raw in text.split('\n')) {
      final line = raw.replaceAll('\r', '').trim();
      if (line.isEmpty || line.startsWith(';')) continue;

      final tokens = line.split(RegExp(r'\s+'));
      if (tokens.length < 4) continue;

      // tokens[0] = message number, with a trailing ')' in 1.x / 2.x.
      var idx = 1;
      final time = double.tryParse(tokens[idx]);
      if (time == null) continue;
      idx++;

      // Optional direction/type columns that precede the ID (1.1 puts the
      // direction here; 2.x puts the frame type here). Skip non-data frames.
      var skip = false;
      (idx, skip) = _consumeTypeDir(tokens, idx);
      if (skip) continue;

      if (idx >= tokens.length) continue;
      final idTok = tokens[idx];
      final id = int.tryParse(idTok, radix: 16);
      if (id == null) continue;
      // PEAK marks extended ids with 8 hex digits (or an explicit value > 11 bit).
      final extended = idTok.length > 4 || id > 0x7FF;
      idx++;

      // Optional direction/type columns that follow the ID (2.x), plus the
      // reserved '-' placeholder.
      (idx, skip) = _consumeTypeDir(tokens, idx);
      if (skip) continue;
      if (idx < tokens.length && tokens[idx] == '-') idx++;

      if (idx >= tokens.length) continue;
      final dlc = int.tryParse(tokens[idx]);
      if (dlc == null) continue;
      idx++;

      final data = <int>[];
      for (var i = idx; i < tokens.length && data.length < dlc; i++) {
        final b = int.tryParse(tokens[i], radix: 16);
        if (b == null) break;
        data.add(b);
      }

      fb.add(
        time: time / 1000.0,
        id: id,
        extended: extended,
        data: data,
        dlc: dlc,
      );
    }

    return fb.build();
  }

  static CanFrameTable readBytes(Uint8List bytes) =>
      read(String.fromCharCodes(bytes));
}
