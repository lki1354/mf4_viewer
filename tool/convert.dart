import 'dart:io';

import 'package:mf4_viewer/src/convert/converter.dart';

/// Command-line CAN log → MF4 converter.
///
/// Usage:
///
/// ```
/// dart run tool/convert.dart <input.{blf,trc,asc,csv,mf4}> [<input2> ...] \
///     <output.mf4> [--db <database.{dbc,arxml}>]...
/// ```
///
/// Several inputs are merged (time-sorted) into a single MF4 — this is also
/// how multiple MF4 files are combined into one. Databases (DBC or ARXML) are
/// optional; each one supplied is embedded in the output MF4 (ARXML is
/// converted to DBC first) so the trace is self-describing. Databases already
/// embedded in MF4 inputs are carried over automatically.
void main(List<String> args) {
  final positional = <String>[];
  final dbs = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--db' || a == '-d') {
      if (i + 1 >= args.length) {
        _fail('--db requires a path argument.');
      }
      dbs.add(args[++i]);
    } else if (a == '-h' || a == '--help') {
      _usage();
      return;
    } else {
      positional.add(a);
    }
  }

  if (positional.length < 2) {
    _usage();
    exit(positional.isEmpty ? 0 : 64);
  }

  final inputs = positional.sublist(0, positional.length - 1);
  final output = positional.last;

  for (final input in inputs) {
    if (!File(input).existsSync()) {
      _fail('Input file not found: $input');
    }
  }
  for (final db in dbs) {
    if (!File(db).existsSync()) {
      _fail('Database file not found: $db');
    }
  }

  try {
    final result = CanConverter.convertFiles(
      inputPaths: inputs,
      outputPath: output,
      databasePaths: dbs,
    );
    stdout.writeln(result.summary());
    stdout.writeln('Wrote $output (${result.mf4Bytes.length} bytes).');
  } on FormatException catch (e) {
    _fail(e.message);
  }
}

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/convert.dart <input.{blf,trc,asc,csv,mf4}> '
    '[<input2> ...] <output.mf4> [--db <database.{dbc,arxml}>]...',
  );
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(65);
}
