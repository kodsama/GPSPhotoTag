import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An [IOSink] that accumulates everything written to it into a string buffer,
/// so tests can assert a command's stdout without touching the real console.
class BufferSink implements IOSink {
  final StringBuffer _buf = StringBuffer();

  @override
  Encoding encoding = utf8;

  /// Everything written so far, decoded as text.
  String get text => _buf.toString();

  @override
  void write(Object? obj) => _buf.write(obj);

  @override
  void writeln([Object? obj = '']) => _buf.writeln(obj);

  @override
  void writeAll(Iterable<dynamic> objects, [String sep = '']) =>
      _buf.writeAll(objects, sep);

  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);

  @override
  void add(List<int> data) => _buf.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}

/// A minimal valid JPEG (SOI + EOI) — enough for [JpegExifBackend] to splice an
/// Exif APP1 block into. Avoids depending on `package:image` in the CLI package.
Uint8List minimalJpeg() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
