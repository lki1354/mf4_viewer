import 'dbc_model.dart';

/// Serialises a [DbcDatabase] back to textual DBC.
///
/// Used to embed a canonical `.dbc` in the converted MF4 file — in particular
/// so a database supplied as ARXML can be carried alongside the CAN trace in a
/// form the viewer (and other DBC-based tools) can decode.
class DbcWriter {
  static String write(DbcDatabase db) {
    final b = StringBuffer();
    b.writeln('VERSION ""');
    b.writeln();
    b.writeln('BS_:');
    b.writeln();
    b.writeln('BU_:');
    b.writeln();

    for (final m in db.messages) {
      _writeMessage(b, m);
    }

    // Value tables (VAL_) for enumerated signals.
    for (final m in db.messages) {
      for (final s in m.signals) {
        final table = s.enumTable;
        if (table == null || table.isEmpty) continue;
        b.write('VAL_ ${m.rawId} ${s.name}');
        final keys = table.entries.keys.toList()..sort();
        for (final k in keys) {
          b.write(' $k "${table.entries[k]}"');
        }
        b.writeln(' ;');
      }
    }

    return b.toString();
  }

  static void _writeMessage(StringBuffer b, DbcMessage m) {
    final transmitter =
        m.transmitter.isEmpty ? 'Vector__XXX' : m.transmitter;
    b.writeln('BO_ ${m.rawId} ${m.name}: ${m.dlc} $transmitter');
    for (final s in m.signals) {
      _writeSignal(b, s);
    }
    b.writeln();
  }

  static void _writeSignal(StringBuffer b, DbcSignal s) {
    final order = s.byteOrder == ByteOrder.littleEndian ? '1' : '0';
    final sign = s.signed ? '-' : '+';
    final mux = s.isMultiplexor
        ? ' M'
        : (s.multiplexValue != null ? ' m${s.multiplexValue}' : '');
    final receivers =
        s.receivers.isEmpty ? 'Vector__XXX' : s.receivers.join(',');
    b.writeln(
      ' SG_ ${s.name}$mux : '
      '${s.startBit}|${s.bitLength}@$order$sign '
      '(${_num(s.factor)},${_num(s.offset)}) '
      '[${_num(s.min)}|${_num(s.max)}] '
      '"${s.unit}" $receivers',
    );
  }

  /// Render a double without a trailing `.0` for whole numbers, matching the
  /// terse style most DBC tooling emits.
  static String _num(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return v.toString();
  }
}
