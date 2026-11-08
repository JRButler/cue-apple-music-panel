# CLAUDE.md — Cue (working title)

A floating, always-available control panel for Apple Music on macOS. It replaces the shrunken bottom control bar in Music.app on macOS 27 with a larger, easier-to-use panel that stays on top of whatever you're working in.

> **Workflow:** This spec is milestone-gated. Complete one milestone, meet its acceptance criteria, then **stop and report** before starting the next. Don't jump ahead or bundle milestones.

---

## 1. Goals and non-goals

**Goals**
- A large, readable floating panel with a precise scrub bar. The panel is the reason this app exists.
- Control Music.app only through public Apple Events (its AppleScript dictionary). No private frameworks.
- Event-driven updates where possible, light polling where not. Negligible CPU use while idle.
- Never launch Music.app as a side effect.

**Non-goals (for now)**
- Controlling other players (Spotify, browsers). That would need the private MediaRemote framework.
- Time-synced lyrics or the Up Next queue. Neither is exposed via scripting; we link out to Music instead.
- Mac App Store distribution. We ship as a Developer ID–signed, notarised build, with no sandbox.

---

## 2. Platform and stack

- macOS 27 deployment target, Apple Silicon. The dev machine is a Mac Studio (M1).
- Swift 6 (strict concurrency), SwiftUI for views, and AppKit for the window (`NSPanel`) and the status item.
- Xcode project, with no third-party dependencies.
- An agent app (`LSUIElement = YES`): no Dock icon. A menu-bar status item provides show/hide, settings, and quit.
- Hardened Runtime enabled. Entitlements:
  - `com.apple.security.automation.apple-events` = YES
- Info.plist:
  - `NSAppleEventsUsageDescription`: "Cue controls playback in the Music app."

---

## 3. Architecture

```
Cue/
├── App/
│   ├── main.swift                // explicit entry point — see the note below
│   ├── AppDelegate.swift         // lifecycle, argument parsing
│   ├── StatusItemController.swift
│   ├── EventLog.swift            // M0 only
│   ├── M0Controller.swift        // M0 only
│   ├── M0Probe.swift             // M0 only
│   └── (M1) PanelController.swift  // NSPanel owner, frame persistence
├── Music/
│   ├── MusicBridge.swift         // ALL Apple Events live here
│   ├── MusicScripts.swift        // AppleScript source strings, compiled once
│   ├── MusicEventSource.swift    // DistributedNotificationCenter + NSWorkspace observers
│   └── MusicTypes.swift          // TrackInfo, PlayerState, RepeatMode, AirPlayDevice
├── State/                        // (M1)
│   ├── PlayerModel.swift         // @Observable @MainActor single source of truth
│   └── PlaybackClock.swift       // position interpolation between syncs
├── UI/
│   ├── DebugWindow.swift         // M0 only, deleted when PanelView lands
│   └── (M1+) PanelView.swift, ScrubBar.swift, TransportControls.swift,
│             ArtworkView.swift, AirPlayPicker.swift, VolumeControl.swift
└── Resources/
    ├── Info.plist
    └── App.entitlements
```

**Entry point.** There is no `@main`. An `NSApplicationDelegate` marked `@main`
in an `LSUIElement` app never has its lifecycle methods called — it launches,
nothing happens, and nothing is logged. `App/main.swift` sets the delegate on
`NSApplication.shared` by hand, sets `.accessory`, and calls `run()`.

The target uses a file-system-synchronised group, so a new `.swift` file under
`Cue/` joins the build with no change to the project file.

### 3.1 MusicBridge
- This is the **only** type that sends Apple Events. Everything else goes through its async API.
- Compile each AppleScript once at startup (`NSAppleScript`, `compileAndReturnError`) and reuse it.
- `NSAppleScript` must be used on the main thread. Keep every script tiny so each call stays well under 10 ms. Batch reads: a single `fetchState()` script returns all polled fields in one round trip, rather than making one call per property.
- **Every script sets an explicit `with timeout`.** The Apple Event default is two
  minutes and `NSAppleScript` blocks the thread it runs on, which here is always
  the main thread — so one stalled event freezes the panel for two minutes. This
  is not hypothetical: an unanswered Automation prompt does exactly that, and did
  during M0. `fetchState` allows 2 s (it polls at 1 Hz, so a slower read has
  already missed its slot); commands allow 5 s.
- **`fetchState` returns a list, not a record.** A record with custom keys arrives
  wrapped in a `usrf` key/value list that has to be walked pairwise; a list is
  indexable directly. One round trip for every field is unaffected. The order is
  fixed by `MusicBridge.StateField` and the script's `return {...}` line.
