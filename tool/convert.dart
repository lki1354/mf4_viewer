import 'dart:io';

import 'package:mf4_viewer/src/convert/converter.dart';

/// Command-line CAN log → MF4 converter.
///
/// Usage:
///
/// ```
/// dart run tool/convert.dart <input.{blf,trc,csv,mf4}> <output.mf4> \
///     [--db <database.{dbc,arxml}>]
/// ```
///
/// The database (DBC or ARXML) is optional; when supplied it is embedded in the
/// output MF4 (ARXML is converted to DBC first) so the trace is self-describing.
void main(List<String> args) {
  final positional = <String>[];
  String? db;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--db' || a == '-d') {
      if (i + 1 >= args.length) {
        _fail('--db requires a path argument.');
      }
      db = args[++i];
    } else if (a == '-h' || a == '--help') {
      _usage();
      return;
    } else {
      positional.add(a);
    }
  }

  if (positional.length != 2) {
    _usage();
    exit(positional.isEmpty ? 0 : 64);
  }

  final input = positional[0];
  final output = positional[1];

  if (!File(input).existsSync()) {
    _fail('Input file not found: $input');
  }
  if (db != null && !File(db).existsSync()) {
    _fail('Database file not found: $db');
  }

  try {
    final result = CanConverter.convertFile(
      inputPath: input,
      outputPath: output,
      databasePath: db,
    );
    stdout.writeln(result.summary());
    stdout.writeln('Wrote $output (${result.mf4Bytes.length} bytes).');
  } on FormatException catch (e) {
    _fail(e.message);
  }
}

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/convert.dart <input.{blf,trc,csv,mf4}> '
    '<output.mf4> [--db <database.{dbc,arxml}>]',
  );
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(65);
}
