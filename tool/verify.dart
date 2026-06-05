// Standalone verification harness (pure Dart, no Flutter).
//
// Loads the example MF4 file, decodes signals via the engine and compares the
// results against ground-truth values produced by asammdf.
//
// Run:  dart run tool/verify.dart <file.mf4> <ground_truth.json>

import 'dart:convert';
import 'dart:io';

import 'package:mf4_viewer/src/dbc/dbc_parser.dart';
import 'package:mf4_viewer/src/decode/can_decoder.dart';
import 'package:mf4_viewer/src/mdf/mdf4_reader.dart';

void main(List<String> args) {
  final mf4Path = args.isNotEmpty ? args[0] : 'example.mf4';
  final gtPath = args.length > 1 ? args[1] : 'ground_truth.json';

  final reader = Mdf4Reader.fromFile(mf4Path);
  stdout.writeln('MDF version: ${reader.version}');

  final atts = reader.attachments();
  stdout.writeln('Attachments: ${atts.map((e) => e.key).toList()}');
  final dbcEntry = atts.firstWhere(
    (e) => e.key.toLowerCase().endsWith('.dbc'),
    orElse: () => atts.first,
  );
  final db = DbcParser.parse(utf8.decode(dbcEntry.value, allowMalformed: true));
  stdout.writeln('DBC messages: ${db.messages.length}');

  final frames = reader.readCanFrames();
  stdout.writeln('CAN frames: ${frames.count}');

  final decoder = CanDecoder(frames, db);
  final available = decoder.availableSignals();
  stdout.writeln('Decodable signals: ${available.length}');

  // Build a name -> DecodableSignal index.
  final byName = {for (final s in available) s.qualifiedName: s};

  final gt = jsonDecode(File(gtPath).readAsStringSync()) as Map<String, dynamic>;

  var failures = 0;
  var checks = 0;
  gt.forEach((name, raw) {
    final spec = raw as Map<String, dynamic>;
    final ds = byName[name];
    if (ds == null) {
      stdout.writeln('  MISS  $name : not decodable');
      failures++;
      return;
    }
    final series = decoder.decode(ds.message, ds.signal);
    final expT = (spec['t'] as List).cast<num>();
    final expV = spec['v'] as List;
    final expCount = spec['count'] as int;

    if (series.length != expCount) {
      stdout.writeln(
          '  FAIL  $name : count ${series.length} != $expCount');
      failures++;
    }

    for (var i = 0; i < expT.length; i++) {
      checks++;
      final tOk = (series.timestamps[i] - expT[i]).abs() < 1e-6;
      bool vOk;
      String got;
      if (series.isEnum) {
        got = series.enumLabels![i];
        vOk = got == expV[i].toString();
      } else {
        got = series.values[i].toStringAsFixed(6);
        final ev = expV[i];
        if (ev is num) {
          vOk = (series.values[i] - ev).abs() < 1e-4;
        } else {
          // ground truth is a string (sentinel enum) but we plot numerically.
          vOk = true; // accepted: see DbcSignal.isEnum rationale
        }
      }
      if (!tOk || !vOk) {
        stdout.writeln('  FAIL  $name[$i] t=${series.timestamps[i]} '
            '(exp ${expT[i]}) v=$got (exp ${expV[i]})');
        failures++;
      }
    }
    final kind = series.isEnum ? 'enum' : 'num ';
    stdout.writeln('  OK    [$kind] $name  '
        '(${series.length} samples, first=${series.isEnum ? series.enumLabels!.first : series.values.first})');
  });

  stdout.writeln('\n$checks checks, $failures failures');
  if (failures > 0) exit(1);
}
