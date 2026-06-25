import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  final expected = DateTime(2026, 6, 22, 10, 43, 38);

  test('Pixel PXL_ pattern (trailing ms ignored)', () {
    expect(
      timestampFromFilename('/photos/PXL_20260622_104338000.jpg'),
      expected,
    );
  });

  test('IMG_ pattern', () {
    expect(timestampFromFilename('IMG_20260622_104338.jpg'), expected);
  });

  test('VID_ pattern', () {
    expect(timestampFromFilename('VID_20260622_104338.mp4'), expected);
  });

  test('bare YYYYMMDD_HHMMSS', () {
    expect(timestampFromFilename('20260622_104338.jpg'), expected);
  });

  test('Screenshot_ pattern', () {
    expect(timestampFromFilename('Screenshot_20260622-104338.png'), expected);
  });

  test('ISO-ish with dots and space', () {
    expect(timestampFromFilename('2026-06-22 10.43.38.jpg'), expected);
  });

  test('ISO-ish with T and dashes', () {
    expect(timestampFromFilename('2026-06-22T10-43-38.heic'), expected);
  });

  test('ISO-ish with colons', () {
    expect(timestampFromFilename('clip 2026-06-22 10:43:38.mov'), expected);
  });

  test('junk -> null', () {
    expect(timestampFromFilename('vacation.jpg'), isNull);
    expect(timestampFromFilename('DSC_1234.jpg'), isNull);
    expect(timestampFromFilename(''), isNull);
  });

  test('out-of-range month -> null', () {
    expect(timestampFromFilename('IMG_20261322_104338.jpg'), isNull);
  });

  test('out-of-range day -> null', () {
    expect(timestampFromFilename('IMG_20260632_104338.jpg'), isNull);
  });

  test('out-of-range hour -> null', () {
    expect(timestampFromFilename('IMG_20260622_244338.jpg'), isNull);
  });

  test('out-of-range minute/second -> null', () {
    expect(timestampFromFilename('IMG_20260622_106038.jpg'), isNull);
    expect(timestampFromFilename('IMG_20260622_104360.jpg'), isNull);
  });

  test('impossible calendar day (Feb 31) -> null', () {
    expect(timestampFromFilename('IMG_20260231_104338.jpg'), isNull);
  });

  test('day zero -> null', () {
    expect(timestampFromFilename('IMG_20260600_104338.jpg'), isNull);
  });
}
