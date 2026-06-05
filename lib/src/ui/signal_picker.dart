import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../decode/can_decoder.dart';
import '../model/app_state.dart';

/// Searchable list of decodable signals, grouped by CAN message. Tapping a
/// signal adds it to the [targetGraphIndex] graph.
class SignalPicker extends StatefulWidget {
  final int targetGraphIndex;
  const SignalPicker({super.key, required this.targetGraphIndex});

  @override
  State<SignalPicker> createState() => _SignalPickerState();
}

class _SignalPickerState extends State<SignalPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final q = _query.toLowerCase();
    final signals = state.signals
        .where((s) =>
            q.isEmpty ||
            s.qualifiedName.toLowerCase().contains(q) ||
            s.messageName.toLowerCase().contains(q))
        .toList();

    // group by message
    final byMessage = <String, List<DecodableSignal>>{};
    for (final s in signals) {
      (byMessage[s.messageName] ??= []).add(s);
    }
    final messages = byMessage.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search signals…',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${signals.length} signals → Graph ${widget.targetGraphIndex + 1}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: messages.length,
            itemBuilder: (context, i) {
              final msg = messages[i];
              final list = byMessage[msg]!;
              return ExpansionTile(
                dense: true,
                title: Text(msg,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${list.length} signals'),
                initiallyExpanded: q.isNotEmpty,
                children: [
                  for (final s in list)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        s.isEnum ? Icons.abc : Icons.show_chart,
                        size: 18,
                        color: s.isEnum ? Colors.deepPurple : Colors.blueGrey,
                      ),
                      title: Text(s.qualifiedName),
                      subtitle: s.unit.isNotEmpty ? Text(s.unit) : null,
                      trailing: const Icon(Icons.add, size: 18),
                      onTap: () => context
                          .read<AppState>()
                          .addSignalToGraph(widget.targetGraphIndex, s),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
