#!/usr/bin/env bash
# Set a random wallpaper from a directory, for the configured desktop environment.
# Reads its settings from ~/.config/wallpaper-rotator.conf (written by setup.sh).
set -e

# --auto marks scheduled runs (timer/login); manual runs omit it and ignore the
# on-battery pause.
AUTO=0
FORCED_IMG=""
for a in "$@"; do
  case "$a" in
    --auto) AUTO=1 ;;
    *) [ -f "$a" ] && FORCED_IMG="$a" ;;   # explicit image to set now
  esac
done

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="$CFG/wallpaper-rotator.conf"
# Defaults, overridden by the config file.
DE="gnome"
WALLPAPER_DIRS=()                    # wallpaper directories (listed in the config)
ORDER="shuffle"                      # shuffle | sequential
ON_BATTERY="no"                      # no = AC only | yes = also on battery
SHOW_LABEL="yes"                     # stamp distro label + logo (needs ImageMagick)
# INTERVAL default is seeded from the installed timer, so an unset config key
# leaves the current schedule unchanged.
INTERVAL="15min"
_timer="$CFG/systemd/user/wallpaper-rotator.timer"
[ -f "$_timer" ] && INTERVAL="$(sed -n 's/^OnUnitActiveSec=//p' "$_timer" | head -n1)"
[ -n "$INTERVAL" ] || INTERVAL="15min"
[ -f "$CONF" ] && . "$CONF"

# Backward compatibility with older config keys (SHOW_NAME, DIR/EXTRA_DIRS/USE_*).
[ -n "${SHOW_NAME:-}" ] && SHOW_LABEL="$SHOW_NAME"
if [ "${#WALLPAPER_DIRS[@]}" -eq 0 ]; then
  [ "${USE_LOCAL:-yes}" = "yes" ] && [ -n "${DIR:-}" ] && WALLPAPER_DIRS+=("$DIR")
  if [ -n "${EXTRA_DIRS:-}" ]; then
    IFS=':' read -ra _e <<< "$EXTRA_DIRS"
    for d in "${_e[@]}"; do [ -n "$d" ] && WALLPAPER_DIRS+=("$d"); done
  fi
fi

# Last-shown image, for no-repeat shuffle and sequential order.
STATE="$CFG/wallpaper-rotator.last"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-rotator"   # labeled copies

# Give the setter tools access to the session bus when run by the timer.
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
export DISPLAY="${DISPLAY:-:0}"

# Serialize runs. Setup's `enable --now` fires the timer immediately (OnBootSec
# already elapsed), so its service run and setup's own run overlap — and one
# run's cleanup can delete the labeled file the other just set as the wallpaper,
# leaving a black desktop. Take an exclusive lock; skip if another run holds it.
# (Falls through without locking if flock or the cache dir isn't available.)
if command -v flock >/dev/null 2>&1 && mkdir -p "$CACHE" 2>/dev/null && exec 9>"$CACHE/.lock" 2>/dev/null; then
  flock -n 9 || { echo "Another wallpaper-rotator run is in progress — skipping." >&2; exit 0; }
fi

