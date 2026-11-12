# QuikCal

**QuikCal is a small macOS app that lives in your menu bar. You type (or say) a short note about a meeting, QuikCal turns it into an event you can edit, and only writes it to your calendar after you press the add button.**

Nothing is saved to your calendar automatically. Every event is shown to you first, and you decide.

- **Everyday users:** read [Part 1](#part-1--install-quikcal-on-your-mac) → [Part 2](#part-2--the-five-step-setup-walkthrough) → [Part 4](#part-4--using-quikcal-every-day). That is all you need.
- **Developers:** jump to [Part 9](#part-9--for-developers).

---

## At a glance

| | |
|---|---|
| **What it is** | A native macOS menu-bar app (no Dock icon) that turns typed or spoken notes into calendar events. |
| **Runs on** | macOS 14 (Sonoma) or newer. |
| **Optional upgrade** | macOS 26 or newer on an Apple-Intelligence-capable Mac unlocks on-device AI extraction. Everything still works without it. |
| **Where events go** | A calendar on your Mac (including your iCloud calendars) **or** a Google Calendar — you pick one, never both. |
| **What leaves your Mac** | Network traffic is used for Google Calendar, speech-model downloads, and update checks; Mac calendars can also sync through your calendar provider. See [Part 8](#part-8--privacy-safety-and-what-leaves-your-mac). |
| **Latest published version** | 0.3.22 — see [Step 1: Download the app](#step-1-download-the-app). |
| **Cost** | Free. The source is published here — see [Licensing](#licensing) for the licence position. |

---

## Part 1 — Install QuikCal on your Mac

### What you need first

| Requirement | Why | Required? |
|---|---|---|
| A Mac running **macOS 14 (Sonoma) or newer** | The app is built for macOS 14+ | **Yes** |
| About **7 MB** to download | The `.dmg` installer is ~6.5 MB; the installed app is larger because it bundles a local speech-recognition helper and the update framework | **Yes** |
| About **750 MB** of free disk space | The optional speech model, only if you want to talk to it | Optional |
| A writable calendar | Events need somewhere to go | **Yes** (a local Mac calendar works; iCloud and Google also work) |
| An internet connection | Needed for downloading the app, Google Calendar, the optional speech model, and update checks. **Typing and saving to an available local Mac calendar work offline.** | Optional |
| Apple Intelligence, macOS 26+, eligible Mac | Smarter text extraction | Optional — see below |

**About Apple Intelligence (optional).** On newer Macs with Apple Intelligence turned on, QuikCal asks macOS's own on-device language model to read your note. On every other Mac, QuikCal uses its own built-in English parser, which understands the common ways people write dates and times. Both paths show you the same editable draft, and both require your confirmation. macOS manages the Apple model — QuikCal never downloads a text model.

### Step 1: Download the app

1. Open the **Releases** page: <https://github.com/bootsphotography1-beep/QuikCal/releases>
2. Find the newest release (at the time of writing: **QuikCal 0.3.22**).
3. Under **Assets**, download **`QuikCal-0.3.22.dmg`** (about 6.5 MB).

   Direct link: <https://github.com/bootsphotography1-beep/QuikCal/releases/download/v0.3.22/QuikCal-0.3.22.dmg>

**Which asset do I want?** A release contains three files and you only need one:

| File | Size | What it is | Do you want it? |
|---|---|---|---|
| `QuikCal-0.3.22.dmg` | ~6.5 MB | The disk image you double-click to install the app | **Yes — this one** |
| `QuikCal-0.3.22.zip` | ~5.5 MB | The automatic-update package used by the in-app updater | No |
| `appcast.xml` | ~2 KB | The update-feed description the app reads | No |

The `.dmg` filename contains the version number, so a newer release has a newer name. Always get it from the Releases page rather than from a bookmarked link.

### Step 2: Open the disk image

1. Find `QuikCal-0.3.22.dmg` in your **Downloads** folder and double-click it.
2. macOS mounts it like a USB stick: a window appears showing **QuikCal.app** and an **Applications** shortcut.
3. **Nothing starts automatically.** Opening the disk image does not launch the app — you drag it across first (next step).

### Step 3: Move QuikCal into Applications

1. Drag **QuikCal.app** onto the **Applications** shortcut in the disk-image window.
2. Wait for the copy to finish. macOS may ask for your password or Touch ID.
3. Eject the disk image using the eject button next to it in the Finder sidebar.
4. Open your **Applications** folder. Always launch the installed copy from here, rather than from the disk image, so permissions apply to the copy you will keep using.

### Step 4: Launch it for the first time

1. In **Applications**, double-click **QuikCal**. If macOS blocks it, follow Step 5 below, then return here.
2. Look in the **menu bar at the top-right of your screen**, near the clock, battery and Wi-Fi icons. QuikCal shows a small **calendar-with-a-plus** icon and has **no Dock icon**.
3. The **setup window opens automatically** on first launch, starting with a short setup card — click **Start Setup** to begin. Continue with [Part 2](#part-2--the-five-step-setup-walkthrough).

If you cannot see the icon, switch to Finder so fewer app menus occupy the menu bar. On a Mac with a camera notch, some icons may not fit. If you use a menu-bar organizer, check its hidden icons. You can also reopen QuikCal from Applications: setup opens if unfinished, or Settings opens after setup.

### Step 5: If macOS says it cannot open the app

The current release is signed with a **development certificate** and is **not notarized** by Apple. macOS may say the developer cannot be verified or Apple cannot check the app for malicious software. Only continue if you downloaded it from this repository and trust the source.

On newer macOS versions, use the per-app exception in System Settings:

1. Attempt to open **QuikCal in Applications** once, then dismiss the warning.
2. Open **Apple menu → System Settings → Privacy & Security**.
3. Scroll to the **Security** section. Look for a message that QuikCal was blocked, then click **Open Anyway**, if available.
4. Authenticate with your password or Touch ID if asked, then confirm **Open**.

On older macOS versions, **Control-click QuikCal in Applications → Open** may offer the same one-time exception. If it does not, use the System Settings steps above. A managed work or school Mac may prevent overrides; contact its administrator if the option is unavailable.

If macOS says the app **is damaged** or **will harm your computer**, stop instead of bypassing that warning. Delete that downloaded copy, download again from the Releases page, and report the problem if it persists.

You do not need to disable Gatekeeper or System Integrity Protection, or run Terminal commands to remove quarantine. After opening successfully, return to Step 4 and continue setup.

**How QuikCal behaves after setup (worth knowing now):**

| You do this | You get this |
|---|---|
| Open QuikCal from Applications when it is not running | It starts quietly and shows **only the menu-bar icon** |
| Click the menu-bar icon | The **capture bar** appears (see [Part 4](#part-4--using-quikcal-every-day)) |
| Right-click (or Control-click) the menu-bar icon | A small menu with **Start/Replay Setup…**, **Settings…**, **Check for Updates…** and **Quit QuikCal** |
| Open QuikCal from Applications or Spotlight while it is already running | The **Settings** window opens |
| Quit and reopen later | The menu-bar icon is back — your settings are remembered |

---

## Part 2 — The five-step setup walkthrough

The setup window has five short pages. You can leave and come back: if you stop halfway, the next launch first shows a short card — click **Resume Setup** to continue exactly where you stopped, or **Open Settings** to finish in Settings instead.

### Setup page 1 — Welcome

A short introduction. Click **Get started**.

### Setup page 2 — Calendar (where your events should go)

This is the most important page, because it decides where your events are saved.

1. Pick a **destination**:
   - **Mac calendars (EventKit)** — any calendar on your Mac, including your **iCloud** calendars if you are signed into iCloud in System Settings → Apple ID. Choose this if you want QuikCal to behave exactly like Apple Calendar.
   - **Google** — sign in with a Google account and pick a Google Calendar. See [Google Calendar](#google-calendar) below.
2. For **Mac calendars**, click **Connect calendar**. macOS will ask for permission to access your calendars ("QuikCal needs calendar access so you can pick a writable calendar and add events you explicitly confirm"). Click **OK**. Your writable calendars then appear in a list on the same page — click the one you want. A tick mark appears next to your choice.
3. If macOS grants QuikCal only limited ("add-only") access, QuikCal says so honestly: events go to your default calendar, and you can grant fuller access and pick a specific calendar later in **Settings → Calendars & Accounts**.
4. If you skip this page, QuikCal will not know where to put events, and the add button stays disabled. You can finish it later in **Settings → Calendars & Accounts**.

> You only ever need **one** destination. QuikCal writes to Mac calendars **or** Google, never to both at once.

### Setup page 3 — Permissions (only needed for talking to QuikCal)

QuikCal can capture your voice. To do that it needs macOS to allow it to see your key press. This page explains exactly which permission your chosen shortcut needs and offers a button that opens the right System Settings pane.

- **If you chose Fn (Globe) as the hold-to-talk key** → you need **Input Monitoring**.
- **If you chose Option, Command or Control** → you need **Accessibility** (Input Monitoring also works for these).

The page offers **Set up voice later**, and skipping is genuinely fine: **typing always works**, and you can grant the permission later in **Settings → General**. Choosing it skips the remaining voice steps and lands on the final page.

Details for every permission are in [Part 3](#part-3--permissions-explained).

### Setup page 4 — Voice setup (optional)

This page offers **one** action: **Download** the speech model.

- The model is about **731 MB** and comes from a pinned, public source. QuikCal verifies it against a checksum before using it.
- **You can skip this.** If you skip, QuikCal still works — you just type instead of talk.
- The model is **not** inside the `.dmg`; downloading it is a separate, explicit step.
- Nothing here is Apple Speech and nothing is sent to a cloud service. The audio never leaves your Mac.

This page also has a short **practice** step where you can try holding your shortcut and saying a sentence. Practice is **parse-only**: it never writes anything to your calendar.

### Setup page 5 — Ready

A short summary and an **Open QuikCal** button. When you finish, QuikCal shows a small **hint anchored to the real menu-bar icon** explaining that a left-click captures and a right-click opens Settings. You can replay that hint any time from **Settings → General → Show menu bar hint**. Dismissing it never resets your setup.

---

## Part 3 — Permissions explained

macOS asks for permission separately for each capability. QuikCal only ever asks when it needs the permission, from an explicit button you pressed — it never throws a parade of dialogs at you at launch.

| Permission | When macOS asks | What breaks if you say no |
|---|---|---|
| **Microphone** | The first time you actually capture audio — by pressing the mic button or holding your chosen shortcut. **Never at launch.** | Talking to QuikCal stops working. Typing is unaffected. |
| **Input Monitoring** | Only if your hold-to-talk key is **Fn (Globe)** and you press **Request…** / **Open…**. | Holding Fn cannot be detected. Typing is unaffected. |
| **Accessibility** | Only if your hold-to-talk key is **Option, Command or Control** and you press **Request…**. | Holding that key cannot be detected. Typing is unaffected. |
| **Calendars** | When you pick a calendar to write to. | QuikCal cannot show or add events. |
| **Screen & System Audio Recording** | **Never.** QuikCal has no feature that needs it. | Nothing — it is listed in Settings for completeness only. |

### Why Fn needs Input Monitoring and other keys need Accessibility

The **Fn / Globe** key is a system key: while QuikCal is not the frontmost app, the only way to notice it is a "listen-only" key tap, and macOS gates that behind **Input Monitoring**.

The ordinary modifiers (**Option**, **Command**, **Control**) are delivered by the global event monitor, which macOS gates behind **Accessibility**. The listen-only tap sees those modifiers too, so **Input Monitoring works for them as well**.

### Granting a permission

1. Click the matching **Open…** / **Request…** button in QuikCal (Settings → General, or the setup page).
2. System Settings opens on the right pane.
3. Turn the toggle **on** next to **QuikCal** (or click **Add…** and select the app if it is not listed).
4. **For Input Monitoring: quit and reopen QuikCal.** macOS applies listen-access changes to *newly created* key taps, so an app that was already running may keep missing the key. Quit it from the menu-bar menu (right-click the icon → **Quit**), then open it again from Applications.
5. **For Accessibility:** click **Check again** (or reopen the app) — the permission is normally picked up immediately, and a reopen always works.
6. **For the microphone:** press the mic button or hold your chosen shortcut; macOS shows the prompt; click **OK**. If you clicked **Don't Allow** by mistake, re-enable it in **System Settings → Privacy & Security → Microphone → QuikCal**.

### Taking a permission away

System Settings → Privacy & Security → the matching section → turn **QuikCal** off. QuikCal notices the change and tells you hold-to-talk stopped. Typing keeps working.

### Good to know

- The very first install of a stable-signed QuikCal can require you to **grant Accessibility once more**, because the signing identity changed. Later updates keep your existing grant.
- QuikCal has **no microphone picker**: it always uses the **system default input** (change that in System Settings → Sound → Input).
- QuikCal registers **no login item**, so it does not start when you log in. Open it from Applications when you want it.

---

## Part 4 — Using QuikCal every day

### Capture a typed event (the fastest way)

1. Click the **menu-bar icon** (left-click). A small **capture bar** floats over whatever you were doing — it looks like a Spotlight search box.
2. Click into the text field (it is focused automatically) and type a note. For example:

   ```
   Coffee with Sam tomorrow at 10am
   ```

3. Press the round **arrow button** at the right-hand end of the bar (its tooltip is *"Review what QuikCal understood before anything is saved"*). QuikCal reads the note and shows a **draft card**: a title, a date, a start time, and the calendar it would go into.
4. If QuikCal is unsure whether you meant the morning or the afternoon, a row of time choices appears under the bar (for example **9:00 am** / **3:00 pm**). Tap one and QuikCal re-reads the *same* note with that choice — nothing is saved either way.
5. **Check the card.** The title, location and notes can be edited in place, and the time, duration and reminder can be adjusted. If QuikCal could not work out the time at all, the card says *"Did not resolve yet — fix the time below. Nothing will be added until this is fixed."*
6. Press **Yes, add it**. Only now is anything written to your calendar.
7. The card marks the event as **Added**, and a **Saved** receipt appears underneath, followed by that day's schedule.

Other notes that work well:

```
Dentist appointment on Thursday at 2:30 pm
Team retro next Monday morning
Dinner with Alex on Friday at 7pm, near the station
```

Short, ordinary sentences are best. "Next Monday" and "tomorrow" are resolved against your current date and time zone.

### Capture a spoken event

1. Hold the **Fn (Globe)** key — or whichever key you chose in Settings → General.
2. Keep holding and say your note, for example:

   ```
   Lunch with Dana on Friday at 1 pm
   ```

3. **Release the key.** Recording stops, the words are transcribed locally, and the same editable draft card appears — nothing is saved yet.
4. Review it, then press **Yes, add it**.

You can also press the **microphone button** at the right-hand end of the capture bar and tap it again to stop, if holding a key is awkward for you.

Spoken capture needs all three of: the **speech model** downloaded, the **microphone** permission granted, and a **key permission** (Input Monitoring for Fn, Accessibility for other keys).

### The review step (important)

- The draft always shows **where the event will go** (the calendar name) and, when relevant, a **reminder** and a **location**.
- Nothing is written until you press the add button. Even a spoken *"yes"* never saves anything — only the button does.
- Pressing **No** cancels the draft but **keeps your text**, so you can edit it or speak again.
- If you dismiss the capture bar with **Escape**, the draft is kept for next time and still nothing is written.

### Finding events you already saved

- **Apple Calendar destination:** after adding, the capture bar shows that day's schedule with arrows to move to the **previous** or **next** day, and a **New entry** button.
- **Google Calendar destination:** the receipt includes a **View on Google Calendar** link that opens the event in your browser. The in-app day list is deliberately hidden for Google, because QuikCal does not request read access to your Google calendars just to draw a list.
- **Any destination:** the real calendar is the source of truth — open the **Calendar** app to see everything.
- **QuikCal's own record:** a small local receipt file is kept in your user folder (`~/Library/Application Support/QuietCalendar/`). It is a record of what QuikCal saved, not a second calendar.

### Keyboard and mouse cheat sheet

| Action | How |
|---|---|
| Open the capture bar | Left-click the menu-bar icon |
| Open Settings | Right-click (or Control-click) the menu-bar icon → **Settings…** |
| Check for an update | Right-click the menu-bar icon → **Check for Updates…** |
| Quit QuikCal | Right-click the menu-bar icon → **Quit QuikCal** |
| Replay the setup | Right-click the menu-bar icon → **Replay Setup…**, or Settings → General → **Replay…** |
| Talk to QuikCal | Hold **Fn (Globe)** (or your chosen key), speak, release |
| Parse what you typed | The round **arrow button** at the right of the capture bar |
| Dismiss without saving | **Escape** (your draft is kept) |
| Save the draft | **Yes, add it** |

---

## Part 5 — Settings reference

Open Settings by right-clicking the menu-bar icon → **Settings**, or by opening QuikCal from Applications/Spotlight while it is already running. There are four tabs.

### General

- **Version** — the running version number.
- **Hold-to-talk shortcut** — choose **Fn (Globe)**, **Option**, **Command** or **Control**. The change takes effect immediately.
- **Permission status rows** — the live status of each macOS permission, with **Open…** / **Request…** buttons that jump to the correct System Settings pane, and a **Check again** action.
- **Hold-to-talk setup guide…** — a guided walkthrough with a practice step.
- **Enable hold-to-talk** / **Turn off** — switches the feature on or off without changing permissions.
- **Replay…** — replays the onboarding steps. Your calendar, appearance, shortcut and Google connection are kept.
- **Show menu bar hint** — replays the little menu-bar tip.
- **Check for Updates…** — see [Part 6](#part-6--updating-quikcal).
- **Technical details** (expandable) — a plain-language summary of what the permissions are for, that typing still works if a permission is denied, and that launches-at-login is not offered yet.

### Calendars & Accounts

- A switch between **Mac calendars (EventKit)** and **Google**.
- **Mac calendars:** **Choose EventKit calendar…**, then pick from your writable calendars. The status line tells you the truth — *Not configured*, *Permission denied*, *No calendar selected*, or *Connected — add events only* when macOS grants add-only access.
- **Google:** **Sign in with Google…**, your connected accounts, the **target calendar** (only calendars Google reports as writable are listed), and **Import Google configuration…** (see below).

#### Google Calendar

- The released build ships a **public** Google "Desktop app" OAuth client ID inside the app. That client ID is public by design and contains **no secret**. When you click **Sign in with Google…**, macOS opens your browser, you choose an account and approve access, and the app returns via a local `127.0.0.1` callback.
- Your Google tokens are stored in your **Keychain** (macOS's encrypted password store), never in a file you can read and never in the app bundle.
- **Only calendars Google reports as writable are offered as a target.**
- If the app shows **"Unconfigured — a Google Cloud Desktop OAuth client ID is required."**, the build you are running has no client ID. Download a build from the Releases page, or set the `QUIET_CALENDAR_GOOGLE_CLIENT_ID` environment variable before launching, or use **Import Google configuration…**.
- **Import Google configuration…** lets you point the app at a `client_secret_*.json` file you downloaded from Google Cloud Console. The app validates it, stores the secret in the Keychain, and never displays its contents. **Keep that file private** — never upload it to GitHub, chat or a shared folder.
- If Google refuses the sign-in, the Google Cloud project behind the client ID may not have the Calendar API enabled. Either ask the maintainer, or import your own Desktop client JSON.
- Google and Mac calendars are **mutually exclusive destinations**. QuikCal never writes the same event to both.

### Appearance

- A **Glass** slider that changes the translucency of the capture bar. Text always stays sharp.
- If you have **Reduce Transparency** or **Reduce Motion** switched on in System Settings, QuikCal respects them and uses a solid bar instead.

### Speech & Parsing

- **Apple Intelligence** — the current **Extraction status** (`Available`, `Requires macOS 26+`, `Not supported on this Mac`, `Apple Intelligence is off`, `Preparing`, `Unavailable`) plus a one-line explanation of what QuikCal will use instead. **Refresh status** re-checks.
- **Local Parakeet** — the speech engine, plus **Download speech model** (~731 MB), **Select speech GGUF…** (use a copy you already have) and **Use existing speech**.
- A note that Parakeet weights use the **NVIDIA Open Model License**, with the full license texts inside the app bundle under `Resources/Notices`.
- **Microphone** — the live authorization status and an **Open…** button.

---

## Part 6 — Updating QuikCal

If you enable automatic update checks, QuikCal checks the public GitHub Releases feed about **once a day** and shows a normal macOS update alert when a newer version exists. It **only notifies** — nothing is downloaded, installed or relaunched without you clicking the install button. Releases are signed with an update key, so a tampered file is rejected.

You can also check at any time: **Settings → General → Check for Updates…**.

If you prefer to update by hand, quit QuikCal first, then download the newer `.dmg` from the [Releases page](https://github.com/bootsphotography1-beep/QuikCal/releases), drag the new `QuikCal.app` onto the old one in Applications, and choose **Replace**. Your settings are not affected.

---

## Part 7 — Troubleshooting

**I cannot find the QuikCal icon.**
QuikCal has no Dock icon. Switch to Finder to free menu-bar space, and check hidden icons if you use a menu-bar organizer. Open QuikCal from **Applications** to start it or reopen setup/Settings. If macOS blocks it, follow [Step 5](#step-5-if-macos-says-it-cannot-open-the-app).

**I double-clicked the `.dmg` and nothing happened.**
Opening the disk image does not launch the app. Drag **QuikCal.app** into **Applications**, eject the disk image, then open the app from Applications.

**macOS says "cannot be opened because the developer cannot be verified".**
Follow [Step 5](#step-5-if-macos-says-it-cannot-open-the-app) to use **System Settings → Privacy & Security → Open Anyway**, if offered. Do not switch off Gatekeeper.

**Typing works, but holding the key does nothing.**
First check your shortcut permissions and whether hold-to-talk is enabled:
- Using **Fn (Globe)** → grant **Input Monitoring**, then **quit and reopen** QuikCal (macOS only applies listen-access to newly created key taps).
- Using **Option / Command / Control** → grant **Accessibility** (Input Monitoring works too).
Check the status rows in **Settings → General**, press **Check again**, and confirm that **Enable hold-to-talk** is switched on.

**The microphone prompt never appears.**
That is intentional — macOS is only asked when you actually capture. Press the mic button or hold your chosen shortcut to trigger it. If you previously clicked **Don't Allow**, re-enable it in **System Settings → Privacy & Security → Microphone → QuikCal**.

**"Did not resolve yet — fix the time below."**
QuikCal could not determine the date and time from your note. Pick one of the suggested times, or type the time yourself. Nothing is added until the card is complete.

**My event was not added.**
The add button is disabled until a writable calendar is chosen. Check **Settings → Calendars & Accounts**. Also make sure macOS has not denied calendar access.

**Google says "Unconfigured".**
Your build has no Google client ID. Use a build from the Releases page, set `QUIET_CALENDAR_GOOGLE_CLIENT_ID` before launching, or import your own Desktop client JSON with **Import Google configuration…**.

**Google sign-in opens the browser but never comes back.**
The callback uses a local `127.0.0.1` address, so a firewall or VPN that blocks loopback can break it. Quit and reopen QuikCal and try again. If the Google Cloud project behind the client ID has no Calendar API enabled, the sign-in will be refused — import your own client JSON in that case.

**The speech model will not download.**
It is about 731 MB and must be downloaded from its pinned public source, so you need that much free disk space and working internet. If the source is unreachable, download the model yourself and use **Settings → Speech & Parsing → Select speech GGUF…**. Meanwhile, typing works normally.

**Clicking the menu-bar icon does nothing.**
The capture bar may be behind a full-screen app or another Space. Press **Escape** and try again. Right-clicking the icon always reaches Settings, so you can recover from anywhere.

**QuikCal asks for Accessibility again after an update.**
The first stable-signed install needs a one-time fresh Accessibility grant. Grant it once more; later updates keep it.

**I want to move to another Mac.**
Nothing is stored in the app bundle. Your settings live in your user account, and your events live in your calendar. Install QuikCal on the new Mac and set it up again.

---

## Part 8 — Privacy, safety and what leaves your Mac

**Nothing is written to your calendar without your explicit confirmation.** The add button is the only thing that saves an event. A spoken *"yes"* never does.

**Only one destination at a time.** Mac calendars **or** Google — never both.

**Speech stays on your Mac.** QuikCal transcribes with a local Parakeet model running through a bundled `transcribe.cpp` helper. It is **not** Apple Speech, and there is **no cloud fallback**. Temporary recordings are written with owner-only permissions and deleted after use, success or failure.

**No screen recording.** QuikCal never asks for Screen & System Audio Recording.

**Your notes are not stored as a cloud service.** The only local file QuikCal keeps is a small receipt list of what it saved, in `~/Library/Application Support/QuietCalendar/`.

**What can leave your Mac:**
- The **optional speech-model download** (~731 MB) from its pinned public source.
- **Google** traffic, but only if you choose the Google destination and sign in.
- The **update check** to the public GitHub Releases feed.
- Event details are sent to Google when you confirm an event for the Google destination. Mac calendars may sync through iCloud or another configured account. Parsing and transcription happen on your Mac.

**Credentials.** Google tokens are stored in the **Keychain**. If you import a Google client JSON, its secret goes to the Keychain and is never displayed in the app. Keep your own copy of that file private.

---

## Part 9 — For developers

### Requirements

- macOS 14 or newer (the package declares `.macOS(.v14)`).
- **Swift 6** toolchain and the Xcode Command Line Tools.
- **CMake** and a C/C++ toolchain — only to build the bundled speech helper from source.
- The first SwiftPM build needs network access to resolve the pinned **Sparkle 2.10.1** dependency.

### Repository layout

```
Package.swift                 SwiftPM manifest (library "QuietCalendarCore" + executable "QuietCalendar")
Package.resolved              Pinned dependency versions
Sources/QuietCalendar/        The AppKit application (menu bar agent, windows, capture panel)
Sources/QuietCalendarCore/    Pure logic: parsing, routing, policies, confirmation gates (no AppKit)
Tests/QuietCalendarCoreTests/ Unit tests for the core logic
Resources/Info.plist          Bundle identity, permissions text, Sparkle feed + public update key, Google client ID
Resources/Notices/            Third-party license texts (ggml, transcribe.cpp, NVIDIA Parakeet)
Resources/SpeechRuntime/      Pinned speech-model manifest (the helper binary itself is built locally)
scripts/                      Build, package, verify and publish scripts
vendor/local-models/          Pinned upstream speech-engine source (transcribe.cpp + ggml)
local-models/stt-fixtures/    One synthetic audio fixture used by the packaged-speech acceptance test
```

### Build and test

```sh
swift test                         # unit tests for the core logic
./scripts/build_speech_helper.sh   # builds the transcribe.cpp helper (needs CMake)
./scripts/build_app.sh             # assembles + signs build/QuikCal.app
./scripts/build_dmg.sh             # builds dist/QuikCal-<version>.dmg
./scripts/accept_packaged_synthetic.sh   # packaged-speech acceptance test (needs a built app + a real model)
```

`build_app.sh` requires the resolved **Sparkle.framework** artifact and exactly **one** valid **Apple Development** signing identity; it refuses to guess or fall back silently. `QUIKCAL_SIGN_MODE=adhoc` is an explicit local-development override. `build_dmg.sh` refuses to package an ad-hoc build unless `QUIKCAL_ALLOW_ADHOC_DMG=1` is also set. **Neither mode produces a Developer ID-signed or notarized app** — macOS may require the per-app exception described in [Step 5](#step-5-if-macos-says-it-cannot-open-the-app).

Both scripts replace generated output under `build/` and `dist/`. Review those directories before running them.

### Releases

Download published installers and update packages from the [Releases page](https://github.com/bootsphotography1-beep/QuikCal/releases). Building a local app or disk image does not upload anything to GitHub.

The maintainer's release-preparation and publication scripts are not included in this published source snapshot. Creating a distributable update additionally requires the maintainer's signing setup; running the build commands above does not create an official release.

### Configuration reference (`Resources/Info.plist`)

| Key | Meaning |
|---|---|
| `CFBundleIdentifier` | `com.quietcalendar.app` |
| `LSUIElement` | `true` — a menu-bar agent with no Dock icon |
| `LSMinimumSystemVersion` | `14.0` |
| `NSMicrophoneUsageDescription` | Shown in the macOS microphone prompt |
| `NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription` | Shown in the macOS calendar prompt |
| `GoogleDesktopOAuthClientID` | Public Desktop OAuth client ID. No secret is ever embedded. |
| `SUFeedURL` | The public GitHub Releases appcast the updater reads |
| `SUPublicEDKey` | Sparkle's **public** EdDSA update key (verification only — the private key is not in this repository) |
| `SUEnableAutomaticChecks` | `true` — periodic *checks* are on |
| `SUAllowsAutomaticUpdates` | `false` — automatic *download and install* are structurally disabled |

### Architecture notes

- **Pure core, thin shell.** `QuietCalendarCore` holds the decision logic (launch routing, permission capability model, parsing, grounding, confirmation gates) with no AppKit dependency, so it is directly unit-testable. `QuietCalendar` is the AppKit shell.
- **Launch routing** (`LaunchRouting.swift`) decides what a launch shows: an incomplete profile always opens onboarding (and resumes at its saved cursor); a completed profile cold-starts to the menu bar only, and a Finder/Spotlight reopen opens Settings. Readiness never re-opens onboarding for a completed profile.
- **Capability-aware permissions** (`PrivacyPermissionPanes.swift`) model the real difference between Input Monitoring and Accessibility, so the UI never mislabels one as the other.
- **Grounding** — every extracted field is validated against the user's own note before it can reach a draft.
- **Confirmation gate** — a draft only becomes a write after an explicit user action; the rejection path is structurally unable to write.
- **Single-lane destination** — EventKit **or** Google, never both.

### Testing notes

- `swift test` runs the core unit-test suites. The published snapshot deliberately omits four historical model-evaluation suites whose research inputs are not part of this source publication.
- The packaged-speech acceptance test is explicitly gated: it needs a built app and a real Parakeet model, so it does not run as part of a normal test pass.
- No automated test launches the app, grants a real permission, or writes to a real calendar. GUI behaviour, calendar prompts, live writes and Google sign-in are verified by hand.

### Licensing

There is **no project-level LICENSE file** in this repository, and none has been invented. Third-party license texts are kept under `Resources/Notices/` (ggml/MIT, transcribe.cpp, and the NVIDIA Open Model License for the Parakeet weights). Sparkle remains a separately resolved SwiftPM dependency with its own license terms.

---

## Honest status

- The **publicly installable artifact** is the release `.dmg` on the [Releases page](https://github.com/bootsphotography1-beep/QuikCal/releases) — that link is real and the file is downloadable today.
- The app is signed with a **development certificate and is not notarized**, so macOS may require the per-app **Open Anyway** exception described in [Step 5](#step-5-if-macos-says-it-cannot-open-the-app).
- Release binaries are built from this source tree, but **the published app was not run end-to-end against a live Google account or a real calendar as part of publishing**. Behaviour described here comes from the code and from the shipped release notes.
- The speech model is **not bundled**; it is downloaded on demand and verified against a pinned checksum.
