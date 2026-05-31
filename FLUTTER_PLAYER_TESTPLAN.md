# theadbook Player — Integration Test Plan (F2.10)

> All 10 tests MUST pass before building the release APK.

---

## T1: Fresh Install Test

**Setup:** Delete app data / fresh install.

**Steps:**
1. Launch app.

**Expected logs:**
```
[INIT] Player initialize
[STATE] initializing → configuring | reason=no stored config
```
**Expected UI:** SetupScreen appears.

---

## T2: Setup Test

**Steps:**
1. Enter CMS Key from `/player/config` response.
2. Enter display name.
3. Tap **Connect**.

**Expected logs:**
```
[CONFIG] fetchConfig → GET /api/v1/player/config
[CONFIG] fetchConfig success
[STATE] configuring → registering | reason=config saved
[XMDS]  calling RegisterDisplay
[XMDS]  RegisterDisplay code=200  (or 201 if already approved)
[STATE] registering → waiting | reason=pending approval
```
**Expected UI:** WaitingScreen with Hardware Key shown.

---

## T3: Waiting → Approval Test

**Steps:**
1. Observe WaitingScreen.
2. Approve device in Xibo admin panel.
3. Wait ≤15 seconds.

**Expected logs:**
```
[PLAYER] Polling status every 15s
[PLAYER] status=active
[STATE]  waiting → syncing | reason=admin approved
[PLAYER] CollectionService cycle start
```
**Expected UI:** Spinner changes to "Loading content…" then transitions.

---

## T4: First Content Load Test

**Steps:** (auto-triggered from T3 approval)

**Expected logs:**
```
[XMDS]    GetSchedule layouts=N default=...
[DOWNLOAD] Manifest total=N
[DOWNLOAD] HTTP OK: X.xlf (Ybytes)
[DOWNLOAD] HTTP OK: image.jpg (Zbytes)
[XLF]     Parsing layout X
[XLF]     Total playlist items=N
[STATE]   syncing → playing | reason=playlist N items
```
**Expected UI:** Content visible fullscreen. No chrome.

---

## T5: Schedule Refresh Test (no re-download)

**Steps:**
1. Wait 60 seconds after T4.

**Expected logs:**
```
[PLAYER] CollectionService cycle start
[DOWNLOAD] Cached OK: image.jpg
[DOWNLOAD] Summary skipped=0 success=N failed=0
[XLF]    Total playlist items=N
```
**Expected UI:** Content continues playing without interruption.

---

## T6: Add New Media Test

**Steps:**
1. Add a new image to the display group in Xibo admin.
2. Wait 60 seconds OR send `collectNow` via XMR.

**Expected logs:**
```
[DOWNLOAD] HTTP OK: new_image.jpg (Nbytes)
[XLF]    Total playlist items=N+1
[PLAYER] Playlist changed — will swap after current item
```
**Expected UI:** New image appears in rotation after current item completes.

---

## T7: Remove Media Test

**Steps:**
1. Remove an image from the display group in Xibo admin.
2. Wait 60 seconds.

**Expected logs:**
```
[PLAYER] CollectionService cycle start
[XLF]    Total playlist items=N-1
[PLAYER] Playlist changed — will swap after current item
```
**Expected UI:** Removed image no longer plays.

---

## T8: Network Loss Test

**Steps:**
1. Disable WiFi while content is playing.
2. Wait 60+ seconds.
3. Re-enable WiFi.

**Expected logs (during outage):**
```
[PLAYER] CollectionService cycle failed — using cache
[STATE]  (stays PLAYING — no state change)
```
**Expected logs (after reconnect, ≤60s):**
```
[PLAYER] CollectionService cycle start
[XMDS]   GetSchedule ...
[STATE]  (stays PLAYING or transitions SYNCING → PLAYING)
```
**Expected UI:** Content keeps playing through outage. Recovers automatically.

---

## T9: App Crash / Restart Test

**Steps:**
1. Force-close the app.
2. Re-launch.

**Expected logs:**
```
[INIT]   Player initialize
[INIT]   Config present → REGISTERING
[XMDS]   calling RegisterDisplay
[XMDS]   RegisterDisplay code=201
[STATE]  registering → syncing | reason=approved (201)
[STATE]  syncing → playing | reason=playlist N items
```
**Expected UI:** Goes straight to PlayerScreen. No SetupScreen.

---

## T10: No Content Test

**Steps:**
1. Remove ALL media from the display group in Xibo admin.
2. Wait 60 seconds.

**Expected logs:**
```
[XLF]    No layout ids from schedule or default
[STATE]  playing → noContent | reason=no scheduled content
```
**Expected UI:** NoContentScreen with logo + "Checking every 60 seconds…"

**Recovery steps:**
1. Add media back.
2. Wait ≤60 seconds.

**Expected:** Transitions back to PLAYING automatically.

---

## Production Build

After all 10 tests pass:

```bash
flutter build apk --release --obfuscate --split-debug-info=./debug-info
```

**Verify:**
- APK size < 50 MB
- Installs and auto-starts on Android TV / Android phone hardware (not emulator)
- Boot receiver fires on device restart → app starts automatically
- Immersive kiosk mode active (no status bar, no navigation bar)
