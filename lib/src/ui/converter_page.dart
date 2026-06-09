import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../convert/converter.dart';
import '../model/app_state.dart';

/// A self-contained screen that converts a CAN log (BLF / TRC / ASC / CSV /
/// MDF) to an ASAM MDF4 (`.mf4`) file, optionally embedding a DBC or ARXML
/// database. The converted file can be saved and/or plotted straight away.
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
  _PickedFile? _log;
  _PickedFile? _db;
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
                'Convert a CAN log to ASAM MDF4',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Input formats: BLF, TRC, ASC (PCAN/Vector ASCII), CSV and '
                'MDF/MF4. Attach a DBC or ARXML database to embed it in the '
                'output so the trace is self-describing — then plot it straight '
                'away.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              _fileTile(
                label: 'CAN log',
                file: _log,
                hint: 'Pick a .blf / .trc / .asc / .csv / .mf4 file',
                icon: Icons.timeline,
                onPick: _pickLog,
                onClear: () => setState(() => _log = null),
              ),
              const SizedBox(height: 12),
              _fileTile(
                label: 'Database (optional)',
                file: _db,
                hint: 'Pick a .dbc / .arxml file',
                icon: Icons.menu_book,
                onPick: _pickDb,
                onClear: () => setState(() => _db = null),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _log == null || _busy ? null : _convert,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.transform),
                label: Text(_busy ? 'Converting…' : 'Convert & save MF4'),
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

  Widget _fileTile({
    required String label,
    required _PickedFile? file,
    required String hint,
    required IconData icon,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(file?.name ?? label),
        subtitle: Text(file == null
            ? hint
            : '${(file.bytes.length / 1024).toStringAsFixed(1)} KiB'),
        trailing: file == null
            ? const Icon(Icons.add)
            : IconButton(icon: const Icon(Icons.clear), onPressed: onClear),
        onTap: onPick,
      ),
    );
  }

  Future<_PickedFile?> _pick(List<String>? extensions) async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
    );
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.first;
    var bytes = f.bytes;
    if (bytes == null && f.path != null) {
      try {
        bytes = await File(f.path!).readAsBytes();
      } catch (_) {
        return null;
      }
    }
    if (bytes == null) return null;
    return _PickedFile(f.name, bytes);
  }

  Future<void> _pickLog() async {
    final picked = await _pick(
        ['blf', 'trc', 'asc', 'csv', 'txt', 'log', 'mf4', 'mdf']);
    if (picked != null) {
      setState(() {
        _log = picked;
        // A new input invalidates any previously converted result.
        _convertedBytes = null;
        _convertedName = null;
      });
    }
  }

  Future<void> _pickDb() async {
    final picked = await _pick(['dbc', 'arxml', 'xml']);
    if (picked != null) setState(() => _db = picked);
  }

  Future<void> _convert() async {
    final log = _log;
    if (log == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final result = CanConverter.convertBytes(
        logBytes: log.bytes,
        logName: log.name,
        dbBytes: _db?.bytes,
        dbName: _db?.name,
      );
      final outName = '${_stem(log.name)}.mf4';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save converted MF4',
        fileName: outName,
        bytes: result.mf4Bytes,
      );
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
        _convertedBytes = null;
        _convertedName = null;
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

  static String _stem(String name) {
    final base = name.split('/').last.split(r'\').last;
    final dot = base.lastIndexOf('.');
    return dot < 0 ? base : base.substring(0, dot);
  }
}
