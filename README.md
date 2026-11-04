# Wingman

**Your iPad and iPhone, beside your Windows laptop.** A second screen, a
remote control and a desk clock in one free app. It connects over the cable,
over Wi-Fi, or from anywhere through Tailscale.

[![Wingman: the showcase video](docs/wingman-strip.jpg)](docs/wingman.mp4)

▶ [Watch the 40-second video](docs/wingman.mp4)

> A personal learning project: a Python "hub" on the laptop and a SwiftUI app
> on the iPad and iPhone, talking over a protocol of their own. It isn't on
> the App Store; you install it yourself with SideStore (free).

---

## What it does

**On the iPad**
- **Extend**: the iPad becomes a second screen, with touch and keyboard.
- **Mirror**: the laptop's screen on the iPad.
- **Sound**: the laptop's audio plays on the iPad.
- **A quick panel** over Extend and Mirror: shortcuts, controls and the clipboard.

**On the iPad and the iPhone**
- **Controls**: volume, brightness, music, dark mode, Wi-Fi and Bluetooth,
  power plans, keeping the laptop awake.
- **Shortcuts**: one tap opens an app or website, runs a keyboard shortcut, or
  locks the laptop. They're editable on the device and show the real app icons.
- **Clipboard history and files**: copy on one side, paste on the other;
  send files both ways.
- **Dashboard** (ASUS ROG laptops): temperatures, fans, usage and battery
  health, live.
- **Dock**: a desk clock for the device standing beside the laptop. It shows
  what's playing, a volume line, your shortcuts, a timer with an alarm, and a
  red night mode.
- **Trackpad** (iPhone): the phone drives the laptop's pointer and keyboard.

**On the laptop**
- **Ctrl+Alt+I**: the laptop's own keyboard, touchpad and mouse control the
  iPad over Bluetooth, with the iPad's real trackpad gestures.
- **On-screen indicators** for whatever the device changes (volume, music,
  files received…).

**Connections:** the cable (fastest, pairs automatically), Wi-Fi (paired once
with a 6-digit code, then encrypted), and **Tailscale** for when you're away
from home. Settings in the app choose which ones are allowed.

---

## What you need

| | |
|---|---|
| **Laptop** | Windows 11 (made and tested on it; Windows 10 may mostly work but is untested). An ASUS laptop for the temperatures and fans on the Dashboard; a Precision touchpad (most modern laptops) for Ctrl+Alt+I's real trackpad gestures. |
| **iPad / iPhone** | iPadOS / iOS 16 or newer. |
| **Free accounts** | An Apple ID (to sign the app with SideStore). Optional: Tailscale, for use away from home. |
| **Free software** | Python 3.12 or newer, Apple Devices, the Parsec Virtual Display Driver, SideStore (all explained below). |

Wingman doesn't work with a Mac laptop: the laptop side uses Windows features.

---

## Setup

### 1. The laptop

