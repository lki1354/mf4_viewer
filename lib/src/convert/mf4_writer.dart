import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../mdf/mdf4_reader.dart';

/// An attachment to embed in the written MF4 file (e.g. the source database).
class Mf4Attachment {
  final String fileName;
  final String mimeType;
  final Uint8List data;

  /// zlib-compress the payload on write (the format the viewer expects for
  /// embedded `.dbc` databases).
  final bool compress;

  Mf4Attachment({
    required this.fileName,
    required this.data,
    this.mimeType = 'application/octet-stream',
    this.compress = true,
  });
}

/// Writes a [CanFrameTable] as a valid ASAM MDF 4.10 (`.mf4`) bus-logging file.
///
/// The layout deliberately mirrors what [Mdf4Reader] consumes — a single sorted
/// data group whose record carries the master `t` channel plus the standard
/// `CAN_DataFrame.*` channels — so a file written here reads back identically.
/// Optional attachments (typically the DBC/ARXML database) are embedded as
/// `##AT` blocks, zlib-compressed by default.
class Mf4Writer {
  static const _blockHeader = 24; // id(4) + reserved(4) + length(8) + nlinks(8)

  /// Channel record layout (byte offsets within one record):
  ///   t              : float64 @ 0   (8 bytes, master)
  ///   CAN_DataFrame.ID         : uint32 @ 8   (4 bytes)
  ///   CAN_DataFrame.IDE        : uint8  @ 12  (1 byte)
  ///   CAN_DataFrame.DataLength : uint8  @ 13  (1 byte)
  ///   CAN_DataFrame.DataBytes  : bytes  @ 14  (stride bytes)
  static const _offTime = 0;
  static const _offId = 8;
  static const _offIde = 12;
  static const _offLen = 13;
  static const _offData = 14;

