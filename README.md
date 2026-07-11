# Wallpaper Rotator (Linux, all desktops)

Rotates the desktop wallpaper on a timer, like Windows 11's slideshow.
It also picks a fresh wallpaper at **every login** — boot, logout→login, or
shutdown→start. Linux only. Works on any desktop with `systemd`, and knows how
to set the wallpaper on the major desktop environments. No `sudo` needed —
everything installs under your home directory.

## Contents
- [Requirements](#requirements)
- [Install](#install)
- [How to use](#how-to-use)
- [Wallpaper directories (local, network, USB)](#wallpaper-directories-local-network-usb)
- [Order: shuffle or in sequence](#order-shuffle-or-in-sequence)
- [Fit / scaling (automatic)](#fit--scaling-automatic--not-a-setting)
- [Battery / power (laptops)](#battery--power-laptops)
- [Show a label on the wallpaper](#show-a-label-on-the-wallpaper)
- [Managing your wallpapers](#managing-your-wallpapers)
- [When does the wallpaper change?](#when-does-the-wallpaper-change)
- [Stop, start & restart](#stop-start--restart)
- [Change settings](#change-settings)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Supported desktops](#supported-desktops)
- [How it works / files](#how-it-works--files)

---

## Requirements
- Linux with `systemd` (for the timer and login service)
- `bash`, `coreutils` (`shuf`), `findutils` — present on virtually every distro
- The wallpaper tool for your desktop (already installed with that desktop):
  `gsettings` (GNOME/Cinnamon/MATE), `plasma-apply-wallpaperimage` (KDE),
  `xfconf-query` (XFCE), `pcmanfm`/`pcmanfm-qt` (LXDE/LXQt), or `feh` (X11)
- *Optional:* [ImageMagick](https://imagemagick.org) and `python3` — only if you
  turn on [the on-image label (distro name + kernel and logo)](#show-a-label-on-the-wallpaper);
  setup installs both automatically. ImageMagick stamps the label, `python3`
  chooses its colour.

---

## Install
1. Get the project directory onto the machine (copy it, or clone the repo), then
   open a terminal in it:
   ```bash
   cd wallpaper-rotator
   ```
2. Make the scripts executable (only needed the first time):
   ```bash
   chmod +x setup.sh uninstall.sh linux-wallpaper-rotator.sh
   ```
3. Run the interactive installer:
   ```bash
   ./setup.sh
   ```
   **Just 3 quick questions** (press **Enter** to accept each default):
   - **Desktop** — auto-detected; press Enter to keep it, or pick from the menu
   - **Wallpaper directory** — default `~/Pictures/Wallpapers`
   - **How often** — e.g. `30s`, `5min`, `15min` (default), `1h`

   Then it asks **“Customise advanced options?”** — press Enter (`N`) to skip and
   use sensible defaults, or `y` to set:
   - **Order** — `Shuffle` (random, default) or `Sequential` (file-name order)
   - **Extra directories** — add more directories, e.g. a network/NAS mount or USB
   - **On battery** *(laptops only)* — AC only (default) or keep rotating
   - **Label** — stamp the distro name + kernel and logo (default) or not

   The installer then:
   - installs the script to `~/.local/bin/` and the systemd **user** units
   - enables and starts the rotation timer
   - enables the login service (fresh wallpaper at every login/boot)
   - sets one wallpaper immediately
   - prints a summary and the next scheduled run

That's it. To start using your own images, see below.

---

## How to use
Once installed it runs on its own — you don't need to keep a terminal open.
Day to day you only ever do two things:

**1. Put images in your wallpaper directory** (default `~/Pictures/Wallpapers`):
```bash
cp ~/Downloads/*.jpg ~/Pictures/Wallpapers/
```

**2. (optional) Change the wallpaper right now** instead of waiting for the timer:
```bash
wallpaper-rotator.sh
```
It picks a new random image and prints which file it chose.

Everything else — rotating on schedule and refreshing at login — happens
automatically.

---

## Wallpaper directories (local, network, USB)
List your wallpaper directories in `WALLPAPER_DIRS` in
`~/.config/wallpaper-rotator.conf` — **add as many as you like, one per line**.
They can be local disks, USB sticks, or mounted network/NAS directories:
```bash
WALLPAPER_DIRS=(
    "$HOME/Pictures/Wallpapers"
    "/mnt/usb/wallpapers"
  # "/mnt/nas/photos"        # disabled — a leading '#' turns a directory off
    "/run/user/1000/gvfs/smb-share:server=nas,share=pics"
)
```
- **Disable a directory** by putting `#` in front of its line — it's skipped until
  you remove the `#`.
- Directories that don't exist right now (e.g. a share that isn't mounted yet) are
  skipped safely, and symlinked directories work too.
- **Every directory gets equal turns** — rotation is fair *per folder*, not per
  image. A folder with 5 images comes up as often as one with 5000, so small
  collections aren't drowned out by a large one (see [Order](#order-shuffle-or-in-sequence)).
- **Only your directories are used** — there is no system-wallpaper fallback. At
  least one listed directory must contain images; if none do, the current wallpaper
  is left unchanged.

Changes apply on the **next** scheduled change — the script never rotates early
just because you edited the config.

---

## Order: shuffle or in sequence
Also chosen at setup and stored as `ORDER` in the config. With more than one
folder, both modes rotate **fairly across folders** (each folder gets equal turns
regardless of size):
- **`shuffle`** *(default)* — each change picks a folder at random (equal weight,
  and not the same folder twice in a row when there's a choice), then a random
  image from it — so it never repeats the same image twice in a row.
- **`sequential`** — walks the folders **round-robin**, taking the next image
  (filename/alphabetical order) from each in turn, wrapping back to the start. The
  folders alternate rather than showing one whole folder before the next.

## Fit / scaling (automatic — not a setting)
The **fill mode is always chosen automatically** for each wallpaper, from the
image's resolution and aspect ratio versus your screen's. This is intentional
and has no config knob — it just does the right thing per image:
- **fill (cover)** when the image roughly matches the screen shape — it fills
  the screen, cropping only a little.
- **fit (contain)** when the shapes clash (a portrait photo or an ultrawide
  panorama on a normal screen) — the whole image shows, with letterbox bars, so
  nothing important is cut off.
- **centre** for a tiny image, shown at its native size instead of being blown
  up into a blur.

Each mode is mapped to the right setting per desktop — GNOME/Cinnamon/MATE
`picture-options`, XFCE `image-style`, KDE Plasma `FillMode`, LXDE/LXQt
`pcmanfm --wallpaper-mode`, and the matching `feh --bg-*` flag. Image dimensions
are read with ImageMagick, falling back to `identify` or `file`; if the size
can't be read, it defaults to fill.

---

## Battery / power (laptops)
Like Windows 11's "pause slideshow on battery", the slideshow **only changes on
AC power by default**, to save battery. Controlled by `ON_BATTERY` in the config:
- **`no`** *(default)* — the **automatic** timer/login runs only change the
  wallpaper on **AC** power; on battery they exit quietly and leave it as-is.
- **`yes`** — rotate on battery too.

This pause applies to automatic runs only. Running `wallpaper-rotator.sh`
yourself (or re-running `./setup.sh`) **always** changes the wallpaper, because
you asked for it explicitly.

Power state is read from `/sys/class/power_supply/`. **Desktops** (no battery)
always count as AC, so this setting has no effect there — and `setup.sh` skips
the question entirely on a machine with no battery.

---

## Show a label on the wallpaper
Stamp your **distro name and kernel version** into the bottom-right corner of
the wallpaper (e.g. `Debian_GNU/Linux_6.12.94+deb13-amd64`), with your Linux
distribution's logo just above it. Controlled by `SHOW_LABEL` in the config
(older configs' `SHOW_NAME` is still honoured):
- **`yes`** *(default)* — before applying, a labeled copy is rendered and *that*
  copy is set as the wallpaper. The label:
  - reads the distro name from `/etc/os-release` and the kernel from `uname -r`,
    joined with underscores;
  - uses your **desktop's own UI font** (from the GSettings interface font,
    falling back to fontconfig's default sans);
  - is a **real colour taken from the wallpaper itself** — never a synthetic or
    random tint. A saturated accent (a "pop") is used when one reads clearly on
    the spot behind the text; otherwise the lightest tone over a dark spot, or
    the darkest over a light one, so it always stays readable. No outline or
    shadow — one solid colour;
  - carries the **running distro's emblem** above it (Debian swirl, Arch, Ubuntu,
    Fedora, openSUSE, Gentoo, Mint, Manjaro, …), found via the freedesktop
    `os-release` `LOGO` icon with per-distro fallbacks — tinted to the *same*
    colour as the text. If no logo is found (e.g. an unknown distro) the text is
    stamped on its own.
  - is placed inside the **visible (cropped) area** so it isn't cut off,
    whatever the auto fill mode does.
- **`no`** — set the image as-is.

**Requires [ImageMagick](https://imagemagick.org)** (`magick`, or the older
`convert`). If it isn't installed the script logs a note and falls back to the
plain image. Install it with e.g. `sudo apt install imagemagick`. The label
colour is chosen by a small `python3` helper installed alongside the script; if
`python3` is missing the label falls back to a neutral tone.

The labeled copies live in `~/.cache/wallpaper-rotator/` and are regenerated
each change (old ones are cleaned up), so this costs a little CPU and disk per
rotation. Your original image files are never modified, and no-repeat/sequential
ordering still tracks the real filenames.

---

## Managing your wallpapers
- The rotation pool is simply **whatever images are in your `WALLPAPER_DIRS`
  directories** (default `~/Pictures/Wallpapers`). Add or delete files anytime; the
  directories are re-scanned on every change, so there's nothing to restart.
- Supported image types: **`.jpg`, `.jpeg`, `.png`, `.webp`** (other files are
  ignored). **Subdirectories are scanned too**, so you can organise into categories.
- **No images?** If your directories are empty (or you've commented them all out),
  the script logs a note and leaves the current wallpaper unchanged — there is
  no system-wallpaper fallback. See
  [Wallpaper directories](#wallpaper-directories-local-network-usb).

```bash
ls ~/Pictures/Wallpapers          # see the current pool
```

---

## When does the wallpaper change?
| Event | Handled by |
|---|---|
| Every N minutes while logged in | the timer (`wallpaper-rotator.timer`) |
| Boot / restart | login service + timer's `OnBootSec` |
| Shutdown → start | login service |
| Logout → login | login service |
| On demand (`wallpaper-rotator.sh`) | you |

---

## Stop, start & restart
These use `systemctl --user` (no `sudo`).

**Check status / when it next runs:**
```bash
systemctl --user list-timers wallpaper-rotator.timer     # next scheduled run
systemctl --user status wallpaper-rotator.timer          # is it active?
```

**Pause rotation (until you re-enable it):**
```bash
systemctl --user disable --now wallpaper-rotator.timer
```

**Resume rotation:**
```bash
systemctl --user enable --now wallpaper-rotator.timer
```

**Restart after changing settings** (e.g. you edited the interval):
```bash
systemctl --user daemon-reload
systemctl --user restart wallpaper-rotator.timer
```

**Turn the "change at login" behaviour off / on** (leaves the timer alone):
```bash
systemctl --user disable wallpaper-rotator-login.service   # off
systemctl --user enable  wallpaper-rotator-login.service   # on
```

---

## Change settings
Easiest: just **re-run the installer** — it's safe to run again and overwrites
the old settings.
```bash
./setup.sh
```

Prefer to edit by hand? Everything lives in one file —
`~/.config/wallpaper-rotator.conf` — with the settings you'll actually change at
the **top**:
- `WALLPAPER_DIRS` — your directories (one per line; `#` disables a line)
- `INTERVAL` — how often it changes (`30s`, `5min`, `1h`, …)
- `ORDER` — `shuffle` or `sequential`
- `ON_BATTERY` — `no` (AC only) or `yes`
- `SHOW_LABEL` — `yes`/`no` for the on-image distro label + logo
- *Advanced:* `DE`

**Changes take effect on the next scheduled change** — the script never rotates
early just because you saved the file. Editing `INTERVAL` is enough: the next
run re-syncs the systemd timer for you (no `systemctl` commands needed). The
fill/scaling mode is automatic and has no setting.

---

## Uninstall
Run the uninstaller from the project directory:
```bash
./uninstall.sh
```
It stops and disables the timer + login service, removes the installed script,
units, config, state and cache, and **resets the desktop to its default
wallpaper** (on GNOME/Cinnamon/MATE/XFCE). **Your wallpaper directories and images
are left untouched** (delete those directories yourself if you also want the images
gone). Re-install anytime with `./setup.sh`.

<details><summary>Prefer to do it by hand?</summary>

```bash
systemctl --user disable --now wallpaper-rotator.timer
systemctl --user disable --now wallpaper-rotator-login.service
rm -f ~/.local/bin/wallpaper-rotator.sh \
      ~/.config/systemd/user/wallpaper-rotator.{service,timer} \
      ~/.config/systemd/user/wallpaper-rotator-login.service \
      ~/.config/wallpaper-rotator.conf
systemctl --user daemon-reload
```
</details>

---

## Troubleshooting
**See what happened on the last run:**
```bash
journalctl --user -u wallpaper-rotator.service -n 20 --no-pager        # timer runs
journalctl --user -u wallpaper-rotator-login.service -n 20 --no-pager  # login runs
```

- **"No images found …"** — none of your `WALLPAPER_DIRS` directories contain
  supported images. Add some `.jpg`/`.png` files, or add a directory that has some;
  the wallpaper is left unchanged until then.
- **`wallpaper-rotator.sh: command not found`** — `~/.local/bin` isn't on your
  `PATH`. Run it with the full path `~/.local/bin/wallpaper-rotator.sh`, or add
  `~/.local/bin` to your `PATH`.
- **Wrong desktop / nothing changes visibly** — check the `DE=` value in
  `~/.config/wallpaper-rotator.conf` matches your desktop, or re-run `./setup.sh`.
- **KDE at login** — `plasma-apply-wallpaperimage` occasionally races the
  desktop starting up; the very next timer tick corrects it.

---

## Supported desktops
GNOME / Ubuntu, Cinnamon, MATE, KDE Plasma, XFCE, LXDE / LXQt, and any X11
desktop via `feh`. Selected in `setup.sh` and stored in
`~/.config/wallpaper-rotator.conf`.

---

## How it works / files
Everything installs into your home directory as **systemd user units** — a
timer for scheduled rotation and a oneshot service that fires at each session
start. Both call the same script, which reads its config, gathers images from
your chosen sources, picks the next one (shuffle or sequential), and applies it
with the right tool for your desktop.

**In the project directory:**
- `setup.sh` — interactive installer (desktop, directories, interval, order); also
  generates the systemd timer
- `uninstall.sh` — stops/disables everything and removes installed files (keeps your images)
- `linux-wallpaper-rotator.sh` — picks the next image (shuffle/sequential), sets it per the chosen desktop
- `linux-wallpaper-rotator.service` — oneshot unit that runs the script (used by the timer)
- `linux-wallpaper-rotator-login.service` — oneshot unit that sets a fresh wallpaper
  at every login / session start (boot, logout→login, shutdown→start)

**Installed on your system:**
- `~/.local/bin/wallpaper-rotator.sh` — the script
- `~/.config/systemd/user/wallpaper-rotator.{service,timer}` — scheduled rotation
- `~/.config/systemd/user/wallpaper-rotator-login.service` — change at login
- `~/.config/wallpaper-rotator.conf` — your settings (directories, interval, order, …)
- `~/.config/wallpaper-rotator.last` — remembers the last image (for no-repeat / sequential)
