import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../convert/converter.dart';
import '../model/app_state.dart';

/// A self-contained screen that converts one or more CAN logs (BLF / TRC /
/// ASC / CSV / MDF) to a single ASAM MDF4 (`.mf4`) file, optionally embedding
/// DBC or ARXML databases. Selecting several inputs merges them onto one
/// timeline — which also makes this the "combine multiple MF4 files" tool.
/// The converted file can be saved and/or plotted straight away.
class ConverterPage extends StatefulWidget {
  const ConverterPage({super.key});

  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _PickedFile {
  final String name;
  final Uint8List bytes;
  _PickedFile(this.name, this.bytes);
}

class _ConverterPageState extends State<ConverterPage> {
  final List<_PickedFile> _logs = [];
  final List<_PickedFile> _dbs = [];
  bool _busy = false;
  String? _status;
  bool _error = false;

  // Holds the most recent successful conversion so it can be plotted directly.
  Uint8List? _convertedBytes;
  String? _convertedName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Convert to MF4')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Convert CAN logs to ASAM MDF4',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Input formats: BLF, TRC, ASC (PCAN/Vector ASCII), CSV and '
                'MDF/MF4. Select several logs to merge them into one MF4 — '
                'e.g. to combine multiple MF4 files. Attach one or more DBC '
                'or ARXML databases to embed them in the output so the trace '
                'is self-describing — then plot it straight away.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              _filesSection(
                label: _logs.length > 1 ? 'CAN logs (merged)' : 'CAN log(s)',
                files: _logs,
                hint: 'Add .blf / .trc / .asc / .csv / .mf4 files',
                icon: Icons.timeline,
                onAdd: _pickLogs,
                onRemove: (f) => setState(() {
                  _logs.remove(f);
                  _invalidateResult();
                }),
              ),
              const SizedBox(height: 12),
              _filesSection(
                label: 'Databases (optional)',
                files: _dbs,
                hint: 'Add .dbc / .arxml files',
                icon: Icons.menu_book,
                onAdd: _pickDbs,
                onRemove: (f) => setState(() {
                  _dbs.remove(f);
                  _invalidateResult();
                }),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _logs.isEmpty || _busy ? null : _convert,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.transform),
                label: Text(_busy
                    ? 'Converting…'
                    : _logs.length > 1
                        ? 'Combine & save MF4'
                        : 'Convert & save MF4'),
              ),
              if (_convertedBytes != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _plotConverted,
                  icon: const Icon(Icons.show_chart),
                  label: const Text('Plot converted file'),
                ),
              ],
              if (_status != null) ...[
                const SizedBox(height: 20),
                Card(
                  color: _error
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_status!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _filesSection({
    required String label,
    required List<_PickedFile> files,
    required String hint,
    required IconData icon,
    required VoidCallback onAdd,
    required void Function(_PickedFile) onRemove,
  }) {
    return Card(
      child: Column(
        children: [
          for (final f in files)
            ListTile(
              leading: Icon(icon),
              title: Text(f.name),
              subtitle:
                  Text('${(f.bytes.length / 1024).toStringAsFixed(1)} KiB'),
              trailing: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => onRemove(f),
              ),
            ),
          ListTile(
            leading: files.isEmpty ? Icon(icon) : null,
            title: Text(files.isEmpty ? label : 'Add more…'),
            subtitle: files.isEmpty ? Text(hint) : null,
            trailing: const Icon(Icons.add),
            onTap: onAdd,
          ),
        ],
      ),
    );
  }

  Future<List<_PickedFile>> _pick(List<String>? extensions) async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
      allowMultiple: true,
    );
    if (result == null) return const [];
    final out = <_PickedFile>[];
    for (final f in result.files) {
      var bytes = f.bytes;
      if (bytes == null && f.path != null) {
        try {
          bytes = await File(f.path!).readAsBytes();
        } catch (_) {
          continue;
        }
      }
      if (bytes == null) continue;
      out.add(_PickedFile(f.name, bytes));
    }
    return out;
  }

  Future<void> _pickLogs() async {
    final picked = await _pick(
        ['blf', 'trc', 'asc', 'csv', 'txt', 'log', 'mf4', 'mdf']);
    if (picked.isEmpty) return;
    setState(() {
      _addAll(_logs, picked);
      // A new input invalidates any previously converted result.
      _invalidateResult();
    });
  }

  Future<void> _pickDbs() async {
    final picked = await _pick(['dbc', 'arxml', 'xml']);
    if (picked.isEmpty) return;
    setState(() {
      _addAll(_dbs, picked);
      _invalidateResult();
    });
  }

  /// Append [picked] to [target], skipping files already in the list.
  static void _addAll(List<_PickedFile> target, List<_PickedFile> picked) {
    for (final p in picked) {
      if (target.any((f) => f.name == p.name)) continue;
      target.add(p);
    }
  }

  void _invalidateResult() {
    _convertedBytes = null;
    _convertedName = null;
  }

  Future<void> _convert() async {
    if (_logs.isEmpty) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final result = CanConverter.convertMany(
        logs: [for (final f in _logs) NamedBytes(f.name, f.bytes)],
        databases: [for (final f in _dbs) NamedBytes(f.name, f.bytes)],
      );
      final outName = _logs.length == 1
          ? '${_stem(_logs.first.name)}.mf4'
          : '${_stem(_logs.first.name)}_combined.mf4';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save converted MF4',
        fileName: outName,
        bytes: result.mf4Bytes,
      );
      // On desktop platforms `saveFile` only returns the chosen path and does
      // not write `bytes` to disk — that only happens on mobile/web. Write the
      // file ourselves so the conversion is actually persisted.
      if (path != null && _isDesktop) {
        await File(path).writeAsBytes(result.mf4Bytes, flush: true);
      }
      if (!mounted) return;
      setState(() {
        _error = false;
        _convertedBytes = result.mf4Bytes;
        _convertedName = outName;
        _status = path == null
            ? '${result.summary()}\nNot saved — you can still plot it below.'
            : '${result.summary()}\nSaved to $path';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _invalidateResult();
        _status = 'Conversion failed: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Load the freshly converted MF4 into the app and return to the viewer to
  /// plot it. Requires an embedded database (attach a DBC/ARXML) to decode.
  Future<void> _plotConverted() async {
    final bytes = _convertedBytes;
    final name = _convertedName;
    if (bytes == null || name == null) return;

    final state = context.read<AppState>();
    await state.loadFile(bytes, name);
    if (!mounted) return;

    if (state.error != null) {
      setState(() {
        _error = true;
        _status = 'Cannot plot: ${state.error}';
      });
      return;
    }
    Navigator.of(context).pop();
  }

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static String _stem(String name) {
    final base = name.split('/').last.split(r'\').last;
    final dot = base.lastIndexOf('.');
    return dot < 0 ? base : base.substring(0, dot);
  }
}
