import 'dart:typed_data';

import '../../mdf/mdf4_reader.dart';
import '../frame_builder.dart';

/// Reads CAN frames from a delimited text (CSV) log.
///
/// The format is intentionally forgiving — column meaning is discovered from a
/// header row, the delimiter is auto-detected (`,`, `;` or tab) and several
/// common layouts for the payload are accepted:
///
/// * **Single payload column** named `Data` / `Data Bytes` holding hex bytes,
///   either space-separated (`11 22 33`) or contiguous (`112233`).
/// * **Per-byte columns** `D0..D7`, `Byte0..Byte7` or `Data0..Data7`.
///
/// Recognised columns (case-insensitive, punctuation ignored):
///   * time      — `Time`, `Timestamp`, `Time (s)`; a `ms`/`µs` unit in the
///                 header rescales to seconds.
///   * id        — `ID`, `Identifier`, `CAN ID`, `Arbitration ID`. Values with
///                 a `0x` prefix, or headers mentioning `hex`, are parsed as
///                 hex; otherwise decimal with a hex fallback.
///   * extended  — `IDE`, `Extended`; otherwise inferred from id > 0x7FF.
///   * dlc       — `DLC`, `Length`, `Len`; otherwise the payload byte count.
class CsvCanReader {
  static CanFrameTable read(String text) {
    final rows = _splitRows(text);
    if (rows.isEmpty) {
      throw const FormatException('CSV log is empty.');
    }

    final delimiter = _detectDelimiter(rows.first);
    final header =
        _splitLine(rows.first, delimiter).map((h) => _strip(_norm(h))).toList();

    int? col(List<String> names) {
      for (final n in names) {
        final i = header.indexOf(n);
        if (i >= 0) return i;
      }
      return null;
    }

    final timeCol = col(['time', 'timestamp', 'times', 'abstime', 'timeabs']);
    final timeScale = _timeScale(rows.first, delimiter, timeCol);
    final idCol = col(['id', 'identifier', 'canid', 'arbitrationid', 'msgid', 'frameid']);
    if (idCol == null) {
      throw const FormatException('CSV log has no recognisable ID column.');
    }
    final idIsHex = _headerIsHex(rows.first, delimiter, idCol);
    final ideCol = col(['ide', 'extended', 'ext', 'xtd']);
    final dlcCol = col(['dlc', 'length', 'len', 'datalength', 'datalen']);
    final dataCol = col(['data', 'databytes', 'data bytes', 'payload', 'bytes']);

    // Per-byte payload columns (D0/Byte0/Data0 …) in ascending order.
    final byteCols = <int>[];
    final byteRe = RegExp(r'^(?:d|data|byte)(\d+)$');
    final indexed = <int, int>{};
    for (var i = 0; i < header.length; i++) {
      final m = byteRe.firstMatch(header[i]);
      if (m != null) indexed[int.parse(m.group(1)!)] = i;
    }
    if (dataCol == null && indexed.isNotEmpty) {
      final keys = indexed.keys.toList()..sort();
      for (final k in keys) {
        byteCols.add(indexed[k]!);
      }
    }

    final fb = FrameBuilder();
    for (var r = 1; r < rows.length; r++) {
      final line = rows[r];
      if (line.trim().isEmpty) continue;
      final cells = _splitLine(line, delimiter);
      if (idCol >= cells.length) continue;

      final time = timeCol != null && timeCol < cells.length
          ? (double.tryParse(cells[timeCol].trim()) ?? 0) * timeScale
          : (r - 1).toDouble();

      final id = _parseInt(cells[idCol], hex: idIsHex);
      if (id == null) continue;

      bool extended;
      if (ideCol != null && ideCol < cells.length) {
        extended = _truthy(cells[ideCol]);
      } else {
        extended = id > 0x7FF;
      }

      final List<int> data;
      if (dataCol != null && dataCol < cells.length) {
        data = _parseHexBytes(cells[dataCol]);
      } else if (byteCols.isNotEmpty) {
        data = [
          for (final c in byteCols)
            if (c < cells.length && cells[c].trim().isNotEmpty)
              _parseInt(cells[c], hex: true) ?? 0,
        ];
      } else {
        data = const [];
      }

      int? dlc;
      if (dlcCol != null && dlcCol < cells.length) {
        dlc = _parseInt(cells[dlcCol], hex: false);
      }

      fb.add(
        time: time,
        id: id,
        extended: extended,
        data: data,
        dlc: dlc ?? data.length,
      );
    }

    return fb.build();
  }