- **The first reads in `fetchState` are deliberately not wrapped in `try`.** Only
  genuinely absent values are: `player position` is `missing value` when stopped,
  `current track` errors when nothing is queued, `duration` is absent on some
  streams. Wrapping the rest would turn "we are not permitted to talk to Music"
  into a well-formed list of empty values that reads as a stopped player — hiding
  §5's denied state behind a plausible lie. `player state` is the canary.
- **Guard rule:** before *any* call, check that `NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")` is non-empty. If Music isn't running, return `.musicNotRunning` and do not send the event. Sending `tell application "Music"` would launch it.
- Map errors to a typed `MusicBridgeError`:
  - `-1743` (`errAEEventNotPermitted`) and `-1744` (`errAEEventWouldRequireUserConsent`) → `.automationDenied`
  - `-600` (`procNotFound`) / `-609` (`connectionInvalid`) → `.musicNotRunning`
  - `-1712` (`errAETimeout`) → `.timedOut`
  - Anything else → `.scriptError(code, message)`
- Permission is read with `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)`,
  which is silent and separates "never asked" (`-1744`) from "refused" (`-1743`).
  Sending a probe event cannot make that distinction, because sending is what
  triggers the prompt.

### 3.2 MusicEventSource

Observe the `com.apple.Music.playerInfo` distributed notification. **Verified on
macOS 27.0.1**: it fires on track change and on play, pause and stop, and the
payload is below.

- **Register with an explicit name.** `addObserver(forName: nil, …)` never fires
  on a `DistributedNotificationCenter` — distributed delivery is routed by name,
  so a wildcard matches nothing, and it fails *silently* rather than erroring.
  That looks exactly like "Music posts nothing at all", and cost time in M0.
  There is no supported way to enumerate what a process posts. A controlled test
  confirmed the failure is contained: a nil-name registration does not disturb
  other registrations on the same observer object, and both the block-based and
  selector-based APIs deliver correctly.
- We use the block-based API with `queue: .main`, and convert to a `Sendable`
  `PlayerInfoPayload` at that boundary, which keeps `Notification` — not
  `Sendable` — from crossing into the main actor. The selector-based API works
  equally well; this is a concurrency-ergonomics choice, not a correctness one.
- `suspensionBehavior: .deliverImmediately` matters for the selector-based API,
  so that macOS does not queue notifications while the agent is inactive — which
  for an `LSUIElement` app is nearly always.
- Music **also** posts `com.apple.iTunes.playerInfo` with a byte-identical
  payload. Observe only one, or every change is handled twice.

**The payload, as actually delivered** (9 keys):

| key | type | notes |
|---|---|---|
| `Name` | String | track title |
| `Artist` | String | |
| `Album` | String | |
| `Genre` | String | not in the original spec's expected set |
| `Composer` | String | not in the original spec's expected set |
| `Player State` | String | `Playing` / `Paused` |
| `Total Time` | Int | **milliseconds**, and rounded to the second |
| `PersistentID` | Int | **signed** 64-bit decimal |
| `Library PersistentID` | Int | signed; identifies the library, not the track |

Two conversions are needed, and `PlayerInfoPayload` does both:

- **`PersistentID` is a signed decimal; AppleScript's `persistent ID` is a
  16-digit uppercase hex string.** They are the same number:
  `UInt64(bitPattern:)` then `%016llX`. Verified against the same track from both
  sources — decimal `1061950922838147007` is `0EBCCEBCE4AA7FBF`. Without this,
  §4.3's artwork cache would never get a key hit between the two paths.
- **`Total Time` is milliseconds, `duration` is seconds** — and `Total Time` is
  the rounder of the two (`353000` ms against a true `353.05` s). Use
  AppleScript's `duration` for §4.2's scrub bar; treat `Total Time` as a hint.

There is **no position field** in the payload, which is why position must still
be polled (§3.3, §7.1).

- Observe `NSWorkspace` `didLaunchApplicationNotification` and `didTerminateApplicationNotification`, filtered to `com.apple.Music`. These are an ordinary notification centre, so selectors are fine.
- On any event, ask `PlayerModel` to resync.

### 3.3 PlayerModel and PlaybackClock

- `PlayerModel` (`@Observable`, `@MainActor`) holds: connection status, the current track, player state, position, shuffle, repeat, volume, favourite, and AirPlay devices.

**The reads are split in two.** This is the decision taken in §7.1, forced by M0's
measurement that one property reference costs one ~8.3 ms Apple Event on the main
thread. Polling everything at 1 Hz would block for ~90 ms every second.

