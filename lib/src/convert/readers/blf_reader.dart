import 'dart:io';
import 'dart:typed_data';

import '../../mdf/mdf4_reader.dart';
import '../frame_builder.dart';

/// Reads CAN frames from a Vector Binary Logging Format (`.blf`) file.
///
/// BLF is a container format: a `LOGG` file header followed by a stream of
/// `LOBJ` objects. Most real logs wrap their events in `LOG_CONTAINER`
/// objects whose payload is zlib-compressed. The decompressed container
/// payloads form one continuous object stream — a single event may straddle
/// two containers — so this reader inflates each container and stitches the
/// stream back together before parsing the contained events.
///
/// Supported event types:
///   * `CAN_MESSAGE` (1) and `CAN_MESSAGE2` (86) — classic CAN.
///   * `CAN_FD_MESSAGE` (100) — CAN-FD (up to 64 payload bytes).
///   * `CAN_FD_MESSAGE_64` (101) — CAN-FD, the type written by current
///     Vector tools for both classic and FD frames.
/// Other object types are skipped by their declared size.
class BlfReader {
  // Object type ids.
  static const _canMessage = 1;
  static const _canMessage2 = 86;
  static const _canFdMessage = 100;
  static const _canFdMessage64 = 101;
  static const _logContainer = 10;

  // Compression methods used by LOG_CONTAINER.
  static const _noCompression = 0;
  static const _zlibDeflate = 2;

  // Extended-id flag carried in the BLF arbitration id.
  static const _extFlag = 0x80000000;

  static CanFrameTable read(Uint8List bytes) {
    if (bytes.length < 8 ||
        String.fromCharCodes(bytes, 0, 4) != 'LOGG') {
      throw const FormatException('Not a BLF file (missing LOGG signature).');
    }
    final bd = ByteData.sublistView(bytes);
    final headerSize = bd.getUint32(4, Endian.little);

    final fb = FrameBuilder();

    // Trailing bytes of the previous container that did not form a complete
    // object; the object continues in the next container.
    var tail = Uint8List(0);

    var pos = headerSize;
    while (true) {
      final start = _nextObject(bytes, pos);
      if (start < 0 || start + 16 > bytes.length) break;
      final headerVersion = bd.getUint16(start + 6, Endian.little);
      final objectSize = bd.getUint32(start + 8, Endian.little);
      final objectType = bd.getUint32(start + 12, Endian.little);
      if (objectSize < 16 || start + objectSize > bytes.length) break;

      if (objectType == _logContainer) {
        final inflated = _inflate(bytes, start, objectSize);
        if (inflated != null) {
          final stream = tail.isEmpty ? inflated : _concat(tail, inflated);
          final consumed = _parseStream(stream, fb);
          tail = consumed >= stream.length
              ? Uint8List(0)
              : Uint8List.sublistView(stream, consumed);
        }
      } else {
        _parseEvent(bytes, start, headerVersion, objectType, objectSize, fb);
      }

      // The next object follows after 0–3 padding bytes; _nextObject scans
      // for the signature, so no padding arithmetic is needed here.
      pos = start + objectSize;
    }
    return fb.build();
  }

  static CanFrameTable readFile(String path) =>
      read(File(path).readAsBytesSync());

  /// Find the next `LOBJ` signature at or shortly after [from].
  ///
  /// Objects are followed by 0–3 padding bytes whose exact count differs
  /// between writers (`objectSize % 4` in Vector's tools, round-up-to-4 in
  /// others), so the signature is searched for instead of computed.
  static int _nextObject(Uint8List data, int from) {
    final last = from + 4;
    for (var i = from; i <= last && i + 4 <= data.length; i++) {
      if (data[i] == 0x4C /* L */ &&
          data[i + 1] == 0x4F /* O */ &&
          data[i + 2] == 0x42 /* B */ &&
          data[i + 3] == 0x4A /* J */) {
        return i;
      }
    }
    return -1;
  }

  /// Decompress the payload of a LOG_CONTAINER object, or `null` if the
  /// compression method is unknown.
  static Uint8List? _inflate(Uint8List data, int pos, int objectSize) {
    final bd = ByteData.sublistView(data);
    // Container header (after the 16-byte base header):
    //   method u16, 6 reserved, uncompressed_size u32, 4 reserved  -> 16 bytes.
    final base = pos + 16;
    final method = bd.getUint16(base, Endian.little);
    final uncompressedSize = bd.getUint32(base + 8, Endian.little);
    final container = Uint8List.sublistView(data, base + 16, pos + objectSize);

    final Uint8List inflated;
    if (method == _noCompression) {
      inflated = container;
    } else if (method == _zlibDeflate) {
      inflated = Uint8List.fromList(ZLibCodec().decoder.convert(container));
    } else {
      return null; // unknown compression — skip this container.
    }

    if (uncompressedSize > 0 && uncompressedSize < inflated.length) {
      return Uint8List.sublistView(inflated, 0, uncompressedSize);
    }
    return inflated;
  }