  // ---- helpers -----------------------------------------------------------

  static List<String> _splitRows(String text) => text
      .split('\n')
      .map((l) => l.replaceAll('\r', ''))
      .where((l) => l.isNotEmpty && !l.startsWith('#') && !l.startsWith('//'))
      .toList();

  static String _detectDelimiter(String headerLine) {
    for (final d in [',', ';', '\t']) {
      if (headerLine.contains(d)) return d;
    }
    return ',';
  }

  static List<String> _splitLine(String line, String delimiter) {
    // Minimal quoted-field support: keep delimiters inside double quotes.
    final out = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == delimiter && !inQuotes) {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Drop a trailing unit/format token (`hex`, `ms`, `us`, `sec`) so headers
  /// like `Identifier (hex)` or `Timestamp (ms)` still match `identifier` /
  /// `timestamp`. Byte columns (`data0`) keep their digit suffix.
  static String _strip(String h) {
    for (final u in const ['hex', 'ms', 'us', 'sec']) {
      if (h.length > u.length && h.endsWith(u)) {
        return h.substring(0, h.length - u.length);
      }
    }
    return h;
  }

  static double _timeScale(String headerLine, String delimiter, int? timeCol) {
    if (timeCol == null) return 1.0;
    final raw = _splitLine(headerLine, delimiter);
    if (timeCol >= raw.length) return 1.0;
    final h = raw[timeCol].toLowerCase();
    if (h.contains('us') || h.contains('µs') || h.contains('micro')) return 1e-6;
    if (h.contains('ms') || h.contains('milli')) return 1e-3;
    return 1.0;
  }

  static bool _headerIsHex(String headerLine, String delimiter, int idCol) {
    final raw = _splitLine(headerLine, delimiter);
    return idCol < raw.length && raw[idCol].toLowerCase().contains('hex');
  }

  static int? _parseInt(String cell, {required bool hex}) {
    var s = cell.trim();
    if (s.isEmpty) return null;
    if (s.toLowerCase().startsWith('0x')) {
      return int.tryParse(s.substring(2), radix: 16);
    }
    if (hex) return int.tryParse(s, radix: 16);
    return int.tryParse(s) ?? int.tryParse(s, radix: 16);
  }

  static List<int> _parseHexBytes(String cell) {
    var s = cell.trim();
    if (s.isEmpty) return const [];
    if (s.contains(' ') || s.contains('-') || s.contains(',')) {
      return [
        for (final tok in s.split(RegExp(r'[\s,\-]+')))
          if (tok.isNotEmpty) int.tryParse(tok, radix: 16) ?? 0,
      ];
    }
    // Contiguous hex string: split into byte pairs.
    if (s.toLowerCase().startsWith('0x')) s = s.substring(2);
    final out = <int>[];
    for (var i = 0; i + 1 < s.length; i += 2) {
      out.add(int.tryParse(s.substring(i, i + 2), radix: 16) ?? 0);
    }
    return out;
  }

  static bool _truthy(String s) {
    final v = s.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'x' || v == 'yes' ||
        v == 'extended' || v == 'ext';
  }

  /// Convenience: read directly from raw file bytes.
  static CanFrameTable readBytes(Uint8List bytes) =>
      read(String.fromCharCodes(bytes));
}