  static Uint8List write(
    CanFrameTable frames, {
    List<Mf4Attachment> attachments = const [],
  }) {
    final stride = frames.stride;
    final recordSize = _offData + stride;
    final recordBytes = recordSize * frames.count;

    // Channel definitions, in record order.
    final channels = <_Channel>[
      _Channel('t', type: 2, syncType: 1, dataType: 4, byteOffset: _offTime, bitCount: 64),
      _Channel('CAN_DataFrame.ID', dataType: 0, byteOffset: _offId, bitCount: 32),
      _Channel('CAN_DataFrame.IDE', dataType: 0, byteOffset: _offIde, bitCount: 8),
      _Channel('CAN_DataFrame.DataLength', dataType: 0, byteOffset: _offLen, bitCount: 8),
      _Channel('CAN_DataFrame.DataBytes', dataType: 10, byteOffset: _offData, bitCount: stride * 8),
    ];

    // Pre-compress attachments so we know their final sizes before laying out.
    final atPayloads = [
      for (final a in attachments)
        a.compress
            ? Uint8List.fromList(ZLibCodec().encoder.convert(a.data))
            : a.data,
    ];

    // ---- assign block offsets (sizes are deterministic) -------------------
    var pos = 64; // ID block occupies [0, 64)
    final hdOff = pos;
    pos += _size(6, 32);

    final nameOff = <int>[];
    for (final c in channels) {
      nameOff.add(pos);
      pos += _size(0, utf8.encode(c.name).length + 1);
    }

    final atFileNameOff = <int>[];
    final atOff = <int>[];
    for (var i = 0; i < attachments.length; i++) {
      atFileNameOff.add(pos);
      pos += _size(0, utf8.encode(attachments[i].fileName).length + 1);
      atOff.add(pos);
      pos += _size(4, 40 + atPayloads[i].length);
    }

    final dgOff = pos;
    pos += _size(4, 8);
    final cgOff = pos;
    pos += _size(6, 32);

    final cnOff = <int>[];
    for (var i = 0; i < channels.length; i++) {
      cnOff.add(pos);
      pos += _size(8, 72);
    }

    final dtOff = pos;
    final total = dtOff + _blockHeader + recordBytes;

    // ---- serialise ---------------------------------------------------------
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    _writeIdBlock(out);

    // HD: links dg_first, fh_first, ch_first, at_first, ev_first, md.
    final hd = _BlockWriter(out, bd, hdOff, '##HD', [
      dgOff,
      0,
      0,
      atOff.isEmpty ? 0 : atOff.first,
      0,
      0,
    ]);
    hd.u64(DateTime.now().toUtc().microsecondsSinceEpoch * 1000); // start_time_ns
    hd.i16(0); // tz offset
    hd.i16(0); // dst offset
    hd.u8(0); // time flags
    hd.u8(0); // time class
    hd.u8(0); // flags
    hd.u8(0); // reserved
    hd.f64(0); // start angle
    hd.f64(0); // start distance

    for (var i = 0; i < channels.length; i++) {
      _writeTx(out, bd, nameOff[i], channels[i].name);
    }

    for (var i = 0; i < attachments.length; i++) {
      _writeTx(out, bd, atFileNameOff[i], attachments[i].fileName);
      final a = attachments[i];
      final payload = atPayloads[i];
      final next = i + 1 < attachments.length ? atOff[i + 1] : 0;
      final at = _BlockWriter(out, bd, atOff[i], '##AT', [
        next,
        atFileNameOff[i],
        0,
        0,
      ]);
      at.u16(a.compress ? 0x03 : 0x01); // flags: embedded (+compressed)
      at.u16(0); // creator index
      at.skip(4); // reserved
      at.skip(16); // md5 (unused)
      at.u64(a.data.length); // original size
      at.u64(payload.length); // embedded size
      at.bytes(payload);
    }

    // DG: links dg_next, cg_first, dg_data, md.
    final dg = _BlockWriter(out, bd, dgOff, '##DG', [0, cgOff, dtOff, 0]);
    dg.u8(0); // rec_id_size = 0 (sorted, single CG)
    dg.skip(7);

    // CG: links cg_next, cn_first, tx_acq_name, si_acq_source, sr_first, md.
    final cg = _BlockWriter(out, bd, cgOff, '##CG', [0, cnOff.first, 0, 0, 0, 0]);
    cg.u64(0); // record id
    cg.u64(frames.count); // cycle count
    cg.u16(0); // flags
    cg.u16(0); // path separator
    cg.skip(4); // reserved
    cg.u32(recordSize); // data bytes
    cg.u32(0); // invalidation bytes

    for (var i = 0; i < channels.length; i++) {
      final c = channels[i];
      final next = i + 1 < channels.length ? cnOff[i + 1] : 0;
      // CN: links cn_next, composition, tx_name, si_source, cc, data, unit, md.
      final cn = _BlockWriter(out, bd, cnOff[i], '##CN', [
        next,
        0,
        nameOff[i],
        0,
        0,
        0,
        0,
        0,
      ]);
      cn.u8(c.type);
      cn.u8(c.syncType);
      cn.u8(c.dataType);
      cn.u8(0); // bit offset
      cn.u32(c.byteOffset);
      cn.u32(c.bitCount);
      // Remaining 60 bytes (flags, inval pos, precision, ranges…) stay zero,
      // but must still count into the declared block length or strict readers
      // (asammdf, CANape) reject the channel block as truncated.
      cn.skip(60);
    }

    // DT: raw records. No links; length must not include padding.
    out.setRange(dtOff, dtOff + 4, ascii.encode('##DT'));
    bd.setUint64(dtOff + 8, _blockHeader + recordBytes, Endian.little);
    bd.setUint64(dtOff + 16, 0, Endian.little); // link count
    final dataBase = dtOff + _blockHeader;
    for (var i = 0; i < frames.count; i++) {
      final rec = dataBase + i * recordSize;
      bd.setFloat64(rec + _offTime, frames.time[i], Endian.little);
      bd.setUint32(rec + _offId, frames.id[i] & 0x1FFFFFFF, Endian.little);
      out[rec + _offIde] = frames.ide[i];
      out[rec + _offLen] = frames.length[i];
      final view = frames.dataBytesView(i);
      out.setRange(rec + _offData, rec + _offData + view.length, view);
    }

    return out;
  }