  /// Parse complete objects from the stitched container stream [data].
  ///
  /// Returns the number of bytes consumed; the remainder starts an object
  /// that continues in the next container and must be retried once more data
  /// is available.
  static int _parseStream(Uint8List data, FrameBuilder fb) {
    final bd = ByteData.sublistView(data);
    var pos = 0;
    while (true) {
      final start = _nextObject(data, pos);
      // No signature within the padding window: end of stream, or the
      // remainder continues in the next container.
      if (start < 0 || start + 16 > data.length) return pos;
      final headerVersion = bd.getUint16(start + 6, Endian.little);
      final objectSize = bd.getUint32(start + 8, Endian.little);
      final objectType = bd.getUint32(start + 12, Endian.little);
      if (objectSize < 16) return data.length; // corrupt — discard the rest.
      if (start + objectSize > data.length) return pos; // split object.

      _parseEvent(data, start, headerVersion, objectType, objectSize, fb);
      pos = start + objectSize;
    }
  }

  static void _parseEvent(
    Uint8List data,
    int pos,
    int headerVersion,
    int objectType,
    int objectSize,
    FrameBuilder fb,
  ) {
    final bd = ByteData.sublistView(data);

    // Object header (after the 16-byte base header). v1: flags u32,
    // clientIndex u16, objectVersion u16, timestamp u64 (16 bytes). v2:
    // flags u32, timestampStatus u8, pad, objectVersion u16, timestamp u64,
    // originalTimestamp u64 (24 bytes). Both keep flags at +16 and the
    // timestamp at +24.
    final int payload;
    if (headerVersion == 1) {
      payload = pos + 32;
    } else if (headerVersion == 2) {
      payload = pos + 40;
    } else {
      return; // unknown header version.
    }
    if (payload + 16 > pos + objectSize || payload + 16 > data.length) return;

    final flags = bd.getUint32(pos + 16, Endian.little);
    final timestampRaw = bd.getUint64(pos + 24, Endian.little);

    // Timestamp units: TIME_TEN_MICS (1) -> 10 µs, otherwise nanoseconds.
    final factor = flags == 1 ? 1e-5 : 1e-9;
    final time = timestampRaw * factor;

    final end = pos + objectSize;
    switch (objectType) {
      case _canMessage:
      case _canMessage2:
        // channel u16, flags u8, dlc u8, arbitration_id u32, data[8].
        if (payload + 16 > data.length) return;
        final arbId = bd.getUint32(payload + 4, Endian.little);
        final dlc = data[payload + 3];
        final len = dlc > 8 ? 8 : dlc;
        fb.add(
          time: time,
          id: arbId & 0x1FFFFFFF,
          extended: (arbId & _extFlag) != 0,
          data: Uint8List.sublistView(data, payload + 8, payload + 8 + len),
          dlc: len,
        );
        break;
      case _canFdMessage:
        // channel u16, flags u8, dlc u8, arbitration_id u32, frameLength u32,
        // arbBitCount u8, fdFlags u8, validDataBytes u8, 5 reserved, data[64].
        if (payload + 20 > data.length) return;
        final arbId = bd.getUint32(payload + 4, Endian.little);
        final valid = data[payload + 14];
        var len = valid > 64 ? 64 : valid;
        final avail = (end < data.length ? end : data.length) - (payload + 20);
        if (len > avail) len = avail < 0 ? 0 : avail;
        fb.add(
          time: time,
          id: arbId & 0x1FFFFFFF,
          extended: (arbId & _extFlag) != 0,
          data: Uint8List.sublistView(data, payload + 20, payload + 20 + len),
          dlc: valid > 64 ? 64 : valid,
        );
        break;
      case _canFdMessage64:
        // channel u8, dlc u8, validDataBytes u8, txCount u8,
        // arbitration_id u32, frameLength u32, flags u32, btrCfgArb u32,
        // btrCfgData u32, timeOffsetBrs u32, timeOffsetCrcDel u32,
        // bitCount u16, dir u8, extDataOffset u8, crc u32, data[...].
        if (payload + 40 > data.length) return;
        final arbId = bd.getUint32(payload + 4, Endian.little);
        final valid = data[payload + 2] > 64 ? 64 : data[payload + 2];
        // When extDataOffset is set, the payload area ends there (extended
        // frame data follows); it may also be shorter than validDataBytes,
        // in which case the frame is zero-padded (as CANoe does).
        final extOffset = data[payload + 35];
        final headerLen = payload - pos;
        var avail = (extOffset != 0 ? extOffset : objectSize) - headerLen - 40;
        final inBuffer = (end < data.length ? end : data.length) - (payload + 40);
        if (avail > inBuffer) avail = inBuffer;
        final len = valid < avail ? valid : (avail < 0 ? 0 : avail);
        fb.add(
          time: time,
          id: arbId & 0x1FFFFFFF,
          extended: (arbId & _extFlag) != 0,
          data: Uint8List.sublistView(data, payload + 40, payload + 40 + len),
          dlc: valid,
        );
        break;
      default:
        break; // unsupported event type — ignored.
    }
  }

  static Uint8List _concat(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }
}
