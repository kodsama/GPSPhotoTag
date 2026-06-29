/// A thin `dart:ffi` wrapper over the ONNX Runtime C API for the one inference
/// shape the Tier-2 detector needs: feed a uint8 NHWC image tensor, read the
/// float detection outputs by name.
///
/// This is the ONLY file that touches the native runtime. It loads
/// `libonnxruntime` via [DynamicLibrary.open], walks the `OrtApi` function-
/// pointer table by ordinal (the table is append-only across releases, so the
/// ordinals captured for v1.27 stay valid), and exposes a tiny [OrtSession] that
/// creates a session from a model file and runs it. All image pre/post-
/// processing lives in pure sibling files; this file is covered by a real
/// integration test against the bundled lib + model.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Ordinals of the `OrtApi` functions used here, captured from the v1.27 C API
/// header. The table only ever grows by appending, so these stay valid.
const int _oGetErrorMessage = 2;
const int _oCreateEnv = 3;
const int _oCreateSession = 7;
const int _oRun = 9;
const int _oCreateSessionOptions = 10;
const int _oSetSessionExecutionMode = 13;
const int _oSetSessionGraphOptimizationLevel = 23;
const int _oSetIntraOpNumThreads = 24;
const int _oSessionGetInputName = 36;
const int _oSessionGetOutputCount = 31;
const int _oSessionGetOutputName = 37;
const int _oCreateTensorWithDataAsOrtValue = 49;
const int _oGetTensorMutableData = 51;
const int _oGetTensorShapeElementCount = 64;
const int _oGetTensorTypeAndShape = 65;
const int _oCreateCpuMemoryInfo = 69;
const int _oAllocatorFree = 76;
const int _oGetAllocatorWithDefaultOptions = 78;
const int _oReleaseEnv = 92;
const int _oReleaseStatus = 93;
const int _oReleaseMemoryInfo = 94;
const int _oReleaseSession = 95;
const int _oReleaseValue = 96;
const int _oReleaseTensorTypeAndShapeInfo = 99;
const int _oReleaseSessionOptions = 100;

/// The `ONNXTensorElementDataType` for uint8 (the detector's image input type).
const int _onnxTensorElemUint8 = 2;

/// The `ONNXTensorElementDataType` for float32 (the embedder's input type).
const int _onnxTensorElemFloat = 1;

/// The `OrtLoggingLevel` for warnings (env creation severity).
const int _ortLoggingLevelWarning = 2;

/// The `GraphOptimizationLevel` for all optimizations.
const int _ortEnableAll = 3;

/// Thrown when a native ONNX Runtime call returns a non-null `OrtStatus`.
class OrtException implements Exception {
  /// Creates an exception carrying the runtime's [message].
  OrtException(this.message);

  /// The error string read from the `OrtStatus`.
  final String message;

  @override
  String toString() => 'OrtException: $message';
}

/// The parallel float outputs of one detection run.
class OrtDetectionOutputs {
  /// Creates the outputs from the model's three relevant tensors.
  OrtDetectionOutputs({
    required this.scores,
    required this.classes,
    required this.numDetections,
  });

  /// `detection_scores`: per-box confidence in 0..1.
  final List<double> scores;

  /// `detection_classes`: per-box COCO category id (as a float).
  final List<double> classes;

  /// `num_detections`: how many leading entries are valid.
  final int numDetections;
}

/// An open ONNX Runtime session over one model, ready to [runDetection].
///
/// Construct via [OrtSession.open] (which loads the library and creates the
/// native env/session), use it, then [close] it to release native resources.
class OrtSession {
  OrtSession._(this._api, this._env, this._session, this._inputName);

  final _OrtApi _api;
  final Pointer<Void> _env;
  final Pointer<Void> _session;
  final String _inputName;
  bool _closed = false;

