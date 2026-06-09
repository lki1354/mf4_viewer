import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../dbc/dbc_model.dart';
import '../dbc/dbc_parser.dart';
import '../dbc/dbc_writer.dart';
import '../mdf/mdf4_reader.dart';
import 'arxml_parser.dart';
import 'mf4_writer.dart';
import 'readers/asc_reader.dart';
import 'readers/blf_reader.dart';
import 'readers/csv_reader.dart';
import 'readers/trc_reader.dart';

/// Supported CAN log input formats.
enum LogFormat { blf, trc, asc, csv, mf4 }

/// Supported database description input formats.
enum DbFormat { dbc, arxml }

/// Outcome of a conversion: the MF4 bytes plus a short summary.
class ConversionResult {
  final Uint8List mf4Bytes;
  final int frameCount;
  final LogFormat inputFormat;
  final String? databaseName;
  final int messageCount;

  ConversionResult({
    required this.mf4Bytes,
    required this.frameCount,
    required this.inputFormat,
    required this.databaseName,
    required this.messageCount,
  });

  String summary() {
    final db = databaseName == null
        ? 'no database'
        : '$databaseName ($messageCount messages)';
    return '${inputFormat.name.toUpperCase()} → MF4: '
        '$frameCount frames, $db.';
  }
}

/// A loaded CAN database together with the canonical DBC text embedded in the
/// converted MF4 file.
class LoadedDatabase {
  final DbcDatabase database;
  final String dbcText;
  final String fileName;

  LoadedDatabase({
    required this.database,
    required this.dbcText,
    required this.fileName,
  });
}

/// High-level entry point for converting CAN logs to ASAM MDF4 (`.mf4`).
class CanConverter {
  /// Guess the log format from a file name extension.
  static LogFormat detectLogFormat(String fileName) {
    final ext = _ext(fileName);
    switch (ext) {
      case 'blf':
        return LogFormat.blf;
      case 'trc':
        return LogFormat.trc;
      case 'asc':
        return LogFormat.asc;
      case 'csv':
      case 'txt':
      case 'log':
        return LogFormat.csv;
      case 'mf4':
      case 'mdf':
      case 'dat':
        return LogFormat.mf4;
      default:
        throw FormatException('Unsupported log format: .$ext');
    }
  }

  static DbFormat detectDbFormat(String fileName) {
    final ext = _ext(fileName);
    if (ext == 'arxml' || ext == 'xml') return DbFormat.arxml;
    if (ext == 'dbc') return DbFormat.dbc;
    throw FormatException('Unsupported database format: .$ext');
  }

  /// Read CAN frames from raw [bytes] of a log named [fileName].
  static CanFrameTable readFrames(
    Uint8List bytes,
    String fileName, {
    LogFormat? format,
  }) {
    final fmt = format ?? detectLogFormat(fileName);
    switch (fmt) {
      case LogFormat.blf:
        return BlfReader.read(bytes);
      case LogFormat.trc:
        return TrcReader.readBytes(bytes);
      case LogFormat.asc:
        return AscReader.readBytes(bytes);
      case LogFormat.csv:
        return CsvCanReader.readBytes(bytes);
      case LogFormat.mf4:
        return Mdf4Reader.fromBytes(bytes).readCanFrames();
    }
  }

  /// Load a database from raw [bytes] of a file named [fileName], normalising
  /// it to a [DbcDatabase] and a canonical DBC text for embedding.
  static LoadedDatabase loadDatabase(Uint8List bytes, String fileName) {
    final fmt = detectDbFormat(fileName);
    switch (fmt) {
      case DbFormat.dbc:
        final text = utf8.decode(bytes, allowMalformed: true);
        return LoadedDatabase(
          database: DbcParser.parse(text),
          dbcText: text,
          fileName: fileName,
        );
      case DbFormat.arxml:
        final db = ArxmlParser.parse(utf8.decode(bytes, allowMalformed: true));
        final dbc = DbcWriter.write(db);
        // Carry the database as a .dbc so the viewer can decode it.
        final dbcName = '${_stem(fileName)}.dbc';
        return LoadedDatabase(
          database: db,
          dbcText: dbc,
          fileName: dbcName,
        );
    }
  }

  /// Convert an in-memory log (and optional database) to MF4 bytes.
  static ConversionResult convertBytes({
    required Uint8List logBytes,
    required String logName,
    Uint8List? dbBytes,
    String? dbName,
    LogFormat? logFormat,
  }) {
    final fmt = logFormat ?? detectLogFormat(logName);
    final frames = readFrames(logBytes, logName, format: fmt);

    LoadedDatabase? db;
    if (dbBytes != null && dbName != null) {
      db = loadDatabase(dbBytes, dbName);
    }

    final attachments = <Mf4Attachment>[];
    if (db != null) {
      attachments.add(Mf4Attachment(
        fileName: db.fileName,
        data: Uint8List.fromList(utf8.encode(db.dbcText)),
      ));
    }

    final mf4 = Mf4Writer.write(frames, attachments: attachments);

    return ConversionResult(
      mf4Bytes: mf4,
      frameCount: frames.count,
      inputFormat: fmt,
      databaseName: db?.fileName,
      messageCount: db?.database.messages.length ?? 0,
    );
  }

  /// Convert a log file on disk to an MF4 file on disk. Returns the result
  /// (the MF4 bytes have already been written to [outputPath]).
  static ConversionResult convertFile({
    required String inputPath,
    required String outputPath,
    String? databasePath,
  }) {
    final logBytes = File(inputPath).readAsBytesSync();
    Uint8List? dbBytes;
    if (databasePath != null) {
      dbBytes = File(databasePath).readAsBytesSync();
    }
    final result = convertBytes(
      logBytes: logBytes,
      logName: inputPath,
      dbBytes: dbBytes,
      dbName: databasePath,
    );
    File(outputPath).writeAsBytesSync(result.mf4Bytes);
    return result;
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String _stem(String name) {
    final base = name.split(Platform.pathSeparator).last.split('/').last;
    final dot = base.lastIndexOf('.');
    return dot < 0 ? base : base.substring(0, dot);
  }
}
