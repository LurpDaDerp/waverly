# Third-party notices

Waverly itself is released under the MIT License ([LICENSE](LICENSE), Copyright (c)
2026 LurpDaDerp). It is built on the work of others. This file lists what the app and
its website include or download, under which licence, and the notices those licences
ask for.

Inside the app, `Waverly.app/Contents/Resources/Licenses/` holds the full licence text
of everything the app ships: `LICENSE` (Waverly), `LICENSE-Phosphor.txt`,
`NOTICE-MediaPipe-models.txt` (with the Apache License 2.0), `OFL-Bricolage.txt`,
`OFL-Newsreader.txt`, and with the bundled uv `LICENSE-uv-APACHE.txt` and
`LICENSE-uv-MIT.txt`. In this repository they are in `macos/Config/Licenses/`, except
`LICENSE` (the repository root) and the font licences (`hud/ui/fonts/`).

## Shipped inside Waverly.app

### Phosphor Icons: "hand-palm-fill"

The open hand in the app icon and the menu bar icon (`design/icon/`), and in the
website's icons and menu bar illustration (`docs/`), is the "hand-palm-fill" glyph
from [Phosphor Icons](https://phosphoricons.com), rotated, recoloured and combined
with original artwork (the sky and the motion trail). The
same notice ships inside the app as `Contents/Resources/Licenses/LICENSE-Phosphor.txt`
(source: `macos/Config/Licenses/LICENSE-Phosphor.txt`).

```
MIT License

Copyright (c) 2023 Phosphor Icons

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Fonts: Bricolage Grotesque and Newsreader

Used by the dashboard, the app's windows and the website. Both are licensed under the
[SIL Open Font License, Version 1.1](https://openfontlicense.org). The full licence
texts travel with the font files: `hud/ui/fonts/OFL-Bricolage.txt` and
`hud/ui/fonts/OFL-Newsreader.txt` (also `docs/assets/fonts/` for the website, and
`Contents/Resources/Licenses/` in the app).

- Bricolage Grotesque: Copyright 2022 The Bricolage Grotesque Project Authors
  (https://github.com/ateliertriay/bricolage)
- Newsreader: Copyright 2020 The Newsreader Project Authors
  (http://github.com/productiontype/Newsreader)

The website uses subsets of the same fonts (Latin, WOFF2).

### MediaPipe models

`hud/models/` holds three models from Google's
[MediaPipe](https://github.com/google-ai-edge/mediapipe): `gesture_recognizer.task`
(hand landmarks and gestures), `blaze_face_short_range.tflite` (face detection) and
`pose_landmarker_lite.task` (pose), unmodified. Copyright Google LLC, licensed under
the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0). The app
ships this notice with the full licence text as
`Contents/Resources/Licenses/NOTICE-MediaPipe-models.txt` (source:
`macos/Config/Licenses/NOTICE-MediaPipe-models.txt`).

### uv

Release builds include the [uv](https://github.com/astral-sh/uv) 0.13.8 binary
(`Waverly.app/Contents/Helpers/uv`, fetched by `scripts/fetch_uv.sh`), which sets up
the hand-tracking environment on first launch. Copyright (c) 2025 Astral Software Inc.,
licensed under either the [Apache License, Version 2.0](https://github.com/astral-sh/uv/blob/0.13.8/LICENSE-APACHE)
or the [MIT License](https://github.com/astral-sh/uv/blob/0.13.8/LICENSE-MIT), at your
option. Both texts ship with it as `Contents/Resources/Licenses/LICENSE-uv-APACHE.txt`
and `LICENSE-uv-MIT.txt` (source: `macos/Config/Licenses/`, from the uv 0.13.8 release
tag; the release archive itself holds only the binaries).

## Downloaded on first launch

These are not part of the app or this repository. Waverly's setup downloads them once
into `~/Library/Application Support/Waverly/venv`, from their usual public sources,
under their own licences.

| Component | Licence | Source |
|---|---|---|
| Python 3.12 (installed by uv) | Python Software Foundation License | [python-build-standalone](https://github.com/astral-sh/python-build-standalone) |
| mediapipe | Apache-2.0 | PyPI |
| opencv-contrib-python (required by mediapipe) | Apache-2.0 (OpenCV); MIT (packaging) | PyPI |
| numpy | BSD-3-Clause (bundled parts: 0BSD, MIT, Zlib, CC0-1.0) | PyPI |
| aiohttp | Apache-2.0 (with MIT-licensed parts) | PyPI |

Their own dependencies come along with them, each under its licence (for example
absl-py, flatbuffers, matplotlib, sounddevice, attrs, multidict, yarl, frozenlist and
certifi). The installed packages' licences can be read in each package's
`*.dist-info` folder inside the environment.

## Data and content shown in the dashboard

Waverly fetches these at run time and shows them to you on your Mac; it does not
redistribute them. Waverly is not affiliated with or endorsed by any of these providers.

- **Weather:** [Open-Meteo.com](https://open-meteo.com/). Weather data by Open-Meteo.com,
  licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **Word of the day:** Merriam-Webster's public Word of the Day feed. The word, its
  pronunciation and definition are © Merriam-Webster, Incorporated.
- **Fact of the day:** Wikipedia's "Did you know" (English Wikipedia's featured-content
  feed). Wikipedia text is available under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); the dashboard credits
  Wikipedia next to each fact. When Wikipedia can't be reached, the fact comes from
  [uselessfacts.jsph.pl](https://uselessfacts.jsph.pl).
- **Calendar and tasks:** your own data, read from the Google Calendar API and the
  Google Tasks API with your permission. Google, Google Calendar and Google Tasks are
  trademarks of Google LLC.

Apple, Mac, macOS and Apple silicon are trademarks of Apple Inc. Waverly uses Apple's
system frameworks (such as Vision, AVFoundation, Core Location and MapKit) as provided
by macOS.
