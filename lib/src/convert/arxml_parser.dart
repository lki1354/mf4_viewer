import 'package:xml/xml.dart';

import '../dbc/dbc_model.dart';

/// Pragmatic AUTOSAR ARXML → [DbcDatabase] parser.
///
/// Targets the common system / ECU-extract description shape and extracts the
/// information needed to decode CAN signals:
///
///   `CAN-FRAME-TRIGGERING` (id, addressing mode, frame ref)
///     → `CAN-FRAME` (name, length)
///       → `PDU-TO-FRAME-MAPPING` → `I-SIGNAL-I-PDU`
///         → `I-SIGNAL-TO-I-PDU-MAPPING` (start bit, byte order, signal ref)
///           → `I-SIGNAL` (length, base type, compu method)
///             → `COMPU-METHOD` (LINEAR factor/offset or TEXTTABLE enum)
///
/// References (`*-REF`) are resolved against an index of every element that
/// carries a `SHORT-NAME`, keyed by its absolute AUTOSAR path.
///
/// Limitations: big-endian (Motorola) start-bit numbering is taken verbatim,
/// multiplexing is not modelled, and vendor-specific extensions are ignored.
/// For exact round-trips prefer little-endian (Intel) signals.
class ArxmlParser {
  final Map<String, XmlElement> _byPath = {};

  ArxmlParser._();

  static DbcDatabase parse(String xml) {
    final parser = ArxmlParser._();
    final doc = XmlDocument.parse(xml);
    parser._index(doc.rootElement, const []);
    return parser._build(doc);
  }

  // ---- path index --------------------------------------------------------

  void _index(XmlElement el, List<String> prefix) {
    final shortName = _childText(el, 'SHORT-NAME');
    final path = shortName == null ? prefix : [...prefix, shortName];
    if (shortName != null) {
      _byPath['/${path.join('/')}'] = el;
    }
    for (final child in el.children.whereType<XmlElement>()) {
      _index(child, path);
    }
  }

  XmlElement? _resolve(String? ref) {
    if (ref == null) return null;
    final key = ref.startsWith('/') ? ref : '/$ref';
    return _byPath[key];
  }

  // ---- build -------------------------------------------------------------

  DbcDatabase _build(XmlDocument doc) {
    final messages = <DbcMessage>[];
    for (final trig in doc.findAllElements('CAN-FRAME-TRIGGERING')) {
      final msg = _message(trig);
      if (msg != null) messages.add(msg);
    }
    return DbcDatabase(messages);
  }

  DbcMessage? _message(XmlElement trig) {
    final idText = _childText(trig, 'IDENTIFIER');
    final id = idText == null ? null : int.tryParse(idText.trim());
    if (id == null) return null;

    final mode = (_childText(trig, 'CAN-ADDRESSING-MODE') ??
            _childText(trig, 'ADDRESSING-MODE') ??
            'STANDARD')
        .toUpperCase();
    final extended = mode.contains('EXTENDED');
    final rawId = extended ? (id | 0x80000000) : id;

    final frame = _resolve(_refText(trig, 'FRAME-REF'));
    if (frame == null) return null;
    final name = _childText(frame, 'SHORT-NAME') ?? 'MSG_$id';
    final frameLenBits = int.tryParse(_childText(frame, 'FRAME-LENGTH') ?? '');
    final dlc = frameLenBits ?? 8;

    final signals = <DbcSignal>[];
    for (final pduMap in frame.findAllElements('PDU-TO-FRAME-MAPPING')) {
      final pdu = _resolve(_refText(pduMap, 'PDU-REF'));
      if (pdu == null) continue;
      final pduStartBits =
          int.tryParse(_childText(pduMap, 'START-POSITION') ?? '0') ?? 0;
      _collectSignals(pdu, pduStartBits, signals);
    }

    return DbcMessage(
      rawId: rawId,
      name: name,
      dlc: dlc,
      transmitter: 'Vector__XXX',
      signals: signals,
    );
  }

  void _collectSignals(XmlElement pdu, int pduStartBits, List<DbcSignal> out) {
    for (final map in pdu.findAllElements('I-SIGNAL-TO-I-PDU-MAPPING')) {
      final sig = _resolve(_refText(map, 'I-SIGNAL-REF'));
      if (sig == null) continue;
      final start = int.tryParse(_childText(map, 'START-POSITION') ?? '0') ?? 0;
      final orderText =
          (_childText(map, 'PACKING-BYTE-ORDER') ?? 'MOST-SIGNIFICANT-BYTE-LAST')
              .toUpperCase();
      final littleEndian = orderText.contains('LAST'); // Intel
      final byteOrder =
          littleEndian ? ByteOrder.littleEndian : ByteOrder.bigEndian;

      final length = int.tryParse(_childText(sig, 'LENGTH') ?? '') ?? 0;
      final signal = _signal(
        sig,
        name: _childText(sig, 'SHORT-NAME') ?? 'SIG',
        startBit: pduStartBits + start,
        bitLength: length,
        byteOrder: byteOrder,
      );
      out.add(signal);
    }
  }

