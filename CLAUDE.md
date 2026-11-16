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
- AirPlay device switching. Declined in §4.7 rather than merely deferred: it conflicts with §4.1's focus contract, and macOS routes audio perfectly well without us.
- Mac App Store distribution. We ship as a Developer ID–signed, notarised build, with no sandbox.

---

## 2. Platform and stack

- macOS 27 deployment target, Apple Silicon. The dev machine is a Mac Studio (M1).
  The floor is a product decision, not an API constraint — see §5b before lowering it.
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
  - `-600` (`procNotFound`) → `.musicNotRunning`
  - `-609` (`connectionInvalid`) → `.connectionLost`, **not** `.musicNotRunning`.
    -609 means the Apple Event connection has gone stale; Music is still running
    and still playing. Conflating the two put "Music isn't open" over a live
    player — see §6.4.
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
- **End time:** the wall-clock time the track will finish, computed as
  `now + remaining`, using the user's locale and 12/24 h setting via
  `DateFormatter.timeStyle = .short` rather than a hard-coded pattern. (en_NZ
  renders an uppercase "PM" on macOS 27, so the lowercase in this spec's
  original example was wishful.)

  **Moved to the tooltip in M2, at Julian's request.** It had a line of its own
  under the scrub bar, which cost 17 pt of panel height — about a tenth of the
  panel — for something read occasionally. It now appears in the trailing
  label's tooltip alongside the track length, and shows "paused" there when
  stopped. The panel shrank from 164 pt to 147 pt as a result, and the artwork
  square grew into the saved space proportionally.
- **Track length**, available via the toggle above and also shown in the tooltip.

Interaction:
- Click anywhere on the bar to seek there.
- Drag the thumb to scrub. While dragging, show a time bubble above the thumb with the target time. **Commit the seek only on release** (one `set player position`). Suppress clock updates during the drag so the thumb doesn't jump.
- Hit target: at least a 20 pt tall interactive area, even if the visible track is thinner. Fixing fiddly controls is the point of the app.
- Keyboard (when the panel is key): ← / → seek ±5 s, ⇧← / ⇧→ seek ±30 s.
- For streaming tracks where the duration is 0 or missing, show an indeterminate bar and disable seeking.
  **Only when a track actually exists.** "No duration" covers two different
  states: a real track Music will not size, which earns the indeterminate bar,
  and nothing queued at all, which earns §5's empty bar. Rendering both the
  same way made a parked player look like it was endlessly seeking.

### 4.3 Album art and Now Playing info ✅ confirmed
- Artwork preview: `raw data of artwork 1 of current track`, decoded to `NSImage`.
  Prefer `raw data` (`pRaw`) over `data` (`pPCT`): the latter is typed `picture`,
  the former hands back the original bytes, which `NSImage` decodes directly.
  `artwork` also exposes `format` and `downloaded`, which are worth checking
  before assuming a track has usable art. Display it at a minimum of 64 × 64 pt in the compact layout, scaling up with the panel, with rounded corners and a subtle shadow.
