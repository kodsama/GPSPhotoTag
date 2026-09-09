import 'package:stunda_engine/src/app/duplicates_service.dart';
import 'package:stunda_engine/src/app/shrink_service.dart';
import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/data/ports/trash.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:test/test.dart';

class _Trash implements Trash {
  @override
  Future<void> toTrash(String path) async {}
}

class _Runner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async =>
      const ProcResult(1, '', '');
}

void main() {
  group('ShrinkStage.byWire', () {
    test('maps every stage name the CLI and MCP accept', () {
      expect(ShrinkStage.byWire('duplicates'), ShrinkStage.duplicates);
      expect(ShrinkStage.byWire('orphans'), ShrinkStage.orphans);
      expect(ShrinkStage.byWire('pairs'), ShrinkStage.pairs);
      expect(ShrinkStage.byWire('low-quality'), ShrinkStage.lowQuality);
    });

    test('an unknown stage is null so callers can report bad_input', () {
      expect(ShrinkStage.byWire('lowQuality'), isNull);
      expect(ShrinkStage.byWire(''), isNull);
    });

    test('every value round-trips through its wire name', () {
      for (final stage in ShrinkStage.values) {
        expect(ShrinkStage.byWire(stage.wire), stage);
      }
    });
  });

  group('PairDropSide.byWire', () {
    test('maps both sides', () {
      expect(PairDropSide.byWire('raw'), PairDropSide.dropRaw);
      expect(PairDropSide.byWire('photo'), PairDropSide.dropPhoto);
    });

    test('an unknown side is null', () {
      expect(PairDropSide.byWire('jpeg'), isNull);
    });
  });

  test('both services fall back to a system temp dir when none is given', () {
    // Constructing without tmpDir must not throw: the default is what a plain
    // `dart run` gets, and the CLI/MCP always take it.
    expect(
      () => DuplicatesService(runner: _Runner(), trash: _Trash()),
      returnsNormally,
    );
    expect(
      () => ShrinkService(runner: _Runner(), trash: _Trash()),
      returnsNormally,
    );
  });
}
