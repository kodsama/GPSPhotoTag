#!/usr/bin/env bash
#
# Populates app/assets/onnx/ with the ONNX Runtime native library and the
# Apache-2.0 SSD-MobileNet COCO model used by the Tier-2 on-device people/animal
# detector (engine/lib/src/services/people/). Both are bundled into the app at
# `flutter build` time, mirroring tool/fetch-exiftool.sh, and are also consumed
# by the engine's integration test (which loads them via dart:ffi).
#
# Kept out of git (~60MB total) and regenerated here. Run before tests/build;
# CI runs this in the same step it vendors exiftool.
#
# Layout (one ONNX Runtime build per desktop platform; the model is shared):
#   app/assets/onnx/osx-arm64/libonnxruntime.dylib
#   app/assets/onnx/osx-x64/libonnxruntime.dylib
#   app/assets/onnx/linux-x64/libonnxruntime.so
#   app/assets/onnx/win-x64/onnxruntime.dll
#   app/assets/onnx/ssd_mobilenet_v1_12.onnx   (Tier-2 people/animal detector)
#   app/assets/onnx/mobilenetv2-12.onnx        (Smart duplicate-metric embedder)
#
# At runtime the host platform's library + the shared model resolve from one
# bundle dir (see app/lib/src/engine/onnx_bundle_dir.dart and the engine's
# resolveOnnxBundle). $STUNDA_ONNX_BUNDLE_DIR overrides the dir for the engine
# test so it can point at app/assets/onnx/<thisPlatform>/ with the model copied
# alongside.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/app/assets/onnx"

ORT_VER="${ORT_VERSION:-1.27.0}"
# Mobile builds get the ONNX Runtime library from the Android AAR / iOS CocoaPod,
# not a bundled desktop dylib: --models-only fetches just the shared .onnx models
# (and creates the empty platform dirs the pubspec declares), keeping the desktop
# libraries (~15MB each) out of the mobile app.
MODELS_ONLY="${STUNDA_ONNX_MODELS_ONLY:-}"
for arg in "$@"; do
  [ "$arg" = "--models-only" ] && MODELS_ONLY=1
done
MODEL_FILE="ssd_mobilenet_v1_12.onnx"
MODEL_URL="https://huggingface.co/onnxmodelzoo/ssd_mobilenet_v1_12/resolve/main/${MODEL_FILE}"
# Apache-2.0 MobileNetV2-12 (ONNX Model Zoo): the image-embedding model behind
# the Smart duplicate-finder metric. Shared across platforms like the detector.
EMBED_FILE="mobilenetv2-12.onnx"
EMBED_URL="https://huggingface.co/onnxmodelzoo/mobilenetv2-12/resolve/main/${EMBED_FILE}"

mkdir -p "$DEST"

# Flutter's `assets:` declares all four platform subdirs (app/pubspec.yaml), and
# a declared asset directory must exist at build time even when empty (only the
# host platform's library is fetched here). Create them all up front.
for plat in osx-arm64 osx-x64 linux-x64 win-x64; do
  mkdir -p "$DEST/$plat"
done

# --- The models (shared across platforms; both Apache-2.0). ----------------
if [ ! -s "$DEST/$MODEL_FILE" ]; then
  echo "downloading $MODEL_FILE"
  curl -fsSL "$MODEL_URL" -o "$DEST/$MODEL_FILE"
fi
echo "model: $DEST/$MODEL_FILE ($(wc -c < "$DEST/$MODEL_FILE") bytes)"

if [ ! -s "$DEST/$EMBED_FILE" ]; then
  echo "downloading $EMBED_FILE"
  curl -fsSL "$EMBED_URL" -o "$DEST/$EMBED_FILE"
fi
echo "embed model: $DEST/$EMBED_FILE ($(wc -c < "$DEST/$EMBED_FILE") bytes)"

# Mobile: models + empty platform dirs are enough; skip the desktop ORT libs.
# Clear any previously-vendored desktop libraries so a re-run (or a dirty tree)
# never leaves a dylib/so/dll behind to be bundled.
if [ -n "$MODELS_ONLY" ]; then
  for plat in osx-arm64 osx-x64 linux-x64 win-x64; do
    rm -rf "${DEST:?}/$plat"
    mkdir -p "$DEST/$plat"
  done
  echo "models-only (mobile build): skipping desktop ONNX Runtime libraries"
  exit 0