- `fetchPosition()` — **the 1 Hz hot path.** `player position` alone: one
  reference, one event, 8.3 ms median. Nothing else goes in here, ever. Adding a
  single field to this call doubles its cost.
- `fetchState()` — **the full sync, not on the timer.** Three references, ~25 ms:
  `properties` (application), `player position`, and `properties of current
  track`. Driven by `playerInfo` (§3.2) and by explicit user action.

  Three, not two, because **`player position` is not in the application
  `properties` record.** That record has 16 fields — `pnam`, `pPlS`, `vers`,
  `pisf`, `pVol`, `pMut`, `pShE`, `pShM`, `pRpt`, `pVsE`, `pFSc`, `pEQ `, `pFix`,
  `pCnv`, `pAPE`, `pAPD` — and neither `pPos` nor `pTrk` is among them. Verified
  with `tools/run-probe.sh --dump-records`, which prints every keyword, its
  descriptor type and its value; write parsers against that output, not against
  the sdef alone.

  `properties of current track` errors with **-1728** when nothing is queued,
  rather than returning an empty record, so that reference needs its own `try`.

**Use the notification payload for the instant update.** §3.2's payload already
carries name, artist, album and player state, so the panel can repaint the moment
a track changes, with the authoritative 3-event sync landing ~25 ms later. Do not
take duration from the payload for the scrub bar: `Total Time` is rounded to the
second where `duration` is precise.

Volume, shuffle and repeat therefore update on notification rather than on the
poll. A change made inside Music with no play-state change will lag until the
next notification; if that proves annoying in use, fold those three into a
low-frequency secondary poll rather than into `fetchPosition()`.

- **Position strategy:**
  - While playing, call `fetchPosition()` at 1 Hz.
  - `PlaybackClock` interpolates position from the last sync timestamp so the scrub bar moves smoothly at display refresh rate (use `TimelineView` or `CADisplayLink` equivalent).
  - If the polled and interpolated positions differ by more than 0.5 s, snap to the polled value. Otherwise, ease toward it.
  - While paused or stopped, stop polling. The notifications are enough.
  - While the panel is hidden, stop polling entirely.
  - The interpolated clock is what the scrub bar renders, so the 8.3 ms poll is a
    rendering stutter at worst, never a positional error.

**Record field types**, as observed, since the accessor has to match:

| descriptor type | accessor | fields |
|---|---|---|
| `utxt` | `stringValue` | `pnam`, artist, album, `pPIS` |
| `enum` | `enumCodeValue` | `pPlS` (`kPSS`/`kPSP`/`kPSp`/`kPSF`/`kPSR`), `pRpt` (`kRpO`/`kRp1`/`kAll`), `pShM` |
| `long` | `int32Value` | `pVol` |
| `doub` | `doubleValue` | `pDur`, `pPos` |
| `true` / `fals` | `booleanValue` | `pShE`, `pMut`, `pLov` |
| `msng` | — | a genuinely absent value |

Note booleans arrive as `true`/`fals`, not `bool`, so switching on the type
string needs all three.

**If the stutter is visible on the real panel**, §7.1's option 3 is the fallback:
move the hot path to `NSAppleEventDescriptor.sendEvent(options:timeout:)`, which
is public and safe off the main thread, unlike `NSAppleScript`. Judge it by eye
in M1 before taking that on.

---

## 4. Features

### 4.1 Floating panel ✅ confirmed
- `NSPanel` with style mask `.nonactivatingPanel`, `.titled`, and `.fullSizeContentView`. The titlebar is transparent and its buttons are hidden.
- `level = .floating` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- `isMovableByWindowBackground = true`. Clicking a control must **not** activate the app or steal focus.
- The background uses a vibrancy material (`NSVisualEffectView` / `.ultraThinMaterial`) with rounded corners.
- Persist the frame across launches. If the saved frame is off-screen after a display change, clamp it back on-screen.
- The panel is resizable between a minimum and maximum width; controls lay out to fit.

### 4.2 Scrub bar ✅ confirmed (core feature)
Display:
- **Elapsed** time on the left (`m:ss`, or `h:mm:ss` when the track is 1 h or longer).
- **Remaining** time on the right (`-m:ss`). Clicking it toggles between remaining and total duration. Persist the choice.
- **End time:** the wall-clock time the track will finish, e.g. "ends 2:47 PM", computed as `now + remaining`. Use the user's locale and 12/24 h setting via `DateFormatter.timeStyle = .short` rather than a hard-coded pattern — en_NZ renders an uppercase "PM" on macOS 27, so the lowercase in this spec's original example was wishful. Show it only while playing; while paused, show "paused".
- **Track length**, available via the toggle above and also shown in the tooltip.

