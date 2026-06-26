import 'explore_model.dart';

/// An inclusive capture-time span: the earliest [start] and latest [end] dates
/// seen across a set of photos. [start] is never after [end] (a single dated
/// photo yields `start == end`).
typedef DateSpan = ({DateTime start, DateTime end});

/// The [DateSpan] covering every dated photo in [photos], or null when none
/// carry a capture [ExplorePhoto.date].
///
/// Pure: ignores null-dated photos entirely, so the Timeline slider's bounds
/// (and whether the button is even offered) are unit testable without a widget
/// tree. A single dated photo yields a zero-width span (`start == end`).
DateSpan? dateSpanOf(Iterable<ExplorePhoto> photos) {
  DateTime? min, max;
  for (final photo in photos) {
    final date = photo.date;
    if (date == null) continue;
    if (min == null || date.isBefore(min)) min = date;
    if (max == null || date.isAfter(max)) max = date;
  }
  if (min == null) return null;
  return (start: min, end: max!);
}

/// [photos] whose capture date falls within [start]..[end] inclusive.
///
/// Pure and order-stable. Photos with a null/unknown [ExplorePhoto.date] are
/// ALWAYS kept (they can't be range-filtered, so the Timeline filter never
/// drops them). A dated photo is kept when its date is not before [start] and
/// not after [end] — both ends inclusive.
List<ExplorePhoto> filterPhotosByDateRange(
  Iterable<ExplorePhoto> photos, {
  required DateTime start,
  required DateTime end,
}) {
  return [
    for (final photo in photos)
      if (_inRange(photo.date, start, end)) photo,
  ];
}

bool _inRange(DateTime? date, DateTime start, DateTime end) {
  if (date == null) return true;
  return !date.isBefore(start) && !date.isAfter(end);
}

/// [date] as the `double` a `RangeSlider` operates on (its
/// milliseconds-since-epoch). Pure inverse of [sliderValueToDateTime].
double dateTimeToSliderValue(DateTime date) =>
    date.millisecondsSinceEpoch.toDouble();

/// The [DateTime] for a slider [value] produced by [dateTimeToSliderValue]
/// (interpreting it as milliseconds since epoch, rounded to the nearest ms).
DateTime sliderValueToDateTime(double value) =>
    DateTime.fromMillisecondsSinceEpoch(value.round());
