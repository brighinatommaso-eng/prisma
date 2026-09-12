# Installing Prisma on an iPhone, from Windows

This takes an unsigned `Prisma.ipa` built by GitHub Actions and puts it on the iPhone
with nothing but a Windows PC, a USB cable and a free Apple ID. No Mac is involved at
any point.

There are two stages. **Stage 1** installs the app once with Sideloadly over the cable.
That proves the whole chain works. **Stage 2** sets up SideStore on the phone, which
re-signs Prisma over Wi-Fi so it keeps opening after the 7-day free certificate runs out.

Do stage 1 first, and stage 2 the same day while the app is still empty (see
[Why hand over while the app is empty](#why-hand-over-while-the-app-is-empty)).

---

## What you need

| | |
|---|---|
| iPhone | iOS **26.0 or later** with a passcode set. The app will not install on anything older. |
| PC | Windows 10 or 11, 64-bit. |
| Cable | USB cable that carries data, not only charge. |
| Apple ID | A free one works. You can use your main Apple ID or a separate one made for sideloading. Use **the same one** in Sideloadly and SideStore throughout, because both tools share its limits. |
| GitHub | Signed in to github.com. GitHub only lets signed-in users download artifacts, even from a public repository. |

### The free Apple ID limits

These come from Apple and apply per Apple ID, whichever tool does the signing.

| Limit | What it means here |
|---|---|
| **7-day certificate** | A signed app stops opening 7 days after it was signed. SideStore re-signs it before then. If the phone is off Wi-Fi for longer than that, the app will not open until you refresh it. |
| **3 active apps** | At most 3 apps signed with the Apple ID can be installed at once, **SideStore included**. With SideStore and Prisma installed, one slot is left. |
| **10 App IDs per 7 days** | Each *new* bundle identifier you sign uses one, for a rolling 7 days. Re-signing or updating an app you already have does not use a new one. Deleting an app does not give its App ID back. |

---

## Stage 1 — Install with Sideloadly

### 1.1 One-time PC setup

1. **Install the web versions of iTunes and iCloud, not the Microsoft Store versions.**
   Sideloadly needs Apple's device drivers, and these installers provide them. If the
   Microsoft Store versions are installed, uninstall them first. The download links are
   at the bottom of [sideloadly.io](https://sideloadly.io/).
2. Install **Sideloadly for Windows** from [sideloadly.io](https://sideloadly.io/).
   Download it only from that site.
3. Connect the iPhone by cable and unlock it. When the phone asks
   **Trust This Computer?**, tap **Trust** and enter the passcode.
4. Open iTunes once and check that the iPhone appears. If it does not, Sideloadly
   will not see it either: fix the cable or drivers first.

### 1.2 Download the build

1. Open the [iOS workflow runs](https://github.com/brighinatommaso-eng/prisma/actions/workflows/ios.yml).
2. Click the newest run with a **green tick** on branch `main`. The run title shows its
   run number, for example `#7`.
3. The run's **summary** shows a *Prisma.ipa* table with Version, Build and Commit.
   Write down **Build** and **Commit**: you will check them on the phone.
4. Scroll to **Artifacts** at the bottom of the summary and download **`Prisma.ipa`**.
   It downloads as the `.ipa` itself, not a zip. There is also an `xcodebuild-log`
   artifact, which you only need when a build fails.

Artifacts are kept for 30 days. To get an older build, re-run its workflow or push a
new commit.

### 1.3 Sign and install

1. Open Sideloadly with the iPhone connected and unlocked.
2. Check that your iPhone is selected in the **iDevice** field.
3. Enter your Apple ID in the **Apple account** field.
4. Drag `Prisma.ipa` onto the IPA icon on the left of the window.
5. Leave the **Advanced options** at their defaults.
6. Click **Start**. Enter your Apple ID password when asked, and the two-factor code
   if Apple sends one. Sideloadly sends these to Apple to create the free signing
   certificate; they do not go into this project.
7. Wait for **Done.** in the log at the bottom of the window. The Prisma icon appears
   on the phone.

### 1.4 First launch on the iPhone

The first time an app signed with your Apple ID is installed, iOS blocks it until you
approve it. Both steps are one-time for each Apple ID on the phone.

1. **Trust the developer.** Settings → General → **VPN & Device Management** → under
   *Developer App*, tap your Apple ID → **Trust "…"** → **Trust**. Enter the passcode
   if asked.
2. **Turn on Developer Mode.** Settings → **Privacy & Security** → scroll to the bottom
   → **Developer Mode** → on → **Restart**. After the restart, unlock the phone and
   tap **Turn On** in the prompt that appears, then enter the passcode.
   The Developer Mode entry only appears once a developer-signed app is installed,
   so do step 1.3 first.
3. Open **Prisma**. The screen lists **Version**, **Build** and **Commit**.

**Check the build.** *Build* must equal the run number and *Commit* the short SHA you
wrote down in 1.2. If they match, the pipeline works end to end: this is the build you
just made. If *Commit* says `local`, the app was built outside CI. If it says
`unknown`, the SHA was not injected, and the workflow should have failed its
*Verify Prisma.ipa* step.

---

## Stage 2 — SideStore, for the weekly refresh

A free certificate lasts 7 days. Rather than reconnecting the cable every week,
SideStore runs on the phone and re-signs apps over Wi-Fi. It does this by talking to
the phone through a local on-device VPN, **LocalDevVPN**, using a *pairing file*
created once over the cable.

SideStore's own documentation installs it with **iloader**, not Sideloadly, because
iloader also places the pairing file. This guide follows that. The steps below were
checked against [docs.sidestore.io](https://docs.sidestore.io/docs/installation/prerequisites)
in September 2026. If something on screen differs, their docs win.

### 2.1 Install SideStore (PC, cable)

1. On the iPhone, install **LocalDevVPN** from the App Store.
2. On the PC, download the Windows installer (`.msi`) of **iloader** from its
   [GitHub releases](https://github.com/nab138/iloader/releases/latest) and install it.
   It relies on the iTunes you installed in 1.1.
3. Connect and unlock the iPhone, then open iloader.
4. Sign in with **the same Apple ID** you used in Sideloadly. iloader treats it as
   case-sensitive, so type it exactly as registered.
5. Select your iPhone and choose **Install SideStore (Stable)**. Wait for it to finish.
   This is the step that writes the pairing file.

### 2.2 First SideStore launch (iPhone)

1. Open **LocalDevVPN** and turn it on. Allow the VPN configuration when iOS asks.
2. Settings → General → VPN & Device Management: SideStore is signed with the same
   Apple ID, so it should already be trusted from 1.4. If it shows as untrusted, trust
   it again.
3. Open **SideStore** and sign in with the same Apple ID.
4. Go to **My Apps** and tap the **7 DAYS** counter under SideStore to refresh it once.
   If that succeeds, SideStore can sign on the phone by itself.

### 2.3 Hand Prisma over to SideStore

SideStore only refreshes apps in its own list. An app installed by Sideloadly is not
in it until you install it again through SideStore.

1. Put `Prisma.ipa` on the iPhone: download it from the run page in Safari on the
   phone (signed in to GitHub), or copy it into the Files app. Keep it in
   **On My iPhone** or iCloud Drive.
2. Make sure LocalDevVPN is on.
3. Open SideStore → **My Apps** → **+** → pick `Prisma.ipa`.
4. **Keep the Sideloadly-installed Prisma on the phone while doing this.** SideStore's
   FAQ says installing the same app over an existing one adds it to SideStore's list.
5. Prisma now appears under My Apps with its own day counter. Open it and check
   *Build* and *Commit* again.

If you end up with **two Prisma icons**, SideStore installed it under a different
bundle identifier (free-account signers can append the team ID). Delete the older
icon, the one Sideloadly installed. Keep the one listed in SideStore. Because of the
3-app limit, check that you have not reached it before you install anything else.

#### Why hand over while the app is empty

Two installs with different bundle identifiers are two separate apps with separate
storage. Once Prisma holds a downloaded music library, moving to a differently
identified copy would lose that library. Today the app stores nothing, so switching
costs nothing.

### 2.4 Keeping it alive

- **Refresh.** SideStore refreshes apps when you open it and tap the day counters, or
  use **Refresh All** in My Apps. Both need Wi-Fi and LocalDevVPN turned on. Open
  SideStore at least once a week. It shows how many days each app has left.
- **The pairing file.** An iOS update or a device reset can invalidate it. If SideStore
  starts failing to refresh after an update, connect the cable and run iloader again.
  Its pairing-file options are described in SideStore's
  [pairing file guide](https://docs.sidestore.io/docs/advanced/pairing-file).
- **If the 7 days run out anyway**, Prisma and possibly SideStore will not open. Your
  data is not deleted. Refresh from SideStore if it still opens. Otherwise reinstall
  SideStore with iloader (2.1), then refresh Prisma.

---

## Installing a newer build

Push to `main`, wait for a green run, download its `Prisma.ipa`, then:

- **Usual path:** SideStore → My Apps → **+** → pick the new `Prisma.ipa`. It installs
  over the existing Prisma, keeping its data and the same App ID.
- **With the cable instead:** Sideloadly as in 1.3. Only do this before stage 2. Once
  SideStore manages Prisma, always update through SideStore, so you stay on the same
  bundle identifier and keep the data.

After updating, open Prisma and check that *Build* shows the new run number.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No green run, or no `Prisma.ipa` artifact | The build failed. Open the run and read the **Summarise build errors** step and the annotations at the top of the run. Full output is in the `xcodebuild-log` artifact. |
| Artifact list is empty or the download link is missing | You are not signed in to GitHub, or the artifact is older than 30 days and has expired. |
| Sideloadly does not list the iPhone | Microsoft Store iTunes is installed instead of the web version, the phone is locked, or *Trust This Computer* was dismissed. Also try another cable. |
| *"The maximum number of apps for free development profiles has been reached."* | 3 apps signed with this Apple ID are already installed. Delete one you do not need, then retry. |
| *"Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days."* | Too many new bundle identifiers this week. Wait until the oldest one is 7 days old. Updating existing apps still works. |
| *Untrusted Developer* when opening Prisma | Step 1.4, part 1. |
| Prisma closes immediately, or iOS says Developer Mode is required | Step 1.4, part 2. |
| Install fails with a message about the iOS version | The iPhone is below iOS 26.0. Update iOS. |
| Prisma opened last week but not today | The 7-day certificate expired. See 2.4. |
| SideStore refresh fails | Check LocalDevVPN is on and the phone is on Wi-Fi. If it still fails after an iOS update, regenerate the pairing file (2.4). |
| *Build* or *Commit* on the phone do not match the run | You installed an older `.ipa`. Browsers keep earlier downloads as `Prisma (1).ipa` and similar. Delete old copies and download again. |
