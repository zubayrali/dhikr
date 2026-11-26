#!/bin/bash
# Full-corpus validation: every case in the manifest through the real pipeline.
cd "$(dirname "$0")/../.."
BIN=.build/evalharness/pipeline_eval
pass=0; fail=0
for case in "subhanallah-x10 subhanallah 10" "alhamdulillah-x10 alhamdulillah 10" "allahuakbar-x10 allahuakbar 10" "subhanallah-fast-x15 subhanallah 15" "negative-news subhanallah 0" "istighfar-x10 istighfar 10" "salawat-x10 salawat 10"; do
  set -- $case
  result=$($BIN "eval/corpus/out/$1.wav" "$2" "$3" 2>/dev/null | grep -oE "(PASS|FAIL)$")
  echo "$1: $result"
  [ "$result" = "PASS" ] && pass=$((pass+1)) || fail=$((fail+1))
done
# Permanent low-volume regression: the original istighfar corpus attenuated to
# -54dB (RMS ~0.00025). Energy VAD cannot segment it at all; Silero+AGC must
# still recover all 10. Generated under .build so the source corpus stays clean.
quiet=.build/evalharness/istighfar-x10-minus54db.wav
python3 - <<'PYGEN'
import array
import wave
from pathlib import Path

src = Path('eval/corpus/out/istighfar-x10.wav')
dst = Path('.build/evalharness/istighfar-x10-minus54db.wav')
dst.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(src), 'rb') as r:
    params = r.getparams()
    samples = array.array('h')
    samples.frombytes(r.readframes(r.getnframes()))
scaled = array.array('h', (max(-32768, min(32767, round(x * 0.002))) for x in samples))
with wave.open(str(dst), 'wb') as w:
    w.setparams(params)
    w.writeframes(scaled.tobytes())
PYGEN
result=$($BIN "$quiet" istighfar 10 2>/dev/null | grep -oE "(PASS|FAIL)$")
echo "istighfar-x10-minus54db: $result"
[ "$result" = "PASS" ] && pass=$((pass+1)) || fail=$((fail+1))
echo "$pass passed, $fail failed"
