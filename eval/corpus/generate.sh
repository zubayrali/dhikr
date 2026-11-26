#!/bin/bash
# Generate synthetic Arabic tasbih test audio using macOS TTS (Majed, ar_001).
# TTS is cleaner than real recitation — this is the conversion smoke-test corpus,
# not the accuracy corpus. Output: 16kHz mono WAV, matching the inference pipeline.
set -e
cd "$(dirname "$0")"
mkdir -p raw out

gen() { # name, text, rate
  local name="$1" text="$2" rate="${3:-160}"
  say -v Majed -r "$rate" -o "raw/$name.aiff" "$text" 2>/dev/null
  afconvert -f WAVE -d LEI16@16000 -c 1 "raw/$name.aiff" "out/$name.wav"
  echo "out/$name.wav: $(python3 -c "import wave; w=wave.open('out/$name.wav'); print(f'{w.getnframes()/16000:.1f}s')")"
}

rep() { # word, n, separator
  python3 -c "print(' $3 '.join(['$1']*$2))"
}

# slow clear recitation with pauses (comma = natural TTS pause)
gen subhanallah-x10 "$(rep 'سبحان الله' 10 '،')"
gen alhamdulillah-x10 "$(rep 'الحمد لله' 10 '،')"
gen allahuakbar-x10 "$(rep 'الله أكبر' 10 '،')"
# mixed tasbih sequence: 5x each
gen tasbih-mixed-x5 "$(rep 'سبحان الله' 5 '،')، $(rep 'الحمد لله' 5 '،')، $(rep 'الله أكبر' 5 '،')"
# fast chain, fewer pauses
gen subhanallah-fast-x15 "$(rep 'سبحان الله' 15 ' ')" 200
# negative control: unrelated Arabic speech
gen negative-news "أعلنت وزارة الخارجية اليوم عن اجتماع جديد لمناقشة التطورات الاقتصادية في المنطقة"
# istighfar and salawat
gen istighfar-x10 "$(rep 'أستغفر الله' 10 '،')"
gen salawat-x10 "$(rep 'اللهم صل على محمد' 10 '،')"