  /// Opens a session: loads the ORT shared library at [libraryPath], creates an
  /// environment and a session over the model at [modelPath]. Throws
  /// [OrtException] (or an FFI error) when the library or model cannot load.
  static OrtSession open({
    required String libraryPath,
    required String modelPath,
  }) {
    final lib = DynamicLibrary.open(libraryPath);
    final api = _OrtApi(lib);
    return using((Arena arena) {
      final envPP = arena<Pointer<Void>>();
      api.check(
        api.createEnv(_ortLoggingLevelWarning, _cstr('stunda', arena), envPP),
      );
      final env = envPP.value;

      final optsPP = arena<Pointer<Void>>();
      api.check(api.createSessionOptions(optsPP));
      final opts = optsPP.value;
      api.setIntraOpNumThreads(opts, 1);
      api.setSessionGraphOptimizationLevel(opts, _ortEnableAll);
      api.setSessionExecutionMode(opts, 0);

      final sessPP = arena<Pointer<Void>>();
      api.check(api.createSession(env, _cstr(modelPath, arena), opts, sessPP));
      final session = sessPP.value;
      api.releaseSessionOptions(opts);

      final allocPP = arena<Pointer<Void>>();
      api.check(api.getAllocatorWithDefaultOptions(allocPP));
      final alloc = allocPP.value;
      final inputName = api.inputName(session, alloc, arena);

      return OrtSession._(api, env, session, inputName);
    });
  }

  /// Runs the model on one [side]×[side] uint8 NHWC RGB image in [input]
  /// (length `side * side * 3`) and returns the detection outputs. Throws on a
  /// native failure.
  OrtDetectionOutputs runDetection(Uint8List input, {required int side}) {
    if (_closed) throw StateError('OrtSession is closed');
    return using((Arena arena) {
      final memPP = arena<Pointer<Void>>();
      _api.check(_api.createCpuMemoryInfo(0, 0, memPP));
      final memInfo = memPP.value;

      final dataPtr = arena<Uint8>(input.length);
      dataPtr.asTypedList(input.length).setAll(0, input);

      final shape = arena<Int64>(4);
      shape[0] = 1;
      shape[1] = side;
      shape[2] = side;
      shape[3] = 3;

      final inputValPP = arena<Pointer<Void>>();
      _api.check(
        _api.createTensorWithData(
          memInfo,
          dataPtr,
          input.length,
          shape,
          4,
          _onnxTensorElemUint8,
          inputValPP,
        ),
      );
      final inputVal = inputValPP.value;

      final outCountP = arena<Size>();
      _api.check(_api.sessionGetOutputCount(_session, outCountP));
      final outCount = outCountP.value;
      final outNames = <String>[
        for (var i = 0; i < outCount; i++)
          _api.outputName(_session, i, _allocator(arena), arena),
      ];

      final inNamesArr = arena<Pointer<Utf8>>(1);
      inNamesArr[0] = _cstr(_inputName, arena);
      final inValsArr = arena<Pointer<Void>>(1);
      inValsArr[0] = inputVal;
      final outNamesArr = arena<Pointer<Utf8>>(outCount);
      for (var i = 0; i < outCount; i++) {
        outNamesArr[i] = _cstr(outNames[i], arena);
      }
      final outValsArr = arena<Pointer<Void>>(outCount);
      for (var i = 0; i < outCount; i++) {
        outValsArr[i] = nullptr;
      }

      _api.check(
        _api.run(
          _session,
          nullptr,
          inNamesArr,
          inValsArr,
          1,
          outNamesArr,
          outCount,
          outValsArr,
        ),
      );

      final byName = <String, List<double>>{};
      for (var i = 0; i < outCount; i++) {
        byName[outNames[i]] = _api.readFloats(outValsArr[i], arena);
        _api.releaseValue(outValsArr[i]);
      }
      _api.releaseValue(inputVal);
      _api.releaseMemoryInfo(memInfo);

      final scores = byName['detection_scores'] ?? const <double>[];
      final classes = byName['detection_classes'] ?? const <double>[];
      final numList = byName['num_detections'] ?? const <double>[];
      final num = numList.isEmpty ? scores.length : numList.first.round();
      return OrtDetectionOutputs(
        scores: scores,
        classes: classes,
        numDetections: num,
      );
    });
  }

