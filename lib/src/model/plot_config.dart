/// Serializable configuration describing the plot layout: a workspace of one
/// or more graphs, each holding signals assigned to the left or right y-axis.
///
/// Colors are stored as ARGB integers so the whole model is plain JSON and
/// does not depend on Flutter, keeping it unit-testable.
library;

enum AxisSide { left, right }

class SeriesConfig {
  final String signalName;
  final String messageName;
  int colorValue;
  AxisSide axis;
  double strokeWidth;
  bool visible;

  /// Stepped (sample-and-hold) line, the natural representation for state /
  /// enum signals. Defaults on for enums.
  bool stepped;

  SeriesConfig({
    required this.signalName,
    required this.messageName,
    required this.colorValue,
    this.axis = AxisSide.left,
    this.strokeWidth = 1.5,
    this.visible = true,
    this.stepped = false,
  });

  /// Stable identity within a graph.
  String get key => '$messageName::$signalName';

  Map<String, dynamic> toJson() => {
        'signal': signalName,
        'message': messageName,
        'color': colorValue,
        'axis': axis.name,
        'stroke': strokeWidth,
        'visible': visible,
        'stepped': stepped,
      };

  factory SeriesConfig.fromJson(Map<String, dynamic> j) => SeriesConfig(
        signalName: j['signal'] as String,
        messageName: (j['message'] ?? '') as String,
        colorValue: (j['color'] as num).toInt(),
        axis: AxisSide.values.firstWhere(
          (a) => a.name == j['axis'],
          orElse: () => AxisSide.left,
        ),
        strokeWidth: (j['stroke'] as num?)?.toDouble() ?? 1.5,
        visible: (j['visible'] as bool?) ?? true,
        stepped: (j['stepped'] as bool?) ?? false,
      );
}

class GraphConfig {
  String title;
  final List<SeriesConfig> series;

  GraphConfig({required this.title, List<SeriesConfig>? series})
      : series = series ?? [];

  bool get hasLeft => series.any((s) => s.axis == AxisSide.left && s.visible);
  bool get hasRight => series.any((s) => s.axis == AxisSide.right && s.visible);

  Map<String, dynamic> toJson() => {
        'title': title,
        'series': series.map((s) => s.toJson()).toList(),
      };

  factory GraphConfig.fromJson(Map<String, dynamic> j) => GraphConfig(
        title: (j['title'] ?? 'Graph') as String,
        series: ((j['series'] as List?) ?? [])
            .map((e) => SeriesConfig.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class Workspace {
  final List<GraphConfig> graphs;

  /// Link the time (x) axis across all graphs so panning/zooming one moves
  /// them all together — the usual expectation for a multi-graph trace viewer.
  bool linkXAxis;

  Workspace({List<GraphConfig>? graphs, this.linkXAxis = true})
      : graphs = graphs ?? [GraphConfig(title: 'Graph 1')];

  Map<String, dynamic> toJson() => {
        'version': 1,
        'linkXAxis': linkXAxis,
        'graphs': graphs.map((g) => g.toJson()).toList(),
      };

  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
        linkXAxis: (j['linkXAxis'] as bool?) ?? true,
        graphs: ((j['graphs'] as List?) ?? [])
            .map((e) => GraphConfig.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A palette used to auto-assign distinct colors to new series.
const List<int> kSeriesPalette = [
  0xFF1565C0, // blue
  0xFFD32F2F, // red
  0xFF2E7D32, // green
  0xFFF57C00, // orange
  0xFF6A1B9A, // purple
  0xFF00838F, // teal
  0xFFC2185B, // pink
  0xFF558B2F, // light green
  0xFF4E342E, // brown
  0xFF455A64, // blue grey
];
