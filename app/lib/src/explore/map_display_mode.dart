/// How the Explore map renders the photo distribution.
enum MapDisplayMode {
  /// The classic marker-cluster pins with counts (default).
  numbers,

  /// A density heat overlay only (no number markers).
  heatmap,

  /// The heat overlay *under* the cluster markers.
  both;

  /// The next mode when the mode button is clicked: numbers → heatmap → both →
  /// numbers. Pure so the cycle is unit testable.
  MapDisplayMode get next => switch (this) {
    MapDisplayMode.numbers => MapDisplayMode.heatmap,
    MapDisplayMode.heatmap => MapDisplayMode.both,
    MapDisplayMode.both => MapDisplayMode.numbers,
  };

  /// Whether the cluster/number markers should be drawn in this mode.
  bool get showsMarkers =>
      this == MapDisplayMode.numbers || this == MapDisplayMode.both;

  /// Whether the heat overlay should be drawn in this mode.
  bool get showsHeatmap =>
      this == MapDisplayMode.heatmap || this == MapDisplayMode.both;
}
