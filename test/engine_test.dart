import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mf4_viewer/src/dbc/dbc_parser.dart';
import 'package:mf4_viewer/src/decode/can_decoder.dart';
import 'package:mf4_viewer/src/mdf/mdf4_reader.dart';

/// End-to-end engine test against the bundled example trace. Ground-truth
/// values were produced independently with asammdf.
void main() {
  final mf4 = File('test/fixtures/example_can_trace.mf4');
  final gtFile = File('test/fixtures/ground_truth.json');

  late CanDecoder decoder;
  late Map<String, DecodableSignal> byName;

  setUpAll(() {
    final reader = Mdf4Reader.fromFile(mf4.path);
    final dbcAtt = reader
        .attachments()
        .firstWhere((e) => e.key.toLowerCase().endsWith('.dbc'));
    final db = DbcParser.parse(utf8.decode(dbcAtt.value, allowMalformed: true));
    final frames = reader.readCanFrames();
    decoder = CanDecoder(frames, db);
    byName = {for (final s in decoder.availableSignals()) s.qualifiedName: s};
  });

  test('reads MDF version and CAN frames', () {
    final reader = Mdf4Reader.fromFile(mf4.path);
    expect(reader.version, '4.10');
    final frames = reader.readCanFrames();
    expect(frames.count, 26951);
  });

  test('extracts embedded compressed DBC', () {
    final reader = Mdf4Reader.fromFile(mf4.path);
    final atts = reader.attachments();
    expect(atts, isNotEmpty);
    expect(atts.first.key.toLowerCase(), endsWith('.dbc'));
    final db = DbcParser.parse(utf8.decode(atts.first.value));
    expect(db.messages.length, greaterThan(20));
  });

  test('decoded signals match asammdf ground truth', () {
    final gt = jsonDecode(gtFile.readAsStringSync()) as Map<String, dynamic>;
    gt.forEach((name, raw) {
      final spec = raw as Map<String, dynamic>;
      final ds = byName[name];
      expect(ds, isNotNull, reason: '$name should be decodable');
      final series = decoder.decode(ds!.message, ds.signal);

      expect(series.length, spec['count'], reason: '$name sample count');

      final expT = (spec['t'] as List).cast<num>();
      final expV = spec['v'] as List;
      for (var i = 0; i < expT.length; i++) {
        expect(series.timestamps[i], closeTo(expT[i].toDouble(), 1e-6),
            reason: '$name timestamp[$i]');
        if (series.isEnum) {
          expect(series.enumLabels![i], expV[i].toString(),
              reason: '$name enum[$i]');
        } else if (expV[i] is num) {
          expect(series.values[i], closeTo((expV[i] as num).toDouble(), 1e-4),
              reason: '$name value[$i]');
        }
      }
    });
  });

  test('pure enum vs scaled-with-sentinel classification', () {
    // FCU_SIV_Stat is a pure enum -> categorical (text) series.
    final enumSig = byName['FCU_SIV_Stat']!;
    expect(decoder.decode(enumSig.message, enumSig.signal).isEnum, isTrue);

    // FCI_EImpSptFrq_App has factor 0.1 + a sparse VAL_ sentinel -> numeric.
    final numSig = byName['FCI_EImpSptFrq_App']!;
    final s = decoder.decode(numSig.message, numSig.signal);
    expect(s.isEnum, isFalse);
    expect(s.values.first, closeTo(6553.5, 1e-6));
  });
}