# Apply INTERVAL from the config to the systemd timer. Rewrites and restarts the
# timer only when the value changed; effective from the next scheduled run.
sync_timer() {
  local unit="$CFG/systemd/user/wallpaper-rotator.timer" cur
  [ -f "$unit" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  [[ "$INTERVAL" =~ ^[0-9]+(s|sec|seconds|m|min|minutes|h|hr|hour|hours|d|day|days)?$ ]] || return 0
  cur="$(sed -n 's/^OnUnitActiveSec=//p' "$unit" | head -n1)"
  [ "$cur" = "$INTERVAL" ] && return 0
  sed -i -e "s/^OnUnitActiveSec=.*/OnUnitActiveSec=$INTERVAL/" \
         -e "s/^OnActiveSec=.*/OnActiveSec=$INTERVAL/" \
         -e "s/^Description=.*/Description=Rotate wallpaper every $INTERVAL/" "$unit"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user restart wallpaper-rotator.timer 2>/dev/null || true
}
sync_timer

# Echo the available ImageMagick CLI ("magick", then "convert"), or nothing.
# Always returns 0 so `x="$(im_bin)"` never trips set -e.
im_bin() {
  command -v magick  >/dev/null 2>&1 && { echo magick;  return 0; }
  command -v convert >/dev/null 2>&1 && { echo convert; return 0; }
  return 0
}

# Install ImageMagick if missing. Manual runs only (a --auto run has no terminal
# for a sudo prompt).
ensure_imagemagick() {
  [ -n "$(im_bin)" ] && return 0
  [ "$AUTO" = 1 ] && return 1            # never prompt for sudo from the timer
  local SUDO=""                          # use sudo only if not root
  [ "$(id -u)" -ne 0 ] && { command -v sudo >/dev/null 2>&1 && SUDO="sudo" || return 1; }
  echo "ImageMagick not found — installing it (needed to stamp the label)..." >&2
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y imagemagick
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y ImageMagick
  elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y ImageMagick
  elif command -v pacman  >/dev/null 2>&1; then $SUDO pacman -S --noconfirm imagemagick
  elif command -v zypper  >/dev/null 2>&1; then $SUDO zypper install -y ImageMagick
  elif command -v apk     >/dev/null 2>&1; then $SUDO apk add imagemagick
  else echo "No known package manager — install ImageMagick manually." >&2; return 1
  fi
  [ -n "$(im_bin)" ]
}

# Primary screen resolution as "WxH". Reads the kernel DRM modes (X11 + Wayland),
# then xrandr, then a default.
screen_res() {
  local f line
  for f in /sys/class/drm/*/modes; do
    [ -r "$f" ] || continue
    read -r line < "$f" 2>/dev/null || continue
    if [[ "$line" =~ ^([0-9]+)x([0-9]+) ]]; then
      echo "${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"; return 0
    fi
  done
  if command -v xrandr >/dev/null 2>&1; then
    line="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
    [[ "$line" =~ ^([0-9]+)x([0-9]+) ]] && { echo "${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"; return 0; }
  fi
  echo "1920x1080"
}

# Percent-encode a path into a file:// URI (GNOME/Cinnamon). Byte-wise under
# LC_ALL=C for correct UTF-8; keeps '/' and unreserved characters.
file_uri() {
  local s="$1" out="" i c LC_ALL=C
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~/-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf 'file://%s' "$out"
}

# Echo an image's pixel size as "W H" via ImageMagick, then identify, then file.
# Prints nothing and returns 1 if undetermined.
image_size() {
  local w h out im
  im="$(im_bin)"
  if [ -n "$im" ]; then
    read -r w h < <("$im" "$1" -format '%w %h\n' info: 2>/dev/null) || true
    [ -n "$w" ] && [ -n "$h" ] && { echo "$w $h"; return 0; }
  fi
  if command -v identify >/dev/null 2>&1; then
    read -r w h < <(identify -format '%w %h\n' "$1" 2>/dev/null | head -n1) || true
    [ -n "$w" ] && [ -n "$h" ] && { echo "$w $h"; return 0; }
  fi
  out="$(file -b -- "$1" 2>/dev/null || true)"
  if [[ "$out" =~ ([0-9]+)[[:space:]]?x[[:space:]]?([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; return 0
  fi
  return 1
}

# Choose a fit mode from the image and screen sizes. Echoes cover | contain |
# center:  tiny image -> center;  crop < ~35% -> cover;  otherwise -> contain.
fit_mode() {
  awk -v iw="$1" -v ih="$2" -v sw="$3" -v sh="$4" 'BEGIN{
    if(iw<=0||ih<=0||sw<=0||sh<=0){print "cover"; exit}
    if(iw < sw*0.5 && ih < sh*0.5){print "center"; exit}
    sx=sw/iw; sy=sh/ih;
    smin=(sx<sy)?sx:sy; smax=(sx>sy)?sx:sy;
    cropfrac=1-smin/smax;
    if(cropfrac<=0.35) print "cover"; else print "contain";
  }'
}

# Echo a path to the distro's logo (SVG preferred), or nothing. Called via
# command substitution, so sourcing /etc/os-release here does not leak globals.
distro_logo() {
  local id="" like="" logo="" c key
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    id="${ID:-}"; like="${ID_LIKE:-}"; logo="${LOGO:-}"
  fi
  # 1) os-release LOGO icon name, SVG-first in the standard icon dirs.
  if [ -n "$logo" ]; then
    for c in \
      "/usr/share/icons/hicolor/scalable/apps/$logo.svg" \
      "/usr/share/pixmaps/$logo.svg" \
      "/usr/share/icons/hicolor/256x256/apps/$logo.png" \
      "/usr/share/icons/hicolor/128x128/apps/$logo.png" \
      "/usr/share/pixmaps/$logo.png"; do
      [ -r "$c" ] && { echo "$c"; return 0; }
    done
  fi
  # 2) Per-distro locations (ID, then ID_LIKE), SVG first.
  for key in $id $like; do
    case "$key" in
      debian)      for c in /usr/share/desktop-base/debian-logos/logo.svg \
                            /usr/share/pixmaps/debian-logo.png; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      ubuntu)      for c in /usr/share/icons/hicolor/scalable/apps/ubuntu-logo-icon.svg \
                            /usr/share/pixmaps/ubuntu-logo-icon.png \
                            /usr/share/plymouth/ubuntu-logo.png; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      arch|archlinux) for c in /usr/share/pixmaps/archlinux-logo.svg \
                            /usr/share/icons/hicolor/scalable/apps/archlinux-logo.svg \
                            /usr/share/pixmaps/archlinux-logo.png; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      fedora|rhel|centos) for c in /usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg \
                            /usr/share/pixmaps/fedora-logo.png; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      opensuse*|suse|sles|sled) for c in /usr/share/icons/hicolor/scalable/apps/distributor-logo.svg \
                            /usr/share/pixmaps/distributor-logo.png; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      gentoo)      for c in /usr/share/pixmaps/gentoo-logo.svg \
                            /usr/share/icons/hicolor/scalable/apps/distributor-logo-gentoo.svg; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      linuxmint)   for c in /usr/share/icons/hicolor/scalable/apps/linuxmint-logo-badge.svg \
                            /usr/share/icons/hicolor/scalable/places/start-here-mint.svg; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
      manjaro)     for c in /usr/share/icons/hicolor/scalable/apps/manjaro.svg \
                            /usr/share/pixmaps/manjaro.png; do [ -r "$c" ] && { echo "$c"; return 0; }; done ;;
    esac
  done
  # 3) Generic distributor logo, then Tux.
  for c in /usr/share/icons/hicolor/scalable/apps/distributor-logo.svg \
           /usr/share/pixmaps/distributor-logo.png \
           /usr/share/pixmaps/tux.png; do
    [ -r "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# Echo "<distro name>_<kernel>" with spaces as underscores, e.g.
# "Debian_GNU/Linux_6.12.94+deb13-amd64". Called via command substitution.
distro_label() {
  local name="" s
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    name="${NAME:-${PRETTY_NAME:-${ID:-Linux}}}"
  fi
  [ -n "$name" ] || name="Linux"
  s="$name $(uname -r)"
  echo "${s// /_}"
}

# Echo the desktop UI font family, else fontconfig's sans, else DejaVu Sans.
# The trailing point size and style word from GSettings font-name are stripped.
ui_font() {
  local f=""
  case "$DE" in
    gnome|unity) f="$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null)" ;;
    cinnamon)    f="$(gsettings get org.cinnamon.desktop.interface font-name 2>/dev/null)" ;;
    mate)        f="$(gsettings get org.mate.interface font-name 2>/dev/null)" ;;
  esac
  f="${f#\'}"; f="${f%\'}"                        # strip surrounding quotes
  if [ -n "$f" ]; then
    f="$(awk '{
      if ($NF ~ /^[0-9]+(\.[0-9]+)?$/) NF=NF-1;   # drop trailing point size
      if ($NF ~ /^(Bold|Italic|Oblique|Light|Medium|Regular|Book|Thin|Black|Heavy|Semilight|Semibold|Demibold|Demi|Condensed)$/) NF=NF-1;
      sub(/[ \t]+$/,""); print }' <<<"$f")"
  fi
  if [ -z "$f" ] && command -v fc-match >/dev/null 2>&1; then
    f="$(fc-match -f '%{family[0]}' sans 2>/dev/null)"
  fi
  [ -n "$f" ] || f="DejaVu Sans"
  echo "$f"
}

# True if on AC power (or a desktop with no battery at all). One pass: an online
# Mains supply wins immediately; otherwise a battery with no online Mains means
# we are on battery; no supplies at all => desktop => treat as AC.
on_ac() {
  local ps saw_batt=0
  for ps in /sys/class/power_supply/*; do
    [ -r "$ps/type" ] || continue
    case "$(cat "$ps/type")" in
      Mains)   [ "$(cat "$ps/online" 2>/dev/null)" = "1" ] && return 0 ;;
      Battery) saw_batt=1 ;;
    esac
  done
  [ "$saw_batt" = 1 ] && return 1
  return 0
}

# Automatic runs pause on battery when configured to; manual runs never do.
if [ "$AUTO" = 1 ] && [ "$ON_BATTERY" != "yes" ] && ! on_ac; then
  echo "On battery power (ON_BATTERY=no) — leaving wallpaper unchanged."
  exit 0
fi

# Gather images grouped by configured folder, so selection can be fair per folder
# instead of biased toward whichever folder holds the most images. Fills, in
# config order and skipping folders with no images:
#   IMAGES[]  every image      IMGROOT[]  its folder (parallel to IMAGES)
#   ROOTS[]   folders with images   ROOTSTART[]/ROOTLEN[]  each folder's slice of IMAGES
# Directories are optional, symlinks followed, names sorted, NUL-safe.
gather() {
  ROOTS=(); IMAGES=(); IMGROOT=(); ROOTSTART=(); ROOTLEN=()
  local r img group
  for r in "$@"; do
    [ -d "$r" ] || continue
    group=()
    mapfile -d '' -t group < <(find -L "$r" -type f \
      \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.webp' \) -print0 | sort -z)
    [ ${#group[@]} -eq 0 ] && continue
    ROOTS+=("$r"); ROOTSTART+=("${#IMAGES[@]}"); ROOTLEN+=("${#group[@]}")
    for img in "${group[@]}"; do IMAGES+=("$img"); IMGROOT+=("$r"); done
  done
}

# Gather from the configured directories only; no system-wallpaper fallback.
gather "${WALLPAPER_DIRS[@]}"

COUNT=${#IMAGES[@]}
[ "$COUNT" -eq 0 ] && [ -z "$FORCED_IMG" ] && {
  echo "No images found in your wallpaper directories. Add images, or add a directory to" >&2
  echo "WALLPAPER_DIRS in $CONF — leaving the wallpaper unchanged." >&2
  exit 1
}

LAST=""
[ -f "$STATE" ] && LAST="$(cat "$STATE")"
NF=${#ROOTS[@]}

# Choose the next image according to ORDER, giving every folder equal turns
# regardless of how many images it holds.
case "$ORDER" in
  sequential)
    # Round-robin interleave of the per-folder (name-sorted) lists, so folders
    # alternate — folder0[0], folder1[0], …, folder0[1], … — then advance to the
    # image after the last one shown, wrapping around.
    SEQ=(); maxlen=0
    for i in "${ROOTLEN[@]}"; do [ "$i" -gt "$maxlen" ] && maxlen="$i"; done
    for (( k=0; k<maxlen; k++ )); do
      for (( ri=0; ri<NF; ri++ )); do
        [ "$k" -lt "${ROOTLEN[$ri]}" ] && SEQ+=("${IMAGES[$(( ROOTSTART[ri] + k ))]}")
      done
    done
    IMG="${SEQ[0]}"
    for i in "${!SEQ[@]}"; do
      if [ "${SEQ[$i]}" = "$LAST" ]; then
        IMG="${SEQ[$(( (i + 1) % ${#SEQ[@]} ))]}"
        break
      fi
    done
    ;;
  *)
    # Shuffle: first pick a folder at random with equal weight (avoiding the last
    # folder when there are others), then a random image within it (avoiding an
    # immediate repeat). Equal weight per folder = small folders rotate as often
    # as large ones.
    LASTROOT=""          # the folder LAST came from, so we can move away from it
    for i in "${!IMAGES[@]}"; do
      [ "${IMAGES[$i]}" = "$LAST" ] && { LASTROOT="${IMGROOT[$i]}"; break; }
    done
    if [ "$NF" -le 1 ]; then
      pickroot="${ROOTS[0]}"
    else
      pickroot="$(shuf -e -n1 -- "${ROOTS[@]}")"
      tries=0
      while [ "$pickroot" = "$LASTROOT" ] && [ "$tries" -lt 8 ]; do
        pickroot="$(shuf -e -n1 -- "${ROOTS[@]}")"
        tries=$((tries + 1))
      done
    fi
    pool=()
    for i in "${!IMAGES[@]}"; do
      [ "${IMGROOT[$i]}" = "$pickroot" ] && pool+=("${IMAGES[$i]}")
    done
    IMG="$(shuf -e -n1 -- "${pool[@]}")"
    tries=0
    while [ ${#pool[@]} -gt 1 ] && [ "$IMG" = "$LAST" ] && [ "$tries" -lt 5 ]; do
      IMG="$(shuf -e -n1 -- "${pool[@]}")"
      tries=$((tries + 1))
    done
    ;;
esac

# A command-line image path overrides the pick above.
[ -n "$FORCED_IMG" ] && IMG="$FORCED_IMG"

# Screen and image geometry, computed once for the fit decision and the label.
read -r SW SH < <(screen_res | tr 'x' ' ') || true
SW="${SW:-1920}"; SH="${SH:-1080}"
read -r IMGW IMGH < <(image_size "$IMG") || true
IMGW="${IMGW:-1920}"; IMGH="${IMGH:-1080}"

# Fill mode is always auto-detected (not a user setting); translated per desktop
# further down.
MODE="$(fit_mode "$IMGW" "$IMGH" "$SW" "$SH")"
[ -n "$MODE" ] || MODE="cover"

# Resolve the label text and emblem once; reused for stamping and the report.
DLABEL="$(distro_label)"
LOGO="$(distro_logo || true)"

# Fast first paint: if the desktop isn't already showing one of our wallpapers
# (e.g. right after install, or after uninstall reset the wallpaper), stamping
# the label takes a couple of seconds — so set the raw image NOW to avoid a gap,
# then the labelled copy replaces it below. Normal rotations already show the
# previous wallpaper meanwhile, so they skip this (no double transition).
if [ "$SHOW_LABEL" = "yes" ]; then
  case "$DE" in
    gnome|unity)
      case "$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)" in
        *"/wallpaper-rotator/"*) : ;;
        *) u="$(file_uri "$IMG")"
           gsettings set org.gnome.desktop.background picture-uri "$u"
           gsettings set org.gnome.desktop.background picture-uri-dark "$u" ;;
      esac ;;
    cinnamon)
      case "$(gsettings get org.cinnamon.desktop.background picture-uri 2>/dev/null)" in
        *"/wallpaper-rotator/"*) : ;;
        *) gsettings set org.cinnamon.desktop.background picture-uri "$(file_uri "$IMG")" ;;
      esac ;;
    mate)
      case "$(gsettings get org.mate.background picture-filename 2>/dev/null)" in
        *"/wallpaper-rotator/"*) : ;;
        *) gsettings set org.mate.background picture-filename "$IMG" ;;
      esac ;;
  esac
fi

# Optionally stamp the label onto a copy of the image (needs ImageMagick) and
# point the desktop at the copy. STATE keeps the original path.
ORIG="$IMG"
if [ "$SHOW_LABEL" = "yes" ]; then
  ensure_imagemagick || true            # install it if missing (manual runs only)
  IM="$(im_bin)"
  if [ -n "$IM" ]; then
    mkdir -p "$CACHE"
    # Unique name so the desktop sees a changed URI. The previous labeled copy is
    # kept until AFTER the new wallpaper is live (cleaned up at the end) so the
    # desktop never crossfades from a deleted file — which caused a black flash.
    LABELED="$CACHE/labeled-$$-$(date +%s).png"
    FONT="$(ui_font)"                     # DLABEL/LOGO resolved above
    # The desktop crops the image to COVER the screen, so the label must sit in
    # the visible centre-cropped area. Computed in image pixels:
    #   f     = cover scale = max(SW/IW, SH/IH)
    #   ix,iy = pixels cropped off each side/top
    #   sizes and margins are set in screen px then divided by f, for a constant
    #   on-screen size and inset across images.
    read -r PT RX DY MAXW LH LDY < <(awk -v iw="$IMGW" -v ih="$IMGH" -v sw="$SW" -v sh="$SH" 'BEGIN{
      f=sw/iw; g=sh/ih; if(g>f) f=g;          # cover scale = max
      vw=sw/f; vh=sh/f;                         # visible area in image px
      ix=(iw-vw)/2; iy=(ih-vh)/2;               # cropped-off margin each side
      pt=int(16.25/f+0.5); if(pt<10)pt=10;      # ~16 screen px tall
      mr=60/f; mb=90/f; ml=40/f;                # screen-px margins -> image px
      dy=int(iy+mb+0.5);
      lh=int(pt*4.5+0.5); if(lh<36)lh=36;       # distro emblem ~4.5x the text height
      ldy=dy+pt+int(pt*0.5+0.5);                 # sit the swirl just above the text
      printf "%d %d %d %d %d %d\n", pt, int(ix+mr+0.5), dy, int(vw-mr-ml+0.5), lh, ldy }')
    # Offset from the visible bottom-right corner (+X from right, +Y from bottom).
    OFF="+${RX}+${DY}"
    # Shrink the point size only if the label overflows the visible width.
    TXTW="$("$IM" -background none -family "$FONT" -style Normal -pointsize "$PT" \
              label:"$DLABEL" -format '%w' info: 2>/dev/null)"
    if [ -n "$TXTW" ] && [ "$MAXW" -gt 0 ] && [ "$TXTW" -gt "$MAXW" ]; then
      PT="$(awk -v pt="$PT" -v maxw="$MAXW" -v txtw="$TXTW" 'BEGIN{p=int(pt*maxw/txtw); print (p<8)?8:p}')"
      TXTW="$("$IM" -background none -family "$FONT" -style Normal -pointsize "$PT" \
                label:"$DLABEL" -format '%w' info: 2>/dev/null)"
    fi
    # Random label colour, fresh each time the wallpaper changes: mostly a vivid
    # NEON (random hue, full saturation), sometimes a neutral black/grey/white.
    # The lightness is set by the patch behind the text so it stays readable —
    # a light shade over a dark spot, a dark shade over a light one. No
    # outline/shadow; one solid colour.
    CW=$(( ${TXTW:-300} + 20 )); CH=$(( PT + 20 ))
    read -r PR PG PB < <("$IM" "$IMG" -gravity SouthEast -crop "${CW}x${CH}${OFF}" +repage \
              -resize 1x1! -format '%[fx:r] %[fx:g] %[fx:b]\n' info: 2>/dev/null) || true
    COLOR="$(awk -v r="${PR:-0}" -v g="${PG:-0}" -v b="${PB:-0}" \
                 -v h="$((RANDOM % 360))" -v roll="$((RANDOM % 100))" 'BEGIN{
      lum=0.2126*r+0.7152*g+0.0722*b;                 # brightness of the patch (readability only)
      dark=(lum<=0.5);                                 # dark spot -> use a light colour, and vice versa
      if(roll<30){                                      # ~30%: neutral black / grey / white
        S=0;
        if(dark) L=(roll<15)?0.95:0.78;                # white or light grey
        else     L=(roll<15)?0.10:0.30;                # black or dark grey
      } else {                                          # ~70%: vivid neon, random hue
        S=1.0;
        L=dark?0.66:0.32;                               # bright neon on dark, deep neon on light
      }
      a=2*L-1; if(a<0)a=-a; C=(1-a)*S;                 # hsl(h,S,L) -> rgb
      hp=h/60; t=hp; while(t>=2)t-=2; tt=t-1; if(tt<0)tt=-tt; X=C*(1-tt);
      if(hp<1){rr=C;gg=X;bb=0} else if(hp<2){rr=X;gg=C;bb=0} else if(hp<3){rr=0;gg=C;bb=X}
      else if(hp<4){rr=0;gg=X;bb=C} else if(hp<5){rr=X;gg=0;bb=C} else {rr=C;gg=0;bb=X}
      m=L-C/2;
      R=int((rr+m)*255+0.5); G=int((gg+m)*255+0.5); B=int((bb+m)*255+0.5);
      if(R<0)R=0;if(R>255)R=255;if(G<0)G=0;if(G>255)G=255;if(B<0)B=0;if(B>255)B=255;
      printf "#%02x%02x%02x", R,G,B;
    }')"
    [ -n "$COLOR" ] || COLOR="#f5f5f5"
    # Stamp the text, plus the emblem above it in the same COLOR, right-aligned.
    # -density/-background precede the SVG: high density so -resize only
    # downscales (smooth edges); -background none keeps transparency. Falls back
    # to text-only if the composite fails.
    # NOTE: the logo's -density 512 leaks past the ) and would scale the text
    # pointsize (~7x) — reset -density 72 before the annotate so the text is sized
    # in pixels.
    STAMPED=0
    if [ -n "$LOGO" ] && "$IM" "$IMG" \
        \( -density 512 -background none "$LOGO" -resize "x${LH}" -fill "$COLOR" -colorize 100 \) \
        -gravity SouthEast -geometry "+${RX}+${LDY}" -composite \
        -density 72 -pointsize "$PT" -family "$FONT" -style Normal -fill "$COLOR" \
        -annotate "$OFF" "$DLABEL" "$LABELED" 2>/dev/null; then
      STAMPED=1
    fi
    if [ "$STAMPED" -eq 0 ] && "$IM" "$IMG" \
        -gravity SouthEast -pointsize "$PT" -family "$FONT" -style Normal \
        -fill "$COLOR" \
        -annotate "$OFF" "$DLABEL" "$LABELED" 2>/dev/null; then
      STAMPED=1
    fi
    if [ "$STAMPED" -eq 1 ]; then
      IMG="$LABELED"
    else
      echo "Could not stamp the label (ImageMagick error) — using original image." >&2
    fi
  else
    echo "SHOW_LABEL=yes but ImageMagick not installed — using unlabeled image." >&2
  fi
fi

# Translate the fill mode per desktop; defaults are the "cover" values.
GSET="zoom"          # gnome/cinnamon/mate  picture-options
XFS=5                # xfce  image-style: 5=Zoomed 4=Scaled 3=Stretched 1=Centered
KFILL=2              # kde   FillMode: 2=Crop 1=Fit 0=Stretch 6=Pad(centre)
FEHBG="--bg-fill"    # feh
PCM="crop"           # pcmanfm  --wallpaper-mode
case "$MODE" in
  contain) GSET="scaled";    XFS=4; KFILL=1; FEHBG="--bg-max";    PCM="fit" ;;
  center)  GSET="centered";  XFS=1; KFILL=6; FEHBG="--bg-center"; PCM="center" ;;
esac

# Set a gsettings key only if its value changed. Re-writing picture-options
# forces the desktop to re-init the background (a visible flash), so we skip it
# when the fill mode is unchanged — and set the image URI first for a smooth
# crossfade to the already-rendered file.
gset_if() { [ "$(gsettings get "$1" "$2" 2>/dev/null)" = "'$3'" ] || gsettings set "$1" "$2" "$3"; }

# Apply it: set both the image and the auto-chosen fill/scaling mode.
case "$DE" in
  gnome|unity)
    URI="$(file_uri "$IMG")"
    gsettings set org.gnome.desktop.background picture-uri "$URI"
    gsettings set org.gnome.desktop.background picture-uri-dark "$URI"
    gset_if org.gnome.desktop.background picture-options "$GSET"
    ;;
  cinnamon)
    gsettings set org.cinnamon.desktop.background picture-uri "$(file_uri "$IMG")"
    gset_if org.cinnamon.desktop.background picture-options "$GSET"
    ;;
  mate)
    gsettings set org.mate.background picture-filename "$IMG"
    gset_if org.mate.background picture-options "$GSET"
    ;;
  kde)
    plasma-apply-wallpaperimage "$IMG"
    # plasma-apply-wallpaperimage sets only the image; set the fill mode too.
    QDBUS="$(command -v qdbus || command -v qdbus6 || command -v qdbus-qt6 || true)"
    if [ -n "$QDBUS" ]; then
      "$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
        var ds = desktops();
        for (var i = 0; i < ds.length; i++) {
          ds[i].currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
          ds[i].writeConfig('FillMode', $KFILL);
        }" >/dev/null 2>&1 || true
    fi
    ;;
  xfce)
    for prop in $(xfconf-query -c xfce4-desktop -l | grep '/last-image$'); do
      xfconf-query -c xfce4-desktop -p "$prop" -s "$IMG"
      style="${prop%/last-image}/image-style"
      xfconf-query -c xfce4-desktop -p "$style" -n -t int -s "$XFS" 2>/dev/null \
        || xfconf-query -c xfce4-desktop -p "$style" -s "$XFS" 2>/dev/null || true
    done
    ;;
  lxde|lxqt)
    if command -v pcmanfm-qt >/dev/null 2>&1; then
      pcmanfm-qt --set-wallpaper="$IMG" --wallpaper-mode="$PCM"
    else
      pcmanfm --set-wallpaper="$IMG" --wallpaper-mode="$PCM"
    fi
    ;;
  feh)
    feh "$FEHBG" "$IMG"
    ;;
  *)
    echo "Unknown desktop '$DE' — edit $CONF" >&2; exit 1
    ;;
esac

# Record the shown image in the state file for no-repeat / sequential ordering.
printf '%s\n' "$ORIG" > "$STATE"

# Now that the new wallpaper is live, remove older labeled copies (kept the
# in-use one so the transition never referenced a deleted file).
[ -d "$CACHE" ] && find "$CACHE" -maxdepth 1 -name 'labeled-*.png' \
  ! -name "$(basename -- "$IMG")" -delete 2>/dev/null || true

# Report the label and emblem (not the image name).
if [ -n "$LOGO" ]; then EMBLEM="$(basename -- "$LOGO")"; else EMBLEM="none"; fi
echo "Wallpaper set  ($DLABEL, emblem: $EMBLEM, desktop: $DE, order: $ORDER, fit: $MODE, screen ${SW}x${SH})"

# Manual runs only: point the user at the config (kept out of the journal).
if [ "$AUTO" = 0 ]; then
  echo "Note: to personalise your preferences — wallpaper directories, rotation interval," >&2
  echo "      order, battery behaviour, and the on-image label — please edit your"      >&2
  echo "      configuration file at $CONF. Changes apply at the next rotation."         >&2
fi
