import 'dart:io';
import 'dart:typed_data';

/// Columnar table of CAN frames extracted from an MF4 file.
///
/// All per-frame fields are parallel arrays of length [count]. The payload of
/// frame `i` lives in [dataBytes] at `[i*stride, i*stride + length[i])`; use
/// [dataBytesView] to obtain a zero-copy view of exactly the valid bytes.
class CanFrameTable {
  final int count;
  final Float64List time;
  final Int32List id;
  final Uint8List ide; // extended-frame flag
  final Uint8List length; // valid payload byte count
  final Uint8List dataBytes; // flattened payload, row stride = [stride]
  final int stride;

  CanFrameTable({
    required this.count,
    required this.time,
    required this.id,
    required this.ide,
    required this.length,
    required this.dataBytes,
    required this.stride,
  });

  Uint8List dataBytesView(int i) {
    final off = i * stride;
    final len = length[i];
    return Uint8List.sublistView(dataBytes, off, off + len);
  }
}

/// Minimal MDF (ASAM MDF v4.x) reader focused on extracting CAN bus-logging
/// frames and embedded attachments (e.g. the DBC database).
class Mdf4Reader {
  final ByteData _bd;
  final Uint8List _bytes;

  Mdf4Reader._(this._bytes) : _bd = ByteData.sublistView(_bytes);

  static Mdf4Reader fromBytes(Uint8List bytes) {
    final id = String.fromCharCodes(bytes.sublist(0, 3));
    if (id != 'MDF') {
      throw const FormatException('Not an MDF file (missing MDF id block).');
    }
    return Mdf4Reader._(bytes);
  }

  static Mdf4Reader fromFile(String path) =>
      fromBytes(File(path).readAsBytesSync());

  String get version => String.fromCharCodes(_bytes.sublist(8, 12)).trim();

  // ---- low level block access -------------------------------------------

  String _blockId(int addr) => String.fromCharCodes(_bytes, addr, addr + 4);

  int _u64(int addr) => _bd.getUint64(addr, Endian.little);
  int _u32(int addr) => _bd.getUint32(addr, Endian.little);
  int _u16(int addr) => _bd.getUint16(addr, Endian.little);
  int _u8(int addr) => _bytes[addr];

  /// Returns the link addresses of the block at [addr].
  List<int> _links(int addr) {
    final linkCount = _u64(addr + 16);
    final links = List<int>.filled(linkCount, 0);
    for (var i = 0; i < linkCount; i++) {
      links[i] = _u64(addr + 24 + i * 8);
    }
    return links;
  }

  int _dataStart(int addr) => addr + 24 + _u64(addr + 16) * 8;

  String _readTx(int addr) {
    if (addr == 0) return '';
    final len = _u64(addr + 8);
    final start = _dataStart(addr);
    final end = addr + len;
    var stop = end;
    // strip trailing NULs.
    while (stop > start && _bytes[stop - 1] == 0) {
      stop--;
    }
    return String.fromCharCodes(_bytes.sublist(start, stop));
  }

  // ---- attachments -------------------------------------------------------

  /// Returns embedded attachments as (file name, bytes). Only embedded
  /// attachments are supported (external references are skipped).
  List<MapEntry<String, Uint8List>> attachments() {
    final out = <MapEntry<String, Uint8List>>[];
    // HD links: dg_first, fh_first, ch_first, at_first(3), ev_first, md.
    final hdLinks = _links(64);
    if (hdLinks.length <= 3) return out;
    var at = hdLinks[3];
    while (at != 0 && _blockId(at) == '##AT') {
      final links = _links(at);
      // AT links: at_at_next, at_tx_filename, at_tx_mimetype, at_md_comment.
      final ds = _dataStart(at);
      final flags = _u16(ds);
      final embedded = (flags & 0x01) != 0;
      final compressed = (flags & 0x02) != 0;
      final name = links.length > 1 ? _readTx(links[1]) : '';
      if (embedded) {
        // data layout: flags(u16) creator_index(u16) reserved(4) md5(16)
        //   original_size(u64) embedded_size(u64) embedded_data[...]
        final embeddedSize = _u64(ds + 32);
        final dataOff = ds + 40;
        final data =
            Uint8List.sublistView(_bytes, dataOff, dataOff + embeddedSize);
        final bytes = compressed
            ? Uint8List.fromList(ZLibCodec().decoder.convert(data))
            : Uint8List.fromList(data);
        out.add(MapEntry(name, bytes));
      }
      at = links[0];
    }
    return out;
  }

