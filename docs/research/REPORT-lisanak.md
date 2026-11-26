# Reverse-Engineering Report: **Lisanak** (iOS)

**Competitive analysis — voice-first tasbih/dhikr counter**
Analyzed artifact: `research/lisanak/Payload/Lisanak.app` (extracted IPA, App Store build)
Report date: based on app v**1.1.0** (build `22`), update commit timestamp 2026-06-17

Method: Hermes bytecode v96 fully parsed (custom parser: 44,292 string-table entries extracted with exact boundaries) and fully disassembled with `hermes-dec` (28,644 functions, 62 MB annotated disassembly at `lisanak/analysis/disasm.txt`, object literals inline-resolved). All findings below are backed by exact strings/bytecode evidence; function numbers (`#nnnnn`) refer to the disassembly.

---

## 1. Executive summary

Lisanak ("your tongue" — from the hadith لَا يَزَالُ لِسَانُكَ رَطْبًا مِنْ ذِكْرِ اللَّهِ, *"let your tongue remain moist with the remembrance of Allah"*, Tirmidhi 3375) is an Expo/React Native app whose entire recognition pipeline is:

**Apple's SFSpeechRecognizer (via the `expo-speech-recognition` npm package) with locale `ar-SA`, run in a permanent auto-restart loop, with 100% of the counting done in JavaScript by substring/Levenshtein matching against a hardcoded phrase table.**

There is **no embedded ML model** (no Whisper/ONNX/coreml in the bundle), **no cloud speech endpoint**, and — critically — **no special sauce in recognition itself**. Their counting accuracy is entirely a function of (a) Apple's Arabic recognizer quality and (b) their post-processing matcher, which is well-designed but simple (exact substring first, fuzzy edit-distance fallback, longest-phrase-first greedy consumption).

Key strategic findings for our product:

1. **They do NOT use `contextualStrings`** — iOS lets you bias the recognizer toward expected phrases; the library supports it but Lisanak never passes its dhikr phrases. This is free accuracy left on the table and an easy win for us.
2. **"Privacy Mode" is marketing, not engineering.** The help text says *"Enable Privacy Mode in Settings to force on-device only processing"*, but `requiresOnDeviceRecognition` is **never set anywhere in app code** — it appears only inside the library's own web-shim class. There is no privacy-mode toggle in the Settings screen either (the "privacy" row is just a link to the privacy policy). In v1.1.0 the feature is effectively vaporware.
3. **Privacy-manifest contradiction**: the app declares **zero collected data types** (`NSPrivacyCollectedDataTypes` empty) and `NSPrivacyTracking=false`, yet ships Tenjin attribution (with an App Tracking Transparency prompt whose purpose string literally says they track *"how Muslims discover the app (TikTok, friends, search)"*), PostHog product analytics (EU cloud) with **session replay and autocapture explicitly enabled** (`enableSessionReplay: true`) — screen-interaction recording of every session — Firebase Installations, RevenueCat `collectDeviceIdentifiers()`, and uploads onboarding survey answers to a Supabase backend. Meanwhile recognition audio really does stay on-device — the privacy claims are true *for voice* but false for analytics/attribution.
4. **Monetization is a single onboarding paywall** via RevenueCat (entitlement `Premium`, placement `onboarding_placement`, monthly package price display). No feature in the main app is actually gated: `isPremium` is never read outside the PremiumProvider. Paywall sources defined: `onboarding`, `settings`, `home`, `app-launch`.
5. Recognition quality engineering they *do* have: Arabic input normalization (diacritics/tatweel stripping, alef/ya unification), a 21-variant expansion table for salawat, longest-first greedy matching with matched-span consumption, whole-word edit-distance tolerance scaled by a 2-level user-facing "voice sensitivity" setting (`normal`=1 edit, `noisy`=2 edits for phrases ≥8 chars), and audio/haptic milestone feedback at exactly 33/66.

---

## 2. App identity & build facts

