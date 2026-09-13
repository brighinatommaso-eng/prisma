# Prisma

> ## ⚠️ The backend has no authentication — never expose it to the internet
>
> The backend in [`backend/`](backend/) has **no authentication of any kind, by
> design**, and binds `0.0.0.0`. It is intended for a private LAN and Tailscale only.
>
> Do **not** port-forward it, do **not** publish port 8000 through your router,
> and do **not** put it behind a public reverse proxy. Anyone who can reach it
> can queue arbitrary downloads and read the entire library: exposing it
> publishes an open yt-dlp front end running on your hardware.

[![iOS](https://github.com/brighinatommaso-eng/prisma/actions/workflows/ios.yml/badge.svg?branch=main)](https://github.com/brighinatommaso-eng/prisma/actions/workflows/ios.yml)

A private music app for a single iPhone. A self-hosted backend searches YouTube Music
and downloads audio with yt-dlp; a native SwiftUI app keeps the library on the phone
and plays it fully offline. It is sideloaded, never published to the App Store.

The design is in [`2026-09-12-app-musicale-privata-design.md`](2026-09-12-app-musicale-privata-design.md)
(Italian). Its section 9 sets the build order; the project is currently at step 3.

| Step | | State |
|---|---|---|
| 1 | Backend, testable with `curl` | phase 1a deployed: search and yt-dlp extraction |
| 2 | Build pipeline, proven with an empty app | done: CI builds an installable `.ipa`, verified on device |
| 3 | Functional app, rough UI | in progress: read-only Settings, Search and Library tabs; no downloads or playback yet |

## Repository layout

| Path | What it is |
|---|---|
| [`backend/`](backend/) | FastAPI service run with Docker on a home server. Deploy guide in [`backend/README.md`](backend/README.md). |
| [`docker-compose.yml`](docker-compose.yml) | Runs the backend. |
| [`ios/`](ios/) | Xcode project for the iOS app: one SwiftUI target, no dependencies. |
| [`ios/BUILD.md`](ios/BUILD.md) | How to get the app onto an iPhone from Windows. |
| [`.github/workflows/ios.yml`](.github/workflows/ios.yml) | Builds the unsigned `.ipa` on a macOS runner. |

## Building the iOS app

There is no Mac in this project. Xcode only runs on macOS, so the app is built by
GitHub Actions and signed afterwards on Windows.

- **Every push to `main`** runs the [iOS workflow](https://github.com/brighinatommaso-eng/prisma/actions/workflows/ios.yml).
  To build without pushing, open that page and use **Run workflow**.
- The workflow builds unsigned (`CODE_SIGNING_ALLOWED=NO`), packages
  `Payload/Prisma.app` into `Prisma.ipa`, and uploads it as an artifact of the run.
- Before uploading, it unpacks the `.ipa` and fails if the bundle id, minimum iOS
  version (26.0), build number or commit SHA are not what they should be. A green run
  means the file is installable, not only that it compiled.
- The build number is the workflow run number and the commit is the short SHA. Both
  are shown at the bottom of the app's Settings tab, so you can confirm the build on
  the phone is the one you just made.

**When a build fails**, read the run page from the bottom up. The *Summarise build
errors* step lists every compiler error with file and line, and each appears as an
annotation at the top of the run. The complete raw output is in the `xcodebuild-log`
artifact.

**Toolchain.** The runner image and Xcode are pinned (`macos-26`, Xcode 26.6), because
a silent upgrade that breaks the build cannot be diagnosed without a Mac. The spec says
`macos-15`, but that image stops at Xcode 26.3 and will be retired first. To move to a
newer Xcode, check the
[runner image's software list](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
and change `XCODE_VERSION` and `DEVELOPER_DIR` together at the top of the job.

**Adding source files.** `ios/Prisma/` is a synchronised folder: any `.swift` file
placed there is compiled with no change to `project.pbxproj`. Build settings still
live in the project file.

## The app today

Three tabs, in plain SwiftUI with no styling yet. Every request error is shown in
full on screen (URL, error code, server response), because there is no debugger or
console on the device.

| Tab | What it does |
|---|---|
| **Settings** | Opens first. Stores the backend address on the phone and tests it against `/health`. At the bottom it shows the app's version, build number and commit. |
| **Search** | Searches YouTube Music through the backend: title, artist, album, duration and a thumbnail per result. |
| **Library** | Shows the backend's catalogue, albums with covers and their tracks. Pull down to reload. |

Nothing is downloaded or played yet, and nothing except the server address is stored
on the phone.

## Installing on the iPhone

Download `Prisma.ipa` from a green run, sign it with a free Apple ID in Sideloadly, and
install it over USB. SideStore then re-signs it over Wi-Fi before the 7-day
certificate runs out. The full procedure, including limits and troubleshooting, is in
**[`ios/BUILD.md`](ios/BUILD.md)**.

The app needs iOS 26.0 or later, because the interface depends on Liquid Glass APIs
that do not exist earlier.

## This repository is public

macOS runner minutes are free only for public repositories. Nothing secret belongs
here: no server addresses, no credentials, no signing material. Signing happens on
your own machine, never in CI. Server addresses in the docs are placeholders such as
`YOUR_SERVER_IP`, and real values live in untracked `.env` files.
