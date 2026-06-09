import 'dart:typed_data';

import '../../mdf/mdf4_reader.dart';
import '../frame_builder.dart';

/// Reads CAN frames from a Vector / PEAK PCAN-View **ASCII** trace (`.asc`).
///
/// This is the de-facto text log format emitted by PCAN-View ("Save As …
/// ASCII") and the Vector CANalyzer/CANoe tool-chain. A tolerant tokeniser
/// handles both the classic-CAN and the CAN-FD line layouts:
///
///   classic: `<time> <chan> <id>[x] <Rx|Tx> d <dlc> <b0 b1 …>`
///   CAN-FD:  `<time> CANFD <chan> <Rx|Tx> <id>[x] [name] <brs> <esi> <dlc>
///             <len> <b0 b1 …> …`
///
/// Timestamps are absolute seconds (the ASC convention). Numbers default to
/// hexadecimal; a `base dec` header switches ids and payload bytes to decimal.
/// Only data frames yield rows — remote (`r`), error (`ErrorFrame`), statistic
/// and trigger lines are skipped. A trailing `x` on the id (or an 11-bit
/// overflow) marks an extended frame.
class AscReader {
  static CanFrameTable read(String text) {
    final fb = FrameBuilder();
    var radix = 16; // Vector default is `base hex`.

    for (final raw in text.split('\n')) {
      final line = raw.replaceAll('\r', '').trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith(';')) {
        continue;
      }

      final lower = line.toLowerCase();
      // Header / control lines that precede or interleave the data block.
      if (lower.startsWith('base ')) {
        if (lower.contains('dec')) radix = 10;
        if (lower.contains('hex')) radix = 16;
        continue;
      }
      if (lower.startsWith('date ') ||
          lower.startsWith('begin triggerblock') ||
          lower.startsWith('end triggerblock') ||
          lower.startsWith('internal events') ||
          lower.startsWith('measurement') ||
          lower.startsWith('//')) {
        continue;
      }

      final tokens = line.split(RegExp(r'\s+'));
      if (tokens.length < 2) continue;

      final time = double.tryParse(tokens[0]);
      if (time == null) continue; // not a timed event line (e.g. "Start of …").

      final parsed = tokens[1].toLowerCase() == 'canfd'
          ? _parseFd(tokens, radix)
          : _parseClassic(tokens, radix);
      if (parsed == null) continue;

      fb.add(
        time: time,
        id: parsed.id,
        extended: parsed.extended,
        data: parsed.data,
        dlc: parsed.length,
      );
    }

    return fb.build();
  }

  static CanFrameTable readBytes(Uint8List bytes) =>
      read(String.fromCharCodes(bytes));

  /// `<time> <chan> <id>[x] <Rx|Tx> <d|r> <dlc> <bytes…>`
  static _AscFrame? _parseClassic(List<String> t, int radix) {
    if (t.length < 6) return null;
    // t[0]=time, t[1]=channel.
    final idInfo = _parseId(t[2], radix);
    if (idInfo == null) return null;

    if (!_isDir(t[3])) return null;
    // Frame type: only data frames carry a payload. `r` = remote frame.
    if (t[4].toLowerCase() != 'd') return null;

    final dlc = int.tryParse(t[5]);
    if (dlc == null) return null;

    return _AscFrame(
      id: idInfo.id,
      extended: idInfo.extended,
      length: dlc,
      data: _bytes(t, 6, dlc, radix),
    );
  }

  /// `<time> CANFD <chan> <Rx|Tx> <id>[x] [name] <brs> <esi> <dlc> <len>
  ///  <bytes…> …`
  static _AscFrame? _parseFd(List<String> t, int radix) {
    if (t.length < 9) return null;
    // t[0]=time, t[1]=CANFD, t[2]=channel, t[3]=dir, t[4]=id.
    if (!_isDir(t[3])) return null;
    final idInfo = _parseId(t[4], radix);
    if (idInfo == null) return null;

    // An optional symbolic message name sits between the id and the brs flag.
    // Locate the `<brs> <esi> <dlc> <len>` quartet: brs/esi are single 0/1
    // digits, dlc a short hex code, len a plausible decimal byte count.
    var j = 5;
    int? len;
    while (j + 3 < t.length) {
      final brs = t[j];
      final esi = t[j + 1];
      final dlcOk = int.tryParse(t[j + 2], radix: 16) != null &&
          t[j + 2].length <= 2;
      final l = int.tryParse(t[j + 3]);
      if ((brs == '0' || brs == '1') &&
          (esi == '0' || esi == '1') &&
          dlcOk &&
          l != null &&
          l >= 0 &&
          l <= 64) {
        len = l;
        break;
      }
      j++;
    }
    if (len == null) return null;

    return _AscFrame(
      id: idInfo.id,
      extended: idInfo.extended,
      length: len,
      data: _bytes(t, j + 4, len, radix),
    );
  }

  static List<int> _bytes(List<String> t, int start, int count, int radix) {
    final data = <int>[];
    for (var i = start; i < t.length && data.length < count; i++) {
      final b = int.tryParse(t[i], radix: radix);
      if (b == null || b < 0 || b > 0xFF) break;
      data.add(b);
    }
    return data;
  }

  static bool _isDir(String s) {
    final d = s.toLowerCase();
    return d == 'rx' || d == 'tx';
  }

  /// Parse an arbitration id token, honouring a trailing `x` extended marker.
  static _IdInfo? _parseId(String tok, int radix) {
    var s = tok;
    var extended = false;
    if (s.toLowerCase().endsWith('x')) {
      extended = true;
      s = s.substring(0, s.length - 1);
    }
    final id = int.tryParse(s, radix: radix);
    if (id == null) return null;
    return _IdInfo(id, extended || id > 0x7FF);
  }
}

class _IdInfo {
  final int id;
  final bool extended;
  _IdInfo(this.id, this.extended);
}

class _AscFrame {
  final int id;
  final bool extended;
  final int length;
  final List<int> data;
  _AscFrame({
    required this.id,
    required this.extended,
    required this.length,
    required this.data,
  });
}