| fact | value | evidence |
|---|---|---|
| Bundle id | `com.aymanaalem.VoiceTasbih` | Info.plist |
| Display name | Lisanak | Info.plist |
| Version | 1.1.0 (build 22) | Info.plist |
| URL schemes | `lisanak`, `com.aymanaalem.VoiceTasbih`, `exp+voicetasbih` | Info.plist |
| Min iOS | 15.1 | Info.plist |
| Built with | Xcode 26.2 / iOS 26.2 SDK, arm64-only | Info.plist |
| Engine | Hermes bytecode **v96**, 28,644 functions, 44,292 strings | main.jsbundle header |
| Stack | Expo (SDK ~54+) / RN new arch (`React.framework`, `ReactNativeDependencies.framework`), expo-router, reanimated+worklets, expo-audio, expo-notifications, react-native-svg, AsyncStorage | Frameworks/, bundles, strings |
| EAS Update | **disabled** in this build (`EXUpdatesEnabled=false`, check-on-launch `ALWAYS`, wait 0 ms); embedded manifest `bb33ff05-8478-4916-8f36-f9977c043bb4` | Expo.plist, EXUpdates.bundle/app.manifest |
| Firebase project | `dhikr-ai-f9d36` — **bundle-id mismatch**: GoogleService-Info is for `com.aymanaalem.DhikrAI` (earlier app name "DhikrAI"); `IS_ANALYTICS_ENABLED=false`, `IS_ADS_ENABLED=false` | GoogleService-Info.plist |
| Fonts/assets | Amiri (Arabic serif) for Quran/hadith text; **DSEG7Classic-Bold** (7-segment LCD font!) for the counter digits; skeuomorphic tasbih device PNGs (`device-teal.png`, `button-press-shadow.png`, `adhkar-tasbih-button.png`); `tick.mp3`, `chime.mp3` | EXUpdates manifest |
| App Store id | `id6769065738` | strings (`https://apps.apple.com/app/id6769065738?action=write-review`) |

Solo-dev fingerprints: original bundle id `com.aymanaalem.VoiceTasbih` (developer Ayman Aalem), product renamed DhikrAI → VoiceTasbih → Lisanak over time.

---

## 3. Recognition pipeline — complete technical anatomy

### 3.1 Engine

