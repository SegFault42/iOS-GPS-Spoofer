# Preparing your iPhone for GPS spoofing

This tool uses Apple's **developer location-simulation** service — the exact same
mechanism as Xcode's *Product ▸ Scheme ▸ Simulate Location*. **No jailbreak, no
profile, nothing permanent.** The fake location only applies while the phone is
connected to this Mac and is cleared when you stop.

You need to do three things once:

1. [Pair & trust the iPhone](#1-pair--trust-the-iphone)
2. [Enable Developer Mode](#2-enable-developer-mode)
3. [Let the DeveloperDiskImage mount on the first run](#3-first-run)

Then [verify](#4-verify) and you're done. A [troubleshooting](#troubleshooting)
table is at the end.

---

## What works

| iOS version | Supported | Transport |
|---|---|---|
| iOS 17, 18, 26 … | ✅ yes | CoreDevice tunnel (`--transport native`, no root) |
| iOS 16 and older | ⚠️ not by this build | would use plain usbmux (`pymobiledevice3 developer simulate-location`) |

You also need, on the Mac:

- macOS with a current **Xcode** installed (provides the Apple Mobile Device
  support that `usbmuxd` needs to recognise new iPhones).
- The project set up once: `./setup.sh`.

---

## 1. Pair & trust the iPhone

1. Connect the iPhone to the Mac with a **data-capable USB cable** (a charge-only
   cable will not work — the Mac won't see the device at all).
2. **Unlock the iPhone** and keep it unlocked.
3. On the iPhone tap **Trust** on the "Trust This Computer?" prompt, then enter
   your **passcode**.
   - If no prompt appears: unplug, make sure the phone is unlocked, plug back in.
     Still nothing? See [USB Restricted Mode](#the-mac-doesnt-see-the-iphone-at-all).
4. Confirm the Mac sees it:

   ```bash
   ./.build/release/iosgpsspoof list
   # 00008110-0011304A1E61801E  iPhone — iOS 26.5.2 (iPhone14,3, usb)
   ```

   If the list is empty, jump to [troubleshooting](#the-mac-doesnt-see-the-iphone-at-all).

### Wi-Fi (optional)

Once the phone has been **USB-paired** at least once, it can also be reached over
Wi-Fi:

- In Finder, select the iPhone ▸ **General** ▸ tick *"Show this iPhone when on
  Wi-Fi"*.
- The Mac and iPhone must be on the **same network**.
- USB is more reliable and faster — prefer it for routes.

---

## 2. Enable Developer Mode

Developer Mode is required on **iOS 16 and later** for any developer service
(including location simulation).

1. On the iPhone: **Settings ▸ Privacy & Security ▸ Developer Mode**.
2. Toggle it **on**.
3. Tap **Restart** when prompted.
4. After the phone reboots, unlock it and tap **Turn On** on the confirmation
   alert, then enter your passcode.

> **"Developer Mode" isn't in Settings?**
> The row only appears after the phone has been connected to a developer tool
> once. With the phone plugged in and trusted, run any command — e.g.
> `./.build/release/iosgpsspoof list` — then look again. If it's still missing,
> open Xcode ▸ Window ▸ Devices and Simulators with the phone connected, then
> recheck Settings.

You can turn Developer Mode back off the same way when you're finished; it has no
effect on normal use while it's on.

---

## 3. First run

The first time you spoof a given iPhone, the tool runs
`pymobiledevice3 mounter auto-mount`, which downloads and mounts the matching
**DeveloperDiskImage** on the device. On iOS 17+ this is a *personalised* image:

- The Mac needs **internet access** for this one-time download.
- It takes a few seconds; the GUI shows *"Preparing…"* and the log shows the
  mount progress.
- It persists until the phone reboots, so subsequent runs are instant.

Then the tool opens the CoreDevice tunnel via Apple's `remotepairingd`
(`--transport native`) — **no root, no password**.

---

## 4. Verify

**GUI:**

```bash
./run-gui.sh
```

The iPhone should appear in the left column. Select it, click a spot on the map,
hit **Start spoofing** — the status badge turns green and the log shows
`● holding at <lat>, <lon>`. Open **Maps** on the iPhone; the blue dot jumps to
the spot. Hit **Stop** and it returns to the real location.

**CLI:**

```bash
./.build/release/iosgpsspoof spoof 48.8584 2.2945   # Eiffel Tower
# Ctrl-C to stop and restore
```

---

## Returning the phone to normal

The real GPS is restored automatically when you **Stop** in the GUI, quit the
app, or press Ctrl-C in the CLI. If something was force-killed and the phone
seems stuck:

```bash
./.build/release/iosgpsspoof clear
```

or just **reboot the iPhone** — a simulated location never survives a reboot.

---

## Troubleshooting

### The Mac doesn't see the iPhone at all

`iosgpsspoof list` is empty and `system_profiler SPUSBDataType | grep -i iphone`
shows nothing:

| Cause | Fix |
|---|---|
| Charge-only cable / bad port | Use a known-good data cable, plug **straight into the Mac** (no hub, dock, or monitor). |
| Not trusted | Unlock the phone, unplug/replug, tap **Trust**, enter passcode. |
| **USB Restricted Mode** | If the phone has been locked for ~1 hour, iOS disables the data port. Unlock it *before* plugging in. Optionally: Settings ▸ Face ID & Passcode ▸ **Accessories** → allow. |
| Stale `usbmuxd` after a macOS/Xcode update | `sudo pkill -9 usbmuxd` (launchd restarts it), then replug. |
| Really stuck | Reboot the Mac. |

### Shows in `system_profiler` but not in `iosgpsspoof list`

It's connected but not paired:

```bash
./.venv/bin/pymobiledevice3 lockdown pair      # then tap Trust + passcode
```

### "Developer Mode disabled" / service errors

Enable Developer Mode ([step 2](#2-enable-developer-mode)) **and reboot**. The
toggle must be confirmed *after* the reboot.

### "Could not mount the DeveloperDiskImage"

- Make sure the Mac has **internet** (the personalised image is fetched from
  Apple on first use).
- Update **Xcode** to a version that supports your iOS release.
- Try manually: `./.venv/bin/pymobiledevice3 mounter auto-mount`.

### Tunnel won't establish (`--transport native` fails)

- Try `--transport userspace` (pure-Python tunnel, no root, a bit slower):
  `iosgpsspoof spoof <lat> <lon> --transport userspace`
- Or run the privileged tunnel daemon and use it:
  ```bash
  sudo ./.venv/bin/pymobiledevice3 remote tunneld     # leave running
  iosgpsspoof spoof <lat> <lon> --transport tunneld
  ```

### The blue dot doesn't move in an app

- **Maps** and most apps pick it up immediately; some cache aggressively —
  force-quit and reopen the app.
- Check the tool actually reports the session as active (green badge / log line).
- A few apps run their own anti-spoofing checks and may ignore it; that's outside
  this tool's control.

### The location snaps back on its own

That's the automatic *clear* on stop/disconnect. To keep a fake location in place
after the CLI exits, pass `--no-clear-on-exit`.
