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
DIM=$'\033[2m'; RST=$'\033[0m'
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { echo; printf '%s\n' "$LINE"; printf '  \033[1;96m%s\033[0m\n' "$1"; printf '%s\n' "$LINE"; }  # active step = bright

STEPS_DONE=(); cur=1                                  # STEPS_DONE[n] = step n summary
is_back() { case "$1" in b|B|back|BACK) return 0 ;; *) return 1 ;; esac; }
# Redraw the wizard: clear, print the header, then the already-answered steps
# (those before the active one) dimmed, so only the current step stands out.
redraw() {
  if [ -t 1 ] && command -v clear >/dev/null 2>&1; then clear; fi
  echo
  printf '%s\n' "$LINE"; bold "  WALLPAPER ROTATOR — SETUP"; printf '%s\n' "$LINE"
  local i
  for (( i=1; i<cur; i++ )); do [ -n "${STEPS_DONE[$i]:-}" ] && printf "    ${DIM}%s${RST}\n" "${STEPS_DONE[$i]}"; done
}

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

# Aligned "Label : value" row for the final summary.
srow() { printf "    %-19s :  %s\n" "$1" "$2"; }

# Install ImageMagick (label stamping) and jpegtran (transcodes progressive JPEGs
# to baseline, working around libjpeg builds that garble them). Installs only what
# is missing. Best-effort; uses the system package manager, may prompt for sudo.
install_deps() {
  local need_im=1 need_jt=1
  { command -v magick || command -v convert; } >/dev/null 2>&1 && need_im=0
  command -v jpegtran >/dev/null 2>&1 && need_jt=0
  [ "$need_im" = 0 ] && [ "$need_jt" = 0 ] && return 0
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && { command -v sudo >/dev/null 2>&1 && SUDO="sudo" || return 1; }
  local mgr imp jtp
  if   command -v apt-get >/dev/null 2>&1; then mgr="$SUDO apt-get install -y";     imp=imagemagick; jtp=libjpeg-turbo-progs; $SUDO apt-get update -qq
  elif command -v dnf     >/dev/null 2>&1; then mgr="$SUDO dnf install -y";         imp=ImageMagick; jtp=libjpeg-turbo-utils
  elif command -v yum     >/dev/null 2>&1; then mgr="$SUDO yum install -y";         imp=ImageMagick; jtp=libjpeg-turbo-utils
  elif command -v pacman  >/dev/null 2>&1; then mgr="$SUDO pacman -S --noconfirm";  imp=imagemagick; jtp=libjpeg-turbo
  elif command -v zypper  >/dev/null 2>&1; then mgr="$SUDO zypper install -y";      imp=ImageMagick; jtp=libjpeg-turbo
  elif command -v apk     >/dev/null 2>&1; then mgr="$SUDO apk add";                imp=imagemagick; jtp=libjpeg-turbo-utils
  else return 1
  fi
  local pkgs=""
  [ "$need_im" = 1 ] && pkgs="$imp"
  [ "$need_jt" = 1 ] && pkgs="$pkgs $jtp"
  $mgr $pkgs
  { command -v magick || command -v convert; } >/dev/null 2>&1
}

# ---- defaults ------------------------------------------------------------
DETECTED="$(detect)"
DISTRO="$( . /etc/os-release 2>/dev/null || true; echo "${PRETTY_NAME:-${NAME:-Linux}}" )"
declare -A DENAME=( [gnome]="GNOME" [cinnamon]="Cinnamon" [mate]="MATE" [kde]="KDE" [xfce]="XFCE" [lxde]="LXDE" [feh]="feh" )
DIR_DEF="$HOME/Pictures/Wallpapers"
ORDER="shuffle"
ON_BATTERY="no"
SHOW_LABEL="yes"

# ---- interactive wizard (active step bright, answered dimmed; "b" = go back) --
declare -A DEMAP=( [1]=gnome [2]=cinnamon [3]=mate [4]=kde [5]=xfce [6]=lxde [7]=feh )

# Step 4 sub-menu renderer: the active sub-setting is bright, the others dimmed.
sub_line() {   # $1 key  $2 active-key  $3 text
  if   [ -z "$2" ];     then printf "    %s\n" "$3"
  elif [ "$1" = "$2" ]; then printf "    \033[1;96m%s\033[0m\n" "$3"
  else                       printf "    ${DIM}%s${RST}\n" "$3"; fi
}
redraw4() {    # $1 = active sub key (order|power|label) or "" for the menu
  redraw
  step "Step 4 of 4  ·  Advanced settings"
  sub_line order "$1" "1) Order   [$ORDER]"
  if has_battery; then sub_line power "$1" "2) Power   [$([ "$ON_BATTERY" = no ] && echo 'only on AC' || echo 'AC and battery')]"; fi
  sub_line label "$1" "3) Label   [$([ "$SHOW_LABEL" = yes ] && echo 'on' || echo 'off')]"
}