fi

# --- ONNX Runtime native library, per platform. ----------------------------
# $1 = ORT release suffix (e.g. osx-arm64), $2 = our platform dir (osx-arm64),
# $3 = the dylib/so/dll name inside the release, $4 = our target file name,
# $5 = archive extension ("tgz" for macOS/Linux, "zip" for Windows).
fetch_ort() {
  local rel_suffix="$1" plat_dir="$2" libname="$3" target="$4" ext="${5:-tgz}"
  local outdir="$DEST/$plat_dir"
  if [ -s "$outdir/$target" ]; then
    echo "ort $plat_dir already present"
    return 0
  fi
  mkdir -p "$outdir"
  local tmp base url archive
  tmp="$(mktemp -d)"
  base="onnxruntime-${rel_suffix}-${ORT_VER}"
  archive="$tmp/ort.$ext"
  url="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VER}/${base}.${ext}"
  echo "downloading $url"
  if ! curl -fsSL "$url" -o "$archive"; then
    echo "WARN: could not download ORT for $plat_dir ($url); skipping" >&2
    rm -rf "$tmp"
    return 0
  fi
  # The Windows distribution is a .zip; macOS/Linux are .tgz. Use unzip for zip
  # (more reliable than tar's libarchive zip support across runners).
  if [ "$ext" = "zip" ]; then
    unzip -q -o "$archive" -d "$tmp"
  else
    tar xzf "$archive" -C "$tmp"
  fi
  local found
  found="$(find "$tmp" -name "$libname" -type f | head -1)"
  if [ -z "$found" ]; then
    echo "WARN: $libname not found in $base; skipping $plat_dir" >&2
    rm -rf "$tmp"
    return 0
  fi
  cp "$found" "$outdir/$target"
  echo "ort $plat_dir: $outdir/$target ($(wc -c < "$outdir/$target") bytes)"
  rm -rf "$tmp"
}

# Desktop targets. The Windows zip uses .zip not .tgz; handled by tar on most
# systems via libarchive, but we fetch only what each CI host can use plus the
# host's own. Best-effort: a failed download warns and is skipped (the detector
# falls back to Tier-1 on platforms without a bundled lib).
case "$(uname -s)" in
  Darwin)
    if [ "$(uname -m)" = "arm64" ]; then
      fetch_ort "osx-arm64" "osx-arm64" "libonnxruntime.${ORT_VER}.dylib" "libonnxruntime.dylib"
    else
      fetch_ort "osx-x86_64" "osx-x64" "libonnxruntime.${ORT_VER}.dylib" "libonnxruntime.dylib"
    fi
    ;;
  Linux)
    fetch_ort "linux-x64" "linux-x64" "libonnxruntime.so.${ORT_VER}" "libonnxruntime.so"
    ;;
  # Windows CI runs this under Git Bash, where uname -s is MINGW*/MSYS*/CYGWIN*.
  # The Windows ORT release zip lays the dll at runtime/onnxruntime.dll; `tar`
  # on the runners handles .zip via libarchive (fetch_ort calls tar xzf).
  MINGW*|MSYS*|CYGWIN*)
    fetch_ort "win-x64" "win-x64" "onnxruntime.dll" "onnxruntime.dll" "zip"
    ;;
  *)
    echo "unsupported host for ORT fetch: $(uname -s); model is present, lib skipped" >&2
    ;;
esac

# Copy the model next to the host platform's library so a single bundle dir is
# self-contained for the engine integration test.
HOST_DIR=""
case "$(uname -s)" in
  Darwin) HOST_DIR="$([ "$(uname -m)" = arm64 ] && echo osx-arm64 || echo osx-x64)" ;;
  Linux)  HOST_DIR="linux-x64" ;;
esac
if [ -n "$HOST_DIR" ] && [ -d "$DEST/$HOST_DIR" ]; then
  cp -f "$DEST/$MODEL_FILE" "$DEST/$HOST_DIR/$MODEL_FILE"
  cp -f "$DEST/$EMBED_FILE" "$DEST/$HOST_DIR/$EMBED_FILE"
  echo "host bundle dir: $DEST/$HOST_DIR"
fi
