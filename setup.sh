#!/usr/bin/env bash
# Setup for the Linux wallpaper rotator: installs a systemd user timer and login
# service, writes the configuration, and (if the label is enabled) installs
# ImageMagick. Interactive; run from the project directory.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/wallpaper-rotator.conf"
BIN="$HOME/.local/bin/wallpaper-rotator.sh"
UNIT_DIR="$HOME/.config/systemd/user"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-rotator"

LINE="────────────────────────────────────────────────────────────"
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { echo; printf '%s\n' "$LINE"; bold "  $1"; printf '%s\n' "$LINE"; }

# Show a failure banner if any installation step errors out.
PHASE=""
trap 'echo; printf "%s\n" "$LINE"; bold "  [FAILED]  Setup did not complete${PHASE:+  —  $PHASE}"; printf "%s\n" "$LINE"; echo; exit 1' ERR

# True on a laptop (has a battery).
has_battery() {
  local ps
  for ps in /sys/class/power_supply/*; do
    [ -r "$ps/type" ] || continue
    [ "$(cat "$ps/type")" = "Battery" ] && return 0
  done
  return 1
}

# Auto-detect the desktop environment.
detect() {
  local d="${XDG_CURRENT_DESKTOP:-$DESKTOP_SESSION}"; d="${d,,}"
  case "$d" in
    *gnome*|*ubuntu*) echo gnome ;;
    *cinnamon*)       echo cinnamon ;;
    *mate*)           echo mate ;;
    *kde*|*plasma*)   echo kde ;;
    *xfce*)           echo xfce ;;
    *lxqt*|*lxde*)    echo lxde ;;
    *)                echo gnome ;;
  esac
}

# Numbered-choice question. The menu is drawn on stderr; the chosen number is
# printed on stdout (so it can be captured).
ask_choice() {   # ask_choice "explanation" default# option1 option2 ...
  local q="$1" def="$2"; shift 2
  local opts=("$@") i n mark ans
  { [ -n "$q" ] && echo "  $q"
    for i in "${!opts[@]}"; do
      n=$((i+1)); mark=""; [ "$n" = "$def" ] && mark="   [default]"
      printf "    %d) %s%s\n" "$n" "${opts[$i]}" "$mark"
    done
    printf "    Choice > "
  } >&2
  read -r ans || true
  printf '%s' "${ans:-$def}"
}

# Free-text question with a default. The value is printed on stdout.
ask_text() {   # ask_text "explanation" default [hint]
  local q="$1" def="$2" hint="${3:-}" ans
  { echo "  $q"; [ -n "$hint" ] && echo "    $hint"; printf "    > "; } >&2
  read -r ans || true
  printf '%s' "${ans:-$def}"
}

# Short confirmation line printed after a choice is made.
note() { printf "    \033[32m✓\033[0m %s\n" "$1"; }

# Aligned "Label : value" row for the final summary.
srow() { printf "    %-19s :  %s\n" "$1" "$2"; }

# Install ImageMagick if it is missing (required for the label). Best-effort;
# uses the system package manager and may prompt for sudo.
install_imagemagick() {
  command -v magick  >/dev/null 2>&1 && return 0
  command -v convert >/dev/null 2>&1 && return 0
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && { command -v sudo >/dev/null 2>&1 && SUDO="sudo" || return 1; }
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y imagemagick
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y ImageMagick
  elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y ImageMagick
  elif command -v pacman  >/dev/null 2>&1; then $SUDO pacman -S --noconfirm imagemagick
  elif command -v zypper  >/dev/null 2>&1; then $SUDO zypper install -y ImageMagick
  elif command -v apk     >/dev/null 2>&1; then $SUDO apk add imagemagick
  else return 1
  fi
  command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1
}

# ---- defaults ------------------------------------------------------------
DETECTED="$(detect)"
DISTRO="$( . /etc/os-release 2>/dev/null || true; echo "${PRETTY_NAME:-${NAME:-Linux}}" )"
declare -A DENAME=( [gnome]="GNOME" [cinnamon]="Cinnamon" [mate]="MATE" [kde]="KDE" [xfce]="XFCE" [lxde]="LXDE" [feh]="feh" )
DIR_DEF="$HOME/Pictures/Wallpapers"
ORDER="shuffle"
ON_BATTERY="no"
SHOW_LABEL="yes"

echo
printf '%s\n' "$LINE"
bold "  WALLPAPER ROTATOR — SETUP"
printf '%s\n' "$LINE"

# ---- Step 1: desktop (auto-detected) -------------------------------------
step "Step 1 of 4  ·  Desktop environment"
declare -A DEMAP=( [1]=gnome [2]=cinnamon [3]=mate [4]=kde [5]=xfce [6]=lxde [7]=feh )
DNUM=1; for k in "${!DEMAP[@]}"; do [ "${DEMAP[$k]}" = "$DETECTED" ] && DNUM="$k"; done
ch="$(ask_choice "Detected automatically. Enter for default, or select another." "$DNUM" \
  "GNOME" "Cinnamon" "MATE" "KDE Plasma" "XFCE" "LXDE / LXQt" "Other X11 (feh)")"
DE="${DEMAP[$ch]:-$DETECTED}"
note "Desktop ${DENAME[$DE]:-$DE} selected."

# ---- Step 2: wallpaper directory --------------------------------------------
step "Step 2 of 4  ·  Wallpaper Directory"
DIR="$(ask_text "Directory containing your wallpaper images." "$DIR_DEF" \
  "(To use several directories, edit $CONF after setup.)
    [Default = $DIR_DEF]")"
note "Directory set to $DIR"

# ---- Step 3: rotation interval (minutes) ---------------------------------
step "Step 3 of 4  ·  Rotation interval"
while :; do
  MINS="$(ask_text "How often should the wallpaper rotate? Enter a number of minutes." "15" \
    "(e.g. 5, 15, 30, 60, 90, 120 ...)
    [Default 15 mins]")"
  [[ "$MINS" =~ ^[0-9]+$ ]] && [ "$MINS" -gt 0 ] && break
  echo "    Please enter a whole number of minutes (for example, 15)." >&2
done
INTERVAL="${MINS}min"
note "Rotation every ${MINS} minutes selected."

# ---- Step 4: advanced settings (list; details on selection) --------------
step "Step 4 of 4  ·  Advanced settings"
echo "  Type a number to change a setting, or press Enter to finish."
while :; do
  echo
  printf "    1) Order    [%s]\n" "$ORDER"
  has_battery && printf "    2) Power    [%s]\n" "$([ "$ON_BATTERY" = no ] && echo 'only on AC' || echo 'AC and battery')"
  printf "    3) Label    [%s]\n" "$([ "$SHOW_LABEL" = yes ] && echo 'on' || echo 'off')"
  printf "    Change which?\n    [Enter = done]\n    > "
  read -r pick || break
  case "$pick" in
    "") break ;;
    1) c="$(ask_choice "Order in which wallpapers are shown." "$([ "$ORDER" = shuffle ] && echo 1 || echo 2)" \
          "Shuffle — random, no repeats" "Sequential — file-name order")"
       [ "$c" = 2 ] && ORDER="sequential" || ORDER="shuffle"
       note "Order set to $ORDER." ;;
    2) if has_battery; then
         c="$(ask_choice "Behaviour while on battery power." "$([ "$ON_BATTERY" = no ] && echo 1 || echo 2)" \
            "Rotate only on AC power" "AC and battery")"
         [ "$c" = 2 ] && ON_BATTERY="yes" || ON_BATTERY="no"
         note "$([ "$ON_BATTERY" = yes ] && echo 'Rotates on AC and battery.' || echo 'Rotates only on AC power.')"
       fi ;;
    3) c="$(ask_choice "Stamp a label (distro name, kernel, logo) on each wallpaper." "$([ "$SHOW_LABEL" = yes ] && echo 1 || echo 2)" \
          "On — requires ImageMagick (installed automatically)" "Off")"
       [ "$c" = 2 ] && SHOW_LABEL="no" || SHOW_LABEL="yes"
       note "$([ "$SHOW_LABEL" = yes ] && echo 'Label enabled.' || echo 'Label disabled.')" ;;
  esac
done

# ---- installation --------------------------------------------------------
step "Installing"

PHASE="copying files"
mkdir -p "$HOME/.local/bin" "$UNIT_DIR" "$DIR"
install -m 755 "$HERE/wallpaper-rotator.sh"            "$BIN"
install -m 644 "$HERE/wallpaper-rotator.service"       "$UNIT_DIR/wallpaper-rotator.service"
install -m 644 "$HERE/wallpaper-rotator-login.service" "$UNIT_DIR/wallpaper-rotator-login.service"
echo "  [OK]  Script and service files installed."

PHASE="writing configuration"
cat > "$CONF" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
#  Wallpaper Rotator — your settings   (edit freely; applies on the NEXT rotation)
# ─────────────────────────────────────────────────────────────────────────────

# Your wallpaper directories — add as many as you like, ONE PER LINE, in quotes.
# They can be local disks, USB sticks, or mounted network/NAS directories.
# Put a '#' in front of a line to DISABLE that directory (it will be skipped).
# At least one directory must contain images (there is no system fallback).
# Rotation is fair per folder: each directory gets equal turns no matter how
# many images it holds, so a small folder isn't drowned out by a large one.
WALLPAPER_DIRS=(
    "$DIR"
  # "/mnt/nas/photos"        # example: a network/NAS directory (remove the # to use it)
)

# How often to rotate:  30s, 5min, 15min, 1h, …
INTERVAL="$INTERVAL"

# Order:  shuffle = random (no repeats)  |  sequential = file-name order
ORDER="$ORDER"

# On battery:  no = only on AC power  |  yes = keep rotating on battery
ON_BATTERY="$ON_BATTERY"

# Stamp the distro name + kernel and logo on the wallpaper?  yes | no  (needs ImageMagick)
SHOW_LABEL="$SHOW_LABEL"

# ── Advanced (usually leave as-is) ──────────────────────────────────────────
DE="$DE"                                 # gnome cinnamon mate kde xfce lxde feh
EOF
echo "  [OK]  Configuration written."

PHASE="creating the timer"
cat > "$UNIT_DIR/wallpaper-rotator.timer" <<EOF
[Unit]
Description=Rotate wallpaper every $INTERVAL

[Timer]
OnActiveSec=$INTERVAL
OnUnitActiveSec=$INTERVAL

[Install]
WantedBy=timers.target
EOF

PHASE="enabling services"
systemctl --user daemon-reload
systemctl --user enable --now wallpaper-rotator.timer        >/dev/null 2>&1
systemctl --user enable      wallpaper-rotator-login.service >/dev/null 2>&1
echo "  [OK]  Timer and login service enabled."

if [ "$SHOW_LABEL" = yes ]; then
  PHASE="installing ImageMagick"
  if install_imagemagick; then
    echo "  [OK]  ImageMagick is available."
  else
    echo "  [!!]  ImageMagick could not be installed — the label is skipped until it is."
  fi
fi
PHASE=""

# Apply one wallpaper now and report the outcome (an empty directory just means
# nothing changes yet — the timer will keep trying).
if "$BIN" >/dev/null 2>&1; then
  echo "  [OK]  First wallpaper applied."
else
  echo "  [!!]  No wallpaper applied yet — add images to your directory (the timer will keep trying)."
fi

# ---- success -------------------------------------------------------------
echo
printf '%s\n' "$LINE"
bold "  [SUCCESS]  Installation complete"
printf '%s\n' "$LINE"
echo
srow "Distro"              "$DISTRO"
srow "Desktop"             "${DENAME[$DE]:-$DE}"
srow "Wallpaper Directory" "$DIR"
srow "Interval"            "every $MINS mins"
srow "Order"               "$ORDER"
has_battery && srow "Power" "$([ "$ON_BATTERY" = no ] && echo 'only on AC' || echo 'AC and battery')"
srow "Label"               "$([ "$SHOW_LABEL" = yes ] && echo 'on' || echo 'off')"
echo
printf '%s\n' "$LINE"
srow "Script"    "$BIN"
srow "Config"    "$CONF"
srow "Services"  "$UNIT_DIR/wallpaper-rotator.{service,timer,-login.service}"
srow "Cache"     "$CACHE"
echo
printf '%s\n' "$LINE"
printf "    %-16s   →   %s\n" "Add wallpapers" "put images in $DIR, or add directories in the config"
printf "    %-16s   →   %s\n" "Rotate now"     "wallpaper-rotator.sh"
printf "    %-16s   →   %s\n" "Pause"          "systemctl --user disable --now wallpaper-rotator.timer"
printf "    %-16s   →   %s\n" "Settings"       "edit $CONF  (or re-run ./setup.sh)"
printf "    %-16s   →   %s\n" "Uninstall"      "./uninstall.sh"
printf '%s\n' "$LINE"
echo
