import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/app_state.dart';
import '../model/plot_config.dart';
import 'plot_panel.dart';
import 'signal_picker.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _targetGraph = 0;

  @override
  void initState() {
    super.initState();
    // Optional auto-load for automation / demos:
    //   flutter run --dart-define=MF4_AUTOLOAD=/path/to.mf4 [--dart-define=MF4_DEMO=1]
    const auto = String.fromEnvironment('MF4_AUTOLOAD');
    if (auto.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoLoad(auto));
    }
  }

  Future<void> _autoLoad(String path) async {
    final bytes = await _readPath(path);
    if (bytes == null || !mounted) return;
    final state = context.read<AppState>();
    await state.loadFile(bytes, path.split(Platform.pathSeparator).last);
    if (!mounted) return;
    if (const bool.fromEnvironment('MF4_DEMO') ||
        const String.fromEnvironment('MF4_DEMO').isNotEmpty) {
      _populateDemo(state);
    }
  }

  /// Builds an illustrative layout: a numeric dual-axis graph and a graph of
  /// enum/state signals shown as text.
  void _populateDemo(AppState state) {
    void add(int g, String name, {bool right = false}) {
      final sig = state.signalByName(name);
      if (sig == null) return;
      state.addSignalToGraph(g, sig);
      final cfg = state.workspace.graphs[g].series.last;
      if (right) state.updateSeries(cfg, (c) => c.axis = AxisSide.right);
    }

    add(0, 'FCI_EU_FCI'); // voltage, left axis
    add(0, 'FCI_EI_FCIo', right: true); // current, right axis
    add(0, 'FCI_SupBat_Volt');
    state.renameGraph(state.workspace.graphs[0], 'Power transfer (V / A)');

    state.addGraph();
    add(1, 'FCI_State'); // enum -> text axis
    state.renameGraph(state.workspace.graphs[1], 'States');

    state.addGraph();
    add(2, 'FCU_SIV_Stat'); // enum -> text axis
    state.renameGraph(state.workspace.graphs[2], 'SIV status');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isWide = MediaQuery.of(context).size.width >= 900;

    _targetGraph = _targetGraph.clamp(0, state.workspace.graphs.length - 1);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.fileName == null
            ? 'MF4 Viewer'
            : 'MF4 Viewer — ${state.fileName}'),
        actions: _actions(context, state),
      ),
      drawer: (isWide || !state.hasData)
          ? null
          : Drawer(child: SafeArea(child: _picker(state))),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : !state.hasData
              ? _welcome(context, state)
              : isWide
                  ? Row(
                      children: [
                        SizedBox(
                          width: 320,
                          child: Material(
                            elevation: 1,
                            child: _picker(state),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _graphs(state)),
                      ],
                    )
                  : _graphs(state),
      floatingActionButton: state.hasData
          ? FloatingActionButton.extended(
              onPressed: state.addGraph,
              icon: const Icon(Icons.add_chart),
              label: const Text('Graph'),
            )
          : null,
    );
  }

  List<Widget> _actions(BuildContext context, AppState state) {
    return [
      IconButton(
        tooltip: 'Open MF4 file',
        icon: const Icon(Icons.folder_open),
        onPressed: () => _openFile(context),
      ),
      if (state.hasData) ...[
        IconButton(
          tooltip: state.workspace.linkXAxis
              ? 'Time axis linked across graphs'
              : 'Time axis independent',
          icon: Icon(
              state.workspace.linkXAxis ? Icons.link : Icons.link_off),
          onPressed: () => state.setLinkXAxis(!state.workspace.linkXAxis),
        ),
        IconButton(
          tooltip: 'Reset zoom',
          icon: const Icon(Icons.fit_screen),
          onPressed: state.resetView,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) => _onMenu(context, state, v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'export', child: Text('Export config…')),
            PopupMenuItem(value: 'import', child: Text('Import config…')),
            PopupMenuItem(value: 'info', child: Text('File info')),
          ],
        ),
      ],
    ];
  }

  Widget _picker(AppState state) =>
      SignalPicker(targetGraphIndex: _targetGraph);

  Widget _graphs(AppState state) {
    final graphs = state.workspace.graphs;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Give each graph a sensible minimum height; scroll when many.
        final minH = 260.0;
        final totalH = (minH * graphs.length)
            .clamp(constraints.maxHeight, double.infinity);
        return SingleChildScrollView(
          child: SizedBox(
            height: totalH,
            child: Column(
              children: [
                for (var i = 0; i < graphs.length; i++)
                  Expanded(
                    child: PlotPanel(
                      index: i,
                      isTarget: i == _targetGraph,
                      onSelectTarget: () => setState(() => _targetGraph = i),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _welcome(BuildContext context, AppState state) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.show_chart, size: 72),
            const SizedBox(height: 16),
            Text('MF4 Viewer',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Open an ASAM MDF4 (.mf4) CAN trace log to plot signals.\n'
              'Signals are decoded with the embedded DBC; enumerations are '
              'shown as text.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _openFile(context),
              icon: const Icon(Icons.folder_open),
              label: const Text('Open MF4 file'),
            ),
            if (state.error != null) ...[
              const SizedBox(height: 16),
              Text(state.error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.any,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    Uint8List? bytes = f.bytes;
    if (bytes == null && f.path != null) {
      // On some desktop platforms bytes is null; read via dart:io path.
      bytes = await _readPath(f.path!);
    }
    if (bytes == null) return;
    if (!context.mounted) return;
    await context.read<AppState>().loadFile(bytes, f.name);
  }

  Future<Uint8List?> _readPath(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _onMenu(
      BuildContext context, AppState state, String value) async {
    switch (value) {
      case 'export':
        await _exportConfig(context, state);
        break;
      case 'import':
        await _importConfig(context, state);
        break;
      case 'info':
        _showInfo(context, state);
        break;
    }
  }

  Future<void> _exportConfig(BuildContext context, AppState state) async {
    final json = state.exportWorkspace();
    final bytes = Uint8List.fromList(utf8.encode(json));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save plot configuration',
      fileName: 'mf4_viewer_config.json',
      bytes: bytes,
    );
    if (!context.mounted) return;
    if (path != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Configuration saved')));
    }
  }

  Future<void> _importConfig(BuildContext context, AppState state) async {
    final result = await FilePicker.platform
        .pickFiles(withData: true, type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) return;
    try {
      state.importWorkspace(utf8.decode(bytes));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Invalid config: $e')));
    }
  }

  void _showInfo(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('File info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File: ${state.fileName ?? '-'}'),
            Text('MDF version: ${state.mdfVersion ?? '-'}'),
            Text('DBC: ${state.dbcName ?? '-'}'),
            Text('Decodable signals: ${state.signals.length}'),
            Text('Time range: ${state.dataTMin.toStringAsFixed(3)} – '
                '${state.dataTMax.toStringAsFixed(3)} s'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }
}
