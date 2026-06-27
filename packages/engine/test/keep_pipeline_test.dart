import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// Builds a [HashedFile] with the fields the cascade reads, defaulting the rest.
HashedFile hf(
  String path, {
  int width = 100,
  int height = 100,
  int fileSize = 1000,
  double quality = 0.5,
}) => HashedFile(
  path: path,
  hash: 0,
  width: width,
  height: height,
  fileSize: fileSize,
  basename: path,
  isRaw: false,
  quality: ImageQuality(
    sharpness: quality,
    contrast: quality,
    colorfulness: quality,
    composite: quality,
  ),
);

void main() {
  group('chooseKeeper — resolution rule', () {
    test(
      'a clear resolution winner stops early (quality is never consulted)',
      () {
        // The low-res file has higher quality, but resolution decides first and
        // its winner has >15% more pixels, so quality never runs.
        final big = hf('/big.jpg', width: 200, height: 200, quality: 0.1);
        final small = hf('/small.jpg', width: 100, height: 100, quality: 0.9);
        final keeper = chooseKeeper([small, big], KeepPipeline.standard);
        expect(keeper.path, '/big.jpg');
      },
    );

    test('within ~15% pixels is a near-tie → falls through to quality', () {
      // 110×100 vs 100×100 = +10% pixels: under the 1.15 ratio, so resolution
      // can't decide and the higher-quality candidate wins via the next rule.
      final a = hf('/a.jpg', width: 110, height: 100, quality: 0.2);
      final b = hf('/b.jpg', width: 100, height: 100, quality: 0.9);
      final keeper = chooseKeeper([a, b], KeepPipeline.standard);
      expect(keeper.path, '/b.jpg');
    });
  });

  group('chooseKeeper — quality rule', () {
    test(
      'near-equal resolution falls through; quality picks the clear winner',
      () {
        final a = hf('/a.jpg', width: 100, height: 100, quality: 0.2);
        final b = hf('/b.jpg', width: 100, height: 100, quality: 0.8);
        expect(chooseKeeper([a, b], KeepPipeline.standard).path, '/b.jpg');
      },
    );

    test('quality within the margin is a near-tie → final tie-break', () {
      // Same resolution, quality differs by 0.04 (< 0.08 margin) → neither rule
      // decides, so the larger file wins.
      final a = hf('/a.jpg', quality: 0.50, fileSize: 100);
      final b = hf('/b.jpg', quality: 0.54, fileSize: 999);
      expect(chooseKeeper([a, b], KeepPipeline.standard).path, '/b.jpg');
    });
  });

  group('chooseKeeper — final tie-break', () {
    test('all rules tie → larger file size, then smallest path', () {
      final small = hf('/z.jpg', fileSize: 100);
      final big = hf('/y.jpg', fileSize: 999);
      expect(chooseKeeper([small, big], KeepPipeline.standard).path, '/y.jpg');

      final samePathTie = chooseKeeper([
        hf('/z.jpg', fileSize: 100),
        hf('/a.jpg', fileSize: 100),
      ], KeepPipeline.standard);
      expect(samePathTie.path, '/a.jpg');
    });
  });

  group('chooseKeeper — ordering & flags', () {
    test('reordering rules changes the outcome', () {
      // A high-res-but-dull file vs a low-res-but-crisp file, where neither is a
      // clear winner under its OWN first rule but is under the other.
      // big has +56% pixels (clear resolution winner); small has +0.7 quality
      // (clear quality winner). So resolution-first keeps big, quality-first
      // keeps small.
      final big = hf('/big.jpg', width: 125, height: 125, quality: 0.1);
      final small = hf('/small.jpg', width: 100, height: 100, quality: 0.8);

      final resFirst = chooseKeeper(
        [small, big],
        const KeepPipeline([
          KeepStep(KeepRule.resolution),
          KeepStep(KeepRule.quality),
        ]),
      );
      expect(resFirst.path, '/big.jpg');

      final qualFirst = chooseKeeper(
        [small, big],
        const KeepPipeline([
          KeepStep(KeepRule.quality),
          KeepStep(KeepRule.resolution),
        ]),
      );
      expect(qualFirst.path, '/small.jpg');
    });

    test('a disabled rule is skipped', () {
      // Resolution would keep big, but it's disabled, so quality decides → small.
      final big = hf('/big.jpg', width: 200, height: 200, quality: 0.1);
      final small = hf('/small.jpg', width: 100, height: 100, quality: 0.9);
      final keeper = chooseKeeper(
        [small, big],
        const KeepPipeline([
          KeepStep(KeepRule.resolution, enabled: false),
          KeepStep(KeepRule.quality),
        ]),
      );
      expect(keeper.path, '/small.jpg');
    });

    test(
      'the not-yet-implemented people rule never decides (falls through)',
      () {
        final a = hf('/a.jpg', fileSize: 100);
        final b = hf('/b.jpg', fileSize: 999);
        final keeper = chooseKeeper([
          a,
          b,
        ], const KeepPipeline([KeepStep(KeepRule.people)]));
        // No people scoring yet → tie → final tie-break keeps the larger file.
        expect(keeper.path, '/b.jpg');
      },
    );

    test('a single candidate is returned directly', () {
      final only = hf('/only.jpg');
      expect(chooseKeeper([only], KeepPipeline.standard).path, '/only.jpg');
    });

    test('an empty candidate list throws', () {
      expect(
        () => chooseKeeper(const [], KeepPipeline.standard),
        throwsArgumentError,
      );
    });

    test('a fully-disabled pipeline falls straight to the tie-break', () {
      final keeper = chooseKeeper(
        [hf('/a.jpg', fileSize: 100), hf('/b.jpg', fileSize: 999)],
        const KeepPipeline([
          KeepStep(KeepRule.resolution, enabled: false),
          KeepStep(KeepRule.quality, enabled: false),
        ]),
      );
      expect(keeper.path, '/b.jpg');
    });

    test('three candidates: the top resolution clear-winner is kept', () {
      final keeper = chooseKeeper([
        hf('/mid.jpg', width: 120, height: 120, quality: 0.9),
        hf('/big.jpg', width: 300, height: 300, quality: 0.1),
        hf('/small.jpg', width: 100, height: 100, quality: 0.9),
      ], KeepPipeline.standard);
      expect(keeper.path, '/big.jpg');
    });
  });

  group('KeepStep / KeepPipeline serialization', () {
    test('round-trips the standard pipeline (enabled rules first)', () {
      final json = KeepPipeline.standard.toJson();
      final back = KeepPipeline.fromJson(json);
      // The two saved rules round-trip enabled, in order; the reserved (not-yet-
      // saved) people rule is appended disabled so its toggle can still appear.
      expect(back.steps[0].rule, KeepRule.resolution);
      expect(back.steps[0].enabled, isTrue);
      expect(back.steps[1].rule, KeepRule.quality);
      expect(back.steps[1].enabled, isTrue);
      final people = back.steps.firstWhere((s) => s.rule == KeepRule.people);
      expect(people.enabled, isFalse);
    });

    test('round-trips a reordered, partially-disabled pipeline', () {
      const pipeline = KeepPipeline([
        KeepStep(KeepRule.quality),
        KeepStep(KeepRule.resolution, enabled: false),
      ]);
      final back = KeepPipeline.fromJson(pipeline.toJson());
      expect(back.steps[0].rule, KeepRule.quality);
      expect(back.steps[0].enabled, isTrue);
      expect(back.steps[1].rule, KeepRule.resolution);
      expect(back.steps[1].enabled, isFalse);
    });

    test('withEnabled flips only the enabled flag', () {
      const step = KeepStep(KeepRule.quality);
      final off = step.withEnabled(false);
      expect(off.rule, KeepRule.quality);
      expect(off.enabled, isFalse);
    });

    test('fromJson on garbage yields the standard pipeline', () {
      expect(KeepPipeline.fromJson('nope').steps.length, 2);
      expect(KeepPipeline.fromJson(null).steps.length, 2);
      expect(KeepPipeline.fromJson(42).steps.length, 2);
    });

    test('fromJson drops unknown and duplicate rules', () {
      final back = KeepPipeline.fromJson([
        {'rule': 'quality', 'enabled': true},
        {'rule': 'quality', 'enabled': false}, // duplicate → dropped
        {'rule': 'mystery', 'enabled': true}, // unknown → dropped
        'not a map', // garbage → dropped
      ]);
      // quality kept once (enabled), then the missing rules appended disabled.
      expect(back.steps.first.rule, KeepRule.quality);
      expect(back.steps.first.enabled, isTrue);
      expect(back.steps.map((s) => s.rule).toSet(), KeepRule.values.toSet());
    });

    test('fromJson appends rules missing from the saved order, disabled', () {
      // Only resolution saved → quality (and people) appended, disabled.
      final back = KeepPipeline.fromJson([
        {'rule': 'resolution', 'enabled': true},
      ]);
      expect(back.steps.first.rule, KeepRule.resolution);
      expect(back.steps.first.enabled, isTrue);
      final quality = back.steps.firstWhere((s) => s.rule == KeepRule.quality);
      expect(quality.enabled, isFalse);
    });

    test('fromJson on an empty list yields the standard pipeline', () {
      expect(KeepPipeline.fromJson(const <Object>[]).steps.length, 2);
    });

    test('KeepStep.fromJson rejects non-map and bad rule name', () {
      expect(KeepStep.fromJson('x'), isNull);
      expect(KeepStep.fromJson({'rule': 99}), isNull);
      expect(KeepStep.fromJson({'rule': 'nope'}), isNull);
    });
  });
}