- Cache artwork keyed by persistent ID, holding the last 20 tracks in an LRU. Fetch it on track change only, never on the 1 Hz poll.
- Some streamed catalogue tracks return no artwork data. Show a neutral placeholder rather than an empty box. (If this happens often in M2 testing, a later option is fetching catalogue artwork via MusicKit; that's out of scope for now.)
- Crossfade (150 ms) when the artwork changes.
- Title, artist, and album. Each line truncates cleanly when it fits the column
  and **scrolls when it does not** — see `MarqueeText`.

  The marquee is AppKit, not SwiftUI, and that is the whole point. Continuous
  motion driven by SwiftUI costs 5–8% of a core (§7.4); one `CABasicAnimation`
  on a layer runs on the render server and costs the main thread nothing.
  Measured: **1.00–1.04%** with it scrolling, identical to the panel without it.
  It installs no animation at all when the text fits, which is most of the time.

  Three traps, all of which made it look broken before it was:

  - **Do not use `NSTextField` for this.** It draws through a cell that caches
    its layout from the previous frame, so a wider frame is not enough: it kept
    rasterising the older, narrower layout and the marquee scrolled a *snapshot*
    of the clipped text. The log said `measured 329pt, label frame 329pt` while
    the screen showed a truncated string — the width was never wrong, the
    drawing was. Resizing forced the cell to refresh, which is why dragging the
    panel appeared to fix it while a track change did not.

    `CATextLayer` renders the string into whatever bounds it is given, with no
    cell in between. Two things it does not do for free: set `contentsScale`
    from the backing scale factor, or text is soft on Retina; and wrap frame
    changes in a `CATransaction` with actions disabled, or every track change
    animates its layers into place.
  - `sizeToFit()` can also settle on a width the current frame allows, so the
    "full" width comes back already truncated. Measure the string against its
    font instead.
  - `.frame(maxWidth: .infinity, alignment: .leading)` stretches the *frame* and
    aligns the child within it; it does not stretch the child. The marquee views
    needed it on themselves.
  - The panel sitting at its **minimum width** gives the title column its 118 pt
    floor, where everything scrolls. That is fine now the marquee works — the
    text just takes longer to go by — and the compact panel is worth keeping.
    The default width is 760 pt, at which most titles do not scroll at all.
  - **Coalesce rebuilds.** A SwiftUI layout pass proposes several slightly
    different widths before settling, and each tripped the change threshold:
    bursts of 76–252 rebuilds inside one second were measured on every track
    change, each tearing down and reinstalling the animation. It settled every
    time, so nothing looked wrong. `reflowIfNeeded` now defers to the next
    runloop turn, which collapses a burst into one rebuild — 4 at launch,
    none during playback.
  - `updateNSView` runs on **every** SwiftUI update, and the panel re-renders
    about once a second from the clock. Rebuilding the animation there removed
    and re-added it each time, so it never escaped its opening pause and sat
    still and clipped — indistinguishable from a marquee that does not work.
    `MarqueeView` now rebuilds only when the text, font or width actually
    changes, and counts its rebuilds so "restarting constantly" can be told
    apart from "logged once": a counter that climbs after launch is the bug
    returning.
- Clicking the artwork brings Music.app forward (`activate`).

### 4.4 Transport ✅ confirmed
- Layout: **previous · play/pause · next** as a centred group, with play/pause visibly larger than the buttons either side.
- Hit targets: at least 32 pt for previous and next, and at least 44 pt for play/pause.
  **The target and the glyph are separate budgets.** §4.4 governs the target —
  the frame plus its `contentShape` — and says nothing about the symbol drawn
  inside it. The first build left a 21 pt play glyph floating in its 46 pt
  target, which read as timid. The glyphs were enlarged substantially (play 27,
  prev/next 19, shuffle/repeat 18, star 15, volume speakers 13, scrub times 13)
  with the targets untouched, so the row height and the panel height did not
  change at all. Check the volume track stays over §4.6's 160 pt floor when
  touching the speaker icon frames; it is 170 pt.
- Commands: `previous track` / `playpause` / `next track` — **except from a
  parked player**. `playpause` toggles *the current track*, so with nothing
  queued it has nothing to toggle and does nothing at all; Cue's play button
  was dead from a cold Music. Bare `play` starts playback and is used when
  there is no current track. Measured with `tools/run-probe.sh --probe-play`:
  `playpause` left it stopped, `play` started it, `play current playlist`
  errored with -1700.
- The play/pause icon reflects the actual player state, updating optimistically on click and reconciling on the next sync.
- Previous follows Music's behaviour: more than 3 s in restarts the track.
- Space toggles play/pause when the panel is key.

### 4.5 Shuffle, repeat, favourite ⏳ proposed
- Shuffle: read and set `shuffle enabled`.
- Repeat: cycle off → all → one via `song repeat`.
- Favourite: toggle the favourite property on the current track. The property is
  **`favorited`** (code `pLov`, boolean, on `track`), confirmed in M0 — see §6.1.
  There is also `disliked` (`pHat`), plus `album favorited` / `album disliked`.

**All three writes are asynchronous.** Music applies them a moment after the
event returns, so reading the property back in the same script yields the OLD
value. An early M3 probe did exactly that and the writes looked like they were
being silently ignored; with a 0.6 s pause they all took effect. Update the UI
optimistically and let the 0.9 s tick reconcile — never confirm one of these
writes with an immediate read, or every button appears to flip back the instant
it is clicked.

### 4.6 Volume ✅ confirmed
- A horizontal slider bound to Music's `sound volume` (0–100). This is Music's own level, not system volume.
- **Decent width:** at least 160 pt in the compact layout. It grows with the panel and never shrinks to an icon-sized control. The interactive height is at least 20 pt, the same as the scrub bar.
- Speaker icons sit at each end: low on the left, high on the right. Clicking the low icon toggles mute, restoring the previous level.
- Send updates while dragging at no more than 15 Hz, plus a final value on release.
- Scrolling over the slider (trackpad or wheel) adjusts the volume in steps of 2.
- Read the volume on each sync, so changes made in Music itself are reflected.

### 4.6a Panel layout

Built in M2 as a mini-player: the artwork is a square **column** at the
left-hand end, not a row above everything, which is what lets the panel be
short. Transport sits directly above the scrub bar; the volume control has the
top-right zone on the title's line.

```
┌─────────────────────────────────────────────────────────┐
│  ┌─────────┐  Title                  🔈 ━━━━━━━━━━ 🔊    │
│  │         │  Artist — Album                             │
│  │   art   │            ⏮    ⏯    ⏭                      │
│  │         │  1:42 ━━━━━━━━●───────────────   -2:13      │
│  └─────────┘                                             │
└─────────────────────────────────────────────────────────┘
```

Shuffle and repeat flank the transport group once M3 lands.

**Geometry is derived, not tuned.** All of it lives in `PanelMetrics`, shared
by the window and the layout rather than computed twice:

- the artwork square is exactly the height of the stack beside it, so the two
  columns start and finish level
- the content height follows from the artwork plus its margins
- one margin, equal on all four sides (15 pt), tunable with
  `defaults write nz.slstudio.Cue PanelMargin`. Note the knob is the margin
  *before* the 3 pt optical nudge is folded in, so 12 there gives the 15 pt
  you see.
- the panel resizes **horizontally only**, from a minimum that always leaves
  room for §4.6's 160 pt volume track beside the artwork and a readable title

An intermediate version moved the volume between the title's line and a row of
its own depending on width. It worked, but it was more machinery than the space
it saved, and the fixed minimum width replaced it.

### 4.7 AirPlay picker ❌ declined

~~Popover listing `AirPlay devices` with name and kind. Multi-select sets
`current AirPlay devices`.~~

**Not built, decided before starting M4.** Output routing stays in Music and
Control Centre; Cue controls playback.

The decisive reason is §4.1's focus contract. A popover containing a
selectable device list needs key status to be usable — arrow keys, selection,
click-outside-to-dismiss — and the panel is built never to take focus, which
is verified and is the property that lets it be used while you type. Breaking
that for the rarest action in the app is a bad trade.

Supporting reasons: output switching is a roughly daily action in a panel
earning its space on constant ones; macOS already offers two faster routes
from anywhere (Control Centre's Sound section, ⌥-click on the menu-bar
volume); and `current AirPlay devices` is list-valued with multi-select
writes, which given §6.3–§6.7's catalogue of surprises on simple booleans is
the riskiest bridge work in the spec.

**If it is ever wanted, the status item menu is the place — not the panel.**
An `NSMenu` runs its own event loop and so does not disturb the focus
contract, costs no panel space, and a device list with checkmarks maps
naturally onto multi-select. §4.9's menu is the natural host.

### 4.8 Escape hatches ⏳ proposed
- "Lyrics" and "Up Next" buttons that bring Music.app forward. No UI scripting.

### 4.9 App chrome ✅ confirmed — trimmed on build

Shipped as: Show/Hide Panel, Always on Top (toggle), Launch at Login
(`SMAppService.mainApp`), Quit. The ticks are read fresh in `menuNeedsUpdate`
rather than cached, because `SMAppService.mainApp.status` is the only true
account of the login item — a user can remove it in System Settings and our
stored flag would never know.

Three proposed items were **dropped as scope** rather than deferred:

- A Settings window. Two toggles do not need one.
- A global hotkey. §7.3 already settled that a global key grab conflicts with
  §4.1's focus contract, and the panel is always visible anyway.
- Auto-hiding when Music isn't running, plus §4.8's escape hatches. §5's
  placeholder states already cover Music being closed, and hiding the window
  out from under someone is worse than showing them a button.

Note that Launch at Login cannot be tested from a debug build in the build
tree: `SMAppService` registers the bundle by path, so it must be verified from
`/Applications` after §5b's pipeline has run.

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

## 5b. Shipping

`tools/sign-and-notarise.sh` takes the tree to a notarised, stapled zip:
archive → export (`tools/ExportOptions.plist`) → verify → zip → submit →
staple → **re-zip**. That last step is not redundant: stapling writes the
ticket into the `.app`, so a zip made before it ships unstapled.

Adapted from ScreenRecorderPlus's script of the same name, and its checks are
kept rather than rewritten — each exists because something went wrong once.
Two gates are Cue-specific:

- `LSUIElement == true`, because losing it turns the agent into a Dock app and
  nothing else complains
- the `com.apple.security.automation.apple-events` entitlement, without which
  the app ships unable to do the only thing it does

It also refuses to ship a version that is already tagged, so two different
builds cannot wear the same version number.

Prerequisites are **per machine, not per project**: a Developer ID Application
certificate in the login keychain, and a stored `notarytool` credential
profile. The profile is an Apple ID credential, so one notarises every app —
hence `CUE_NOTARY_PROFILE` defaulting to an existing profile name rather than a
duplicate under a new one.

**Notarisation returns 403 — "a required agreement is missing or has expired"
— until the Apple Developer Program License Agreement is accepted.** There is
no CLI for accepting it and no separate way to query it: the 403 *is* the status
check, and `xcrun notarytool history --keychain-profile <profile>` succeeding is
the confirmation. Apple updates the agreement periodically, so this recurs.
Accepting it does not take effect instantly — it kept returning 403 for a few
minutes afterwards, so re-test before assuming the wrong agreement was signed.

**Verify the zip, not the build-tree app.** Stapling writes the ticket into the
`.app`, so unpacking `build/Cue.zip` somewhere else and running `spctl` there is
the only check that proves the re-zip happened. It should report
`source=Notarized Developer ID`; a bundle whose ticket never made it into the
zip says `source=Developer ID` instead, and that difference is the whole point
of the step.

### The app icon

A reel-to-reel tape reel. `tools/icon-master.png` is the 1024×1024 master;
`swift tools/make-icon.swift` composites it into
`Cue/Assets.xcassets/AppIcon.appiconset`, drawing each size at its own
resolution and masking it to the macOS icon shape.

The target uses `fileSystemSynchronizedGroups`, so the asset catalog needed no
project-file surgery — only `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in
both configurations. Verify by looking for `AppIcon.icns` and `Assets.car` in
the built `Contents/Resources/`, plus `CFBundleIconName` in the Info.plist;
a missing asset catalog fails silently and simply ships a blank app.

Two things worth knowing before changing it:

- **Small sizes need their own proportions, not the same drawing scaled.** The
  generator's `shape(for:)` gives 16 and 32 px a smaller canvas inset so the
  artwork itself is drawn larger. Even so, the photographic master reads as a
  blue tile with an orange centre at 16 px — accepted knowingly. A flat second
  master for the small end is the fix if it ever matters; `shape(for:)` is
  where it would branch.
- **The icon is now most of the app.** `Assets.car` is 1.96 MB against a
  binary of a couple of hundred KB, which took the download from 320 KB to
  2.3 MB. Harmless, but it means a change to the master moves the release size
  far more than a change to the code does.

Cue has no Dock icon, so the icon is seen in Finder, in System Settings (Login
Items, and Privacy & Security → Automation) and on the release page.

### Distribution — decided 2026-11-16

Public GitHub repo, MIT licensed, with binaries attached to GitHub Releases:
<https://github.com/JRButler/cue-apple-music-panel>. The app is Cue; the repo
carries the searchable name, because plenty of Mac apps are called Cue and
none of them are findable.


`README.md` is the user-facing document; **this file stays the internal spec.**
Keep them apart: the README should never explain Apple Event descriptors, and
this file should never apologise for a permission prompt.

- **The macOS 27 floor stays, for a product reason rather than a technical
  one.** The APIs in use go back much further — `onGeometryChange` is the
  highest at macOS 15, then `@Observable` at 14 and `SMAppService` at 13 — so
  lowering the target is one build setting. It stays at 27 because macOS 27 is
  the release whose Music redesign created the need; before it, Music's own
  controls were adequate and nobody wanted this. Do not "fix" it.
  Lowering it would also mean supporting a Music dictionary never tested here:
  §6.1's `favorited` is version-specific, and older Music used `loved`.
- **No Sparkle before release.** Users download and replace the app. Revisit if
  the project keeps moving — the same call is pending for ScreenRecorderPlus.
- **The name is still open (§7.2) and must be settled before the first
  release**, because it then lives in a URL and in other people's menu bars.
  §5a lists every place it appears.

### Release checklist

1. Settle the version. `MARKETING_VERSION` is 1.0 in both configurations;
   bump it, and `CURRENT_PROJECT_VERSION`, for each release.
2. `tools/sign-and-notarise.sh --dry-run`, then without the flag.
3. Verify the stapled app from outside the build tree: `spctl -a -vvv -t install`
   and `xcrun stapler validate`.
4. Tag `v<version>`, push, create the release, attach `build/Cue.zip`.

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

**Acceptance criteria — all met**
- [x] The scrub bar moves smoothly and stays within 0.5 s of Music. Worst live
      drift against Music: **17 ms**. Motion is 2 Hz by choice, see §6.2 and §7.4.
- [x] Dragging commits exactly one seek. **12 gestures, 12 commits.**
- [x] The end time is correct and updates after a pause and resume.
- [x] Using the panel never steals focus from the frontmost app. Verified three
      independent ways, with the instrumentation left in place.
- [x] Idle CPU use is under 1% while paused. **0.00%** with a track loaded.

#### 6.2 M1 findings

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

**Stays within 0.5 s of Music — verified against the real app.** The 1 Hz tick
logs the gap between what the clock was rendering and what Music then reported.
Over a few minutes of playback the **worst gap was 17 ms**, against a 0.5 s
tolerance — roughly the cost of the `fetchPosition` round trip, which is the
floor. The clock's own arithmetic is checked separately by `--test-clock`.

**Idle CPU under 1% while paused — verified, 0.00%.** Measured in 10 s buckets
with a track loaded and paused, which matters: an earlier 0.45% figure was taken
with *nothing* loaded, a much simpler view tree, and so did not actually test
the criterion. Playing sits at 1.0–1.2%.

**Off-screen frame clamping — verified numerically.** The real condition needs a
display to be unplugged, but the arithmetic does not, so `M1PanelTests` feeds
`PanelController.clamped(_:screens:)` synthetic screen rectangles: a detached
second display, a wildly off-screen origin, a frame deliberately hanging off an
edge (which must survive, being a position the user chose), and a frame wider
than the display.

That last case found a real bug. Visibility was tested before size, so a frame
4000 pt wide counted as "substantially visible" — it overlaps plenty — and was
left that wide. Size is now sanitised against §4.1's width range *first*, and
the position check follows.

**The end time across a pause — verified by eye.** After a ~40 s pause the
finish time had moved later by about that much on resume, which is the behaviour
that matters: the label is `now + remaining`, so it holds steady while playing
and shifts by exactly the length of any pause.

**M1's scaffolding stays.** `M0Probe` and its modes are the only way to get
numbers out of an `LSUIElement` app without a GUI, and they earned their keep:
they caught the DateFormatter, the measurement error, and the clamping bug. The
M0 debug window is gone, as §6 intended, because the panel replaced it.

### M2 — Album art, transport, volume
- Implement §4.3, §4.4, and §4.6, using the layout in §4.6a.

**Acceptance criteria**
- [x] Artwork appears within 300 ms of a track change — **22–30 ms** measured.
      The placeholder path is not yet verified; it needs a track with no art.
- [x] The transport buttons work and the play/pause icon matches Music's state,
      including changes made in Music itself. Confirmed by eye.
- [x] Volume dragging is smooth — confirmed by eye, after the tick was made to
      stand down during a drag. A change made in Music is reflected in **375 ms**
      measured, with a worst case of ~0.92 s by construction; see §6.3.

#### 6.3 M2 findings

Measured: artwork fetch **22–30 ms** against §4.3's 300 ms criterion (a 318 KB
payload), a volume write **8.3 ms**, panel CPU **~1.1%** while playing.

**§4.6's "within 1 s" forced the hot path from one Apple Event to two, and the
poll from 1.0 s to 0.9 s.** Music posts no notification when its own volume
changes, so the only way to notice is to look. The second reference is the
whole application `properties` record, which carries volume, mute, shuffle,
repeat and player state together — one event for all of them, not one each.

The interval matters for the same reason. At exactly 1 Hz the worst case is a
change landing just after a tick: a full interval plus the ~17 ms read, about
1.02 s, which misses the criterion by a hair. At 0.9 s the worst case is
~0.92 s and it is met by construction rather than on average. A measured
sample — changed externally at 16:08:10.686, noticed at 16:08:11.061 — came in
at **375 ms**. CPU went from 1.07% to 1.25%.

`tools/run-probe.sh --volume-latency` performs that measurement. It changes the
volume from a second process, which the panel cannot distinguish from a change
made in Music, and timestamps the moment — the half a by-hand test cannot
supply. It restores the original level afterwards.

**Mute cannot use Music's `mute` property.** `set mute to true` is refused with
error **9038** on macOS 27; `tools/run-probe.sh --probe-mute` establishes that,
and that setting it `false` only appears to work because it was already false.
Mute is implemented as volume-to-zero with a remembered level — which is what
§4.6's "restoring the previous level" describes anyway. A mute set inside Music
is still honoured for display, since `pMut` is read every tick.

**The invisible titlebar caused two separate bugs, both costing 32 pt.**
`.titled` plus `.fullSizeContentView` means the content view spans the whole
window, so window geometry always *looked* right:

1. Assigning `panel.contentLayoutRect` to the hosting view's frame squashed the
   content into 123 pt of a 155 pt window and cut the scrub bar in half.
2. SwiftUI separately applies a safe-area inset for the titlebar, laying the
   content out in 117 pt of 149 and overflowing it evenly — 16 pt each way,
   which put the artwork 33 pt from the top and 1 pt from the bottom.
   `.ignoresSafeArea()` is required, and removes the dead strip at the top too.

**The artwork stopped keeping pace with track changes**, while the text did
not. The text is set optimistically from the §3.2 payload, and the sync then
decided whether to fetch artwork by comparing against the track that optimistic
update had already changed — so the comparison always said "unchanged". The
clock's jump-vs-sync decision had the identical flaw and was only saved by the
snap threshold. Both now key off what was last *applied*, not off `track`.

**Dragging a view that also handles clicks needs AppKit.** A SwiftUI
`DragGesture` reports translation in the view's own coordinate space, and that
space moves with the window — so moving the window changes the translation,
which moves it again. The panel lagged the pointer and popped. `performDrag`
runs AppKit's drag loop against screen coordinates, and click detection falls
out of it: a press that left the window where it started was a click.

**Measure the panel, do not reason about it.** Reasoning about the geometry was
wrong three times in a row; one logged measurement settled it immediately.
`PanelView` logs the stack's rendered height against the prediction and where
the artwork square actually lands, and `PanelController` logs the window and
hosting-view frames. An earlier version of that log printed `contentLayoutRect`
and so looked plausible while hiding the bug — log what the content gets, not
what the window reports.

**Still to verify:**

- [ ] §4.3's placeholder, which needs a track with no artwork. The code path is
      straightforward — a nil payload is cached as "this track has none", so it
      is not re-fetched — but it has not been exercised against a real track.

#### 6.4 Field report: the panel latched into "Music isn't open"

After several days of real use the panel showed §5's "Music isn't open" state
while Music carried on playing, and stayed that way. Three faults, compounding:

1. **No connection state was recoverable.** `tick()` set the state and called
   `stopPolling()`; `updatePolling()` only polls while `.connected`. So the
   tick — the one thing that could have noticed Music was fine — stopped, and
   recovery depended entirely on a notification arriving. Mid-track with
   nothing changing, none does.
2. **-609 was treated as "Music is gone".** It means the Apple Event connection
   is stale, not that the app has quit, and a sleep/wake cycle is an easy way
   to get one after hours of running.
3. **None of the transitions logged**, so the log showed a perfectly healthy
   session right up to the moment of the report, with no trace of the failure.

The fixes, in order of importance:

- **Nothing is terminal.** Any state other than `.connected` starts a 3 s
  recovery loop that retries `resync()` until it succeeds. Note the edge case
  it has to cover: `connection` is initialised to `.musicNotRunning`, and a
  property initialiser does not fire `didSet`, so a *first* sync that fails
  changes nothing and would never start recovery. `start()` therefore checks
  explicitly.
- **-609 is its own error**, handled as transient.
- **Resync on `NSWorkspace.didWakeNotification`.** The pre-sleep connection is
  not to be trusted.
- **Every connection transition is logged**, so a recurrence leaves evidence:

  ```sh
  log show --last 6h --predicate 'subsystem == "nz.slstudio.Cue"' \
    | grep -E 'connection:|recovery:'
  ```

The same report's log also showed **every track change fetching its artwork
twice**, identical sizes milliseconds apart. The two sources of a `TrackInfo`
do not always agree on the persistent ID — the §3.2 payload sometimes yields
none, so `id` falls back to the title/artist/album composite while the
AppleScript record supplies a hex string — and the dedupe guard was keyed on
`id`. Artwork now keys on `TrackInfo.artworkKey`, the composite, which both
paths always produce identically.

**A second fault surfaced the moment the first was fixed.** With the panel
recovering properly, Music relaunched and the artwork stayed a placeholder.
One log line settled it:

```
artwork fetched in 9.8 ms (4 bytes)
```

Music answered with a 4-byte payload instead of an image, presumably still
warming up. The code saw non-empty data, failed to decode it, and cached that
nil as a known negative — so the track was never asked again. Negative caching
is deliberate (§4.3: a track genuinely without artwork should not be re-fetched
every time), but it must distinguish three outcomes, not two:

| outcome | meaning | cache? |
|---|---|---|
| no data returned | the track genuinely has none | **yes** |
| data that will not decode | a bad reply | no — clear the key, retry |
| a thrown error | transient: busy, stale, timed out | no — clear the key, retry |

The bridge also now discards implausibly small replies rather than passing them
on. Both faults in §6.4 were found from the log alone, and the first one had
left no trace at all until transition logging was added — the panel sat wrong
for hours while the log showed a perfectly healthy session. **Log state
transitions, not just activity.** Activity logging says what worked; transition
logging is what tells you when something stopped.

### M3 — Shuffle, repeat, favourite — complete
- Implement §4.5. ✅

All three verified through `MusicBridge` itself, not a reimplementation of it:

```
✓ setShuffle:   toggled false -> true
✓ setRepeat:    set to all
✓ setFavourite: toggled false -> true
```

Shuffle and repeat flank the transport per §4.6a; favourite sits beside the
title, since it describes the track rather than the playback. Two fixes also
landed here that are not §4.5's: the play button could not start a parked
Music (§4.4), and the panel claimed "Music isn't open" on launch before it had
checked (§5).

#### 6.5 M3 findings

`shuffle enabled`, `song repeat` and `favorited` are all writable, checked with
`tools/run-probe.sh --probe-m3` before anything was built on them — `mute` looked
settable in the dictionary too and refuses with 9038 (§6.3), so the dictionary
is not evidence.

**The writes are applied asynchronously**, which the probe nearly got wrong.
Setting a property and reading it back in the same script returns the previous
value, so the first run reported shuffle and repeat as silently ignored. A 0.6 s
pause showed all three working. §4.5 records the consequence: optimistic updates
only, reconciled by the tick.

Placement: shuffle and repeat flank the transport group per §4.6a. Favourite sits
beside the title instead, because it describes the track rather than the
playback, and the transport row was already five controls wide. Both toggles tint
when active — a plain glyph gives no way to read shuffle-on from shuffle-off —
and `repeat one` gets the distinct `repeat.1` glyph rather than a badge, which
would be illegible at 13 pt.

**Four faults found in the first session of real use**, all from the log:

1. **`setShuffle` failed with -10006, "Can't set shuffle enabled to enabled".**
   The handler was `on setshuffle(enabled)`, and `enabled` is a Music term
   (`enbl`, on `track`) — inside a `tell` block the terminology wins over a
   local variable, so AppleScript bound the property instead of the argument.
   Every handler parameter is now prefixed `cue`, which no dictionary uses.
2. **The probe passed while the app was broken**, because it drove Music with
   literal values rather than through the handlers. `--probe-m3` now exercises
   the real `MusicBridge` methods as well, and treats "returned cleanly but
   changed nothing" as a failure — which is exactly how a terminology collision
   presents.
3. **A blank panel after an album finished.** Music keeps answering
   `current track` with a record whose fields are all empty rather than
   erroring, and a TrackInfo built from it gave the panel a track with no
   title, artwork or duration. A hollow record now reads as nothing queued,
   which is §5's state.
4. **The indeterminate scrub bar never stopped.** A `repeatForever` animation
   does not end on its own; it kept sliding after playback finished, looking
   like the panel was still seeking a track that had ended.

**The lesson worth keeping is (2).** A probe that does not exercise the code
path the app uses can report health while the app is broken. Prefer driving the
real method over reproducing what it does.

**Three more faults, all found by using it rather than testing it:**

- **A launch flash.** `connection` began as `.musicNotRunning`, which asserts
  something the app has not checked. There is now a `.connecting` state that
  renders the same furniture, so the first sync fills it in.
- **The favourite star was invisible**, twice over. First because the title row
  needed exactly the panel's width before the star was added to the
  minimum-width sum, so SwiftUI squeezed the fixed-width control to nothing.
  Then because it had never actually been added to the view at all — the script
  that placed it aborted on a later assertion, discarding the earlier write.
  **A multi-edit script that writes at the end loses everything when one match
  fails.** Verify the file, not the script's progress output.
- **The repeat states were illegible.** At 12 pt the numeral inside `repeat.1`
  does not render distinguishably, so repeat-one and repeat-all looked
  identical and the control read as laggy rather than three-state. Rendering
  the glyphs at 12/14/16/18 pt settled it: 16 pt is where it becomes readable.

#### 6.6 Field report: a 3.7-second flash of "Music isn't open"

Seen while tracks were playing. The log:

```
11:32:50.072  connection: connected -> musicNotRunning
11:32:50.072  recovery: retrying every 3.000000s
11:32:53.740  connection: musicNotRunning -> connected
```

Nothing was wrong with Music. A single `isMusicRunning` lookup came back
empty — `NSRunningApplication` does that occasionally — and two choices turned
an instant into 3.7 seconds of wrong screen:

- **A single observation was trusted.** A problem must now persist for 1.5 s
  before the UI shows it. Being briefly out of date beats replacing the whole
  panel for a glitch.
- **The first retry was 3 s away**, which is literally the gap in the log.
  Retries now start at 0.4 s and back off to 3 s only after six attempts.

Together a blip is caught at +0.4 s, inside the grace, and never displayed.

**The grace applies to guesses, not to facts.** `NSWorkspace`'s
`didTerminateApplicationNotification` means Music really has quit, so that path
shows the placeholder at once. Same distinction as -609 (a stale connection)
versus -600 (the process is gone).

Each path now logs `trouble (<source>)` when it trips, because the previous
round left no way to tell whether the guard or the tick had fired.

#### 6.7 The "4-byte artwork" was `missing value` in disguise

Reported as: artwork missing while a track played. The log said

```
Discarding 4-byte artwork reply as implausible
artwork fetched in 49.6 ms (0 bytes)
```

and `--probe-artwork` found the track had `count of artworks → 0` and
`class → URL track` — a streamed Apple Music track, which is precisely §4.3's
documented placeholder case. The placeholder was right; how we reached it was
not.

**AppleScript returns `missing value` as a descriptor of type `type` whose
*code* is `msng`, not as a descriptor whose own type is `msng`.** `isPresent`
tested only the second spelling, so `missing value` read as present and its
four bytes — `m`, `s`, `n`, `g` — were taken for image data. There was never a
warm-up stub.

This one check caused two separate reported bugs. The other was the hollow
track record after an album finished (§6.5), patched at the symptom at the
time; the root cause was here all along.

It was also made worse by a fix of mine. The bridge had been "discarding
implausible replies" by returning nil, and the model reads nil as *"this track
genuinely has no artwork"* and caches it. A bad reply was therefore laundered
into a confident negative, defeating the retry path added for undecodable
data. The bridge now throws for an implausible reply, which the model treats
as transient and retries up to four times with a backoff before settling on
the placeholder — useful anyway for artwork that has not finished downloading.

**The recurring shape, for the fourth time: two different states collapsed
into one value.** -609 vs "quit"; a decode failure vs "no artwork"; an unsized
track vs no track; an empty process lookup vs "not running". Each looked fine
until something real hit the second case.

#### 6.8 Field report: the artwork reverted to the placeholder while paused

Reported after 1.0 shipped: with Music paused, the artwork went blank and
stayed blank. The log, once it could be read at all:

```
16:01:38  artwork cache hit for Tough Leap…
16:01:57  trouble (resync): failed("Music didn't answer in time.")
16:02:05  connection: connected -> failed
16:02:32  trouble cleared; connected
16:02:32  recovery: stopped, connected
16:15:30  artwork cache hit for Tough Leap…
```

**Three things this cost, all worth not repeating.**

**`log` is a zsh builtin.** `log show --predicate …` silently runs the shell's
own `log` and reports "too many arguments". It looks exactly like an app that
never logged, and it nearly produced a day of work on logging that was fine all
along. Use `/usr/bin/log` from a script, always.

**`recovery: stopped, connected` is `stopRecovery()`, not a stopped player.**
Read as the latter it supports a confident, wrong diagnosis. A log line naming
a state transition should say which machine it belongs to.

**§6.4's lesson had only been applied to the connection.** Connection
transitions were logged; the track's were not. So the one fact needed — whether
the track had gone — was the one fact absent, and two wrong diagnoses were
offered before the user's own account settled it. `apply` now logs
`track: <old> -> <new>, player <state>` on every change.

**What it actually was**, by elimination rather than by guessing. Exactly three
paths clear `artworkKey`, and two of them log:

| path | logs | present |
|---|---|---|
| decode failure | `artwork failed to decode` | no |
| transient error | `artwork attempt N failed` | no |
| the track became nil | nothing, at the time | — |

So a *successful* sync returned no current track while Music was merely paused.
Music keeps `current track` across a pause — verified directly, and its UI has
no Stop at all — so that read was hollow: the `missing value` family again
(§6.7), in its third disguise.

**The asymmetry is the bug.** `reportProblem` refuses to believe bad news about
the connection for 1.5 s. `apply` believed bad news about the track instantly,
and one hollow read emptied the panel. It now takes two consecutive track-less
reads, which costs one poll on a genuine end-of-queue and nothing otherwise.
A held read's missing position is ignored too, or the scrub bar snaps to zero
on a track still paused halfway through.

**A second, unrelated bug found while looking for this one.** The artwork
give-up branch called `artworkCache.store(nil, …)` after four failures — and
`nil` there means "asked, and this track genuinely has no artwork". A run of
timeouts is not that, and the lie stuck until the LRU evicted it twenty songs
later. It now caches nothing and retries when the connection recovers. Note
this had never actually fired: the logs show no give-up all day. It was found
by reading, not by reproducing.

**And the placeholder itself changed.** §5's stopped state shows it far more
often than the rare artwork-less track does, and a grey box with a glyph reads
as something broken. It is now Cue's own reel, desaturated so it is not taken
for an album cover — the user's suggestion, and the right one.

### ~~M4 — AirPlay~~ — dropped

§4.7 was declined before this milestone began; see that section. Nothing else
was scoped into M4, so it is gone rather than empty.

### M4 — Polish (was M5) — complete

- §4.9 App chrome — trimmed to two toggles. §4.8 dropped; see §4.9.
- Developer ID signing and notarisation — the pipeline is §5b.
- A reel-to-reel app icon — see §5b.
- **Cue 1.0 released**, 2026-11-16:
  <https://github.com/JRButler/cue-apple-music-panel/releases/tag/v1.0>

Acceptance met. Launch at Login and the Automation prompt were both confirmed
from a copy installed in `/Applications`, and the published `Cue.zip` was
downloaded back from GitHub into an empty directory, where `spctl` reported
`source=Notarized Developer ID` and `stapler validate` passed.

---

## 6a. A note on editing this project

Three features were reported as "not working" when they had simply never been
added: §4.5's favourite star, `PanelController.toggleCollapsed`, and the
collapse chevron. Each time the cause was the same.

Edits are applied by scripts that match on surrounding source text, and the
text they anchor to is most often a **comment** — which is exactly what gets
rewritten as the code is explained better. When a match fails, the script
either aborts before writing (discarding its earlier successful replacements
too) or silently skips that one. The output still reads like success.

**Compiling proves nothing here.** A SwiftUI view property that nothing
references compiles perfectly happily; it just never renders. So after adding
anything, check that it is *used*, not merely that it exists:

```sh
grep -n "FavouriteButton" Cue/UI/PanelView.swift     # is it in the body?
```

and build by exit status rather than by grepping the log, which was how a
non-compiling tree got committed in 573f89c.

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

- ~~Final name~~ — **settled: Cue.** Plenty of other Mac apps are called Cue,
  but with nothing being sold the exposure is negligible, and a crowded
  common-word namespace weakens anyone's exclusive claim to it. The real cost
  was discoverability, and that is solved at the repository instead: the app
  is Cue, the repo is `cue-apple-music-panel`. §5a still lists everywhere the
  name appears, should that ever change.
- Visual direction: minimal glass, or something with more character?
- Should we ever support non-Music players via MediaRemote? This is out of scope unless decided otherwise.

Decided in §5b rather than here: the macOS 27 floor stays, distribution is a
public MIT repo with binaries on GitHub Releases, and Sparkle waits until after
release.
