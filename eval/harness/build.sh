#!/bin/bash
# Build the pipeline eval harness: core + transcriber compiled as one module.
cd "$(dirname "$0")/../.."
mkdir -p .build/evalharness
for f in Sources/DhikrCore/*.swift Sources/DhikrApp/NawahCoreMLTranscriber.swift eval/harness/pipeline_eval.swift; do
  sed 's/^import DhikrCore$//' "$f" > ".build/evalharness/$(basename $f)"
done
cd .build/evalharness && swiftc -O -o pipeline_eval *.swift -framework CoreML -framework Accelerate -framework AVFoundation