  /// Runs the model on one float32 NCHW image tensor in [input] (length
  /// `3 * side * side`, channel-major: all R, then all G, then all B) and
  /// returns the model's single output tensor as a flat float list — used by the
  /// image embedder, whose model takes a normalized `[1,3,H,W]` float input and
  /// emits a feature/logit vector. Throws on a native failure.
  List<double> runEmbedding(Float32List input, {required int side}) {
    if (_closed) throw StateError('OrtSession is closed');
    return using((Arena arena) {
      final memPP = arena<Pointer<Void>>();
      _api.check(_api.createCpuMemoryInfo(0, 0, memPP));
      final memInfo = memPP.value;

      final dataPtr = arena<Float>(input.length);
      dataPtr.asTypedList(input.length).setAll(0, input);

      final shape = arena<Int64>(4);
      shape[0] = 1;
      shape[1] = 3;
      shape[2] = side;
      shape[3] = side;

      final inputValPP = arena<Pointer<Void>>();
      _api.check(
        _api.createTensorWithData(
          memInfo,
          dataPtr.cast<Uint8>(),
          input.length * 4, // float32 = 4 bytes each
          shape,
          4,
          _onnxTensorElemFloat,
          inputValPP,
        ),
      );
      final inputVal = inputValPP.value;

      final outCountP = arena<Size>();
      _api.check(_api.sessionGetOutputCount(_session, outCountP));
      final outCount = outCountP.value;
      final outNames = <String>[
        for (var i = 0; i < outCount; i++)
          _api.outputName(_session, i, _allocator(arena), arena),
      ];

      final inNamesArr = arena<Pointer<Utf8>>(1);
      inNamesArr[0] = _cstr(_inputName, arena);
      final inValsArr = arena<Pointer<Void>>(1);
      inValsArr[0] = inputVal;
      final outNamesArr = arena<Pointer<Utf8>>(outCount);
      for (var i = 0; i < outCount; i++) {
        outNamesArr[i] = _cstr(outNames[i], arena);
      }
      final outValsArr = arena<Pointer<Void>>(outCount);
      for (var i = 0; i < outCount; i++) {
        outValsArr[i] = nullptr;
      }

      _api.check(
        _api.run(
          _session,
          nullptr,
          inNamesArr,
          inValsArr,
          1,
          outNamesArr,
          outCount,
          outValsArr,
        ),
      );

      final result = _api.readFloats(outValsArr[0], arena);
      for (var i = 0; i < outCount; i++) {
        _api.releaseValue(outValsArr[i]);
      }
      _api.releaseValue(inputVal);
      _api.releaseMemoryInfo(memInfo);
      return result;
    });
  }

  Pointer<Void> _allocator(Arena arena) {
    final allocPP = arena<Pointer<Void>>();
    _api.check(_api.getAllocatorWithDefaultOptions(allocPP));
    return allocPP.value;
  }

  /// Releases the native session and environment. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _api.releaseSession(_session);
    _api.releaseEnv(_env);
  }
}

/// Builds a null-terminated UTF-8 C string in [arena].
Pointer<Utf8> _cstr(String s, Arena arena) => s.toNativeUtf8(allocator: arena);

// --- The OrtApi function-pointer table, bound by ordinal. ------------------

typedef _StatusFn = Pointer<Void>;

/// Resolves and calls the subset of `OrtApi` functions the detector uses.
class _OrtApi {
  _OrtApi(DynamicLibrary lib) {
    final getApiBase = lib
        .lookupFunction<
          Pointer<Pointer<Void>> Function(),
          Pointer<Pointer<Void>> Function()
        >('OrtGetApiBase');
    final apiBase = getApiBase();
    final getApi = apiBase.value
        .cast<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>>()
        .asFunction<Pointer<Pointer<Void>> Function(int)>();
    // Request API v26 (not the newest): ORT's C API is backward-compatible, so
    // a newer desktop lib (1.27) still serves it, while the latest ONNX Runtime
    // *Android* AAR (1.26) — which doesn't yet offer v27 — also works. The
    // detector only calls 1.0-era functions, whose ordinals are stable, so the
    // older interface request is safe on every platform.
    _api = getApi(26);
  }

