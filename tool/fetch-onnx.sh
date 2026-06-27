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
#   app/assets/onnx/ssd_mobilenet_v1_12.onnx
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
MODEL_FILE="ssd_mobilenet_v1_12.onnx"
MODEL_URL="https://huggingface.co/onnxmodelzoo/ssd_mobilenet_v1_12/resolve/main/${MODEL_FILE}"

mkdir -p "$DEST"

# Flutter's `assets:` declares all four platform subdirs (app/pubspec.yaml), and
# a declared asset directory must exist at build time even when empty (only the
# host platform's library is fetched here). Create them all up front.
for plat in osx-arm64 osx-x64 linux-x64 win-x64; do
  mkdir -p "$DEST/$plat"
done

# --- The model (shared across platforms; Apache-2.0). ----------------------
if [ ! -s "$DEST/$MODEL_FILE" ]; then
  echo "downloading $MODEL_FILE"
  curl -fsSL "$MODEL_URL" -o "$DEST/$MODEL_FILE"
fi
echo "model: $DEST/$MODEL_FILE ($(wc -c < "$DEST/$MODEL_FILE") bytes)"

# --- ONNX Runtime native library, per platform. ----------------------------
# $1 = ORT release suffix (e.g. osx-arm64), $2 = our platform dir (osx-arm64),
# $3 = the dylib/so/dll name inside the release, $4 = our target file name.
fetch_ort() {
  local rel_suffix="$1" plat_dir="$2" libname="$3" target="$4"
  local outdir="$DEST/$plat_dir"
  if [ -s "$outdir/$target" ]; then
    echo "ort $plat_dir already present"
    return 0
  fi
  mkdir -p "$outdir"
  local tmp tgz base url
  tmp="$(mktemp -d)"
  base="onnxruntime-${rel_suffix}-${ORT_VER}"
  url="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VER}/${base}.tgz"
  echo "downloading $url"
  if ! curl -fsSL "$url" -o "$tmp/ort.tgz"; then
    echo "WARN: could not download ORT for $plat_dir ($url); skipping" >&2
    rm -rf "$tmp"
    return 0
  fi
  tar xzf "$tmp/ort.tgz" -C "$tmp"
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
  echo "host bundle dir: $DEST/$HOST_DIR"
fi
