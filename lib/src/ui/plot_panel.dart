import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../chart/time_series_chart.dart';
import '../model/app_state.dart';
import '../model/plot_config.dart';
import 'series_config_dialog.dart';

/// Renders a single graph: a header (title + actions), the chart and a legend
/// row whose chips configure each series.
class PlotPanel extends StatelessWidget {
  final int index;
  final bool isTarget;
  final VoidCallback onSelectTarget;

  const PlotPanel({
    super.key,
    required this.index,
    required this.isTarget,
    required this.onSelectTarget,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final graph = state.workspace.graphs[index];

    final chartSeries = <ChartSeries>[];
    for (final cfg in graph.series) {
      if (!cfg.visible) continue;
      final s = state.seriesFor(cfg);
      if (s == null) continue;
      chartSeries.add(ChartSeries(
        name: s.name,
        unit: s.unit,
        t: s.timestamps,
        v: s.values,
        color: Color(cfg.colorValue),
        stroke: cfg.strokeWidth,
        stepped: cfg.stepped,
        axis: cfg.axis,
        isEnum: s.isEnum,
        levelLabels: s.isEnum ? s.levelLabels : null,
      ));
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isTarget
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, state, graph),
          if (graph.series.isNotEmpty) _legend(context, state, graph),
          Expanded(
            child: chartSeries.isEmpty
                ? _emptyHint(context)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                    child: TimeSeriesChart(
                      series: chartSeries,
                      viewMin: state.viewTMin,
                      viewMax: state.viewTMax,
                      onViewChanged: (min, max) {
                        if (!min.isFinite || !max.isFinite) {
                          state.resetView();
                        } else {
                          state.setView(min, max);
                        }
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppState state, GraphConfig graph) {
    return InkWell(
      onTap: onSelectTarget,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
        child: Row(
          children: [
            Icon(
              isTarget ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                graph.title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Rename graph',
              icon: const Icon(Icons.edit, size: 18),
              onPressed: () => _renameGraph(context, state, graph),
            ),
            IconButton(
              tooltip: 'Remove graph',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: state.workspace.graphs.length > 1
                  ? () => state.removeGraph(index)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, AppState state, GraphConfig graph) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final cfg in graph.series)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                avatar: CircleAvatar(
                  backgroundColor: Color(cfg.colorValue),
                  radius: 6,
                ),
                label: Text(
                  '${cfg.signalName}  ${cfg.axis == AxisSide.left ? 'L' : 'R'}',
                  style: TextStyle(
                    fontSize: 11,
                    decoration: cfg.visible
                        ? TextDecoration.none
                        : TextDecoration.lineThrough,
                  ),
                ),
                onPressed: () => showSeriesConfigDialog(context, index, cfg),
                onDeleted: () => state.removeSeries(index, cfg),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app,
              size: 32, color: Theme.of(context).disabledColor),
          const SizedBox(height: 8),
          Text(
            isTarget
                ? 'Pick signals from the panel to plot here'
                : 'Tap the header to target this graph, then add signals',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _renameGraph(
      BuildContext context, AppState state, GraphConfig graph) async {
    final controller = TextEditingController(text: graph.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename graph'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('OK')),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      state.renameGraph(graph, result.trim());
    }
  }
}