  DbcSignal _signal(
    XmlElement sig, {
    required String name,
    required int startBit,
    required int bitLength,
    required ByteOrder byteOrder,
  }) {
    final props = _swDataDefProps(sig);
    final compu = _resolve(props == null ? null : _refText(props, 'COMPU-METHOD-REF'));
    final baseType =
        _resolve(props == null ? null : _refText(props, 'BASE-TYPE-REF'));

    var factor = 1.0;
    var offset = 0.0;
    EnumTable? enumTable;
    if (compu != null) {
      final category = (_childText(compu, 'CATEGORY') ?? '').toUpperCase();
      if (category == 'TEXTTABLE' || category == 'SCALE_LINEAR_AND_TEXTTABLE') {
        enumTable = _enumTable(compu);
      }
      if (category == 'LINEAR' ||
          category == 'RAT_FUNC' ||
          category == 'SCALE_LINEAR_AND_TEXTTABLE') {
        final lin = _linear(compu);
        if (lin != null) {
          offset = lin[0];
          factor = lin[1];
        }
      }
    }

    var signed = false;
    if (baseType != null) {
      final enc = (_childText(baseType, 'BASE-TYPE-ENCODING') ?? '').toUpperCase();
      signed = enc.contains('2C') || enc.contains('SIGNED');
    }

    return DbcSignal(
      name: name,
      startBit: startBit,
      bitLength: bitLength,
      byteOrder: byteOrder,
      signed: signed,
      factor: factor,
      offset: offset,
      min: 0,
      max: 0,
      unit: _unit(props),
      receivers: const [],
      enumTable: enumTable,
    );
  }

  XmlElement? _swDataDefProps(XmlElement sig) {
    final props = sig
        .findAllElements('SW-DATA-DEF-PROPS-CONDITIONAL')
        .toList();
    return props.isEmpty ? null : props.first;
  }

  String _unit(XmlElement? props) {
    if (props == null) return '';
    final unit = _resolve(_refText(props, 'UNIT-REF'));
    if (unit == null) return '';
    return _childText(unit, 'DISPLAY-NAME') ??
        _childText(unit, 'SHORT-NAME') ??
        '';
  }

  /// Returns `[offset, factor]` from a LINEAR/RAT_FUNC compu method.
  List<double>? _linear(XmlElement compu) {
    final scale = compu
        .findAllElements('COMPU-SCALE')
        .where((s) => s.findElements('COMPU-RATIONAL-COEFFS').isNotEmpty);
    if (scale.isEmpty) return null;
    final coeffs = scale.first.findElements('COMPU-RATIONAL-COEFFS').first;
    final num = _vValues(coeffs, 'COMPU-NUMERATOR');
    final den = _vValues(coeffs, 'COMPU-DENOMINATOR');
    final d0 = den.isNotEmpty ? den[0] : 1.0;
    if (d0 == 0) return null;
    final offset = (num.isNotEmpty ? num[0] : 0.0) / d0;
    final factor = (num.length > 1 ? num[1] : 0.0) / d0;
    return [offset, factor];
  }

  List<double> _vValues(XmlElement coeffs, String tag) {
    final container = coeffs.findElements(tag);
    if (container.isEmpty) return const [];
    return [
      for (final v in container.first.findElements('V'))
        double.tryParse(v.innerText.trim()) ?? 0.0,
    ];
  }

  EnumTable? _enumTable(XmlElement compu) {
    final entries = <int, String>{};
    for (final scale in compu.findAllElements('COMPU-SCALE')) {
      final vt = scale.findElements('COMPU-CONST').isNotEmpty
          ? _childText(scale.findElements('COMPU-CONST').first, 'VT')
          : _childText(scale, 'VT');
      final lower = _childText(scale, 'LOWER-LIMIT');
      if (vt == null || lower == null) continue;
      final key = int.tryParse(lower.trim());
      if (key != null) entries[key] = vt;
    }
    return entries.isEmpty ? null : EnumTable(entries);
  }

  // ---- xml helpers -------------------------------------------------------

  String? _childText(XmlElement el, String tag) {
    for (final c in el.children.whereType<XmlElement>()) {
      if (c.name.local == tag) return c.innerText;
    }
    return null;
  }

  String? _refText(XmlElement el, String tag) {
    for (final c in el.descendants.whereType<XmlElement>()) {
      if (c.name.local == tag) return c.innerText.trim();
    }
    return null;
  }
}
