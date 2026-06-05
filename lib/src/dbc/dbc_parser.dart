import 'dbc_model.dart';

/// A small, dependency-free parser for the textual DBC format.
///
/// It understands the directives required to decode signals:
///   * `BO_`  – message definition
///   * `SG_`  – signal definition (incl. multiplexing, byte order, sign)
///   * `VAL_` – value/enumeration tables
///
/// All other directives (`CM_`, `BA_`, `BU_`, …) are ignored.
class DbcParser {
  static final _boRe =
      RegExp(r'^\s*BO_\s+(\d+)\s+(\w+)\s*:\s*(\d+)\s+(\w+)');

  // SG_ <name> [mux] : start|len@order sign (factor,offset) [min|max] "unit" recv
  static final _sgRe = RegExp(
    r'^\s*SG_\s+(\w+)\s*(M|m\d+)?\s*:\s*'
    r'(\d+)\|(\d+)@([01])([+-])\s*'
    r'\(\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*\)\s*'
    r'\[\s*([-\d.eE+]*)\s*\|\s*([-\d.eE+]*)\s*\]\s*'
    r'"([^"]*)"\s*(.*)$',
  );

  static final _valRe = RegExp(r'^\s*VAL_\s+(\d+)\s+(\w+)\s+(.*?);?\s*$');
  static final _valPairRe = RegExp(r'(-?\d+)\s+"([^"]*)"');

  /// Parse [text] (the full DBC file contents) into a [DbcDatabase].
  static DbcDatabase parse(String text) {
    final messages = <DbcMessage>[];
    DbcMessage? current;
    // signal lookup per message id for attaching VAL_ tables afterwards.
    final signalIndex = <int, Map<String, DbcSignal>>{};

    final lines = text.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.replaceAll('\r', '');

      final bo = _boRe.firstMatch(line);
      if (bo != null) {
        final rawId = int.parse(bo.group(1)!);
        current = DbcMessage(
          rawId: rawId,
          name: bo.group(2)!,
          dlc: int.parse(bo.group(3)!),
          transmitter: bo.group(4)!,
          signals: [],
        );
        messages.add(current);
        signalIndex[current.id] = {};
        continue;
      }

      final sg = _sgRe.firstMatch(line);
      if (sg != null && current != null) {
        final muxTok = sg.group(2);
        int? muxVal;
        bool isMux = false;
        if (muxTok != null) {
          if (muxTok == 'M') {
            isMux = true;
          } else {
            muxVal = int.parse(muxTok.substring(1));
          }
        }
        final signal = DbcSignal(
          name: sg.group(1)!,
          startBit: int.parse(sg.group(3)!),
          bitLength: int.parse(sg.group(4)!),
          byteOrder:
              sg.group(5) == '1' ? ByteOrder.littleEndian : ByteOrder.bigEndian,
          signed: sg.group(6) == '-',
          factor: double.parse(sg.group(7)!),
          offset: double.parse(sg.group(8)!),
          min: double.tryParse(sg.group(9) ?? '') ?? 0,
          max: double.tryParse(sg.group(10) ?? '') ?? 0,
          unit: sg.group(11)!,
          receivers: sg.group(12)!.trim().isEmpty
              ? const []
              : sg.group(12)!.trim().split(RegExp(r'[,\s]+')),
          multiplexValue: muxVal,
          isMultiplexor: isMux,
        );
        current.signals.add(signal);
        signalIndex[current.id]![signal.name] = signal;
        continue;
      }

      final val = _valRe.firstMatch(line);
      if (val != null) {
        final rawId = int.parse(val.group(1)!);
        final id = (rawId & 0x80000000) != 0
            ? (rawId & 0x1FFFFFFF)
            : (rawId & 0x7FF);
        final sigName = val.group(2)!;
        final target = signalIndex[id]?[sigName];
        if (target != null) {
          final map = <int, String>{};
          for (final p in _valPairRe.allMatches(val.group(3)!)) {
            map[int.parse(p.group(1)!)] = p.group(2)!;
          }
          if (map.isNotEmpty) target.enumTable = EnumTable(map);
        }
        continue;
      }
    }

    return DbcDatabase(messages);
  }
}
