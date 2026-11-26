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
echo "$pass passed, $fail failed"
