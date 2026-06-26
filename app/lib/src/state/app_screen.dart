/// The top-level screen the app is showing.
///
/// The app is a hub-and-spoke workspace, not a linear wizard: pick a library
/// ([welcome]), watch it scan ([scanning]), land on the hub ([workspace]), then
/// open a focused [action] panel and return to the hub.
enum AppScreen {
  /// No library chosen yet — the hero / folder picker.
  welcome,

  /// A scan is in flight; live counts update until it completes.
  scanning,

  /// The library hub: stats, content breakdown, and the action grid.
  workspace,

  /// A single focused action flow (tag, map, prune).
  action,

  /// The live, pannable/zoomable Explore map of geotagged photos.
  explore,
}