while [ "$cur" -le 4 ]; do
  case "$cur" in
    1)
      redraw; step "Step 1 of 4  ·  Desktop environment"
      DNUM=1; for k in "${!DEMAP[@]}"; do [ "${DEMAP[$k]}" = "${DE:-$DETECTED}" ] && DNUM="$k"; done
      ch="$(ask_choice "Detected automatically. Enter for default, or select another." "$DNUM" \
        "GNOME" "Cinnamon" "MATE" "KDE Plasma" "XFCE" "LXDE / LXQt" "Other X11 (feh)")"
      DE="${DEMAP[$ch]:-${DE:-$DETECTED}}"
      STEPS_DONE[1]="Step 1  ·  Desktop    :  ${DENAME[$DE]:-$DE}"
      cur=2 ;;
    2)
      redraw; step "Step 2 of 4  ·  Wallpaper directory"
      raw="$(ask_text "Directory containing your wallpaper images.   (b = back)" "${DIR:-$DIR_DEF}" \
        "(To use several directories, edit $CONF after setup.)
    [Default = ${DIR:-$DIR_DEF}]")"
      if is_back "$raw"; then cur=1; continue; fi
      DIR="$raw"; STEPS_DONE[2]="Step 2  ·  Directory  :  $DIR"; cur=3 ;;
    3)
      redraw; step "Step 3 of 4  ·  Rotation interval"
      while :; do
        raw="$(ask_text "How often should the wallpaper rotate? Number of minutes.   (b = back)" "${MINS:-15}" \
          "(e.g. 5, 15, 30, 60, 90, 120 ...)
    [Default ${MINS:-15} mins]")"
        if is_back "$raw"; then cur=2; continue 2; fi
        if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -gt 0 ]; then MINS="$raw"; break; fi
        echo "    Please enter a whole number of minutes (for example, 15)." >&2
      done
      INTERVAL="${MINS}min"; STEPS_DONE[3]="Step 3  ·  Interval   :  every $MINS min"; cur=4 ;;
    4)
      while :; do
        redraw4 ""
        printf "  Number to change a setting  ·  Enter = done  ·  b = back\n    > "
        read -r pick || pick=""
        if is_back "$pick"; then cur=3; break; fi
        case "$pick" in
          "") cur=5; break ;;
          1) redraw4 order
             c="$(ask_choice "Order in which wallpapers are shown." "$([ "$ORDER" = shuffle ] && echo 1 || echo 2)" \
                "Shuffle — random, no repeats" "Sequential — file-name order")"
             [ "$c" = 2 ] && ORDER="sequential" || ORDER="shuffle" ;;
          2) if has_battery; then
               redraw4 power
               c="$(ask_choice "Behaviour while on battery power." "$([ "$ON_BATTERY" = no ] && echo 1 || echo 2)" \
                  "Rotate only on AC power" "AC and battery")"
               [ "$c" = 2 ] && ON_BATTERY="yes" || ON_BATTERY="no"
             fi ;;
          3) redraw4 label
             c="$(ask_choice "Stamp a label (distro name, kernel, logo) on each wallpaper." "$([ "$SHOW_LABEL" = yes ] && echo 1 || echo 2)" \
                "On — requires ImageMagick (installed automatically)" "Off")"
             [ "$c" = 2 ] && SHOW_LABEL="no" || SHOW_LABEL="yes" ;;
        esac
      done ;;
  esac
done
if has_battery; then POW=" · power $([ "$ON_BATTERY" = yes ] && echo 'AC+battery' || echo 'AC only')"; else POW=""; fi
STEPS_DONE[4]="Step 4  ·  Advanced   :  order $ORDER · label $([ "$SHOW_LABEL" = yes ] && echo on || echo off)$POW"
cur=5; redraw

# ---- installation --------------------------------------------------------
step "Installing"

PHASE="copying files"
mkdir -p "$HOME/.local/bin" "$UNIT_DIR" "$DIR"
install -m 755 "$HERE/linux-wallpaper-rotator.sh"            "$BIN"
install -m 644 "$HERE/linux-wallpaper-rotator.service"       "$UNIT_DIR/wallpaper-rotator.service"
install -m 644 "$HERE/linux-wallpaper-rotator-login.service" "$UNIT_DIR/wallpaper-rotator-login.service"
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
# Shuffle shows every image once, in random order, before repeating; sequential
# goes in file-name order, interleaving the folders.
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
# Fire on time: systemd's default AccuracySec (1min) would let the timer drift.
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

PHASE="enabling services"
systemctl --user daemon-reload
systemctl --user enable --now wallpaper-rotator.timer        >/dev/null 2>&1
systemctl --user enable      wallpaper-rotator-login.service >/dev/null 2>&1
echo "  [OK]  Timer and login service enabled."

if [ "$SHOW_LABEL" = yes ]; then
  PHASE="installing ImageMagick + jpegtran"
  if install_deps; then
    echo "  [OK]  ImageMagick and jpegtran are available."
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
printf "    %-16s   →   %s\n" "Settings"       "edit $CONF  (or re-run ./linux-wallpaper-rotator.setup.sh)"
printf "    %-16s   →   %s\n" "Uninstall"      "./linux-wallpaper-rotator.uninstall.sh"
printf '%s\n' "$LINE"
echo
