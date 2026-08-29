import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mf4_viewer/src/convert/arxml_parser.dart';
import 'package:mf4_viewer/src/convert/converter.dart';
import 'package:mf4_viewer/src/convert/frame_builder.dart';
import 'package:mf4_viewer/src/convert/mf4_writer.dart';
import 'package:mf4_viewer/src/convert/readers/asc_reader.dart';
import 'package:mf4_viewer/src/convert/readers/blf_reader.dart';
import 'package:mf4_viewer/src/convert/readers/csv_reader.dart';
import 'package:mf4_viewer/src/convert/readers/trc_reader.dart';
import 'package:mf4_viewer/src/dbc/dbc_model.dart';
import 'package:mf4_viewer/src/dbc/dbc_parser.dart';
import 'package:mf4_viewer/src/dbc/dbc_writer.dart';
import 'package:mf4_viewer/src/mdf/mdf4_reader.dart';

void main() {
  group('MF4 writer round-trips through the reader', () {
    test('frames and embedded database survive a write → read cycle', () {
      final fb = FrameBuilder();
      fb.add(time: 0.000, id: 0x100, extended: false, data: [1, 2, 3, 4, 5, 6, 7, 8]);
      fb.add(time: 0.001, id: 0x18DAF110, extended: true, data: [0xAA, 0xBB]);
      fb.add(time: 0.002, id: 0x200, extended: false, data: [0xDE, 0xAD]);
      final frames = fb.build();

      const dbc = 'BO_ 256 EngineData: 8 ECU\n'
          ' SG_ Rpm : 0|16@1+ (0.25,0) [0|16383] "rpm" Vector__XXX\n';
      final mf4 = Mf4Writer.write(frames, attachments: [
        Mf4Attachment(
          fileName: 'engine.dbc',
          data: Uint8List.fromList(utf8.encode(dbc)),
        ),
      ]);

      final reader = Mdf4Reader.fromBytes(mf4);
      expect(reader.version, '4.10');

      final read = reader.readCanFrames();
      expect(read.count, 3);
      expect(read.time[0], closeTo(0.0, 1e-9));
      expect(read.time[1], closeTo(0.001, 1e-9));
      expect(read.id[0], 0x100);
      expect(read.ide[0], 0);
      expect(read.length[0], 8);
      expect(read.dataBytesView(0), [1, 2, 3, 4, 5, 6, 7, 8]);

      expect(read.id[1], 0x18DAF110);
      expect(read.ide[1], 1);
      expect(read.length[1], 2);
      expect(read.dataBytesView(1), [0xAA, 0xBB]);

      final atts = reader.attachments();
      expect(atts, hasLength(1));
      expect(atts.first.key, 'engine.dbc');
      expect(utf8.decode(atts.first.value), dbc);
    });
  });

  group('CSV reader', () {
    test('single hex payload column with explicit DLC', () {
      const csv = 'Time,ID,DLC,Data\n'
          '0.001,0x100,8,11 22 33 44 55 66 77 88\n'
          '0.002,0x200,3,AA BB CC\n';
      final f = CsvCanReader.read(csv);
      expect(f.count, 2);
      expect(f.id[0], 0x100);
      expect(f.length[0], 8);
      expect(f.dataBytesView(0), [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]);
      expect(f.id[1], 0x200);
      expect(f.length[1], 3);
      expect(f.dataBytesView(1), [0xAA, 0xBB, 0xCC]);
    });

    test('per-byte columns, hex id and millisecond timestamps', () {
      const csv = 'Timestamp (ms),Identifier (hex),D0,D1,D2\n'
          '1000,1AB,DE,AD,BE\n';
      final f = CsvCanReader.read(csv);
      expect(f.count, 1);
      expect(f.time[0], closeTo(1.0, 1e-9));
      expect(f.id[0], 0x1AB);
      expect(f.dataBytesView(0), [0xDE, 0xAD, 0xBE]);
    });

    test('extended flag inferred from id width', () {
      const csv = 'Time,ID,Data\n0,0x18FF1234,01\n';
      final f = CsvCanReader.read(csv);
      expect(f.ide[0], 1);
    });
  });

  group('TRC reader', () {
    test('PEAK 2.x layout', () {
      const trc = ';\$FILEVERSION=2.1\n'
          ';\$STARTTIME=45000\n'
          ';   a header comment line\n'
          '     1      1000.000 DT     0300 Rx -  8  01 02 03 04 05 06 07 08\n'
          '     2      1001.000 DT     18FEF100 Rx -  4  AA BB CC DD\n';
      final f = TrcReader.read(trc);
      expect(f.count, 2);
      expect(f.time[0], closeTo(1.0, 1e-9));
      expect(f.id[0], 0x300);
      expect(f.ide[0], 0);
      expect(f.dataBytesView(0), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(f.id[1], 0x18FEF100);
      expect(f.ide[1], 1);
      expect(f.length[1], 4);
      expect(f.dataBytesView(1), [0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('PEAK 1.x layout without a type column', () {
      const trc = ';\$FILEVERSION=1.1\n'
          '     1)      1000.0  0300  8  01 02 03 04 05 06 07 08\n';
      final f = TrcReader.read(trc);
      expect(f.count, 1);
      expect(f.id[0], 0x300);
      expect(f.length[0], 8);
      expect(f.dataBytesView(0), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('PEAK 1.1 layout with the direction in the type column', () {
      // Some 1.1 generators (e.g. DENS Kano) put Rx/Tx *before* the ID, in the
      // "Type" column. Extended (29-bit) ids are written with 8 hex digits.
      const trc = ';\$FILEVERSION=1.1\n'
          ';\$STARTTIME=46189.6326979066\n'
          ';   Message Number\n'
          ';---+--   ----+----  --+--  ----+---  +  -+ -- --\n'
          '     1)         0.0  Rx     10062103  6  D4 AF 91 13 21 80 \n'
          '     2)         0.3  Tx     0300      3  01 02 03 \n';
      final f = TrcReader.read(trc);
      expect(f.count, 2);
      expect(f.time[0], closeTo(0.0, 1e-9));
      expect(f.id[0], 0x10062103);
      expect(f.ide[0], 1);
      expect(f.length[0], 6);
      expect(f.dataBytesView(0), [0xD4, 0xAF, 0x91, 0x13, 0x21, 0x80]);
      expect(f.time[1], closeTo(0.0003, 1e-9));
      expect(f.id[1], 0x300);
      expect(f.ide[1], 0);
      expect(f.dataBytesView(1), [0x01, 0x02, 0x03]);
    });
  });

  group('ASC reader', () {
    test('classic CAN with header, standard and extended ids', () {
      const asc = 'date Wed Sep 30 14:00:00.000 2020\n'
          'base hex  timestamps absolute\n'
          'internal events logged\n'
          '// version 13.0.0\n'
          'Begin Triggerblock Wed Sep 30 14:00:00.000 2020\n'
          '   0.000000 Start of measurement\n'
          '   0.001000 1  300             Rx   d 8 01 02 03 04 05 06 07 08\n'
          '   0.002000 1  18FEF100x       Tx   d 4 AA BB CC DD\n'
          '   0.003000 1  200             Rx   r 0\n'
          '   0.004000 1  ErrorFrame\n'
          'End Triggerblock\n';
      final f = AscReader.read(asc);
      // Two data frames; the remote and error frames are skipped.
      expect(f.count, 2);
      expect(f.time[0], closeTo(0.001, 1e-9));
      expect(f.id[0], 0x300);
      expect(f.ide[0], 0);
      expect(f.length[0], 8);
      expect(f.dataBytesView(0), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(f.id[1], 0x18FEF100);
      expect(f.ide[1], 1);
      expect(f.length[1], 4);
      expect(f.dataBytesView(1), [0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('CAN-FD line with a symbolic name', () {
      const asc = '   0.001000 CANFD   1 Rx 18EBFF00x  J1939TP 1 0 a 10 '
          '01 02 03 04 05 06 07 08 09 0A  100000 0 0 0 0 0\n';
      final f = AscReader.read(asc);
      expect(f.count, 1);
      expect(f.id[0], 0x18EBFF00);
      expect(f.ide[0], 1);
      expect(f.length[0], 10);
      expect(f.dataBytesView(0),
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0A]);
    });

    test('base dec switches id and payload to decimal', () {
      const asc = 'base dec  timestamps absolute\n'
          '   0.001000 1  256             Rx   d 2 17 34\n';
      final f = AscReader.read(asc);
      expect(f.count, 1);
      expect(f.id[0], 256);
      expect(f.dataBytesView(0), [17, 34]);
    });
  });

  group('BLF reader', () {
    test('classic + FD frames inside a zlib container, plus a top-level frame', () {
      final container = _blfContainer([
        _blfClassic(timestampRaw: 100, channel: 1, arbId: 0x100, data: [1, 2, 3, 4]),
        _blfClassic(
            timestampRaw: 200, channel: 1, arbId: 0x18DAF110 | 0x80000000, data: [9, 8]),
        _blfFd(
            timestampRaw: 300,
            channel: 1,
            arbId: 0x200,
            data: List<int>.generate(12, (i) => i)),
      ]);
      final topLevel =
          _blfClassic(timestampRaw: 400, channel: 1, arbId: 0x55, data: [0xFF]);

      final blf = _blfFile([container, topLevel]);
      final f = BlfReader.read(blf);

      expect(f.count, 4);
      final byId = {for (var i = 0; i < f.count; i++) f.id[i]: i};

      expect(f.time[byId[0x100]!], closeTo(0.001, 1e-9));
      expect(f.length[byId[0x100]!], 4);
      expect(f.dataBytesView(byId[0x100]!), [1, 2, 3, 4]);

      expect(f.ide[byId[0x18DAF110]!], 1);
      expect(f.dataBytesView(byId[0x18DAF110]!), [9, 8]);

      // CAN-FD: 12 valid bytes.
      expect(f.length[byId[0x200]!], 12);
      expect(f.dataBytesView(byId[0x200]!), List<int>.generate(12, (i) => i));

      expect(f.dataBytesView(byId[0x55]!), [0xFF]);
    });

    test('CAN_FD_MESSAGE_64 events (written by current Vector tools)', () {
      final container = _blfContainer([
        _blfFd64(
            timestampRaw: 100,
            channel: 2,
            arbId: 0x601,
            data: List<int>.generate(24, (i) => i + 1)),
        _blfFd64(
            timestampRaw: 200,
            channel: 2,
            arbId: 0x18DAF110 | 0x80000000,
            data: [0xAA, 0xBB]),
      ]);
      final f = BlfReader.read(_blfFile([container]));

      expect(f.count, 2);
      expect(f.time[0], closeTo(0.001, 1e-9));
      expect(f.id[0], 0x601);
      expect(f.ide[0], 0);
      expect(f.length[0], 24);
      expect(f.dataBytesView(0), List<int>.generate(24, (i) => i + 1));

      expect(f.id[1], 0x18DAF110);
      expect(f.ide[1], 1);
      expect(f.dataBytesView(1), [0xAA, 0xBB]);
    });

    test('an event split across two log containers is reassembled', () {
      final events = [
        _blfClassic(timestampRaw: 100, channel: 1, arbId: 0x101, data: [1]),
        _blfClassic(timestampRaw: 200, channel: 1, arbId: 0x102, data: [2]),
        _blfClassic(timestampRaw: 300, channel: 1, arbId: 0x103, data: [3]),
      ];
      final raw = _concat(events.map(_pad4).toList());
      // Cut mid-way through the second event; the decompressed container
      // payloads form one continuous stream, so the reader must stitch the
      // halves back together.
      final cut = 48 + 20;
      final blf = _blfFile([
        _blfContainerRaw(Uint8List.sublistView(raw, 0, cut)),
        _blfContainerRaw(Uint8List.sublistView(raw, cut)),
      ]);
      final f = BlfReader.read(blf);

      expect(f.count, 3);
      expect(f.id, [0x101, 0x102, 0x103]);
      expect(f.dataBytesView(1), [2]);
    });

    test('objects padded to objectSize % 4 (Vector convention) are found', () {
      // 49-byte object: one data byte beyond the classic 48-byte layout so
      // the object size is not 4-aligned; Vector pads with objectSize % 4
      // bytes rather than rounding up to the next 4-byte boundary.
      final odd = Uint8List(49 + 1); // 49-byte object + 1 padding byte
      odd.setAll(0, _blfClassic(
          timestampRaw: 100, channel: 1, arbId: 0x77, data: [5]));
      final bd = ByteData.sublistView(odd);
      bd.setUint32(8, 49, Endian.little); // object size
      final follower =
          _blfClassic(timestampRaw: 200, channel: 1, arbId: 0x78, data: [6]);

      final f = BlfReader.read(
          _blfFile([_blfContainerRaw(_concat([odd, follower]))]));
      expect(f.count, 2);
      expect(f.id, [0x77, 0x78]);
    });
  });

  group('ARXML parser', () {
    test('extracts a CAN frame and a linear signal', () {
      final db = ArxmlParser.parse(_sampleArxml);
      expect(db.messages, hasLength(1));
      final m = db.messages.first;
      expect(m.rawId, 256);
      expect(m.name, 'EngineData');
      expect(m.dlc, 8);
      expect(m.signals, hasLength(1));

      final s = m.signals.first;
      expect(s.name, 'EngineSpeed');
      expect(s.startBit, 0);
      expect(s.bitLength, 16);
      expect(s.byteOrder, ByteOrder.littleEndian);
      expect(s.factor, closeTo(0.25, 1e-9));
      expect(s.offset, closeTo(0.0, 1e-9));

      // ARXML → DBC text → DBC model round-trips.
      final reparsed = DbcParser.parse(DbcWriter.write(db));
      final rs = reparsed.messages.first.signals.first;
      expect(reparsed.messages.first.id, 256);
      expect(rs.factor, closeTo(0.25, 1e-9));
      expect(rs.bitLength, 16);
    });
  });

  group('end-to-end CanConverter', () {
    test('CSV log + DBC database → MF4 with embedded database', () {
      final csv = utf8.encode('Time,ID,DLC,Data\n'
          '0.000,0x123,8,01 02 03 04 05 06 07 08\n'
          '0.010,0x123,8,11 12 13 14 15 16 17 18\n');
      const dbc = 'BO_ 291 Demo: 8 ECU\n'
          ' SG_ Counter : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';

      final result = CanConverter.convertBytes(
        logBytes: Uint8List.fromList(csv),
        logName: 'demo.csv',
        dbBytes: Uint8List.fromList(utf8.encode(dbc)),
        dbName: 'demo.dbc',
      );
      expect(result.inputFormat, LogFormat.csv);
      expect(result.frameCount, 2);
      expect(result.messageCount, 1);

      final reader = Mdf4Reader.fromBytes(result.mf4Bytes);
      final frames = reader.readCanFrames();
      expect(frames.count, 2);
      expect(frames.id[0], 0x123);
      final dbcAtt = reader.attachments().firstWhere(
            (e) => e.key.toLowerCase().endsWith('.dbc'),
          );
      expect(DbcParser.parse(utf8.decode(dbcAtt.value)).messages, hasLength(1));
    });

    test('multiple DBC databases are all embedded and both decode', () {
      final csv = utf8.encode('Time,ID,DLC,Data\n'
          '0.000,0x123,8,01 02 03 04 05 06 07 08\n'
          '0.010,0x200,2,AA BB\n');
      const dbcA = 'BO_ 291 Demo: 8 ECU\n'
          ' SG_ Counter : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';
      const dbcB = 'BO_ 512 Other: 2 ECU\n'
          ' SG_ Level : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';

      final result = CanConverter.convertMany(
        logs: [NamedBytes('demo.csv', Uint8List.fromList(csv))],
        databases: [
          NamedBytes('a.dbc', Uint8List.fromList(utf8.encode(dbcA))),
          NamedBytes('b.dbc', Uint8List.fromList(utf8.encode(dbcB))),
        ],
      );
      expect(result.databaseNames, ['a.dbc', 'b.dbc']);
      expect(result.messageCount, 2);

      final atts = Mdf4Reader.fromBytes(result.mf4Bytes).attachments();
      expect(atts.map((e) => e.key), containsAll(['a.dbc', 'b.dbc']));

      final merged = DbcDatabase.merge([
        for (final a in atts) DbcParser.parse(utf8.decode(a.value)),
      ]);
      expect(merged.messageForId(0x123)!.name, 'Demo');
      expect(merged.messageForId(0x200)!.name, 'Other');
    });

    test('combining multiple MF4 files merges frames and carries DBCs', () {
      ConversionResult part(String dbcName, String dbc, double t, int id) {
        final fb = FrameBuilder()
          ..add(time: t, id: id, extended: false, data: [1, 2]);
        final mf4 = Mf4Writer.write(fb.build(), attachments: [
          Mf4Attachment(
            fileName: dbcName,
            data: Uint8List.fromList(utf8.encode(dbc)),
          ),
        ]);
        return CanConverter.convertMany(
            logs: [NamedBytes('$dbcName.mf4', mf4)]);
      }

      const dbcA = 'BO_ 256 MsgA: 2 ECU\n'
          ' SG_ SigA : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';
      const dbcB = 'BO_ 512 MsgB: 2 ECU\n'
          ' SG_ SigB : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';
      final a = part('a.dbc', dbcA, 5.0, 0x100).mf4Bytes;
      final b = part('b.dbc', dbcB, 1.0, 0x200).mf4Bytes;

      final combined = CanConverter.convertMany(logs: [
        NamedBytes('a.mf4', a),
        NamedBytes('b.mf4', b),
      ]);
      expect(combined.inputCount, 2);
      expect(combined.frameCount, 2);
      expect(combined.databaseNames, containsAll(['a.dbc', 'b.dbc']));
      expect(combined.messageCount, 2);

      final reread = Mdf4Reader.fromBytes(combined.mf4Bytes);
      final frames = reread.readCanFrames();
      // Frames from both files, re-sorted by timestamp.
      expect(frames.count, 2);
      expect(frames.time[0], closeTo(1.0, 1e-9));
      expect(frames.id[0], 0x200);
      expect(frames.time[1], closeTo(5.0, 1e-9));
      expect(frames.id[1], 0x100);
      expect(reread.attachments(), hasLength(2));
    });

    test('duplicate embedded databases are deduplicated; clashes renamed', () {
      const dbc = 'BO_ 256 MsgA: 2 ECU\n'
          ' SG_ SigA : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';
      const dbcOther = 'BO_ 512 MsgB: 2 ECU\n'
          ' SG_ SigB : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n';
      final db = Uint8List.fromList(utf8.encode(dbc));
      final dbOther = Uint8List.fromList(utf8.encode(dbcOther));
      final fb = FrameBuilder()
        ..add(time: 0, id: 0x100, extended: false, data: [1]);
      final mf4 = Mf4Writer.write(fb.build(), attachments: [
        Mf4Attachment(fileName: 'net.dbc', data: db),
      ]);

      // The same database again (same name + content) is embedded once; a
      // different database under the same name gets a suffixed name.
      final result = CanConverter.convertMany(
        logs: [NamedBytes('a.mf4', mf4), NamedBytes('b.mf4', mf4)],
        databases: [NamedBytes('net.dbc', dbOther)],
      );
      expect(result.databaseNames, ['net.dbc', 'net_2.dbc']);
      expect(result.messageCount, 2);
    });

    test('format detection by extension', () {
      expect(CanConverter.detectLogFormat('a.blf'), LogFormat.blf);
      expect(CanConverter.detectLogFormat('a.trc'), LogFormat.trc);
      expect(CanConverter.detectLogFormat('a.asc'), LogFormat.asc);
      expect(CanConverter.detectLogFormat('a.csv'), LogFormat.csv);
      expect(CanConverter.detectLogFormat('a.mf4'), LogFormat.mf4);
      expect(() => CanConverter.detectLogFormat('a.png'), throwsFormatException);
    });
  });

  test('round-trips the bundled example trace (MF4 → MF4)', () {
    final src = File('test/fixtures/example_can_trace.mf4');
    final frames = Mdf4Reader.fromFile(src.path).readCanFrames();
    final rewritten = Mf4Writer.write(frames);
    final reread = Mdf4Reader.fromBytes(rewritten).readCanFrames();
    expect(reread.count, frames.count);
    expect(reread.id[0], frames.id[0]);
    expect(reread.dataBytesView(10), frames.dataBytesView(10));
    expect(reread.time[frames.count - 1],
        closeTo(frames.time[frames.count - 1], 1e-9));
  });
}

// ---- synthetic BLF builders (mirror the documented binary layout) ---------

Uint8List _blfFile(List<Uint8List> objects) {
  const headerSize = 144;
  final body = _concat(objects.map(_pad4).toList());
  final out = Uint8List(headerSize + body.length);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 4, ascii.encode('LOGG'));
  bd.setUint32(4, headerSize, Endian.little);
  out.setRange(headerSize, headerSize + body.length, body);
  return out;
}

/// Wrap [events] in a zlib-compressed LOG_CONTAINER (object type 10).
Uint8List _blfContainer(List<Uint8List> events) =>
    _blfContainerRaw(_concat(events.map(_pad4).toList()));

Uint8List _blfContainerRaw(Uint8List raw) {
  final compressed =
      Uint8List.fromList(ZLibCodec().encoder.convert(raw));
  final size = 16 + 16 + compressed.length;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 4, ascii.encode('LOBJ'));
  bd.setUint16(4, 16, Endian.little); // header size (base only)
  bd.setUint16(6, 1, Endian.little); // header version
  bd.setUint32(8, size, Endian.little); // object size
  bd.setUint32(12, 10, Endian.little); // LOG_CONTAINER
  bd.setUint16(16, 2, Endian.little); // compression: zlib
  bd.setUint32(16 + 8, raw.length, Endian.little); // uncompressed size
  out.setRange(32, 32 + compressed.length, compressed);
  return out;
}

Uint8List _blfClassic({
  required int timestampRaw,
  required int channel,
  required int arbId,
  required List<int> data,
}) {
  const size = 48;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  _blfBaseAndV1(out, bd, headerSize: 32, objectSize: size, objectType: 1, timestampRaw: timestampRaw);
  bd.setUint16(32, channel, Endian.little);
  out[34] = 0; // flags
  out[35] = data.length; // dlc
  bd.setUint32(36, arbId, Endian.little);
  out.setRange(40, 40 + data.length, data);
  return out;
}

Uint8List _blfFd({
  required int timestampRaw,
  required int channel,
  required int arbId,
  required List<int> data,
}) {
  const size = 116; // 32 header + 20 fixed fields + 64 data
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  _blfBaseAndV1(out, bd, headerSize: 32, objectSize: size, objectType: 100, timestampRaw: timestampRaw);
  bd.setUint16(32, channel, Endian.little);
  out[34] = 0; // flags
  out[35] = data.length; // dlc code (unused by reader)
  bd.setUint32(36, arbId, Endian.little);
  bd.setUint32(40, 0, Endian.little); // frame length
  out[44] = 0; // arb bit count
  out[45] = 0; // fd flags
  out[46] = data.length; // valid data bytes
  // 47..51 reserved
  out.setRange(52, 52 + data.length, data);
  return out;
}

Uint8List _blfFd64({
  required int timestampRaw,
  required int channel,
  required int arbId,
  required List<int> data,
}) {
  final size = 32 + 40 + data.length; // header + fixed fields + payload
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  _blfBaseAndV1(out, bd, headerSize: 32, objectSize: size, objectType: 101, timestampRaw: timestampRaw);
  out[32] = channel;
  out[33] = 0; // dlc code (unused by reader)
  out[34] = data.length; // valid data bytes
  out[35] = 0; // tx count
  bd.setUint32(36, arbId, Endian.little);
  // frameLength, flags, btrCfgArb, btrCfgData, timeOffsetBrs,
  // timeOffsetCrcDel (offsets 40..63) left zero.
  bd.setUint16(64, 0, Endian.little); // bit count
  out[66] = 0; // dir
  out[67] = 0; // extDataOffset (payload runs to end of object)
  bd.setUint32(68, 0, Endian.little); // crc
  out.setRange(72, 72 + data.length, data);
  return out;
}

void _blfBaseAndV1(
  Uint8List out,
  ByteData bd, {
  required int headerSize,
  required int objectSize,
  required int objectType,
  required int timestampRaw,
}) {
  out.setRange(0, 4, ascii.encode('LOBJ'));
  bd.setUint16(4, headerSize, Endian.little);
  bd.setUint16(6, 1, Endian.little); // header version 1
  bd.setUint32(8, objectSize, Endian.little);
  bd.setUint32(12, objectType, Endian.little);
  bd.setUint32(16, 1, Endian.little); // flags: TIME_TEN_MICS (10 µs)
  bd.setUint16(20, 0, Endian.little); // client index
  bd.setUint16(22, 0, Endian.little); // object version
  bd.setUint64(24, timestampRaw, Endian.little);
}

Uint8List _pad4(Uint8List b) {
  final padded = (b.length + 3) & ~3;
  if (padded == b.length) return b;
  final out = Uint8List(padded);
  out.setRange(0, b.length, b);
  return out;
}

Uint8List _concat(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (s, p) => s + p.length);
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

const _sampleArxml = '''
<?xml version="1.0" encoding="UTF-8"?>
<AUTOSAR>
  <AR-PACKAGES>
    <AR-PACKAGE>
      <SHORT-NAME>Cluster</SHORT-NAME>
      <ELEMENTS>
        <CAN-FRAME-TRIGGERING>
          <SHORT-NAME>EngineData_Trig</SHORT-NAME>
          <IDENTIFIER>256</IDENTIFIER>
          <CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE>
          <FRAME-REF DEST="CAN-FRAME">/Frames/EngineData</FRAME-REF>
        </CAN-FRAME-TRIGGERING>
      </ELEMENTS>
    </AR-PACKAGE>
    <AR-PACKAGE>
      <SHORT-NAME>Frames</SHORT-NAME>
      <ELEMENTS>
        <CAN-FRAME>
          <SHORT-NAME>EngineData</SHORT-NAME>
          <FRAME-LENGTH>8</FRAME-LENGTH>
          <PDU-TO-FRAME-MAPPINGS>
            <PDU-TO-FRAME-MAPPING>
              <SHORT-NAME>EngineData_map</SHORT-NAME>
              <START-POSITION>0</START-POSITION>
              <PDU-REF DEST="I-SIGNAL-I-PDU">/Pdus/EngineData</PDU-REF>
            </PDU-TO-FRAME-MAPPING>
          </PDU-TO-FRAME-MAPPINGS>
        </CAN-FRAME>
      </ELEMENTS>
    </AR-PACKAGE>
    <AR-PACKAGE>
      <SHORT-NAME>Pdus</SHORT-NAME>
      <ELEMENTS>
        <I-SIGNAL-I-PDU>
          <SHORT-NAME>EngineData</SHORT-NAME>
          <I-SIGNAL-TO-I-PDU-MAPPINGS>
            <I-SIGNAL-TO-I-PDU-MAPPING>
              <SHORT-NAME>EngineSpeed_map</SHORT-NAME>
              <START-POSITION>0</START-POSITION>
              <PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER>
              <I-SIGNAL-REF DEST="I-SIGNAL">/ISignals/EngineSpeed</I-SIGNAL-REF>
            </I-SIGNAL-TO-I-PDU-MAPPING>
          </I-SIGNAL-TO-I-PDU-MAPPINGS>
        </I-SIGNAL-I-PDU>
      </ELEMENTS>
    </AR-PACKAGE>
    <AR-PACKAGE>
      <SHORT-NAME>ISignals</SHORT-NAME>
      <ELEMENTS>
        <I-SIGNAL>
          <SHORT-NAME>EngineSpeed</SHORT-NAME>
          <LENGTH>16</LENGTH>
          <NETWORK-REPRESENTATION-PROPS>
            <SW-DATA-DEF-PROPS-VARIANTS>
              <SW-DATA-DEF-PROPS-CONDITIONAL>
                <COMPU-METHOD-REF DEST="COMPU-METHOD">/CompuMethods/rpm</COMPU-METHOD-REF>
              </SW-DATA-DEF-PROPS-CONDITIONAL>
            </SW-DATA-DEF-PROPS-VARIANTS>
          </NETWORK-REPRESENTATION-PROPS>
        </I-SIGNAL>
      </ELEMENTS>
    </AR-PACKAGE>
    <AR-PACKAGE>
      <SHORT-NAME>CompuMethods</SHORT-NAME>
      <ELEMENTS>
        <COMPU-METHOD>
          <SHORT-NAME>rpm</SHORT-NAME>
          <CATEGORY>LINEAR</CATEGORY>
          <COMPU-INTERNAL-TO-PHYS>
            <COMPU-SCALES>
              <COMPU-SCALE>
                <COMPU-RATIONAL-COEFFS>
                  <COMPU-NUMERATOR><V>0</V><V>0.25</V></COMPU-NUMERATOR>
                  <COMPU-DENOMINATOR><V>1</V></COMPU-DENOMINATOR>
                </COMPU-RATIONAL-COEFFS>
              </COMPU-SCALE>
            </COMPU-SCALES>
          </COMPU-INTERNAL-TO-PHYS>
        </COMPU-METHOD>
      </ELEMENTS>
    </AR-PACKAGE>
  </AR-PACKAGES>
</AUTOSAR>
''';