1. **Install Python** 3.12 or newer from [python.org](https://www.python.org/downloads/).
   During setup, tick **Add python.exe to PATH**.
2. **Download Wingman**: on this page, **Code → Download ZIP**, and unzip it
   somewhere permanent (for example `Documents\Wingman`). Or with git:
   ```bash
   git clone https://github.com/angelorsbastos/extended_display.git
   ```
3. **Install its packages.** Open a terminal in that folder and run, one at a time:
   ```bash
   python -m venv .venv
   ```
   ```bash
   .venv\Scripts\pip install -r requirements.txt
   ```
4. **Install Apple Devices** from the Microsoft Store (or iTunes). It provides
   the USB service the cable connection needs.
5. **Install the Parsec Virtual Display Driver**, which lets Wingman add a
   screen for Extend. Use the driver installer linked from
   [nomi-san/parsec-vdd](https://github.com/nomi-san/parsec-vdd). You only
   need the driver itself; Wingman controls it.
6. **Give Extend your iPad's exact resolution.** Double-click
   `pc\ipad-resolution.reg` and accept (needs admin). It's set for the iPad 10
   (2360 × 1640). For another iPad, first open the file in Notepad and change
   the two numbers. They're hexadecimal, so Windows' Calculator in Programmer
   mode can convert them. For example, iPad Pro 11": 2388 × 1668 → `954` × `684`;
   iPad Pro 12.9": 2732 × 2048 → `aac` × `800`.
7. **Create the Wingman shortcuts**: right-click `pc\make_shortcuts.ps1` →
   **Run with PowerShell**. This adds *Wingman* to the Start menu and the
   desktop, plus *Send to → iPad (Wingman)* in Explorer's right-click menu.
8. **Start Wingman** from the Start menu. It runs quietly in the system tray
   (bottom right); quit it from the tray icon. If Windows Firewall asks, allow
   it on **private** networks, so the iPad can be found on Wi-Fi.

### 2. The iPad and iPhone

1. **Install SideStore** with your Apple ID, following
   [SideStore's guide](https://docs.sidestore.io). It's the free way to install
   apps that aren't on the App Store. With a free Apple ID, apps have to be
   refreshed in SideStore once a week.
2. In SideStore, **Sources → +**, and add:
   ```
   https://github.com/angelorsbastos/extended_display/releases/latest/download/source.json
   ```
3. Install **Wingman** from that source and open it. Allow **Local Network**
   when it asks: that's how the laptop finds it on Wi-Fi.

SideStore signs the app with *your* Apple ID, and pairing is per device: your
copy only ever talks to your own laptop.

### 3. Connect

1. **The first time, use the cable.** Plug the iPad (or iPhone) into the
   laptop, tap **Trust** on the device if asked, and open Wingman. It connects
   and pairs by itself.
2. **From then on, Wi-Fi works too.** With both on the same Wi-Fi, just open
   Wingman. To pair over Wi-Fi without the cable, type the 6-digit code the
   laptop shows. Guest networks often block devices from seeing each other;
   use the cable or Tailscale there.
3. **Away from home** (optional): install [Tailscale](https://tailscale.com) on
   the laptop and the device, signed in to the same account. Wingman finds the
   device through it by itself. On iOS only one VPN runs at a time, so turn
   Tailscale off for SideStore's weekly refresh if SideStore needs its own.

### 4. Ctrl+Alt+I (the laptop's keyboard and touchpad on the iPad)

1. Press **Ctrl+Alt+I** on the laptop. A note at the top of the screen says
   it's connecting.
2. The first time only: on the iPad, open **Settings → Bluetooth** and tap
   the laptop's name (its Windows computer name).
3. Type, point, click, scroll, and swipe with three or four fingers like on
   an iPad trackpad. A plugged-in mouse works too. **Ctrl+Alt+I** again brings
   everything back to the laptop.

---

## Updating

- **The app:** SideStore shows *Update available* whenever a new version is
  built; tap **Update**.
- **The laptop:** download the project again (or `git pull`), keeping your
  `pc\shortcuts.user.json` and `pc\pairings.json`. Then quit Wingman from the
  tray and start it again.

## Build your own copy

The iPad app is built for free on GitHub's macOS machines, so no Mac is needed:

1. **Fork** this repository.
2. In `ipad/make_source.py`, change `REPO` to your own `user/repository`.
3. Push a change under `ipad/`. GitHub Actions builds the app and publishes it
   as a release, together with your own `source.json`.
4. Add *your* source URL in SideStore (the same as above, with your
   `user/repository`).

If a build fails with *"The job was not acquired by Runner"*, GitHub had no
free Mac at the time: re-run it later. If it keeps happening, switch
`runs-on` in `.github/workflows/build-ipad.yml` between `macos-15` and
`macos-15-intel`.

---

## How it works

- **The laptop side** (`pc/`, Python) is the *hub*. It captures the screen
  (Windows Graphics Capture) and encodes it as H.264. It captures the sound
  (WASAPI loopback) and encodes it as AAC. It sends both to the device and
  carries out what the device asks for: input, shortcuts and controls.
- **The device side** (`ipad/`, SwiftUI, one universal app) decodes the video
  in hardware and the audio with AVAudioEngine. It sends touch, keyboard and
  trackpad input back.
- **Connections:**
  - **The cable:** usbmux, Apple's USB channel.
  - **Wi-Fi:** found by Bonjour, paired once with an X25519 key exchange and
    a 6-digit code. After pairing, every message is sealed with
    ChaCha20-Poly1305.
  - **Keys:** the laptop keeps them encrypted with the Windows account (DPAPI);
    the device keeps them in its Keychain.
- **Extend** adds a real screen to Windows through the Parsec virtual display
  driver.
- **Ctrl+Alt+I** makes the laptop a Bluetooth LE keyboard and Precision
  trackpad (HID over GATT), fed by the touchpad's raw fingers. The iPad then
  does its own pointer and gestures.
- **The video** in `video/` is made in code with [Remotion](https://www.remotion.dev);
  see `video/README.md`.

### Project layout

| Folder | What's in it |
|---|---|
| `pc/` | The laptop hub: `tray.py` starts it; `hub.py` is the core; one file per feature (`audio.py`, `controls.py`, `files.py`, `ipad_control.py`, …). |
| `ipad/` | The iPad and iPhone app (SwiftUI); `project.yml` describes the Xcode project. |
| `.github/workflows/` | The cloud build that publishes the app for SideStore. |
| `video/` | The showcase video's source. |
| `docs/` | The video and the picture at the top of this page. |

## Thanks

[Parsec VDD](https://github.com/nomi-san/parsec-vdd) for the virtual screen,
[SideStore](https://sidestore.io) for installing without the App Store,
[Tailscale](https://tailscale.com) for reaching home from anywhere, and
[Remotion](https://www.remotion.dev) for the video.
