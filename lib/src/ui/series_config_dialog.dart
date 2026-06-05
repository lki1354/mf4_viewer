import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/app_state.dart';
import '../model/plot_config.dart';

/// Per-signal plot configuration: axis side, color, stepped/line, width,
/// visibility. Changes are applied live.
Future<void> showSeriesConfigDialog(
    BuildContext context, int graphIndex, SeriesConfig cfg) {
  return showDialog(
    context: context,
    builder: (_) => _SeriesConfigDialog(graphIndex: graphIndex, cfg: cfg),
  );
}

class _SeriesConfigDialog extends StatefulWidget {
  final int graphIndex;
  final SeriesConfig cfg;
  const _SeriesConfigDialog({required this.graphIndex, required this.cfg});

  @override
  State<_SeriesConfigDialog> createState() => _SeriesConfigDialogState();
}

class _SeriesConfigDialogState extends State<_SeriesConfigDialog> {
  static const _palette = [
    Color(0xFF1565C0),
    Color(0xFFD32F2F),
    Color(0xFF2E7D32),
    Color(0xFFF57C00),
    Color(0xFF6A1B9A),
    Color(0xFF00838F),
    Color(0xFFC2185B),
    Color(0xFF558B2F),
    Color(0xFF4E342E),
    Color(0xFF455A64),
    Color(0xFF000000),
    Color(0xFFFFB300),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final cfg = widget.cfg;

    void apply(VoidCallback fn) {
      setState(fn);
      state.updateSeries(cfg, (_) {});
    }

    return AlertDialog(
      title: Text(cfg.signalName, overflow: TextOverflow.ellipsis),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Message: ${cfg.messageName}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),

            // Axis side
            const Text('Y-axis'),
            const SizedBox(height: 4),
            SegmentedButton<AxisSide>(
              segments: const [
                ButtonSegment(value: AxisSide.left, label: Text('Left')),
                ButtonSegment(value: AxisSide.right, label: Text('Right')),
              ],
              selected: {cfg.axis},
              onSelectionChanged: (s) => apply(() => cfg.axis = s.first),
            ),
            const SizedBox(height: 16),

            // Color
            const Text('Color'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in _palette)
                  GestureDetector(
                    onTap: () => apply(() => cfg.colorValue = c.toARGB32()),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: cfg.colorValue == c.toARGB32()
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // Stepped
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stepped (sample & hold)'),
              subtitle: const Text('Recommended for state / enum signals'),
              value: cfg.stepped,
              onChanged: (v) => apply(() => cfg.stepped = v),
            ),

            // Visible
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Visible'),
              value: cfg.visible,
              onChanged: (v) => apply(() => cfg.visible = v),
            ),

            // Stroke width
            Row(
              children: [
                const Text('Line width'),
                Expanded(
                  child: Slider(
                    min: 0.5,
                    max: 4,
                    divisions: 7,
                    label: cfg.strokeWidth.toStringAsFixed(1),
                    value: cfg.strokeWidth,
                    onChanged: (v) => apply(() => cfg.strokeWidth = v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            state.removeSeries(widget.graphIndex, cfg);
            Navigator.pop(context);
          },
          child: const Text('Remove', style: TextStyle(color: Colors.red)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