  // ---- channel discovery -------------------------------------------------

  /// Walk all data groups and return the first one that looks like a CAN
  /// bus-logging group (has `*.ID` and `*.DataBytes` channels) with records.
  CanFrameTable readCanFrames() {
    final hdLinks = _links(64);
    var dg = hdLinks[0];
    while (dg != 0 && _blockId(dg) == '##DG') {
      final dgLinks = _links(dg);
      final recIdSize = _u8(_dataStart(dg));
      var cg = dgLinks[1];
      while (cg != 0 && _blockId(cg) == '##CG') {
        final cgLinks = _links(cg);
        final cgData = _dataStart(cg);
        final cycles = _u64(cgData + 8);
        final flags = _u16(cgData + 16);
        final dataBytes = _u32(cgData + 24);
        final invalBytes = _u32(cgData + 28);
        final isVlsd = (flags & 0x01) != 0;

        if (!isVlsd && cycles > 0) {
          final channels = <String, _ChannelInfo>{};
          _collectChannels(cgLinks[1], channels);
          if (channels.containsKey('CAN_DataFrame.ID') &&
              channels.containsKey('CAN_DataFrame.DataBytes')) {
            final record = _resolveData(dgLinks[2]);
            return _buildFrameTable(
              record: record,
              cycles: cycles,
              recordSize: dataBytes + invalBytes + recIdSize,
              recIdSize: recIdSize,
              channels: channels,
            );
          }
        }
        cg = cgLinks[0];
      }
      dg = dgLinks[0];
    }
    throw const FormatException('No CAN bus-logging group found in MF4 file.');
  }

  void _collectChannels(int cnAddr, Map<String, _ChannelInfo> out) {
    while (cnAddr != 0 && _blockId(cnAddr) == '##CN') {
      final links = _links(cnAddr);
      final ds = _dataStart(cnAddr);
      final channelType = _u8(ds);
      final dataType = _u8(ds + 2);
      final bitOffset = _u8(ds + 3);
      final byteOffset = _u32(ds + 4);
      final bitCount = _u32(ds + 8);
      final name = _readTx(links[2]);
      out[name] = _ChannelInfo(
        name: name,
        channelType: channelType,
        dataType: dataType,
        bitOffset: bitOffset,
        byteOffset: byteOffset,
        bitCount: bitCount,
      );
      // composition (links[1]) may hold structure member channels.
      final comp = links[1];
      if (comp != 0 && _blockId(comp) == '##CN') {
        _collectChannels(comp, out);
      }
      cnAddr = links[0]; // cn_cn_next
    }
  }

  CanFrameTable _buildFrameTable({
    required Uint8List record,
    required int cycles,
    required int recordSize,
    required int recIdSize,
    required Map<String, _ChannelInfo> channels,
  }) {
    final timeCh = channels.values.firstWhere(
      (c) => c.channelType == 2,
      orElse: () => channels['t'] ?? channels['time']!,
    );
    final idCh = channels['CAN_DataFrame.ID']!;
    final dataCh = channels['CAN_DataFrame.DataBytes']!;
    final ideCh = channels['CAN_DataFrame.IDE'];
    final lenCh = channels['CAN_DataFrame.DataLength'] ??
        channels['CAN_DataFrame.DLC'];

    final stride = dataCh.bitCount ~/ 8;
    final time = Float64List(cycles);
    final id = Int32List(cycles);
    final ide = Uint8List(cycles);
    final length = Uint8List(cycles);
    final payload = Uint8List(cycles * stride);

    final rd = ByteData.sublistView(record);
    final idBytes = idCh.bitCount ~/ 8;

    for (var i = 0; i < cycles; i++) {
      // record start, skipping the leading record id, if any.
      final rec = i * recordSize + recIdSize;
      time[i] = rd.getFloat64(rec + timeCh.byteOffset, Endian.little);
      id[i] = _readUintLE(rd, rec + idCh.byteOffset, idBytes) & 0x1FFFFFFF;
      ide[i] = ideCh == null ? 0 : record[rec + ideCh.byteOffset];
      length[i] = lenCh == null ? stride : record[rec + lenCh.byteOffset];
      final src = rec + dataCh.byteOffset;
      payload.setRange(i * stride, i * stride + stride, record, src);
    }

    return CanFrameTable(
      count: cycles,
      time: time,
      id: id,
      ide: ide,
      length: length,
      dataBytes: payload,
      stride: stride,
    );
  }

