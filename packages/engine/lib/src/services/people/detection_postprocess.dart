/// Pure post-processing of the SSD-MobileNet detector's raw output tensors into
/// a single people/pet score in 0..1.
///
/// The model emits four parallel arrays (`detection_scores`,
/// `detection_classes`, plus boxes and a count). The people/pet score is the
/// highest confidence among detections that (a) clear a confidence threshold and
/// (b) are a person or one of the recognised animals ([isPersonOrAnimal]). With
/// no qualifying detection the score is 0. Everything here is pure so the whole
/// decode is unit-testable without a model.
library;

import 'coco_labels.dart';

/// The minimum confidence a detection must reach to count. SSD-MobileNet emits
/// many low-confidence boxes; ~0.5 is the conventional cut-off.
const double kDetectionScoreThreshold = 0.5;

/// The highest person/animal confidence in the model's outputs, as a 0..1 score.
///
/// [scores] and [classes] are the parallel `detection_scores` /
/// `detection_classes` arrays (same length, one entry per candidate box).
/// [numDetections] is how many leading entries are valid (the model pads the
/// tail); it is clamped to the arrays' length so a bogus count never reads out
/// of range. A detection counts only when its score ≥ [threshold] AND its class
/// [isPersonOrAnimal]. Returns the max such score, or 0 when none qualifies.
double peopleScoreFromDetections(
  List<double> scores,
  List<double> classes,
  int numDetections, {
  double threshold = kDetectionScoreThreshold,
}) {
  final limit = _limit(numDetections, scores.length, classes.length);
  var best = 0.0;
  for (var i = 0; i < limit; i++) {
    final score = scores[i];
    if (score < threshold) continue;
    if (!isPersonOrAnimal(classes[i].round())) continue;
    if (score > best) best = score;
  }
  return best;
}

/// The number of leading detections to read: [numDetections] clamped to [0, the
/// shortest parallel array] so a negative or oversized count is harmless.
int _limit(int numDetections, int scoresLen, int classesLen) {
  final shortest = scoresLen < classesLen ? scoresLen : classesLen;
  if (numDetections < 0) return 0;
  return numDetections < shortest ? numDetections : shortest;
}
