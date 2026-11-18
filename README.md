# Waverly

![Waverly: your day, at a wave](docs/assets/og-card.jpg)

Waverly is a glanceable full-screen dashboard for your Mac that appears when you raise
your hand. Wave at the camera, or make a fist and open your hand, and your day fades in
over whatever you were doing: the time, today's Google Calendar events, your tasks
counting down, the weather hour by hour, and a word and a fact of the day, all on glass
cards over a sky that follows the real time and weather outside. Make a fist, press
Esc, or simply walk away, and it's gone. Everything runs on your Mac: the camera is
processed on-device and never recorded or sent anywhere.

Website: [waverly-app.vercel.app](https://waverly-app.vercel.app) ·
Download: [latest release](https://github.com/LurpDaDerp/Waverly/releases/latest)

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [First-run setup](#first-run-setup)
- [Gestures and keyboard](#gestures-and-keyboard)
- [Settings](#settings)
- [Privacy](#privacy)
- [Google Calendar](#google-calendar)
- [Building from source](#building-from-source)
- [How it works](#how-it-works)
- [Project layout](#project-layout)
- [Tests](#tests)
- [Developer switches](#developer-switches)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)
- [License](#license)

## Features

- **Hands-free:** open with a wave (or a fist, then an open hand), scroll by moving
  your open hand, close with a fist. It also closes by itself a few seconds after you
  leave or the room goes dark. You choose which of these gestures to use.
- **Your day at a glance:** two lists you set up yourself (by default your Google
  Calendar events and your Google Tasks), with countdowns, keyword filters and
  coloured labels. Click a task's ring to check it off; it's marked done in Google
  Tasks after a few seconds, and a second click before then undoes it.
- **Weather and sky:** current conditions and an hourly forecast from Open-Meteo, over
  a sky that moves from dawn to night and shows clouds, rain, snow, fog and storms.
- **Something to read:** Merriam-Webster's word of the day and a "Did you know" fact
  from Wikipedia.
- **Parallax:** the cards lean gently as your head moves.
- **Make it yours:** light, dark or adaptive theme; parallax, weather animation and
  weather detail to taste; hand scrolling either way round; your own keyboard shortcut.
- **Keyboard too:** the shortcut (default fn ⇧ H) opens and closes it, Esc closes it,
  and the trackpad scrolls the lists.
- **Light on battery:** the heavy hand-tracking model only runs while a hand is
  clearly in view (see [How it works](#how-it-works)).
- **Private:** no accounts, no servers, no analytics. Waverly only reads your Google
  calendars and tasks, except to mark a task done when you check it off.

## Requirements

- macOS 14 Sonoma or later
- A Mac with Apple silicon (M1 or newer); MediaPipe has no Intel macOS build
- A camera (the built-in one is fine)
- An internet connection for the one-time setup download (about 250 MB) and for the
  weather, calendar and daily word and fact

## Install

1. Download `Waverly-<version>.dmg` from the
   [latest release](https://github.com/LurpDaDerp/Waverly/releases/latest).
2. Open it and drag **Waverly** to **Applications**.
3. Open Waverly from Applications. Waverly isn't notarized by Apple yet, so the first
   time, macOS refuses to open it. Go to **System Settings › Privacy & Security**,
   scroll down to the message about Waverly, click **Open Anyway** and confirm. This
   is needed only once.

Waverly lives in the menu bar (there is no Dock icon). Its menu has Show Waverly,
Hide Waverly, Pause camera, Connect Google Calendar…, Settings…, Open logs, Launch at
login and Quit Waverly.

## First-run setup

The first launch opens a short setup window:

1. **Your name**, for the greeting (optional).
2. **Permissions**, each optional:
   - **Camera**, for the gestures.
   - **Accessibility**, so the keyboard shortcut works in every app (macOS requires it
     for global shortcuts). Without it, gestures, the menu and Esc still work.
   - **Location**, for the local weather. You can type a city instead.
3. **Preferences:** location, units and clock, launch at login.
4. **Google Calendar:** sign in with Google to show your events and tasks (optional;
   you can connect later from the menu).

Meanwhile Waverly downloads its hand-tracking engine in the background: about 250 MB,
once, into `~/Library/Application Support/Waverly`. It takes a few minutes and you can
keep using your Mac. When it's done, Waverly is ready.

## Gestures and keyboard

| To | Gesture | Keyboard / trackpad |
|---|---|---|
| Open | Wave, or make a fist and then open your hand, palm facing the camera | The shortcut (default **fn ⇧ H**) |
| Scroll | Hold your hand open and move it. Up and down scrolls a list (left hand: left list, right hand: right list); sideways scrolls the hourly forecast. | Two fingers on the trackpad |
| Close | Hold up an open palm, then close it into a full fist. Or walk away, or turn off the light. | The shortcut again, or **Esc** |

Opening only counts while your palm faces the camera, so scratching your head or
showing the back of your hand doesn't open it. Hand scrolling works like dragging a
scroll bar: move your hand down to go further down a list (or right to go later in the
forecast), and back to return. Either direction can be reversed, and each one's speed
set, in Settings; those settings affect hand gestures only, never the trackpad.

Each way of opening and closing can be turned off in **Settings › Controls › Hand
Gestures**: open with a wave, or with a fist and then an open hand; close with a fist,
when you walk away, or when the room goes dark. Walking away and darkness both close
it after 5 seconds. With "when the room goes dark" off, Waverly stays open in the
dark (nobody can be seen there), and "when you walk away" counts from when the light
comes back. Turn both open gestures off and only the keyboard shortcut and the menu
open Waverly, and the hand-tracking models stay idle while it's closed.
Scrolling always works. Changes apply within about 2 seconds, open or closed.

## Settings

Open **Settings…** from the menu bar icon (or press ⌘, while a Waverly window is in
front). Changes apply immediately; there is no Save button. Settings are grouped by
category:

- **General:** your name, location (automatic, or a city you pick) and launch at
  login.
- **Appearance:** theme (**Adaptive**: the cards follow the sky, light by day and dark
  at night; **Light** or **Dark**: that tone at any time of day, while the sky still
  follows the time and weather); temperature (°F/°C), wind (mph/km/h) and 12- or
  24-hour clock; parallax and weather animation on or off; and weather detail
  (**High**: every effect, fog and lightning included; **Medium**: clouds and lighter
  rain or snow, without fog or lightning; **Low**: a simple sky gradient, easiest on
  the battery). Detail and animation are independent: high detail with animation off
  draws the full sky once and keeps it still. **Open animation** and **Close
  animation** pick how Waverly appears and disappears: **Fade**, **Zoom**, **Shatter**,
  **Slide** or **Swirl**. **Open length** (0.3 to 2 seconds, 1 by default) and **Close
  length** (0.2 to 1.5 seconds, 0.75 by default) set how long each takes; at the far
  left of each slider, **Instant** shows or hides it at once, with no animation.
- **Controls:** the keyboard shortcut that shows and hides Waverly (click it, then
  press a new one; it needs fn, ⌃, ⌥ or ⌘; shortcuts macOS already uses, and
  standard ones such as ⌘C, are refused, and you're warned about ones some apps also
  use; **Reset to Default** returns to fn ⇧ H; Esc always closes); **Hand
  Gestures**: which gestures open Waverly (**Wave**; **Fist, then open hand**) and
  what closes it (**Make a fist**; **When you walk away**; **When the room goes
  dark**), each on or off; reverse vertical or horizontal hand scrolling; and the
  vertical and horizontal hand-scrolling speed (half to twice the standard speed).
- **Lists:** each card's title, which calendars and task lists feed it, keyword
  filters for events and tasks, how far ahead the right list looks, and countdowns.
- **Labels:** a colour for every calendar and task list, and shared categories (for
  example "Work") that group several under one label.
- **Google:** connect, reconnect or disconnect your account (a sign-in from before
  Waverly could check tasks off shows **Sign In Again…** to allow it); under
  **Advanced**, use your own Google Cloud OAuth client (see [Google Calendar](#google-calendar)).
- **Permissions:** the state of the camera, Accessibility and location permissions,
  with a way to allow each.

Everything is saved in `~/Library/Application Support/Waverly/config.json`, readable
only by your user account.

## Privacy

- Camera frames are analysed on your Mac (Apple Vision and MediaPipe), never recorded
  and never sent anywhere. The frames passed to the hand-tracking engine go through a
  small shared-memory file in `~/Library/Application Support/Waverly`, readable only by
  your user account; it is wiped as soon as the camera stops sending frames to the
  engine and deleted when Waverly quits.
- Parallax follows your head's position and angle in the camera picture. With parallax
  off, the angle is not computed and no head position goes to the dashboard (Waverly
  still notices whether someone is in front of the camera, so that it can close when
  you leave).
- With the Accessibility permission, Waverly looks at key presses only to recognise
  its shortcut and Esc; keys are not recorded or sent anywhere.
- Google Calendar and Google Tasks are read and shown only to you. The only change
  Waverly ever makes is marking a task completed when you check it off; it never
  deletes, edits or creates anything else. The sign-in tokens stay in
  `~/Library/Application Support/Waverly`, readable only by your user account.
- For the weather, your location is rounded to about 10 km before it is sent to
  Open-Meteo.
- There are no Waverly servers, accounts, analytics or crash reporting.

The full policy: [waverly-app.vercel.app/privacy](https://waverly-app.vercel.app/privacy)
(source: [`docs/privacy.html`](docs/privacy.html)).

## Google Calendar

### Connecting

Choose **Connect Google Calendar…** in the menu (or use the Google page of the setup
window, or **Settings › Google**). Your browser opens Google's sign-in page; sign in,
allow access to your calendars and tasks, and you're done. Waverly asks for two
scopes only: `calendar.readonly`, to read your calendars, and `tasks`, to read your
tasks and mark one completed when you check it off on the HUD. It never deletes,
edits or creates anything else. If you untick one on Google's screen, Waverly still
connects and shows what you allowed (without Tasks, or with tasks you can't check
off). Signed in before checking off existed? Tasks keep showing; **Settings › Google ›
Sign In Again…** adds checking off. To disconnect, use **Settings › Google › Disconnect**, or revoke
Waverly's access at [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

Until Google has verified the app, sign-in shows a **"Google hasn't verified this
app"** screen: click **Advanced**, then **Go to Waverly (unsafe)** to continue. Until
then Google also limits the app to 100 users in total.

### Using your own OAuth client

If you'd rather sign in through your own Google Cloud project (or your build has no
client built in), open **Settings › Google › Advanced**, click **Choose Client File…**
and pick the `client_secret_….json` file of a **Desktop app** client created as below.
Sign-in then uses your client; **Use Built-in Client** switches back.

### Creating the OAuth client (for builds from source)

A build from source has no Google client of its own until you add one:

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project
   (for example "Waverly").
2. **APIs & Services › Library:** enable the **Google Calendar API** and the
   **Google Tasks API**.
3. Set up the **OAuth consent screen** (in the current console: **Google Auth
   Platform**):
   - App name **Waverly**, a user support e-mail and a developer contact e-mail.
   - Audience: **External**.
   - Scopes (Data access): `https://www.googleapis.com/auth/calendar.readonly` and
     `https://www.googleapis.com/auth/tasks`.
   - Privacy policy: `https://waverly-app.vercel.app/privacy` (or your own
     for your own distribution).
   - Publish the app to **In production**. In testing mode only the test users you
     list can sign in, and their access expires after 7 days.
4. **Credentials** (or **Clients**) **› Create OAuth client ID**, application type
   **Desktop app**. Copy the client ID and secret, or download the JSON for the
   Advanced option above.
5. Build them in:

   ```sh
   cp macos/Config/Secrets.example.xcconfig macos/Config/Secrets.xcconfig
   # then edit Secrets.xcconfig (values without quotes):
   #   GOOGLE_CLIENT_ID = 1234…apps.googleusercontent.com
   #   GOOGLE_CLIENT_SECRET = GOCSPX-…
   ```

   `Secrets.xcconfig` is git-ignored and included last by
   `macos/Config/Waverly.xcconfig`, so its values win. Google treats a desktop app's
   client secret as not confidential (it ships inside the app), but keep it out of
   the repository anyway. `scripts/build.sh` ends with "built-in Google client" when
   it was picked up.

The unverified-app screen and the 100-user cap remain until the app passes Google's
verification (a review of the consent screen, privacy policy and scopes).

## Building from source

You need Xcode 16 or later on an Apple silicon Mac.

```sh
scripts/fetch_uv.sh     # download the pinned uv release (SHA-256 checked) into build/vendor
scripts/build.sh        # Release build -> build/Waverly.app (ad-hoc signed, verified)
scripts/make_dmg.sh     # -> dist/Waverly-<version>.dmg (volume "Waverly")
scripts/verify.sh       # check the built app (see Tests)
```

- `build.sh` runs `fetch_uv.sh` itself when uv is missing (`SKIP_UV=1` skips that) and
  regenerates `Waverly.xcodeproj` with `scripts/gen_xcodeproj.py`, so new Swift files
  are built. You can also open `Waverly.xcodeproj` and run the **Waverly** scheme.
- The runtime in `hud/` is copied into the app unchanged; `build.sh` checks that the
  bundled copy is byte-identical.
- `scripts/make_icons.sh` regenerates the app and menu bar icons from the SVGs in
  `design/icon/` (needs Google Chrome).
- `build.sh` signs ad-hoc ("Sign to Run Locally") with the Hardened Runtime, so the DMG
  needs **Open Anyway** on other Macs. To ship without that step, sign with a Developer
  ID and notarize (needs a paid Apple Developer account):

  ```sh
  # once: store notarytool credentials in the keychain
  xcrun notarytool store-credentials Waverly --apple-id you@example.com --team-id TEAMID --password <app-specific password>
  # each release
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/notarize.sh
  ```

  `notarize.sh` builds with the Developer ID, notarizes and staples the app, builds and
  signs the DMG, notarizes and staples it too, and checks both with Gatekeeper.
  `NOTARY_PROFILE` names the stored credentials (default `Waverly`).

## How it works

```
┌───────────────────────── Waverly.app (Swift, menu bar only) ─────────────────────────┐
│ CameraGate + HandGate ── frames (shared-memory ring) ──▶ hud-engine (Python)         │
│   closed: a few frames a second,                         MediaPipe: hands, face,     │
│   Apple Vision only when something moves                 pose; gestures.py           │
│   hand seen: 30 fps to the engine                         │ ws /vision               │
│                                                           ▼                          │
│ CoreLink ◀──────────────── ws /ws ──────────────── hud-core (Python, aiohttp,        │
│   show / hide, camera rate                          127.0.0.1:47780): weather,       │
│                                                     Google, word & fact, config      │
│ Overlay panel + WKWebView ◀──── http + ws /ws ──── (hud-core serves the page)        │
│   the page (hud/ui): cards, sky, parallax                                            │
│ Setup, Settings, Google sign-in, shortcut (event tap), HelperSupervisor              │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

- **Waverly.app** (Swift) owns the camera, the menu bar item, the overlay, the setup
  and Settings windows, Google sign-in and `config.json`. It runs the two Python
  helpers from its own environment and restarts them if they exit.
- **hud-core** (`hud/python/hud/core.py`) serves the page, fetches the weather, Google
  Calendar and Tasks, and the word and fact of the day, and relays messages between
  the engine, the page and the app.
- **hud-engine** (`hud/python/hud/engine.py`) reads camera frames from the shared-memory
  ring, runs MediaPipe and turns hand movement into gestures. It owns the dashboard's
  state (asleep, waking, awake, sleeping); the app carries out its show and hide
  requests.
- **The page** (`hud/ui`) draws the cards and the sky in a full-screen panel above
  every window, full-screen apps, the menu bar and the Dock.

**Idle power.** While Waverly is closed, MediaPipe does not run. The app looks at a few
frames a second: a dark or unchanged picture ends the check at once, and only when
something moves does Apple's on-device hand detector (Vision) look for a hand. A
clearly visible hand switches the camera to full rate and hands the frames to the
engine, which lets go again within about 1.5 seconds once the hand is still or gone.
While you type, no hand detection runs. On battery or in Low Power Mode the camera
pauses while the display sleeps, and it always pauses while the screen is locked, the
Mac sleeps or another user is active. `scripts/power_bench.sh` measures what a running
copy costs.

## Project layout

```
Waverly.xcodeproj        Xcode project (generated by scripts/gen_xcodeproj.py)
macos/
  Sources/               the Swift app (AppDelegate, CameraGate, HandGate, PowerPolicy, Hotkeys,
                         Shortcut, OverlayWindow, OnboardingWindow, SettingsWindow, GoogleAuth,
                         LocationService, ConfigStore, HelperSupervisor, PythonSetup, ...)
  Config/                Info.plist, Waverly.entitlements, Waverly.xcconfig,
                         Secrets.example.xcconfig, AppIcon.icns, menu bar icon
  Config/Licenses/       third-party licence texts shipped in Waverly.app/Contents/Resources/Licenses
hud/                     the runtime, bundled into Waverly.app/Contents/Resources/hud
  python/hud/            core.py, engine.py, gestures.py, handfeatures.py, gcal.py, common.py, framering.py
  ui/                    the page: index.html, style.css, app.js, sky.js, fonts/
  models/                MediaPipe models
  tests/                 test_*.py: gestures, hud-core, frame ring, engine settings, the page (headless Chrome), ...
  tools/                 setup_macos.sh (first-run environment), replay_video.py, fake_app.py, fake_camera.py
LICENSE                  Waverly's licence (MIT)
THIRD_PARTY_NOTICES.md   what Waverly includes or downloads, and under which licences
design/icon/             AppIcon.svg, AppIcon.icns, AppIcon-1024.png, MenuBarIcon.svg/.png/@2x.png
docs/                    the website (deployed to Vercel from this folder): index.html, privacy.html, 404.html, vercel.json, assets/
scripts/                 build.sh, fetch_uv.sh, make_dmg.sh, notarize.sh, verify.sh, make_icons.sh,
                         power_bench.sh, gen_xcodeproj.py, make_dmg_background.swift
```

## Tests

```sh
scripts/verify.sh [path/to/Waverly.app]     # default: build/Waverly.app
```

`verify.sh` checks the signature, that the bundled runtime matches `hud/` and that the
licence texts are bundled, runs the gesture-engine, hud-core and frame-ring tests
against the code inside the bundle, and replays the
calibration clips through MediaPipe when they are present (`hud/calibration/` is
private and not in the repository). It uses the app's Python environment, so open
Waverly once first.

To run the tests directly with that environment:

```sh
PY="$HOME/Library/Application Support/Waverly/venv/bin/python"
cd hud
"$PY" tests/test_gestures.py
"$PY" tests/test_core_lists.py
"$PY" tests/test_framering.py
for t in tests/test_*.py; do "$PY" "$t" | tail -1; done             # all of them (the page tests need Google Chrome)
HUD_MODELS="$PWD/models" "$PY" tools/replay_video.py path/to/clip.mov   # gestures in a recorded clip
```

`tools/fake_app.py` and `tools/fake_camera.py` stand in for the Swift app's side of the
protocol (see their docstrings).

## Developer switches

All off by default. Pass them as launch arguments, for example
`open -n build/Waverly.app --args -HUDDebugSocket /tmp/waverly.sock`.

| Switch | Effect |
|---|---|
| `-HUDDebugSocket PATH` | a control socket (mode 0600) taking one command per connection: `status`, `config`, `onboard-skip [name]`, `wizard [env]`, `settings [tab]`, `set <key> <value>` (a setting, e.g. `set theme dark`, `set close_animation_s instant` or `set hotkey default`), `hotkey-test <key code> [mods]`, `installer`, `install`, `permissions`, `location [refresh]`, `place <city>`, `google`, `menu <title>`, `js <code>`, `snapshot <png>`, `window-snapshot <title> <png>`, `show`, `hide`, `quit` (see `macos/Sources/DebugControl.swift`) |
| `-HUDTestVideo PATH` (`-HUDTestVideoDelay S`, `-HUDTestVideoLoop YES`) | play a video file instead of the camera |
| `-HUDVerboseGate YES` | log every idle-mode hand-detector decision |
| `-HUDPageQuery "mac=1&demo=1"` | the page's URL query: `mac` (Mac layout), `demo` (sample data), `awake=1` or `0`, `phase=dawn`/`day`/`dusk`/`night`, `wx=<kind>` and `lvl=<n>` (weather), `debug` |
| `-HUDShowOnLaunch YES` | show the overlay as soon as the page loads |
| `-HUDNoHelpers YES` | don't start the Python helpers (run them by hand) |

Talk to the socket with, for example, `echo status | nc -U /tmp/waverly.sock`. While
Waverly runs, the page can be inspected from Safari's Develop menu.

## Troubleshooting

- **Logs:** menu bar icon › **Open logs**, or `~/Library/Logs/Waverly` (`app.log`,
  `core.log`, `engine.log`; each is capped at 2 MB with two older copies). The app also
  logs to Console.app under the subsystem `app.waverly.Waverly`.
- **The shortcut does nothing:** allow Waverly in **System Settings › Privacy &
  Security › Accessibility**.
- **Gestures do nothing:** check that the camera is allowed (**Privacy & Security ›
  Camera**) and not paused from the menu, and that your palm faces the camera.
- **Permissions stop working after installing a build you made yourself:** macOS ties
  permissions to the app's signature, and every ad-hoc signed build looks like a new
  app. Turn Waverly's Camera and Accessibility switches off and on again in System
  Settings (or remove Waverly from the list and add it again).
- **The setup download failed:** the setup window shows what went wrong and offers
  **Try Again**. A proxy or firewall must allow GitHub (for Python) and the Python
  Package Index.
- **Start over:** quit Waverly and delete `~/Library/Application Support/Waverly`
  (settings, Google sign-in, cache and the Python environment; about 380 MB); the next
  launch runs the setup again. `~/Library/Caches/Waverly` and `~/Library/Logs/Waverly`
  can go too.
- **Uninstall:** if Google is connected, first use **Settings › Google › Disconnect**
  (that also revokes Waverly's access at Google; if the app is already gone, remove it at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions)). Then
  quit Waverly, move it to the Trash and delete the folders above plus
  `~/Library/Preferences/app.waverly.Waverly.plist`. `tccutil reset All app.waverly.Waverly`
  clears its Camera and Accessibility permissions.

## Credits

- Hand in the app icon: "hand-palm-fill" from [Phosphor Icons](https://phosphoricons.com) (MIT)
- Type: Bricolage Grotesque and Newsreader (SIL Open Font License 1.1)
- Hand tracking: [MediaPipe](https://github.com/google-ai-edge/mediapipe) (Apache 2.0) and Apple Vision
- Weather data by [Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0)
- Word of the day: Merriam-Webster. Fact of the day: Wikipedia
- First-run environment: [uv](https://github.com/astral-sh/uv) by Astral

Full notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Waverly is released under the [MIT License](LICENSE). Copyright (c) 2026 LurpDaDerp.

The parts of other projects that Waverly includes (the Phosphor icon glyph, the
MediaPipe models, the fonts and uv) keep their own licences; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Their licence texts also ship inside
the app, in `Waverly.app/Contents/Resources/Licenses`.
