import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../convert/frame_builder.dart';
import '../dbc/dbc_model.dart';
import '../dbc/dbc_parser.dart';
import '../decode/can_decoder.dart';
import '../decode/signal_series.dart';
import '../mdf/mdf4_reader.dart';
import 'plot_config.dart';

/// Result of parsing one or more files, returned from the background isolate.
class _LoadResult {
  final CanFrameTable frames;
  final DbcDatabase? db;
  final String? dbcName;
  final String version;
  _LoadResult(this.frames, this.db, this.dbcName, this.version);
}

/// Parse every given MF4 file, merge their frame streams (sorted by time)
/// and merge every embedded `.dbc` database into one decoding database.
_LoadResult _parseInIsolate(List<Uint8List> files) {
  final tables = <CanFrameTable>[];
  final dbs = <DbcDatabase>[];
  final dbcNames = <String>{};
  final versions = <String>{};
  for (final bytes in files) {
    final reader = Mdf4Reader.fromBytes(bytes);
    tables.add(reader.readCanFrames());
    versions.add(reader.version);
    for (final att in reader.attachments()) {
      if (att.key.toLowerCase().endsWith('.dbc')) {
        dbs.add(DbcParser.parse(utf8.decode(att.value, allowMalformed: true)));
        dbcNames.add(att.key);
      }
    }
  }
  return _LoadResult(
    FrameBuilder.merge(tables),
    dbs.isEmpty ? null : DbcDatabase.merge(dbs),
    dbcNames.isEmpty ? null : dbcNames.join(', '),
    versions.join(', '),
  );
}

/// Central application state. Holds the loaded log, the decoder, the cached
/// decoded series, the plot workspace and the shared (linked) time window.
class AppState extends ChangeNotifier {
  CanDecoder? _decoder;
  List<DecodableSignal> _signals = [];
  Map<String, DecodableSignal> _signalIndex = {};
  final Map<String, SignalSeries> _seriesCache = {};

  Workspace workspace = Workspace();

  String? fileName;
  String? dbcName;
  String? mdfVersion;
  bool loading = false;
  String? error;

  // Global data extent and current view window (seconds).
  double dataTMin = 0;
  double dataTMax = 1;
  double viewTMin = 0;
  double viewTMax = 1;

  bool get hasData => _decoder != null;
  List<DecodableSignal> get signals => _signals;
  CanDecoder? get decoder => _decoder;

  DecodableSignal? signalByName(String name) => _signalIndex[name];

  Future<void> loadFile(Uint8List bytes, String name) =>
      loadFiles([bytes], [name]);

  /// Load one or more MF4 files at once. Frames from all files are merged
  /// into a single time-sorted stream and every embedded DBC contributes to
  /// the decoding database, so signals from all files plot together.
  Future<void> loadFiles(List<Uint8List> files, List<String> names) async {
    if (files.isEmpty) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await compute(_parseInIsolate, files);
      if (result.db == null) {
        throw const FormatException(
            'No DBC database is embedded in this file. Load a .dbc to decode.');
      }
      _decoder = CanDecoder(result.frames, result.db!);
      _signals = _decoder!.availableSignals();
      _signalIndex = {for (final s in _signals) s.qualifiedName: s};
      _seriesCache.clear();
      fileName = names.length == 1
          ? names.first
          : '${names.first} (+${names.length - 1} more)';
      dbcName = result.dbcName;
      mdfVersion = result.version;

      // Establish the time extent from the raw frame stream.
      final t = result.frames.time;
      if (t.isNotEmpty) {
        dataTMin = t.first;
        dataTMax = t.last;
        for (final v in t) {
          if (v < dataTMin) dataTMin = v;
          if (v > dataTMax) dataTMax = v;
        }
      } else {
        dataTMin = 0;
        dataTMax = 1;
      }
      resetView();
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Decode (and cache) the series for a configured signal.
  SignalSeries? seriesFor(SeriesConfig cfg) {
    if (_decoder == null) return null;
    return _seriesCache.putIfAbsent(cfg.key, () {
      final ds = _signalIndex[cfg.signalName];
      if (ds == null) {
        return SignalSeries(
          name: cfg.signalName,
          unit: '',
          timestamps: Float64List(0),
          values: Float64List(0),
        );
      }
      return _decoder!.decode(ds.message, ds.signal);
    });
  }

  // ---- workspace editing -------------------------------------------------

  int _colorCursor = 0;

  void addSignalToGraph(int graphIndex, DecodableSignal sig) {
    final graph = workspace.graphs[graphIndex];
    if (graph.series.any((s) => s.signalName == sig.qualifiedName)) return;
    final cfg = SeriesConfig(
      signalName: sig.qualifiedName,
      messageName: sig.messageName,
      colorValue: kSeriesPalette[_colorCursor++ % kSeriesPalette.length],
      stepped: sig.isEnum,
      // Put enums on the right axis by default so numeric trends stay readable.
      axis: sig.isEnum && graph.hasLeft ? AxisSide.right : AxisSide.left,
    );
    graph.series.add(cfg);
    notifyListeners();
  }

  void removeSeries(int graphIndex, SeriesConfig cfg) {
    workspace.graphs[graphIndex].series.remove(cfg);
    notifyListeners();
  }

  void addGraph() {
    workspace.graphs.add(GraphConfig(title: 'Graph ${workspace.graphs.length + 1}'));
    notifyListeners();
  }

  void removeGraph(int index) {
    if (workspace.graphs.length <= 1) return;
    workspace.graphs.removeAt(index);
    notifyListeners();
  }

  void renameGraph(GraphConfig graph, String title) {
    graph.title = title;
    notifyListeners();
  }

  void setLinkXAxis(bool value) {
    workspace.linkXAxis = value;
    notifyListeners();
  }

  void updateSeries(SeriesConfig cfg, void Function(SeriesConfig) mutate) {
    mutate(cfg);
    notifyListeners();
  }

  // ---- time view ---------------------------------------------------------

  void resetView() {
    viewTMin = dataTMin;
    viewTMax = dataTMax;
    notifyListeners();
  }

  /// Apply a new view window, clamped to the data extent.
  void setView(double tMin, double tMax) {
    const minSpan = 1e-4;
    if (tMax - tMin < minSpan) return;
    viewTMin = tMin.clamp(dataTMin, dataTMax);
    viewTMax = tMax.clamp(dataTMin, dataTMax);
    if (viewTMax - viewTMin < minSpan) {
      viewTMax = (viewTMin + minSpan).clamp(dataTMin, dataTMax);
    }
    notifyListeners();
  }

  // ---- workspace persistence --------------------------------------------

  String exportWorkspace() =>
      const JsonEncoder.withIndent('  ').convert(workspace.toJson());

  void importWorkspace(String jsonText) {
    final map = jsonDecode(jsonText) as Map<String, dynamic>;
    workspace = Workspace.fromJson(map);
    _seriesCache.clear();
    notifyListeners();
  }
}
