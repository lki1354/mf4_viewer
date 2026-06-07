import 'dart:io';
import 'dart:typed_data';

import '../../mdf/mdf4_reader.dart';
import '../frame_builder.dart';

/// Reads CAN frames from a Vector Binary Logging Format (`.blf`) file.
///
/// BLF is a container format: a `LOGG` file header followed by a stream of
/// `LOBJ` objects. Most real logs wrap their events in `LOG_CONTAINER`
/// objects whose payload is zlib-compressed; this reader transparently inflates
/// those and parses the contained events.
///
/// Supported event types:
///   * `CAN_MESSAGE` (1) and `CAN_MESSAGE2` (86) — classic CAN.
///   * `CAN_FD_MESSAGE` (100) — CAN-FD (up to 64 payload bytes).
/// Other object types are skipped by their declared size.
class BlfReader {
  // Object type ids.
  static const _canMessage = 1;
  static const _canMessage2 = 86;
  static const _canFdMessage = 100;
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
    _parseObjects(bytes, headerSize, bytes.length, fb);
    return fb.build();
  }

  static CanFrameTable readFile(String path) =>
      read(File(path).readAsBytesSync());

  /// Walk the `LOBJ` object stream in [data] over `[start, end)`.
  static void _parseObjects(Uint8List data, int start, int end, FrameBuilder fb) {
    final bd = ByteData.sublistView(data);
    var pos = start;
    while (pos + 16 <= end) {
      if (String.fromCharCodes(data, pos, pos + 4) != 'LOBJ') break;
      final headerVersion = bd.getUint16(pos + 6, Endian.little);
      final objectSize = bd.getUint32(pos + 8, Endian.little);
      final objectType = bd.getUint32(pos + 12, Endian.little);
      if (objectSize < 16 || pos + objectSize > end) break;

      if (objectType == _logContainer) {
        _parseContainer(data, pos, objectSize, fb);
      } else {
        _parseEvent(data, pos, headerVersion, objectType, objectSize, fb);
      }

      // Objects are padded to a 4-byte boundary.
      pos += (objectSize + 3) & ~3;
    }
  }

  static void _parseContainer(Uint8List data, int pos, int objectSize, FrameBuilder fb) {
    final bd = ByteData.sublistView(data);
    // Container header (after the 16-byte base header):
    //   method u16, 6 reserved, uncompressed_size u32, 4 reserved  -> 16 bytes.
    final base = pos + 16;
    final method = bd.getUint16(base, Endian.little);
    final uncompressedSize = bd.getUint32(base + 8, Endian.little);
    final dataStart = base + 16;
    final dataEnd = pos + objectSize;
    final container = Uint8List.sublistView(data, dataStart, dataEnd);

    final Uint8List inflated;
    if (method == _noCompression) {
      inflated = container;
    } else if (method == _zlibDeflate) {
      inflated = Uint8List.fromList(ZLibCodec().decoder.convert(container));
    } else {
      return; // unknown compression — skip this container.
    }

    final limit =
        uncompressedSize > 0 && uncompressedSize <= inflated.length
            ? uncompressedSize
            : inflated.length;
    _parseObjects(inflated, 0, limit, fb);
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

    // Object header (after 16-byte base). v1: flags u32, clientIndex u16,
    // objectVersion u16, timestamp u64. v2 prepends a status byte but keeps a
    // u32 flags + u64 timestamp we can locate.
    int flags;
    int timestampRaw;
    int payload;
    if (headerVersion == 1) {
      flags = bd.getUint32(pos + 16, Endian.little);
      timestampRaw = bd.getUint64(pos + 24, Endian.little);
      payload = pos + 32;
    } else {
      flags = bd.getUint32(pos + 16, Endian.little);
      timestampRaw = bd.getUint64(pos + 24, Endian.little);
      payload = pos + 40;
    }

    // Timestamp units: TIME_ONE_NANS (2) -> ns, else TIME_TEN_MICS -> 10 µs.
    final factor = (flags & 0x02) != 0 ? 1e-9 : 1e-5;
    final time = timestampRaw * factor;

    switch (objectType) {
      case _canMessage:
      case _canMessage2:
        // channel u16, flags u8, dlc u8, arbitration_id u32, data[8].
        final arbId = bd.getUint32(payload + 4, Endian.little);
        final dlc = data[payload + 3];
        final len = dlc > 8 ? 8 : dlc;
        final frame = Uint8List.sublistView(data, payload + 8, payload + 8 + 8);
        fb.add(
          time: time,
          id: arbId & 0x1FFFFFFF,
          extended: (arbId & _extFlag) != 0,
          data: frame.sublist(0, len),
          dlc: len,
        );
        break;
      case _canFdMessage:
        // channel u16, flags u8, dlc u8, arbitration_id u32, frameLength u32,
        // arbBitCount u8, fdFlags u8, validDataBytes u8, reserved u8, data[64].
        final arbId = bd.getUint32(payload + 4, Endian.little);
        final valid = data[payload + 14];
        final len = valid > 64 ? 64 : valid;
        final frame =
            Uint8List.sublistView(data, payload + 16, payload + 16 + 64);
        fb.add(
          time: time,
          id: arbId & 0x1FFFFFFF,
          extended: (arbId & _extFlag) != 0,
          data: frame.sublist(0, len),
          dlc: len,
        );
        break;
      default:
        break; // unsupported event type — ignored.
    }
  }
}