Interaction:
- Click anywhere on the bar to seek there.
- Drag the thumb to scrub. While dragging, show a time bubble above the thumb with the target time. **Commit the seek only on release** (one `set player position`). Suppress clock updates during the drag so the thumb doesn't jump.
- Hit target: at least a 20 pt tall interactive area, even if the visible track is thinner. Fixing fiddly controls is the point of the app.
- Keyboard (when the panel is key): ← / → seek ±5 s, ⇧← / ⇧→ seek ±30 s.
- For streaming tracks where the duration is 0 or missing, show an indeterminate bar and disable seeking.

### 4.3 Album art and Now Playing info ✅ confirmed
- Artwork preview: `raw data of artwork 1 of current track`, decoded to `NSImage`.
  Prefer `raw data` (`pRaw`) over `data` (`pPCT`): the latter is typed `picture`,
  the former hands back the original bytes, which `NSImage` decodes directly.
  `artwork` also exposes `format` and `downloaded`, which are worth checking
  before assuming a track has usable art. Display it at a minimum of 64 × 64 pt in the compact layout, scaling up with the panel, with rounded corners and a subtle shadow.
- Cache artwork keyed by persistent ID, holding the last 20 tracks in an LRU. Fetch it on track change only, never on the 1 Hz poll.
- Some streamed catalogue tracks return no artwork data. Show a neutral placeholder rather than an empty box. (If this happens often in M2 testing, a later option is fetching catalogue artwork via MusicKit; that's out of scope for now.)
- Crossfade (150 ms) when the artwork changes.
- Title, artist, and album, with each line truncating cleanly.
- Clicking the artwork brings Music.app forward (`activate`).

### 4.4 Transport ✅ confirmed
- Layout: **previous · play/pause · next** as a centred group, with play/pause visibly larger than the buttons either side.
- Hit targets: at least 32 pt for previous and next, and at least 44 pt for play/pause.
- Commands: `previous track` / `playpause` / `next track`.
- The play/pause icon reflects the actual player state, updating optimistically on click and reconciling on the next sync.
- Previous follows Music's behaviour: more than 3 s in restarts the track.
- Space toggles play/pause when the panel is key.

### 4.5 Shuffle, repeat, favourite ⏳ proposed
- Shuffle: read and set `shuffle enabled`.
- Repeat: cycle off → all → one via `song repeat`.
- Favourite: toggle the favourite property on the current track. The property is
  **`favorited`** (code `pLov`, boolean, on `track`), confirmed in M0 — see §6.1.
  There is also `disliked` (`pHat`), plus `album favorited` / `album disliked`.

### 4.6 Volume ✅ confirmed
- A horizontal slider bound to Music's `sound volume` (0–100). This is Music's own level, not system volume.
- **Decent width:** at least 160 pt in the compact layout. It grows with the panel and never shrinks to an icon-sized control. The interactive height is at least 20 pt, the same as the scrub bar.
- Speaker icons sit at each end: low on the left, high on the right. Clicking the low icon toggles mute, restoring the previous level.
- Send updates while dragging at no more than 15 Hz, plus a final value on release.
- Scrolling over the slider (trackpad or wheel) adjusts the volume in steps of 2.
- Read the volume on each sync, so changes made in Music itself are reflected.

### 4.6a Panel layout (compact)
```
┌──────────────────────────────────────────────────┐
│ ┌──────┐  Title                                  │
│ │ art  │  Artist — Album                         │
│ └──────┘                                         │
│ 1:42  ━━━━━━━━━━━━●──────────────  -2:13         │
│                    ends 2:47 pm                  │
│        🔀   ⏮    ⏯    ⏭   🔁                     │
│   🔈 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 🔊             │
└──────────────────────────────────────────────────┘
```
Shuffle and repeat flank the transport group once M3 lands.

### 4.7 AirPlay picker ⏳ proposed
- Popover listing `AirPlay devices` with name and kind. Multi-select sets `current AirPlay devices`.
- Show which devices are currently selected.

### 4.8 Escape hatches ⏳ proposed
- "Lyrics" and "Up Next" buttons that bring Music.app forward. No UI scripting.

### 4.9 App chrome ⏳ proposed
- Status item menu: Show/Hide Panel, Always on Top (toggle), Launch at Login (`SMAppService.mainApp`), Settings…, Quit.
- Optional global hotkey to toggle the panel.
- Setting: hide the panel automatically when Music isn't running.

---

## 5. States and errors

| State | Panel shows |
|---|---|
| Music not running | Placeholder: "Music isn't open" with an **Open Music** button (the only place we launch it) |
| Automation denied | "Cue needs permission to control Music" with a button that opens System Settings → Privacy & Security → Automation |
| Stopped / nothing queued | Placeholder artwork, empty bar, transport enabled |
| Streaming track with no duration | Indeterminate bar, seeking disabled |

---

## 5a. Building and running

```sh
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug build

tools/run-probe.sh [--samples <n>] [--listen <s>]  # the M0 measurement sequence
tools/run-probe.sh --grant      # raise the Automation prompt and wait for OK
tools/run-probe.sh --deny       # same, asking for a refusal, to test §5
tools/run-probe.sh --bench      # time fetchState variants against each other
tools/run-probe.sh --watch      # drive a track change, report the notification
```

Running the app with no arguments gives a status item and the M0 debug window
instead. All of this is spike scaffolding and goes when the panel lands.

Debug builds are signed with Developer ID, not ad-hoc, and that is deliberate.
Automation access is granted to a code signature, so a stable signing identity
means the grant survives a rebuild; ad-hoc signing changes the designated
requirement every build and macOS re-prompts each time.

**Launch the app with `open`, never by executing the binary.** macOS attributes
an Automation request to the *responsible process* of whatever sends it. A binary
started from a shell inherits the terminal as responsible, so the request is
refused with no prompt and no TCC entry for Cue ever appears — it looks exactly
like a bug in the bridge. `tools/run-probe.sh` uses `open -n -W` so launchd
starts it and Cue is its own responsible process. Because `open` leaves the app
no usable stdout, the probe also writes to `~/Library/Logs/Cue/`.

Logs: `~/Library/Logs/Cue/m0-debug.log` (every event) and
`m0-probe-report.txt` (the last probe run, truncated each time).

### Renaming the app

"Cue" is a working title (§7). It is confined to:

1. the `Cue/` source folder and the `path = Cue;` line in `project.pbxproj`
2. `Cue.xcodeproj/` and its scheme file
3. `PRODUCT_BUNDLE_IDENTIFIER` (`nz.slstudio.Cue`) in both build configurations
4. `NSAppleEventsUsageDescription` in `Info.plist`

No Swift file hard-codes the name; code reads `Bundle.main` instead. Note that
changing the bundle id resets the Automation grant, so the prompt returns once.

---

## 6. Milestones

### M0 — Bridge spike (no UI beyond a debug window)
- Write `MusicBridge` with `fetchState()`, `playPause()`, `next()`, `previous()`, and `seek(to:)`.
- Write `MusicEventSource`, and log raw notification payloads to the console.
- Handle the first-run Automation permission prompt and the denied state.
- Write `fetchState()` latency, the notification keys, and the favourite property name into this file.

**Acceptance criteria — all met**
- [x] Track changes are logged within 200 ms. Worst observed: **82.5 ms**.
- [x] Music is never launched by Cue. Five of five entry points refused with
      Music closed, and it stayed closed.
- [x] Denied permission is detected and reported. Verified end to end with a real
      refusal, plus a synthetic check of every row of the error table.
- [x] Measured `fetchState()` latency is recorded in this file — and it missed
      §3.1's budget by 10x, which is the substantive outcome of this milestone.
      See §6.1 and the decision in §7.1.

#### 6.1 M0 findings

Measured on a Mac Studio (M1), macOS 27.0.1 (26A434), Xcode 27.1.

**Favourite property — settled.** `favorited`, code `pLov`, boolean, on `track`
(inherited by `current track`). The macOS 27.0.1 scripting definition has no
`loved` property at all. Also present: `disliked` (`pHat`), `album favorited`
(`pALv`), `album disliked` (`pAHt`).

**`persistent ID` — settled.** Not declared on `track`; inherited from the `item`
class, so `persistent ID of current track` is valid. §4.3's artwork cache can key
on it, but it comes back empty for some streamed catalogue tracks, so treat an
empty value as "no stable key" rather than assuming uniqueness.

**AppleScript does not resolve property names at compile time.** `osacompile`
accepts `get flurgle42 of current track` without complaint, so a compile check
says nothing about whether a term exists — unknown identifiers are deferred to
runtime. Verify terminology against the `sdef`, or by sending the event; not by
compiling. (This is also why probing `favorited` and `loved` in one script is
safe: the absent one errors at runtime where `on error` catches it.)

**The default Apple Event timeout will freeze the UI.** Two minutes, on the main
thread. Found the hard way: with an Automation prompt waiting unanswered, a
`fetchState()` call blocked for the full two minutes and returned `-1712`. Every
script now carries an explicit `with timeout` — see §3.1.

**`fetchState()` latency — measured, and §3.1's 10 ms budget was being missed
by 10x.** 200 samples, Music paused with a track loaded:

```
min 74.9 ms   median 91.5 ms   p95 101.7 ms   max 109.3 ms
```

`tools/run-probe.sh --bench` breaks down where that goes (60 samples each):

| variant | refs | median | p95 | ms per ref |
|---|---|---|---|---|
| no-event baseline (`tell` reading nothing) | 0 | 0.5 ms | 0.7 | — |
| one reference (`player position`) | 1 | 8.3 ms | 25.9 | 8.3 |
| ten references (what §3.1 first described) | 10 | 93.2 ms | 102.6 | 9.3 |
| same ten, `tell application "Music"` by name | 10 | 92.0 ms | 115.3 | 9.2 |
| five app fields in one list literal | 5 | 43.5 ms | 59.6 | 8.7 |
| **`properties of current track`** | **1** | **8.3 ms** | 11.5 | 8.3 |
| **`properties` (application level)** | **1** | **8.5 ms** | 24.5 | 8.5 |

What this establishes:

1. **One property reference is one Apple Event, and each costs ~8.3 ms.** The
   relationship is linear: two references cost 16.6 ms, ten cost 93 ms.
2. **AppleScript is not the cost.** A `tell` block that reads nothing runs in
   0.5 ms, so essentially all of it is the round trip to Music.
3. **A list literal does not coalesce.** `{a, b, c, d, e}` is five events, not
   one, so "batch the reads into one script" does not batch the *events* — which
   is what §3.1 actually needs. One `NSAppleScript` execution is not one event.
4. **`properties` returns a whole record for one event.** `properties of current
   track` (8.3 ms) carries name, artist, album, duration, persistent ID and
   favorited together. `properties` on the application works too (8.5 ms) and
   carries player state, position, volume, shuffle and repeat — even though the
   sdef declares `properties`/`pALL` only on `item`, and `application` does not
   inherit from it. Undeclared but answered; verified by measurement.
5. **Addressing by name or by bundle id costs the same.** Keep the id form for
   its robustness.

So a full sync is 2 events (~17 ms), not 10 (~93 ms), and the 1 Hz hot path
needs only `player position` — 1 event, 8.3 ms median, an 11x improvement.

**This invalidates §3.3's polling design and needs a decision — see §7.1.**
Polling everything at 1 Hz costs 93 ms of blocked main thread every second. Even
the reduced 8.3 ms is a dropped frame at 120 Hz, once a second, under a scrub bar
that is supposed to animate at refresh rate. Options are in §7.

**Notification payload — settled.** `com.apple.Music.playerInfo` is alive and
correct on macOS 27.0.1. The real keys, the millisecond/second mismatch and the
signed-decimal/hex persistent ID are all in §3.2. `Genre` and `Composer` arrive
too, which the original expected set did not list, and there is no position field.

**Track changes are logged within 200 ms — met.** Worst observed
notification-to-state-logged interval: **82.5 ms** over several runs (91.9 ms on
an earlier one). Note this is dominated by the ~90 ms `fetchState()` resync it
triggers, so the §7.1 fix improves this figure too.

**A `nil` notification name fails silently.** `addObserver(forName: nil, …)` on a
`DistributedNotificationCenter` never fires. Worse, I then reported *that*
observer's counter instead of the real one, and concluded Music had stopped
broadcasting entirely on macOS 27 — which a standalone listener immediately
disproved. Two lessons, both cheap to apply: register explicit names, and when a
diagnostic says a system feature is gone, verify it from outside the code under
test before believing it.

**The §3.1 guard — verified.** With Music closed, all five entry points
(`fetchState`, `playPause`, `next`, `previous`, `seek`) refused with
`.musicNotRunning`, and Music was still not running afterwards. Run it yourself
with `tools/run-probe.sh` while Music is closed; the check skips itself when
Music is up, because a guard cannot be tested against a running app.

**The denied-permission path — verified end to end.** `tools/run-probe.sh --deny`
raises the prompt asking for a refusal; after clicking Don't Allow, the permission
check reports `DENIED` with the System Settings route, and `fetchState()` throws
`.automationDenied`, surfacing §5's "Cue needs permission to control Music."
This is also what retroactively proves the canary-read decision in §3.1: under the
original all-`try` script, this exact condition returned a *plausible stopped
player* instead of an error.

Every row of §3.1's error table is checked synthetically on each probe run
(-1743, -1744, -600, -609, -1712, and an arbitrary code), since provoking a real
-1712 means hanging Music and a real -1743 needs a human click.

**One caveat on the latency figure.** It depends on whether a track is loaded,
exactly as the per-event model predicts: ~91.5 ms with a current track (ten
references) against ~57.4 ms with nothing queued, where the `current track` block
fails in one event rather than making five reads. Quote the with-a-track figure;
it is the one the panel will live with.

### M1 — Panel and scrub bar
- Build the floating panel (§4.1) and the full scrub bar (§4.2).
- Show minimal title and artist text only; artwork comes in M2.

**Acceptance criteria**
- The scrub bar moves smoothly and stays within 0.5 s of Music.
- Dragging commits exactly one seek.
- The end time is correct and updates after a pause and resume.
- Using the panel never steals focus from the frontmost app.
- Idle CPU use is under 1% while paused.

#### 6.2 M1 progress (in flight)

**Built and working:** `PlayerModel`, `PlaybackClock`, `PanelController`,
`PanelView`, `ScrubBar`, `TimeFormatting`. The panel floats, drags by its
background, persists its frame, and the scrub bar seeks by click and by drag —
confirmed by hand. The M0 debug window is gone.

**§7.1's split, measured with a track playing** (`--bench`):

| path | events | median | p95 |
|---|---|---|---|
| `fetchPosition()`, the 1 Hz hot path | 1 | **8.4 ms** | 16.2 ms |
| `fetchState()`, on notification | 3 | **25.8 ms** | 41.6 ms |
| what it replaced | 10 | 91.3 ms | 100.7 ms |

The record parser is verified against a real track: 58 fields for one event,
with persistent ID, duration and `favorited` all correct.

**CPU while playing: 5.55% → ~1.1%, and the cause was not what it looked like.**

Measured properly, on a Mac Studio M1, 20 s windows with a track playing:

| thumb mechanism | CPU |
|---|---|
| none — static bar | **0.45%** |
| SwiftUI timeline, 2 Hz (what ships) | **1.05–1.20%** |
| SwiftUI timeline, 5–30 Hz | 5.1–5.7% |
| SwiftUI `.animation` on a transform | 6.4–8.8% |

Two things to take from that, because several plausible explanations were wrong:

1. **Everything that moves the thumb through SwiftUI runs on the main thread,
   including `.animation`.** SwiftUI drives its own interpolation rather than
   handing the transform to Core Animation, so *animating cost more than
   ticking*, not less. The rate is therefore the only lever inside SwiftUI, and
   §7.4 covers the way out.
2. **`top` is not trustworthy here.** It reported a flat 3.3% across 5–30 Hz,
   which sent the investigation after a phantom "rate-independent" cost — a
   full Auto Layout pass per display cycle, detaching `NSHostingView` from the
   window's layout, the vibrancy material. None of those were it. The work is
   bursty, and `sample` showed every thread idle while real CPU was 5.55%.
   **Measure with the cumulative-CPU delta instead**, which is what every figure
   above uses:

   ```sh
   T0=$(ps -o time= -p $PID); sleep 20; T1=$(ps -o time= -p $PID)   # delta / wall
   ```

One genuine fix came out of it regardless: `TimeFormatting.endTime` was building
a `DateFormatter` per call, and `sample` traced that through ICU's `udat_open`.
It is cached now. Labels were also moved off the high-rate path — they read the
`@Observable` clock, so they refresh when it syncs, which is the only rate at
which their text can change.

**Never steals focus — verified three ways.** §4.1's contract is the one that
justifies the whole panel design, so it is not taken on trust. While typing in
Safari and clicking and dragging the scrub bar throughout:

- the user's keystrokes kept landing in Safari, never lost
- a 75-sample frontmost-application trace recorded 61 Safari, 14 Code and
  **0 Cue** — Cue never came frontmost
- Cue's own instrumentation logged **0** focus warnings: the panel never became
  key and the app never activated

`PanelController` and `AppDelegate` keep that instrumentation, so a regression
shows up as a log line rather than as a mystery:

```sh
log show --last 5m --predicate 'subsystem == "nz.slstudio.Cue"' | grep -i focus
```

**Exactly one seek per drag — verified.** 12 gestures, 12 `scrubbing began`,
12 `scrubbing ended`, **12 commits**. One of the twelve was a 17 ms click rather
than a drag, and that committed exactly once too, which is the case the shared
`DragGesture(minimumDistance: 0)` exists to make identical.

**Not yet verified:**

- [ ] Off-screen frame clamping, which needs a display change to exercise.

### M2 — Album art, transport, volume
- Implement §4.3, §4.4, and §4.6, using the layout in §4.6a.

**Acceptance criteria**
- Artwork appears within 300 ms of a track change, with a placeholder when none is available.
- The transport buttons work and the play/pause icon matches Music's state, including changes made in Music itself.
- Volume dragging is smooth and a change made in Music is reflected within 1 s.

### M3 — Shuffle, repeat, favourite
- Implement §4.5.

### M4 — AirPlay
- Implement §4.7.

### M5 — Polish
- Implement §4.8 and §4.9.
- Add Developer ID signing and notarisation.

---

## 7. Open questions

### 7.1 Polling and the main thread — needs a decision before M1

M0 measured one Apple Event at ~8.3 ms, and `NSAppleScript` blocks the thread it
runs on, which §3.1 says is the main thread. §3.3's "poll `fetchState()` at 1 Hz"
therefore blocks the main thread for 93 ms every second as first written, or
8.3 ms if reduced to a position-only read. At 120 Hz a frame is 8.3 ms, so even
the reduced version drops a frame once a second underneath a scrub bar that is
meant to move at refresh rate. Four options, cheapest first:

1. **Split the reads, keep the main thread.** A position-only poll at 1 Hz
   (8.3 ms) plus a full 2-event sync (~17 ms) on notification. One dropped frame
   per second, hidden behind `PlaybackClock`'s interpolation — the bar keeps
   moving from the local clock, so the hiccup is a rendering stutter, not a
   position error. Smallest change; delivers §3.1's budget on the hot path.
2. **As above, but poll less often.** The clock interpolates anyway, so a
   correction every 2–5 s may be enough. Fewer stutters, slightly staler data,
   and §4.2's 0.5 s accuracy requirement still holds because interpolation is
   what keeps it accurate between syncs.
3. **Move the events off the main thread.** `NSAppleEventDescriptor.sendEvent(options:timeout:)`
   is public, available since 10.11, and can be called off the main thread —
   unlike `NSAppleScript`, which is not thread-safe. It means building the
   `core`/`getd` event and object specifier by hand instead of writing
   AppleScript. No stutter at all, at the cost of more code and a second,
   lower-level path through §3.1.
4. **Accept 93 ms.** Only viable if the panel turns out to feel fine, which the
   numbers suggest it will not.

**Decided: option 1.** §3.3 has been rewritten accordingly — a position-only
1 Hz poll plus a 2-event full sync on notification. Option 3 is held in reserve
if the stutter turns out to be visible on the real panel, which M1 should judge
by eye.

A related gain, independent of which option wins: reading `properties` records
means parsing enum **codes** (`kPSP`, `kRpO`) rather than `player state as text`.
Codes are stable; the text form risks being localised on a non-English system.
The four-char codes are in the sdef and already noted in `MusicTypes`.

### 7.3 Keyboard seeking cannot coexist with the focus contract

§4.1 requires that using the panel never activates Cue or steals focus, and M1's
acceptance criteria restate it. That is delivered with `.nonactivatingPanel` plus
`becomesKeyOnlyIfNeeded = true`.

The consequence: a panel that never takes key status never receives key events,
so §4.2's `←`/`→` seeking is unreachable in ordinary use. The handlers are wired
and work if the panel is somehow key, but nothing in normal interaction makes it
key — by design, because the alternative is that clicking the panel silently
swallows the keystrokes meant for whatever you were typing in.

Three ways out, for a decision in M5:

1. **§4.9's global hotkey.** Seeking works from anywhere, no focus change. The
   natural answer, and already in scope for M5.
2. **An explicit "focus panel" affordance** — a status-item item, or ⌥-click —
   so the user opts into key status when they want the keyboard.
3. **Weaken the contract**, letting a click take key status. Not recommended:
   it breaks the criterion that justifies the whole panel design.

### 7.4 A smooth thumb needs CALayers, not SwiftUI

M1 established that any continuously-moving element driven by SwiftUI costs
5–8% of a core on an M1, because SwiftUI interpolates on the main thread. The
bar ships at 2 Hz and ~1.1% as a result, which steps visibly rather than
gliding.

The way to get both smooth and cheap is to draw the track, fill and thumb as
`CALayer`s inside a small `NSViewRepresentable`, and re-target a
`CABasicAnimation` on the thumb layer's `position` once per sync. Core Animation
interpolates layer properties on the render server, so the main thread does
nothing between syncs and the motion runs at true display refresh rate. Expect
roughly the static cost, ~0.5%.

Cost: perhaps 150 lines of AppKit, and the scrub bar stops being a SwiftUI view,
so the gesture handling and the hit-target rule move with it. Worth doing only
if the 2 Hz stepping is visibly annoying in use — judge it by eye first.

### 7.2 Product questions

- Final name. "Cue" is a working title; §5a lists everywhere it appears.
- Visual direction: minimal glass, or something with more character?
- Should we ever support non-Music players via MediaRemote? This is out of scope unless decided otherwise.