  late final Pointer<Pointer<Void>> _api;

  Pointer<Void> _fn(int ordinal) => (_api + ordinal).value;

  /// Throws [OrtException] when [status] is a non-null `OrtStatus`.
  void check(_StatusFn status) {
    if (status == nullptr) return;
    final getMsg = _fn(_oGetErrorMessage)
        .cast<NativeFunction<Pointer<Utf8> Function(Pointer<Void>)>>()
        .asFunction<Pointer<Utf8> Function(Pointer<Void>)>();
    final message = getMsg(status).toDartString();
    _fn(_oReleaseStatus)
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>()(status);
    throw OrtException(message);
  }

  Pointer<Void> createEnv(
    int level,
    Pointer<Utf8> logid,
    Pointer<Pointer<Void>> out,
  ) => _fn(_oCreateEnv)
      .cast<
        NativeFunction<
          Pointer<Void> Function(Int32, Pointer<Utf8>, Pointer<Pointer<Void>>)
        >
      >()
      .asFunction<
        Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Pointer<Void>>)
      >()(level, logid, out);

  Pointer<Void> createSessionOptions(
    Pointer<Pointer<Void>> out,
  ) => _fn(_oCreateSessionOptions)
      .cast<NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>>()
      .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>()(out);

  void setIntraOpNumThreads(Pointer<Void> opts, int n) =>
      _fn(_oSetIntraOpNumThreads)
          .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Int32)>>()
          .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(opts, n);

  void setSessionGraphOptimizationLevel(Pointer<Void> opts, int level) =>
      _fn(_oSetSessionGraphOptimizationLevel)
          .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Int32)>>()
          .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(
        opts,
        level,
      );

  void setSessionExecutionMode(Pointer<Void> opts, int mode) =>
      _fn(_oSetSessionExecutionMode)
          .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Int32)>>()
          .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(opts, mode);

  Pointer<Void> createSession(
    Pointer<Void> env,
    Pointer<Utf8> modelPath,
    Pointer<Void> opts,
    Pointer<Pointer<Void>> out,
  ) => _fn(_oCreateSession)
      .cast<
        NativeFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Void>,
            Pointer<Pointer<Void>>,
          )
        >
      >()
      .asFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        )
      >()(env, modelPath, opts, out);

  Pointer<Void> getAllocatorWithDefaultOptions(
    Pointer<Pointer<Void>> out,
  ) => _fn(_oGetAllocatorWithDefaultOptions)
      .cast<NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>>()
      .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>()(out);

  Pointer<Void> createCpuMemoryInfo(
    int allocType,
    int memType,
    Pointer<Pointer<Void>> out,
  ) => _fn(_oCreateCpuMemoryInfo)
      .cast<
        NativeFunction<
          Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>)
        >
      >()
      .asFunction<
        Pointer<Void> Function(int, int, Pointer<Pointer<Void>>)
      >()(allocType, memType, out);

  Pointer<Void> createTensorWithData(
    Pointer<Void> memInfo,
    Pointer<Uint8> data,
    int dataLen,
    Pointer<Int64> shape,
    int shapeLen,
    int elemType,
    Pointer<Pointer<Void>> out,
  ) => _fn(_oCreateTensorWithDataAsOrtValue)
      .cast<
        NativeFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Uint8>,
            Size,
            Pointer<Int64>,
            Size,
            Int32,
            Pointer<Pointer<Void>>,
          )
        >
      >()
      .asFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Uint8>,
          int,
          Pointer<Int64>,
          int,
          int,
          Pointer<Pointer<Void>>,
        )
      >()(memInfo, data, dataLen, shape, shapeLen, elemType, out);

  Pointer<Void> sessionGetOutputCount(
    Pointer<Void> session,
    Pointer<Size> out,
  ) =>
      _fn(_oSessionGetOutputCount)
          .cast<
            NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>
          >()
          .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>()(
        session,
        out,
      );

  Pointer<Void> run(
    Pointer<Void> session,
    Pointer<Void> runOptions,
    Pointer<Pointer<Utf8>> inputNames,
    Pointer<Pointer<Void>> inputs,
    int inputLen,
    Pointer<Pointer<Utf8>> outputNames,
    int outputLen,
    Pointer<Pointer<Void>> outputs,
  ) =>
      _fn(_oRun)
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Pointer<Utf8>>,
                Pointer<Pointer<Void>>,
                Size,
                Pointer<Pointer<Utf8>>,
                Size,
                Pointer<Pointer<Void>>,
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Void>>,
              int,
              Pointer<Pointer<Utf8>>,
              int,
              Pointer<Pointer<Void>>,
            )
          >()(
        session,
        runOptions,
        inputNames,
        inputs,
        inputLen,
        outputNames,
        outputLen,
        outputs,
      );

  /// The session's single input name (index 0), copied to Dart and freed.
  String inputName(Pointer<Void> session, Pointer<Void> alloc, Arena arena) =>
      _ioName(_oSessionGetInputName, session, 0, alloc, arena);

  /// The session's output name at [index], copied to Dart and freed.
  String outputName(
    Pointer<Void> session,
    int index,
    Pointer<Void> alloc,
    Arena arena,
  ) => _ioName(_oSessionGetOutputName, session, index, alloc, arena);

  String _ioName(
    int ordinal,
    Pointer<Void> session,
    int index,
    Pointer<Void> alloc,
    Arena arena,
  ) {
    final namePP = arena<Pointer<Utf8>>();
    check(
      _fn(ordinal)
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Size,
                Pointer<Void>,
                Pointer<Pointer<Utf8>>,
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              int,
              Pointer<Void>,
              Pointer<Pointer<Utf8>>,
            )
          >()(session, index, alloc, namePP),
    );
    final name = namePP.value.toDartString();
    _fn(_oAllocatorFree)
        .cast<
          NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>
        >()
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>()(
      alloc,
      namePP.value.cast(),
    );
    return name;
  }

  /// Reads a float tensor [value]'s contents into a Dart list.
  List<double> readFloats(Pointer<Void> value, Arena arena) {
    final tsPP = arena<Pointer<Void>>();
    check(
      _fn(_oGetTensorTypeAndShape)
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >()(value, tsPP),
    );
    final ts = tsPP.value;
    final countP = arena<Size>();
    check(
      _fn(_oGetTensorShapeElementCount)
          .cast<
            NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>
          >()
          .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>()(
        ts,
        countP,
      ),
    );
    final count = countP.value;
    _fn(_oReleaseTensorTypeAndShapeInfo)
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>()(ts);

    final dataPP = arena<Pointer<Void>>();
    check(
      _fn(_oGetTensorMutableData)
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >()(value, dataPP),
    );
    return List<double>.from(dataPP.value.cast<Float>().asTypedList(count));
  }

  void releaseValue(Pointer<Void> value) => _release(_oReleaseValue, value);
  void releaseMemoryInfo(Pointer<Void> info) =>
      _release(_oReleaseMemoryInfo, info);
  void releaseSession(Pointer<Void> session) =>
      _release(_oReleaseSession, session);
  void releaseSessionOptions(Pointer<Void> opts) =>
      _release(_oReleaseSessionOptions, opts);
  void releaseEnv(Pointer<Void> env) => _release(_oReleaseEnv, env);

  void _release(int ordinal, Pointer<Void> handle) => _fn(ordinal)
      .cast<NativeFunction<Void Function(Pointer<Void>)>>()
      .asFunction<void Function(Pointer<Void>)>()(handle);
}
