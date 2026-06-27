import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('kPeopleSignalTags', () {
    test('covers the face-region, person-name, and keyword conventions', () {
      expect(
        kPeopleSignalTags,
        containsAll([
          'RegionName',
          'RegionType',
          'RegionInfo',
          'PersonInImage',
          'Subject',
          'Keywords',
          'FacesDetected',
        ]),
      );
    });
  });

  group('peopleScoreFromTags — face regions (score 1.0)', () {
    test('a named XMP-mwg-rs region scores 1.0', () {
      expect(peopleScoreFromTags({'RegionName': 'Alice'}), 1.0);
    });

    test('a list of region names scores 1.0', () {
      expect(
        peopleScoreFromTags({
          'RegionName': ['Alice', 'Bob'],
        }),
        1.0,
      );
    });

    test('a RegionType of "Face" scores 1.0', () {
      expect(peopleScoreFromTags({'RegionType': 'Face'}), 1.0);
    });

    test('a RegionType list containing a face scores 1.0', () {
      expect(
        peopleScoreFromTags({
          'RegionType': ['Pet', 'Face'],
        }),
        1.0,
      );
    });

    test('a nested RegionInfo with a RegionList scores 1.0', () {
      expect(
        peopleScoreFromTags({
          'RegionInfo': {
            'RegionList': [
              {'Name': 'Alice', 'Type': 'Face'},
            ],
          },
        }),
        1.0,
      );
    });

    test('a flattened RegionInfo Name scores 1.0', () {
      expect(
        peopleScoreFromTags({
          'RegionInfo': {'Name': 'Alice'},
        }),
        1.0,
      );
    });

    test('a flattened RegionInfo Type of Face scores 1.0', () {
      expect(
        peopleScoreFromTags({
          'RegionInfo': {'Type': 'Face'},
        }),
        1.0,
      );
    });

    test('an empty RegionInfo map is not a signal', () {
      expect(peopleScoreFromTags({'RegionInfo': <String, Object?>{}}), 0.0);
    });

    test('an empty RegionList is not a signal', () {
      expect(
        peopleScoreFromTags({
          'RegionInfo': {'RegionList': <Object?>[]},
        }),
        0.0,
      );
    });

    test('a blank region name is not a signal', () {
      expect(peopleScoreFromTags({'RegionName': '   '}), 0.0);
    });
  });

  group('peopleScoreFromTags — person names (score 1.0)', () {
    test('a PersonInImage name scores 1.0', () {
      expect(peopleScoreFromTags({'PersonInImage': 'Carol'}), 1.0);
    });

    test('a list of person names scores 1.0', () {
      expect(
        peopleScoreFromTags({
          'PersonInImage': ['Carol', 'Dave'],
        }),
        1.0,
      );
    });
  });

  group('peopleScoreFromTags — detected faces (score 1.0)', () {
    test('a positive numeric FacesDetected scores 1.0', () {
      expect(peopleScoreFromTags({'FacesDetected': 3}), 1.0);
    });

    test('a positive numeric-string FacesDetected scores 1.0', () {
      expect(peopleScoreFromTags({'FacesDetected': ' 2 '}), 1.0);
    });

    test('a zero FacesDetected count is not a signal', () {
      expect(peopleScoreFromTags({'FacesDetected': 0}), 0.0);
    });

    test('a non-numeric FacesDetected string is not a signal', () {
      expect(peopleScoreFromTags({'FacesDetected': 'lots'}), 0.0);
    });
  });

  group('peopleScoreFromTags — keyword hints (score 0.5)', () {
    test('a person word in Subject scores 0.5', () {
      expect(peopleScoreFromTags({'Subject': 'portrait of a friend'}), 0.5);
    });

    test('a pet word in Keywords scores 0.5', () {
      expect(
        peopleScoreFromTags({
          'Keywords': ['vacation', 'dog'],
        }),
        0.5,
      );
    });

    test('whole-word matching: "cathedral" does not count as "cat"', () {
      expect(peopleScoreFromTags({'Keywords': 'cathedral sunset'}), 0.0);
    });

    test('keywords split on separators (comma/semicolon)', () {
      expect(peopleScoreFromTags({'Subject': 'sky,clouds;baby'}), 0.5);
    });
  });

  group('peopleScoreFromTags — precedence & no-signal', () {
    test('a face region beats a co-present keyword hint (1.0 not 0.5)', () {
      expect(
        peopleScoreFromTags({'RegionName': 'Alice', 'Subject': 'dog'}),
        1.0,
      );
    });

    test('an entry with no people/pet evidence scores 0.0', () {
      expect(
        peopleScoreFromTags({
          'ImageWidth': 4000,
          'ImageHeight': 3000,
          'Subject': 'sunset mountains',
        }),
        0.0,
      );
    });

    test('an empty entry scores 0.0', () {
      expect(peopleScoreFromTags(const {}), 0.0);
    });

    test('non-string/non-list tag values are ignored', () {
      expect(peopleScoreFromTags({'Subject': 42, 'RegionName': 7}), 0.0);
    });
  });
}
