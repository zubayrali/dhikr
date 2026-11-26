#!/bin/bash
# Convert + compile Silero VAD. Reuses the proven nawah conversion venv when present.
set -e
cd "$(dirname "$0")"
PY="../nawah-coreml/.venv/bin/python"
if [ ! -x "$PY" ]; then PY=python3; fi
"$PY" scripts/convert_silero.py
mkdir -p build/compiled
rm -rf build/compiled/SileroVAD.mlmodelc
xcrun coremlcompiler compile build/SileroVAD.mlpackage build/compiled
echo "built build/compiled/SileroVAD.mlmodelc"
