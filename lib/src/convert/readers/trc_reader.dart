import 'dart:typed_data';

import '../../mdf/mdf4_reader.dart';
import '../frame_builder.dart';

/// Reads CAN frames from a PEAK PCAN-View trace (`.trc`) file.
///
/// Both the older 1.x and the column-richer 2.x layouts are handled by a single
/// tolerant tokeniser:
///
///   `<msg#>)  <time-ms>  [<type>]  <id-hex>  [Rx|Tx]  [-]  <dlc>  <b0 b1 …>`
///
/// Only data frames (`DT`/`FD`, or 1.x rows without an explicit type) yield
/// frames; remote/error/status rows are skipped. Timestamps are the PEAK
/// millisecond offset, converted to seconds.
class TrcReader {
  static final _typeRe = RegExp(r'^(DT|FD|RR|ER|ST|EC|BS|MC)$', caseSensitive: false);
  static const _dataTypes = {'DT', 'FD'};

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

      // Optional frame type (DT/FD/…). Skip non-data frames entirely.
      String? type;
      if (idx < tokens.length && _typeRe.hasMatch(tokens[idx])) {
        type = tokens[idx].toUpperCase();
        idx++;
        if (!_dataTypes.contains(type)) continue;
      }

      if (idx >= tokens.length) continue;
      final idTok = tokens[idx];
      final id = int.tryParse(idTok, radix: 16);
      if (id == null) continue;
      // PEAK marks extended ids with 8 hex digits (or an explicit value > 11 bit).
      final extended = idTok.length > 4 || id > 0x7FF;
      idx++;

      // Optional direction (Rx/Tx) and a reserved '-' placeholder (2.x).
      if (idx < tokens.length &&
          (tokens[idx].toLowerCase() == 'rx' ||
              tokens[idx].toLowerCase() == 'tx')) {
        idx++;
      }
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
