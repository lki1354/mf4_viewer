import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../dbc/dbc_model.dart';
import '../dbc/dbc_parser.dart';
import '../dbc/dbc_writer.dart';
import '../mdf/mdf4_reader.dart';
import 'arxml_parser.dart';
import 'frame_builder.dart';
import 'mf4_writer.dart';
import 'readers/asc_reader.dart';
import 'readers/blf_reader.dart';
import 'readers/csv_reader.dart';
import 'readers/trc_reader.dart';

/// Supported CAN log input formats.
enum LogFormat { blf, trc, asc, csv, mf4 }

/// Supported database description input formats.
enum DbFormat { dbc, arxml }

/// An in-memory input file: its (display) name plus raw content.
class NamedBytes {
  final String name;
  final Uint8List bytes;

  const NamedBytes(this.name, this.bytes);
}

/// Outcome of a conversion: the MF4 bytes plus a short summary.
class ConversionResult {
  final Uint8List mf4Bytes;
  final int frameCount;
  final int inputCount;
  final List<LogFormat> inputFormats;
  final List<String> databaseNames;
  final int messageCount;

  ConversionResult({
    required this.mf4Bytes,
    required this.frameCount,
    required this.inputCount,
    required this.inputFormats,
    required this.databaseNames,
    required this.messageCount,
  });

  LogFormat get inputFormat => inputFormats.first;

  String? get databaseName =>
      databaseNames.isEmpty ? null : databaseNames.join(', ');

  String summary() {
    final fmts = inputFormats
        .map((f) => f.name.toUpperCase())
        .toSet()
        .join('+');
    final files = inputCount == 1 ? '' : ' ($inputCount files merged)';
    final db = databaseNames.isEmpty
        ? 'no database'
        : '${databaseNames.join(', ')} ($messageCount messages)';
    return '$fmts → MF4$files: $frameCount frames, $db.';
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
  }) {
    return convertMany(
      logs: [NamedBytes(logName, logBytes)],
      databases: [
        if (dbBytes != null && dbName != null) NamedBytes(dbName, dbBytes),
      ],
    );
  }

  /// Convert (and merge) one or more in-memory logs to a single MF4.
  ///
  /// Each log may be any supported [LogFormat]; frames from all inputs are
  /// concatenated and re-sorted by timestamp, so this doubles as the
  /// "combine multiple MF4 files" path. Databases work as follows:
  ///
  /// * every file in [databases] (DBC or ARXML) is embedded in the output;
  /// * `.dbc` attachments already embedded in MF4 inputs are carried over,
  ///   so combining self-describing MF4 files stays self-describing.
  ///
  /// Databases with identical content are embedded once; a name clash
  /// between different databases gets a numeric suffix.
  static ConversionResult convertMany({
    required List<NamedBytes> logs,
    List<NamedBytes> databases = const [],
  }) {
    if (logs.isEmpty) {
      throw ArgumentError('At least one input log is required.');
    }

    final tables = <CanFrameTable>[];
    final formats = <LogFormat>[];
    final carried = <NamedBytes>[];
    for (final log in logs) {
      final fmt = detectLogFormat(log.name);
      formats.add(fmt);
      tables.add(readFrames(log.bytes, log.name, format: fmt));
      if (fmt == LogFormat.mf4) {
        for (final att in Mdf4Reader.fromBytes(log.bytes).attachments()) {
          if (att.key.toLowerCase().endsWith('.dbc')) {
            carried.add(NamedBytes(att.key, att.value));
          }
        }
      }
    }
    final frames = FrameBuilder.merge(tables);

    // Explicitly supplied databases take priority over carried-over ones.
    final loaded = <LoadedDatabase>[
      for (final db in databases) loadDatabase(db.bytes, db.name),
    ];
    for (final c in carried) {
      try {
        final text = utf8.decode(c.bytes, allowMalformed: true);
        loaded.add(LoadedDatabase(
          database: DbcParser.parse(text),
          dbcText: text,
          fileName: c.name,
        ));
      } on FormatException {
        // An unreadable embedded database is dropped rather than failing the
        // whole conversion.
      }
    }

    final attachments = <Mf4Attachment>[];
    final embedded = <String, String>{}; // attachment name -> DBC text
    final kept = <DbcDatabase>[];
    for (final db in loaded) {
      if (embedded.containsValue(db.dbcText)) continue; // duplicate content
      var name = _basename(db.fileName);
      if (embedded.containsKey(name)) {
        final stem = _stem(name);
        var i = 2;
        while (embedded.containsKey('${stem}_$i.dbc')) {
          i++;
        }
        name = '${stem}_$i.dbc';
      }
      embedded[name] = db.dbcText;
      kept.add(db.database);
      attachments.add(Mf4Attachment(
        fileName: name,
        data: Uint8List.fromList(utf8.encode(db.dbcText)),
      ));
    }

    final mf4 = Mf4Writer.write(frames, attachments: attachments);

    return ConversionResult(
      mf4Bytes: mf4,
      frameCount: frames.count,
      inputCount: logs.length,
      inputFormats: formats,
      databaseNames: embedded.keys.toList(),
      messageCount: DbcDatabase.merge(kept).messages.length,
    );
  }

  /// Convert (and merge) log files on disk to an MF4 file on disk. Returns
  /// the result (the MF4 bytes have already been written to [outputPath]).
  static ConversionResult convertFile({
    required String inputPath,
    required String outputPath,
    String? databasePath,
  }) =>
      convertFiles(
        inputPaths: [inputPath],
        outputPath: outputPath,
        databasePaths: [if (databasePath != null) databasePath],
      );

  /// Multi-input variant of [convertFile]: merges every input log and embeds
  /// every database.
  static ConversionResult convertFiles({
    required List<String> inputPaths,
    required String outputPath,
    List<String> databasePaths = const [],
  }) {
    final result = convertMany(
      logs: [
        for (final p in inputPaths) NamedBytes(p, File(p).readAsBytesSync()),
      ],
      databases: [
        for (final p in databasePaths) NamedBytes(p, File(p).readAsBytesSync()),
      ],
    );
    File(outputPath).writeAsBytesSync(result.mf4Bytes);
    return result;
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String _basename(String name) =>
      name.split(Platform.pathSeparator).last.split('/').last;

  static String _stem(String name) {
    final base = _basename(name);
    final dot = base.lastIndexOf('.');
    return dot < 0 ? base : base.substring(0, dot);
  }
}
