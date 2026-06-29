import 'package:stunda_engine/src/services/people/ort_session.dart';
import 'package:test/test.dart';

void main() {
  group('OrtException', () {
    test('carries the message and stringifies it', () {
      final e = OrtException('boom');
      expect(e.message, 'boom');
      expect(e.toString(), 'OrtException: boom');
    });
  });

  group('OrtDetectionOutputs', () {
    test('holds the parallel arrays and count', () {
      final out = OrtDetectionOutputs(
        scores: const [0.9],
        classes: const [1],
        numDetections: 1,
      );
      expect(out.scores, [0.9]);
      expect(out.classes, [1]);
      expect(out.numDetections, 1);
    });
  });
}