  /// Total on-disk size of a block, padded so the next block stays 8-aligned.
  static int _size(int nlinks, int dataLen) =>
      _blockHeader + 8 * nlinks + ((dataLen + 7) & ~7);

  static void _writeIdBlock(Uint8List out) {
    void put(int off, String s) {
      final b = ascii.encode(s);
      out.setRange(off, off + b.length, b);
    }

    put(0, 'MDF     ');
    put(8, '4.10    ');
    put(24, 'MF4Wrtr ');
    ByteData.sublistView(out).setUint16(28, 410, Endian.little); // id_ver
  }

  static void _writeTx(Uint8List out, ByteData bd, int off, String text) {
    final body = utf8.encode(text);
    final dataLen = body.length + 1; // NUL terminator
    out.setRange(off, off + 4, ascii.encode('##TX'));
    bd.setUint64(off + 8, _blockHeader + dataLen, Endian.little);
    bd.setUint64(off + 16, 0, Endian.little); // link count
    out.setRange(off + _blockHeader, off + _blockHeader + body.length, body);
  }
}

/// Sequential field writer for one `##`-block, given its absolute [_base]
/// offset and resolved link targets. Tracks a cursor through the data section.
class _BlockWriter {
  final Uint8List _out;
  final ByteData _bd;
  final int _base;
  int _cursor;

  _BlockWriter(this._out, this._bd, this._base, String id, List<int> links)
      : _cursor = _base + Mf4Writer._blockHeader + links.length * 8 {
    final idBytes = ascii.encode(id);
    _out.setRange(_base, _base + 4, idBytes);
    _bd.setUint64(_base + 16, links.length, Endian.little);
    for (var i = 0; i < links.length; i++) {
      _bd.setUint64(_base + 24 + i * 8, links[i], Endian.little);
    }
    // Block length grows as the data section is written (patched per field so
    // a block with no data fields still records its header+links length).
    _flushLength();
  }

  void u8(int v) {
    _out[_cursor] = v & 0xFF;
    _cursor += 1;
    _flushLength();
  }

  void u16(int v) {
    _bd.setUint16(_cursor, v & 0xFFFF, Endian.little);
    _cursor += 2;
    _flushLength();
  }

  void i16(int v) {
    _bd.setInt16(_cursor, v, Endian.little);
    _cursor += 2;
    _flushLength();
  }

  void u32(int v) {
    _bd.setUint32(_cursor, v & 0xFFFFFFFF, Endian.little);
    _cursor += 4;
    _flushLength();
  }

  void u64(int v) {
    _bd.setUint64(_cursor, v, Endian.little);
    _cursor += 8;
    _flushLength();
  }

  void f64(double v) {
    _bd.setFloat64(_cursor, v, Endian.little);
    _cursor += 8;
    _flushLength();
  }

  void bytes(List<int> v) {
    _out.setRange(_cursor, _cursor + v.length, v);
    _cursor += v.length;
    _flushLength();
  }

  void skip(int n) {
    _cursor += n;
    _flushLength();
  }

  void _flushLength() {
    _bd.setUint64(_base + 8, _cursor - _base, Endian.little);
  }
}

class _Channel {
  final String name;
  final int type;
  final int syncType;
  final int dataType;
  final int byteOffset;
  final int bitCount;

  _Channel(
    this.name, {
    this.type = 0,
    this.syncType = 0,
    required this.dataType,
    required this.byteOffset,
    required this.bitCount,
  });
}