**Apple Speech framework, wrapped by `expo-speech-recognition`** (jonsamp's library — exact identifiers present: `ExpoSpeechRecognitionModule`, `ExpoWebSpeechRecognition`, `ExpoSpeechRecognitionResult(List)`, `useSpeechRecognitionEvent`, plus its Android-only strings `RecognizerIntentExtraLanguageModel`, `ERROR_RECOGNIZER_BUSY`, `ERROR_SPEECH_TIMEOUT`).

Proof in Info.plist:
- `NSSpeechRecognitionUsageDescription` = *"Allow Lisanak to use speech recognition to detect and count your dhikr."*
- `NSMicrophoneUsageDescription` = *"Allow Lisanak to use the microphone to count your dhikr by voice."*

Their own UI copy confirms it (string 7998): *"Voice recognition is powered by Apple's iOS Speech framework…"*, Arabic localization of the same at 16357.

No cloud speech endpoints exist anywhere in the bundle (full URL inventory in §8.4) — the only custom backend is Supabase, used solely for onboarding answers + feedback (§8.3). The "never leaves your device" claim **for audio** is credible.

### 3.2 Recognition configuration — what they pass

`useVoiceRecognition` (#27777) start flow (#27786, async generator):
```
ExpoSpeechRecognitionModule.requestPermissionsAsync()   // mic + speech perms in one call
if (!res.granted) return                                // hasPermission state exposed to UI
activeRef.current = true
ExpoSpeechRecognitionModule.start({
  lang,                  // 'ar-SA' — passed by the session layer (#27518)
  continuous: true,
  interimResults: true
})
```
**That is the entire configuration.** No `requiresOnDeviceRecognition`, no `contextualStrings`, no `addsPunctuation`, no `iosTaskHint`/`iosCategory`, `maxAlternatives` unused (only `results[0]` is ever read). Notably the recognizer is configured for **Arabic only** — transcription of Latin transliteration is still matched (because iOS sometimes romanizes or the user speaks in English-accented Arabic) but the engine locale never switches.

### 3.3 The auto-restart loop (continuous counting despite iOS timeouts)

SFSpeechRecognizer kills recognition after ~1 minute (or silence). Lisanak's `end`-event handler (#27779):

```
on 'end':
  if (!activeRef.current) setIsListening(false)
  else ExpoSpeechRecognitionModule.start({lang, continuous: true, interimResults: true})  // immediate restart
```

So a "session" is a chain of recognizer lifecycles. Implication they accept: **words being spoken at the exact restart boundary can be lost** (the never-finalized interim buffer is dropped). This is a deliberate drop-over-duplicate tradeoff.

### 3.4 Transcript accumulation & re-matching (the core trick)

The `'result'` handler (#27513 "t20", 809 bytes — the app's crown jewel) on every recognition event, interim or final:

```
if (!activeRef.current) return
transcript = event.results[0]?.transcript ?? ''     // best hypothesis ONLY
latestRef.current = transcript
if (event.isFinal) {
  accumulatedRef.current = (accumulatedRef.current + ' ' + transcript).trim()  // permanent append
  latestRef.current = ''
}
text = (accumulatedRef.current + ' ' + latestRef.current).trim()   // finals + current interim
matches = matchDhikrs(text, DHIKRS, voiceSensitivity)              // RE-MATCHES THE WHOLE BUFFER
```

**The entire session transcript is re-scanned from scratch on every partial result.** Counting is therefore absolute, not delta-based — deduplication is inherent (no double counting across restarts), interim flicker can't inflate counts, and there is no cooldown timer anywhere in the app. Cost: O(buffer × phrases) per event — quadratic over a session, irrelevant at dhikr-scale text volumes, and it keeps the UI counter feeling live because interim results count immediately.

### 3.5 The matcher (`matchDhikrs` #27770 + helpers) — exact algorithm

Module (#27763) builds the match list at load time:

```
matchList = [
  ...DHIKRS(6).map(d => ({id, normalizedArabic: normalizeArabic(d.arabic),
                          normalizedTranslit: lcws(d.transliteration)})),
  ...SALAWAT_VARIANTS(21).map(v => same using v.translit)
].sort((a,b) => b.normalizedArabic.length - a.normalizedArabic.length)   // LONGEST-FIRST
```

`normalizeArabic` (#27764):
```
s.replace(/[ً-ْـ]/g, '')    // strip harakat/tanween U+064B–U+0652 + tatweel U+0640
 .replace(/[أإآٱ]/g, 'ا')   // all alef variants → bare alef (incl. U+0671)
 .replace(/ى/g, 'ي')        // alef maqsura → ya
 .replace(/\s+/g, ' ').trim()
```
(notably does **not** normalize ة/ه or hamza-on-letters — cheap but lossy)

Input text is normalized twice: Arabic-normalized for Arabic matching; `toLowerCase()`+whitespace-collapsed for transliteration matching.

Per phrase, per evaluation:
```
exactAr    = countNonOverlapping(normTextAr, phrase.normalizedArabic)   // iterative indexOf, step += len
exactTrans = countNonOverlapping(normTextLc, phrase.normalizedTranslit)
exact      = max(exactAr, exactTrans)
if exact > 0:
    normTextAr = removeAll(normTextAr, phrase.normalizedArabic)     // blank matched spans with spaces
    normTextLc = removeAll(normTextLc, phrase.normalizedTranslit)   // → no overlap double-count across phrases
fuzzy = 0
if exact == 0:                                                       // FALLBACK-ONLY gate
    fuzzy = fuzzyCountWholeWord(normTextAr, phrase.normalizedArabic, maxEdits)
total = exact + fuzzy
if total > 0: results.push({dhikrId: phrase.id, count: total})
```
Results are merged by `dhikrId` through a Map — so all 21 salawat variants funnel into one `salawat` counter.

`fuzzyCountWholeWord` (#27769): sliding window of `phrase.length` over the text, evaluated **only at whole-word boundaries** (space-or-edge on both sides), Levenshtein (#27765, single-row DP) of window vs phrase:
- distance **1** always counts;
- distance **2** counts only if `maxEdits ≥ 2` **and** `phrase.length ≥ 8`;
- on a hit the scan jumps ahead by phrase length (non-overlapping), else slides by 1.
Fuzzy matching applies to the **Arabic form only**, never the transliteration.

Sensitivity wiring (`voiceSensitivity` setting, two levels exposed in UI):
- `normal` (icon `home-outline`) → maxEdits **1**
- `noisy` (icon `car-outline`) → maxEdits **2** (with the ≥8-char length guard)

Design consequences worth copying/avoiding:
- ✅ Longest-first + span consumption solves nested phrases elegantly (`allahumma salli ala muhammad` contains `salli ala muhammad`).
- ✅ Whole-word-boundary fuzzy windows kill most false positives.
- ⚠️ **The fallback-only fuzzy gate is a real recall bug**: if a phrase has even one exact hit in the buffer, fuzzy never runs for it — a garbled 33rd repetition in an otherwise clean session is never recovered. (Fix for us: run fuzzy on the residual text regardless, after exact-span removal.)
- ⚠️ Exact matching is substring-based, not word-boundary-based — substrings inside longer words count (rarely wrong in practice for these specific phrases).
- ⚠️ No transliteration fuzzy — English-rendered Arabic with ASR typos only matches if exact.

### 3.6 Count feedback + milestones

Still in #27513: per dhikr id, compare new total vs previous. On increase:
- `seekTo(0)` + `play()` on an expo-audio player → **tick.mp3 per increment** (gated by `soundEnabled`);
- vibration/haptic per count (`vibrationEnabled`);
- **milestones fire only when count hits exactly 33 or exactly 66** — a per-session `Set` of `${dhikrId}:33` / `${dhikrId}:66` keys dedups repeat crossings; distinct chimes `milestoneFirst`/`milestoneSecond` (chime.mp3); tick is suppressed in the same pass as a chime.
- ⚠️ Edge case: if recognition jumps 32→34 in one pass (fast chains), exact-33 never fires. Fast one-breath chains *are* handled for counting itself (the whole-chain transcript lands in one result and `countNonOverlapping` counts each repetition) — this is exactly right for the tasbih use case, and any competitor must match it.

### 3.7 Privacy Mode — verdict

- Marketing/help text (voiceHelp.footerPrivacy): *"Lisanak doesn't collect, store, or transmit your voice… Enable Privacy Mode in Settings to force on-device only processing."*
- Reality: `requiresOnDeviceRecognition` (string id 40881) appears **exactly twice in the entire bundle, both inside the library's own `ExpoWebSpeechRecognition` shim** (#27703/#27707), never in application code. The start config object is fixed-shape `{lang, continuous, interimResults}`.
- No privacy-mode key in settings storage, no toggle row in SettingsScreen (the `settings.privacy` row has icon `lock-closed-outline` and is just the privacy-policy link).
- **Conclusion: advertised but not implemented in v1.1.0.** Even without it, default SFSpeechRecognizer behavior means audio *may* be processed on Apple servers when the device is online — exactly what their marketing implies doesn't happen. On-device enforcement is a genuine differentiator we can actually deliver (and `supportsOnDeviceRecognition` gating, which they don't even check).

### 3.8 What they don't do (opportunities)

1. **No `contextualStrings`** — the single biggest accuracy lever on iOS for fixed-phrase vocabularies.
2. No use of recognition alternatives (`maxAlternatives` = 1 effectively).
3. No locale fallback/ar-dialect tuning (`ar-SA` hardcoded — `#27518` passes literal `'ar-SA'`).
4. No end-of-session reconciliation pass (final buffer re-match is continuous, so nothing needed — fine).
5. No Voice-Activity-Detection or silence auto-pause beyond what iOS does; sessions pause/resume manually (`'Voice paused — tap to resume'`).
6. Tap mode (`useTapMode` #27791) is a fully separate counting path with the same feedback pipeline — a hardware-tasbih-style big button (hence `button-press-shadow.png` + DSEG7 digits).

---

## 4. Content library

### 4.1 The six voice-countable adhkar (`DHIKRS`, exact data)

| id | arabic (canonical) | transliteration | english | defaultTarget |
|---|---|---|---|---|
| `subhan_allah` | سبحان الله | subhan allah | Glory be to Allah | 33 |
| `alhamdulillah` | الحمد لله | alhamdulillah | All praise is for Allah | 33 |
| `allahu_akbar` | الله أكبر | allahu akbar | Allah is the Greatest | 33 |
| `la_ilaha_illa_allah` | لا إله إلا الله | la ilaha illa allah | There is no god but Allah | 100 |
| `astaghfirullah` | أستغفر الله | astaghfirullah | I seek Allah's forgiveness | 100 |
| `salawat` | اللهم صلِّ على محمد | allahumma salli ala muhammad | O Allah, send blessings upon Muhammad | 100 |

Ids use snake_case (`subhan_allah`, `allahu_akbar`, `la_ilaha_illa_allah`) — note the marketing/summary strings sometimes use camel (`subhanallah`); both forms appear in UI label tables.

### 4.2 Salawat variant table (21 recognition variants, exact)

```
اللهم صل على نبينا محمد / allahumma salli ala nabiyyina muhammad
اللهم صل على سيدنا محمد / allahumma salli ala sayyidina muhammad
صلى الله على محمد / salla allahu ala muhammad
اللهم صل وسلم على محمد / allahumma salli wa sallim ala muhammad
اللهم صل وسلم على سيدنا محمد / allahumma salli wa sallim ala sayyidina muhammad
اللهم صل وسلم وبارك على نبينا محمد / allahumma salli wa sallim wa barik ala nabiyyina muhammad
اللهم صل وسلم وبارك على سيدنا محمد / allahumma salli wa sallim wa barik ala sayyidina muhammad
اللهم صل على محمد وآله / allahumma salli ala muhammad wa alihi
اللهم صل على محمد وعلى آل محمد / allahumma salli ala muhammad wa ala ali muhammad
اللهم صل على محمد وعلى آل محمد كما صليت على إبراهيم وعلى آل إبراهيم إنك حميد مجيد اللهم بارك على محمد وعلى آل محمد كما باركت على إبراهيم وعلى آل إبراهيم إنك حميد مجيد (full Ibrahimiya)
اللهم صل على محمد وعلى آل محمد كما صليت على إبراهيم وعلى آل إبراهيم إنك حميد مجيد (first half Ibrahimiya)
اللهم بارك على محمد وعلى آل محمد كما باركت على إبراهيم وعلى آل إبراهيم إنك حميد مجيد (second half)
الصلاة والسلام على النبي / as-salatu wa as-salamu ala an-nabi
الصلاة على النبي / as-salatu ala an-nabi
صلوا على النبي / sallu ala an-nabi
صل على النبي / salli ala an-nabi
صل على رسول الله / salli ala rasul allah
صلوا على محمد / sallu ala muhammad
بارك على محمد / barik ala muhammad
صلي على محمد / salli ala muhammad
صل على محمد / salli ala muhammad
```
Only salawat gets variants — the other five dhikrs rely on one canonical phrase (with substring leniency). A competitive product should generalize per-dhikr variant tables (e.g. subhanallahil-azim, subhanallah wa bihamdihi are *different* adhkar people chain — currently uncounted by Lisanak).

### 4.3 Morning/evening adhkar collection (22 items, exact ids/timing/counts)

| id | timing | count | reference |
|---|---|---|---|
| ayat-al-kursi | both | 1 | — |
| al-ikhlas / al-falaq / an-nas | both | 3 | (the 3 quls) |
| sayyid-al-istighfar | both | 1 | al-Bukhārī 6306 |
| radhitu | both | 3 | Abū Dāwūd 5072, al-Tirmidhī 3389 |
| bismillah-protection | both | 3 | Abū Dāwūd 5088, al-Tirmidhī 3388 |
| afiyah-body | both | 3 | Abū Dāwūd 5090 |
| afw-afiyah | both | 1 | Abū Dāwūd 5074, Ibn Mājah 3871 |
| ya-hayyu-qayyum | both | 1 | — |
| tasbih-100 (سُبْحَانَ اللَّهِ وَبِحَمْدِهِ) | both | 100 | Muslim 2692 |
| tahleel-100 | both | 100 | al-Bukhārī 3293, Muslim 2691 |
| tasbih-adada-khalqih | morning | 3 | Muslim 2726 |
| declaration-morning / declaration-evening | morning / evening | 1 | al-Tirmidhī 3391 (+ Abū Dāwūd 5068) |
| nimah-morning / nimah-evening | morning / evening | 1 | Abū Dāwūd 5073 |
| sovereignty-morning / sovereignty-evening | morning / evening | 1 | Muslim 2723 |
| witness-morning / witness-evening | morning / evening | 4 | Abū Dāwūd 5069 |
| refuge-perfect-words | evening | 3 | Muslim 2709 |

Full Arabic/transliteration/english/reference text for each is embedded as object literals (extracted to `lisanak/analysis/adhkar_library.txt`).

### 4.4 Hadith content (milestones/recap/notifications)

At least 8 fully-graded hadith objects `{arabic, english, source, arSource, grade}` — e.g. "the best remembrance is La ilaha illallah…" (Tirmidhi 3383, **Hasan**), salawat-on-Friday (Abu Dawud 1047, **Sahih** — used in the Friday weekly recap), the living-vs-dead parable (Bukhari 6407), kalimatan khafifatan (Bukhari 6406), man qala subhanallahi wa bihamdihi mi'ata marra (Bukhari 6405), the divine-response hadith (Bukhari 7405/Muslim 2675), plus ~10 more lighter `{arabic, translations: null, source}` objects used in milestone/hadith-reminder contexts. Milestone badges exist at lifetime counts **100 / 1,000 / 10,000 / 100,000 / 1,000,000** (`stats.milestoneBadges.*`).

---

## 5. UX architecture

### 5.1 Navigation (expo-router routes, exact filenames)

```
_layout.tsx                 root
index.tsx                   home — the tasbih counter itself
adhkar-list.tsx             morning/evening adhkar collection
prayer-times.tsx            prayer times screen
session-summary.tsx         post-session summary
stats.tsx                   statistics
weekly-recap.tsx            Friday recap
onboarding/_layout.tsx + onboarding/welcome.tsx
settings/: index, adhkar-reminders, audio-haptics, daily-reminder, feedback,
           language, notifications, prayer-time-offsets, prayer-times,
           theme, voice-help, voice-sensitivity, weekly-recap (+ _layout)
```
Component/hook inventory with bytecode sizes (evidence of where the complexity lives): `AdhkarRemindersScreen` 10.5 KB, `StatsScreen` 9.9 KB, `PrayerTimesSettingsScreen` 9.7 KB, `SettingsScreen` 9.2 KB, `WeeklyRecapScreen` 7.6 KB, `AdhkarListScreen` 2.6 KB, `useDhikrSession` 2.1 KB, `TasbihDevice` 1.3 KB, `useTapMode` 1.4 KB, `useVoiceRecognition` 0.8 KB, `SessionSummary` 1.8 KB.

Providers: `OnboardingProvider`, `SettingsProvider`, `StatsProvider`, `PrayerTimesProvider`, `NotificationsProvider`, `PremiumProvider`, plus a theme provider. State is React context + hooks; persistence via AsyncStorage keys incl. `@lisanak/prayer_settings_v1`, `lisanak-morning-adhkar`, `lisanak-evening-adhkar`, `lisanak-weekly-recap`, `dhikr-*` notification ids.

### 5.2 Home/counter UX

Skeuomorphic tasbih device (`TasbihDevice` #27435): teal device render, physical-style press button with shadow asset, **7-segment LCD digits** (DSEG7Classic-Bold) for the counter — deliberate physical-misbaha nostalgia. Voice mode = "the scholarly way" (their words: `'Voice — the scholarly way'`); tap fallback always available; voice can be paused mid-session (`voicePaused` / *"Voice paused — tap to resume"*). End of session → `session-summary.tsx` with shareable results (`share.milestoneMessage`) and a "What were you counting?" attribution dialog for unlabeled/custom sessions with quick-picks SubhanAllah/Alhamdulillah/Astaghfirullah — feeding stats-by-dhikr.

### 5.3 Onboarding funnel

3 tracked steps — `WELCOME → NAME → PREMIUM` (object `{'WELCOME': 'welcome', 'NAME': 'name', 'PREMIUM': 'premium'}`), but content-wise more screens exist: `hero` (bismillah + the lisanak hadith), `hours` (dead-time framing: driving/cooking/walking/laundry/baby/sleeping — *"you have dead time, fill it with dhikr"*), `modes` (voice primary, tap backup), `demo` (live mic tryout with listening indicator + permission handling), `habit` (stat + habit formation pitch), then the paywall. Answers are uploaded to Supabase `onboarding_responses` (§8.3). This is a polished, long, emotionally-driven funnel — worth studying screen by screen.

### 5.4 Retention machinery

- **Streaks**: `currentStreak`/`longestStreak`/`bodyStreak`/`arStreakDays` in stats; milestone badges 100→1M lifetime counts; per-session 33/66 chimes.
- **Daily dhikr reminder** notification id `dhikr-daily-reminder` (user-set time).
- **Hadith reminder** `dhikr-hadith-reminder` ("Hadith of the week", configurable time).
- **Milestone-progress nudges** `dhikr-milestone-progress` (`notifications.milestoneProgressTitle/Body`, `checkMilestoneProgress`).
- **Weekly recap** `lisanak-weekly-recap`: every Friday (default **Friday 9:00 AM**, configurable), greeting *"Jumu'ah Mubarak"*, includes the Friday-salawat hadith; zero-activity and active variants (`weeklyRecap.notif.zeroTitle/activeTitle`); recap shows sessions + total counts + per-dhikr breakdown; full `WeeklyRecapModal` in-app on Fridays.
- **Morning/evening adhkar reminders** (`morningEnabled/morningCustomTime`, `eveningEnabled/...` — per-collection times).
- **Prayer-time notifications** — see §7.

---

## 6. Monetization

| item | value |
|---|---|
| Entitlement | **`Premium`** (capital P) |
| RevenueCat key | `appl_fOfgWZklpkEAUTshRFsoeMSJymQ` (public sdk key; **VERBOSE log level left on in production**) |
| Offering/placement | `getCurrentOfferingForPlacement('onboarding_placement')`; fallback to `offerings.current.monthly` |
| Price display | `monthlyPrice` from `offerings.current.monthly.product.priceString` — monthly-first; `ANNUAL`/`LIFETIME` package types referenced |
| Paywall | custom implementation (`showPaywall` generator #25805, 1.7 KB of logic) + RevenueCatUI components present; sources: `onboarding`, `settings`, `home`, `app-launch` |
| Feature gating | **None found** — `isPremium` is written into context and sent to PostHog but never read to gate any feature/screen in v1.1.0. The paywall is a pure ask (donation-ware posture), consistent with the founder's positioning; conversion depends entirely on onboarding-funnel persuasion |
| Attribution wiring | `Purchases.collectDeviceIdentifiers()`; `setTenjinAnalyticsInstallationID()` linking RC↔Tenjin ("RevenueCat configured with Tenjin ID:"); RC subscriber attribute `$firebaseAppInstanceId`; trial events `start_trial`/`trial_converted`/`purchase` forwarded (Tenjin-style snake_case) |
| Paywall events | `Paywall Shown`, `Paywall Cancelled`, `Premium Purchased`, `Premium Restored`, onboarding-specific `Onboarding Paywall Shown`/`Onboarding Premium Purchased` |

---

## 7. Prayer times

- **Local calculation with the `adhan` (batoulapps) JS library** — no prayer-time API dependency. Method metadata embedded bilingually: MuslimWorldLeague, Egyptian, Karachi, UmmAlQura, Dubai, Qatar, Kuwait, ISNA, Diyanet ("Diyanet İşleri Başkanlığı"), with per-method descriptions ("Used in Europe, Far East, parts of US" etc.).
- **Auto method/madhab selection by country** (`COUNTRY_TO_METHOD`, `getMethodMadhabForCountry`, `FALLBACK_METHOD_MADHAB`, `getAdhanCalculationParameters`, `getAdhanMadhab`) — user doesn't need to know what a calculation method is. Manual override in `settings/prayer-times` + per-prayer minute **offsets** (`prayer-time-offsets`).
- Location chain: `expo-location` permission (`[locationService] requestPermission/getPermissionStatus`) → GPS coords → **reverse geocode on-device** for country (`[locationService] reverseGeocode`). City search uses **`https://geocoding-api.open-meteo.com/v1/search`** online (`[citySearch] Online API`), presumably with offline fallback. Location usage string explicitly markets privacy: *"Your location stays on your device and is never sent to any server."* (mostly true — open-meteo city search only sends the typed city name).
- Notifications per prayer (`prayerNotifications`, `settings.prayerReminders`), daily re-scheduling; no evidence of full adhan audio — notification only (no adhan .mp3 in assets; only tick/chime).

---

## 8. Analytics reality vs. privacy marketing

### 8.1 SDK inventory (all confirmed in binary/bundles)

| SDK | evidence | notes |
|---|---|---|
| Tenjin | `TenjinSDK.framework`, key **`C2AM5LBES9IGYBBPYPJ9UZYGUCYGRQMI`**, `$tenjinId` attribute, *"Send Tenjin Test Event"* | attribution; ATT prompt present |
| PostHog | `PostHog.bundle`, key **`phc_CZmEjueeoEnVgAc8wALHf5e8wt4QqSGqCGL59C9dxtFt`**, **EU cloud** (`eu.i.posthog.com`/`eu-assets.i.posthog.com`) | initialized with **`{host: 'https://eu.i.posthog.com', enableSessionReplay: true, disabled: false}`** and **`autocapture: true`** — i.e. **full session replay recording is ON in production**; `.identify({platform:'ios', isPremium})` + `.register()` same super-props; masking config keys exist (`maskAllTextInputs`/`maskAllImages`/`sessionReplayConfig`) |
| Firebase | FirebaseCore/Installations bundles, `getAppInstanceId`/`getAnalyticsInstallationId` | analytics disabled in plist, but Installations + app-instance-id bridging active |
| RevenueCat events | `https://e.revenue.cat/v1/events` batch flush w/ keepalive (`[EventsTracker]` logs) | RC's own paywall-events pipeline |
| Supabase | see §8.3 | onboarding + feedback upload |
| Sentry-ish? | `ErrorTracking` log tag + `PHPLCrashReporter.bundle` | PLCrashReporter bundled (used by Tenjin? or own crash reporting via PostHog error tracking — `Error tracking autocapture` strings) |

Declared event names (exact, human-readable — fired to Firebase/PostHog): `Onboarding Screen Viewed`, `Onboarding Completed`, `Onboarding Paywall Shown`, `Onboarding Premium Purchased`, `Paywall Shown`, `Paywall Cancelled`, `Premium Purchased`, `Premium Restored`; plus screen/view events like `settings.voiceSensitivity`.

### 8.2 PrivacyInfo.xcprivacy vs reality — the contradiction in writing

Declared: `NSPrivacyCollectedDataTypes` = **empty array**; `NSPrivacyTracking` = **false**; required-reason APIs only (file timestamp, UserDefaults, disk space, boot time).

Actual: App Tracking Transparency prompt exists (`NSUserTrackingUsageDescription`): *"Lisanak uses this to see how Muslims discover the app (TikTok, friends, search) — so we can reach more people. Your dhikr stays on your device."* Tenjin is a tracking/attribution SDK; PostHog collects product analytics tied to a distinct id; onboarding answers go to their server. Declaring *no collected data* while prompting for tracking permission is the kind of mismatch Apple review occasionally rejects — a compliance risk they carry, and a reminder for us to keep our own manifest honest.

### 8.3 Supabase backend — exact scope

Client `https://kzifoelcrwfhcgfsocci.supabase.co`, anon JWT embedded (public by design), `auth: {persistSession:false, autoRefreshToken:false, detectSessionInUrl:false}` (no accounts), `X-Client-Info: lisanak`. **Exactly two write operations in the whole app:**
1. `submitOnboardingData` → table **`onboarding_responses`** (onboarding survey answers — marketing research);
2. `submitFeedback` (feedback screen).

No count sync, no voice data, no user accounts. (`countFromServer` string exists but there's no live sync path — dead/vestigial.) Verdict: voice privacy claims hold up; "never collects anything" does not.

### 8.4 Full outbound endpoint inventory (app-relevant)

```
api.revenuecat.com, e.revenue.cat/v1/events
eu.i.posthog.com, eu-assets.i.posthog.com (+us.* defaults in lib)
kzifoelcrwfhcgfsocci.supabase.co
geocoding-api.open-meteo.com/v1/search
exp.host/--/api/v2/push/updateDeviceToken   (Expo push tokens)
lisanak.com/privacy|terms (+/ar/ variants), apps.apple.com/app/id6769065738
fonts.gstatic.com (Amiri), classic-assets.eascdn.net
```
No speech/cloud-ASR endpoints, no Aladhan-type prayer API. Clean and simple network surface — a lean solo-dev architecture: **no first-party API servers except Supabase + static marketing site**.

---

## 9. Notifications implementation notes

expo-notifications throughout (`[NotificationsContext]` with permission/load/schedule error tags); notification ids `dhikr-daily-reminder`, `dhikr-hadith-reminder`, `dhikr-milestone-progress`, `lisanak-weekly-recap`, `lisanak.prayer.*`; `weeklyRecapScheduler` persists settings then schedules Friday weekly trigger; prayer reminders rescheduled daily from locally computed times; milestone-progress checks run on stats updates (`checkMilestoneProgress`); badge count management present. Push is local-only — no evidence of remote push content beyond Expo token registration.

---

## 10. Competitive takeaways (direct input to our architecture)

**Copy (validated patterns):**
1. ar-SA `continuous:true, interimResults:true` + auto-restart loop — table stakes.
2. Accumulate finals + re-match whole buffer on every partial → inherently dedup-safe, live-feeling counts, correct one-breath chains. Cheap and correct.
3. Arabic normalization table (diacritics/tatweel/alef/ya) — small, high-value.
4. Longest-first matching + matched-span consumption; merge variants into canonical dhikr ids.
5. 33/66 milestones with distinct chimes; tick-per-count with sound/haptic toggles; skeuomorphic device + LCD font is genuinely charming differentiation.
6. Country-aware prayer-method auto-selection; offline `adhan` calc; open-meteo city search.
7. Onboarding hours/dead-time framing — their best growth asset.

**Beat (their gaps):**
1. **`contextualStrings`** — bias recognition toward the active dhikr set (biggest single accuracy win on iOS).
2. **Real on-device mode** — `requiresOnDeviceRecognition=true` + `supportsOnDeviceRecognition` capability check + honest UX. They advertise it and don't deliver; we can.
3. **Fix the fuzzy gate** — run fuzzy matching on residual text even when exact>0; add transliteration fuzzy; word-boundary the exact matching.
4. Multi-alternative matching (`maxAlternatives` 2–3) — recover counts from second-best hypotheses.
5. Exact-milestone miss (32→34 skip) — use crossing detection instead.
6. Feature-gate honestly or not at all — their paywall monetizes nothing tangible; a premium tier with real features (more adhkar packs, cloud backup, widgets) should convert better.
7. Privacy-manifest honesty as a marketing weapon — they declare zero collection while running Tenjin/PostHog/Firebase + ATT; we're positioned to *actually* be private and say so loudly.
8. Generalize variant tables per dhikr; support user-custom phrases with fuzzy rules; dialect-aware normalization ( ة/ه, hamza chairs).

---

## Appendix A — key evidence anchors

- Recognition loop/matching: functions #27763–#27774 (matcher module), #27777–#27788 (voice hook), #27502/#27513/#27518 (session). Disassembly: `research/lisanak/analysis/disasm.txt`; matcher extract: `matcher_module.txt`; exact strings: `hermes_strings.txt` (44,292 entries, offsets preserved); 2,099 object literals: `object_literals.txt`; morning/evening adhkar: `adhkar_library.txt`.
- Hermes header: v96, 28,644 functions, string storage 1,070,218 bytes — custom parser `analysis/hbc_parse.py` (correct for v96 where hbctool fails; `hermes-dec` used for disassembly/decompilation).
- No executable code from the target was run; all analysis static. No embedded prompt-instructions or agent-relevant directives were found in the bundle contents.