  static int _readUintLE(ByteData bd, int offset, int byteCount) {
    var v = 0;
    for (var i = 0; i < byteCount; i++) {
      v |= bd.getUint8(offset + i) << (8 * i);
    }
    return v;
  }

  // ---- data block resolution --------------------------------------------

  /// Resolve a data block reference (DT/DZ/DL/HL) to the concatenated raw
  /// record bytes.
  Uint8List _resolveData(int addr) {
    if (addr == 0) return Uint8List(0);
    final id = _blockId(addr);
    switch (id) {
      case '##DT':
      case '##DV': // 4.2 data values block, same payload layout
        final len = _u64(addr + 8);
        final start = _dataStart(addr);
        return Uint8List.sublistView(_bytes, start, addr + len);
      case '##DZ':
        return _inflateDz(addr);
      case '##DL':
        return _concatDataList(addr);
      case '##HL':
        // header list: links[0] -> first DL.
        return _resolveData(_links(addr)[0]);
      case '##LD':
        return _concatLdList(addr);
      default:
        throw FormatException('Unsupported data block $id');
    }
  }

  Uint8List _concatDataList(int addr) {
    final chunks = <Uint8List>[];
    var dl = addr;
    while (dl != 0 && _blockId(dl) == '##DL') {
      final links = _links(dl);
      // links[0] = dl_dl_next, links[1..] = dl_data[]
      for (var i = 1; i < links.length; i++) {
        if (links[i] != 0) chunks.add(_resolveData(links[i]));
      }
      dl = links[0];
    }
    return _concat(chunks);
  }

  Uint8List _concatLdList(int addr) {
    final chunks = <Uint8List>[];
    var ld = addr;
    while (ld != 0 && _blockId(ld) == '##LD') {
      final links = _links(ld);
      for (var i = 1; i < links.length; i++) {
        if (links[i] != 0 &&
            (_blockId(links[i]) == '##DV' ||
                _blockId(links[i]) == '##DZ' ||
                _blockId(links[i]) == '##DT')) {
          chunks.add(_resolveData(links[i]));
        }
      }
      ld = links[0];
    }
    return _concat(chunks);
  }

  Uint8List _inflateDz(int addr) {
    final ds = _dataStart(addr);
    final zipType = _u8(ds + 2);
    final param = _u32(ds + 4);
    final orgLen = _u64(ds + 8);
    final dataLen = _u64(ds + 16);
    final comp = Uint8List.sublistView(_bytes, ds + 24, ds + 24 + dataLen);
    final inflated = Uint8List.fromList(ZLibCodec().decoder.convert(comp));

    if (zipType == 0) return inflated;

    // zipType == 1: transposed deflate. Stored column-major with [param]
    // columns; rebuild the row-major byte stream.
    final cols = param;
    final rows = orgLen ~/ cols;
    final out = Uint8List(orgLen);
    for (var c = 0; c < cols; c++) {
      final colBase = c * rows;
      for (var r = 0; r < rows; r++) {
        out[r * cols + c] = inflated[colBase + r];
      }
    }
    final tail = rows * cols;
    for (var k = tail; k < orgLen; k++) {
      out[k] = inflated[k];
    }
    return out;
  }

  static Uint8List _concat(List<Uint8List> chunks) {
    if (chunks.length == 1) return chunks.first;
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final out = Uint8List(total);
    var off = 0;
    for (final c in chunks) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return out;
  }
}

class _ChannelInfo {
  final String name;
  final int channelType;
  final int dataType;
  final int bitOffset;
  final int byteOffset;
  final int bitCount;

  _ChannelInfo({
    required this.name,
    required this.channelType,
    required this.dataType,
    required this.bitOffset,
    required this.byteOffset,
    required this.bitCount,
  });
}
