import 'dart:typed_data';

import '../dbc/dbc_model.dart';
import '../mdf/mdf4_reader.dart';
import 'signal_series.dart';

/// Decodes CAN frames (read from an MF4 file) into physical signal time
/// series using a [DbcDatabase].
class CanDecoder {
  final CanFrameTable frames;
  final DbcDatabase db;

  /// arbitration id -> indices of frames carrying that id.
  final Map<int, List<int>> _frameIndexById = {};

  CanDecoder(this.frames, this.db) {
    for (var i = 0; i < frames.count; i++) {
      (_frameIndexById[frames.id[i]] ??= <int>[]).add(i);
    }
  }

  /// All signals that can be decoded (i.e. whose message id appears in the
  /// log), grouped by message name. Used to populate the signal picker.
  List<DecodableSignal> availableSignals() {
    final out = <DecodableSignal>[];
    for (final entry in _frameIndexById.entries) {
      final msg = db.messageForId(entry.key);
      if (msg == null) continue;
      for (final sig in msg.signals) {
        if (sig.isMultiplexor) continue;
        out.add(DecodableSignal(message: msg, signal: sig));
      }
    }
    out.sort((a, b) => a.qualifiedName.compareTo(b.qualifiedName));
    return out;
  }

  /// Decode a single signal across every matching frame in the log.
  SignalSeries decode(DbcMessage msg, DbcSignal sig) {
    final indices = _frameIndexById[msg.id] ?? const [];
    final ts = Float64List(indices.length);
    final vals = Float64List(indices.length);
    final isEnum = sig.isEnum;
    final labels = isEnum ? <String>[] : null;
    final levels = isEnum ? <String, int>{} : null;

    // Resolve the multiplexor switch signal once (if needed).
    DbcSignal? muxSwitch;
    if (sig.multiplexValue != null) {
      for (final s in msg.signals) {
        if (s.isMultiplexor) {
          muxSwitch = s;
          break;
        }
      }
    }

    var n = 0;
    for (final fi in indices) {
      final bytes = frames.dataBytesView(fi);

      if (muxSwitch != null) {
        final mv = _extractRaw(bytes, muxSwitch);
        if (mv.toInt() != sig.multiplexValue) continue;
      }

      final raw = _extractRaw(bytes, sig);
      ts[n] = frames.time[fi];
      if (isEnum) {
        final text = sig.enumTable!.text(raw) ?? raw.toInt().toString();
        labels!.add(text);
        levels!.putIfAbsent(text, () => levels.length);
        vals[n] = levels[text]!.toDouble();
      } else {
        vals[n] = raw * sig.factor + sig.offset;
      }
      n++;
    }

    if (n != indices.length) {
      // Multiplexed signal absent in some frames: trim arrays.
      return SignalSeries(
        name: sig.name,
        unit: sig.unit,
        timestamps: Float64List.sublistView(ts, 0, n),
        values: Float64List.sublistView(vals, 0, n),
        enumLabels: labels,
        enumLevels: levels,
      );
    }

    return SignalSeries(
      name: sig.name,
      unit: sig.unit,
      timestamps: ts,
      values: vals,
      enumLabels: labels,
      enumLevels: levels,
    );
  }

  /// Extract the raw (unscaled) integer value of [sig] from [bytes].
  static num _extractRaw(Uint8List bytes, DbcSignal sig) {
    if (sig.byteOrder == ByteOrder.littleEndian) {
      return _extractLittleEndian(bytes, sig.startBit, sig.bitLength, sig.signed);
    } else {
      return _extractBigEndian(bytes, sig.startBit, sig.bitLength, sig.signed);
    }
  }

  static num _extractLittleEndian(
      Uint8List bytes, int start, int len, bool signed) {
    var result = 0;
    for (var i = 0; i < len; i++) {
      final bit = start + i;
      final byteIndex = bit >> 3;
      if (byteIndex >= bytes.length) break;
      final b = (bytes[byteIndex] >> (bit & 7)) & 1;
      result |= b << i;
    }
    if (signed) result = _signExtend(result, len);
    return result;
  }

  /// Motorola / big-endian "sawtooth" extraction. [start] is the MSB position
  /// using the DBC bit-numbering convention.
  static num _extractBigEndian(
      Uint8List bytes, int start, int len, bool signed) {
    var result = 0;
    var bit = start;
    for (var i = 0; i < len; i++) {
      final byteIndex = bit >> 3;
      if (byteIndex >= bytes.length) {
        result <<= 1;
      } else {
        final b = (bytes[byteIndex] >> (7 - (bit & 7))) & 1;
        result = (result << 1) | b;
      }
      // advance to the next (less significant) bit along the sawtooth.
      if ((bit & 7) == 0) {
        bit += 15;
      } else {
        bit -= 1;
      }
    }
    if (signed) result = _signExtend(result, len);
    return result;
  }

  static int _signExtend(int value, int bits) {
    if (bits >= 64) return value;
    final signBit = 1 << (bits - 1);
    if ((value & signBit) != 0) {
      return value - (1 << bits);
    }
    return value;
  }
}

/// A signal that is known to be decodable from the loaded log.
class DecodableSignal {
  final DbcMessage message;
  final DbcSignal signal;

  DecodableSignal({required this.message, required this.signal});

  String get qualifiedName => signal.name;
  String get messageName => message.name;
  bool get isEnum => signal.isEnum;
  String get unit => signal.unit;
}
