#!/usr/bin/env bash
# Set a random wallpaper for the configured desktop, per ~/.config/wallpaper-rotator.conf.
set -e

# --auto marks scheduled runs (may pause on battery); a path argument forces that image.
AUTO=0
FORCED_IMG=""
for a in "$@"; do
  case "$a" in
    --auto) AUTO=1 ;;
    *) [ -f "$a" ] && FORCED_IMG="$a" ;;
  esac
done

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="$CFG/wallpaper-rotator.conf"
# Defaults; overridden by the config file.
DE="gnome"
WALLPAPER_DIRS=()
ORDER="shuffle"                      # shuffle | sequential
ON_BATTERY="no"                      # no = AC only | yes = also on battery
SHOW_LABEL="yes"                     # stamp distro label + logo (needs ImageMagick)
INTERVAL="15min"                     # seeded from the installed timer if present
_timer="$CFG/systemd/user/wallpaper-rotator.timer"
[ -f "$_timer" ] && INTERVAL="$(sed -n 's/^OnUnitActiveSec=//p' "$_timer" | head -n1)"
[ -n "$INTERVAL" ] || INTERVAL="15min"
[ -f "$CONF" ] && . "$CONF"

# Backward compatibility with older config keys.
[ -n "${SHOW_NAME:-}" ] && SHOW_LABEL="$SHOW_NAME"
if [ "${#WALLPAPER_DIRS[@]}" -eq 0 ]; then
  [ "${USE_LOCAL:-yes}" = "yes" ] && [ -n "${DIR:-}" ] && WALLPAPER_DIRS+=("$DIR")
  if [ -n "${EXTRA_DIRS:-}" ]; then
    IFS=':' read -ra _e <<< "$EXTRA_DIRS"
    for d in "${_e[@]}"; do [ -n "$d" ] && WALLPAPER_DIRS+=("$d"); done
  fi
fi

STATE="$CFG/wallpaper-rotator.last"   # last-shown image (sequential order)
DECK="$CFG/wallpaper-rotator.deck"    # shuffled playlist, consumed one per run
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-rotator"

# Reach the session bus/display when run from the timer.
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
export DISPLAY="${DISPLAY:-:0}"

# Serialise runs so overlapping runs never delete each other's in-use labeled file.
if command -v flock >/dev/null 2>&1 && mkdir -p "$CACHE" 2>/dev/null && exec 9>"$CACHE/.lock" 2>/dev/null; then
  flock -n 9 || { echo "Another wallpaper-rotator run is in progress — skipping." >&2; exit 0; }
fi

# Apply INTERVAL to the systemd timer; restart only when it changed.
sync_timer() {
  local unit="$CFG/systemd/user/wallpaper-rotator.timer" cur
  [ -f "$unit" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  # Pin AccuracySec so the timer fires on time (systemd's default is 1min).
  if ! grep -q '^AccuracySec=' "$unit"; then
    sed -i '/^OnUnitActiveSec=/a AccuracySec=1s' "$unit"
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart wallpaper-rotator.timer 2>/dev/null || true
  fi
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

# Echo "magick" or "convert" if available, else nothing (always returns 0).
im_bin() {
  command -v magick  >/dev/null 2>&1 && { echo magick;  return 0; }
  command -v convert >/dev/null 2>&1 && { echo convert; return 0; }
  return 0
}

# Choose the label colour from the image's palette. Reads an ImageMagick "%c"
# Reads a 64-colour histogram on stdin plus the spot behind the label (args 1-3), the
# whole-image average (args 4-6), and the patch colours actually behind the label as
# "cnt,R,G,B;..." (arg 7). Echoes "#rrggbb". For each palette colour it scores salience
# (distance from the image average) times a vivid bonus times readability^2, where
# readability is the worst-case contrast against every colour in the patch. So it takes a
# striking image colour when one reads clearly (a red door, a blue sky, an eye), the image
# own most contrasting real tone on a monochrome image (snow, a silhouette, an outline
# grey -- never a synthetic tint), and the least-bad colour on a hopeless multicolour
# patch. POSIX-awk (mawk and gawk).
pick_colour() {
  awk -v sr="$1" -v sg="$2" -v sb="$3" -v mr="$4" -v mg="$5" -v mb="$6" -v pp="$7" '
  function lin(c){ c/=255; return (c<=0.04045)? c/12.92 : exp(2.4*log((c+0.055)/1.055)) }
  function fx(t){ return (t>0.008856)? exp(log(t)/3) : 7.787*t+0.137931 }
  function relY(r,g,b){ return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b) }   # WCAG rel. luminance
  function setlab(r,g,b,   X,Y,Z){                     # -> _L _A _B (CIE Lab)
    X=(0.4124*lin(r)+0.3576*lin(g)+0.1805*lin(b))/0.95047;
    Y=(0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b));
    Z=(0.0193*lin(r)+0.1192*lin(g)+0.9505*lin(b))/1.08883;
    _L=116*fx(Y)-16; _A=500*(fx(X)-fx(Y)); _B=200*(fx(Y)-fx(Z));
  }
  BEGIN{ setlab(sr,sg,sb); sL=_L; sA=_A; sB=_B; sY=relY(sr,sg,sb)
         setlab(mr,mg,mb); mL=_L; mA=_A; mB=_B
         # Parse the patch colours "cnt,R,G,B;..." into luminances py[] with weights pw[].
         np=split(pp,PCH,";"); ptot=0; npc=0
         for(j=1;j<=np;j++){ if(PCH[j]=="") continue; if(split(PCH[j],q,",")<4) continue
           npc++; pw[npc]=q[1]+0; py[npc]=relY(q[2],q[3],q[4])
           setlab(q[2],q[3],q[4]); pa[npc]=_A; pb[npc]=_B; ptot+=q[1]+0 }
         CVIV=18; CMIN=40; best=0 }               # CVIV = chroma above which a colour counts as "vivid"
  {
    ci=index($0,":"); if(ci<=0) next; cnt=substr($0,1,ci-1)+0; if(cnt<CMIN) next;
    p1=index($0,"("); p2=index($0,")"); if(p1<=0||p2<=p1) next;
    trip=substr($0,p1+1,p2-p1-1); gsub(/[^0-9,]/,"",trip);
    if(split(trip,a,",")<3) next;
    setlab(a[1],a[2],a[3]); cC=sqrt(_A*_A+_B*_B); pY=relY(a[1],a[2],a[3]);
    # Readability R = worst-case luminance contrast against every significant colour actually
    # behind the label. A colour that matches any tile in a busy patch scores as unreadable,
    # so on a hopeless multicolour patch the least-bad (most readable) tone still wins.
    R=99;
    if(npc>0){ for(j=1;j<=npc;j++){ if(pw[j]<0.06*ptot) continue;
        hh=(pY>py[j])?pY:py[j]; ll=(pY>py[j])?py[j]:pY; cw=(hh+0.05)/(ll+0.05);
        abd=sqrt((_A-pa[j])^2+(_B-pb[j])^2); hu=1+abd/45; if(hu>cw) cw=hu;   # a different hue also reads
        if(cw<R) R=cw } }
    if(R>=99){ hh=(pY>sY)?pY:sY; ll=(pY>sY)?sY:pY; R=(hh+0.05)/(ll+0.05) }
    # A colour that blends into the patch (near-zero contrast with some tile behind it) is
    # not usable; keep only the least-bad one as a fallback for a hopeless multicolour patch.
    if(R<1.3){ if(R>fbR){fbR=R; fr=a[1]; fg=a[2]; fb=a[3]} next }
    dmean=sqrt((_L-mL)^2+(_A-mA)^2+(_B-mB)^2);                        # how far it stands out from the average
    # Among readable colours, favour a genuine striking one (its hue aids reading); a little
    # extra readability breaks ties. So a readable vivid subject wins, not a bland high-contrast tone.
    vivid=(cC>=CVIV)?(1+cC/25):1;
    s=dmean*vivid*sqrt(R)*exp(0.06*log(cnt));
    if(s>best){ best=s; br=a[1]; bg=a[2]; bb=a[3] }
  }
  END{
    if(best<=0){ if(fbR>0){ br=fr; bg=fg; bb=fb } else { br=(sY>0.5?20:240); bg=br; bb=br } }  # last resort
    # Gentle legibility floor against the patch average, keeping the hue.
    up=(relY(br,bg,bb)>=sY)
    for(t=0;t<24;t++){ pY=relY(br,bg,bb); hi=(pY>sY?pY:sY); lo=(pY>sY?sY:pY)
      if((hi+0.05)/(lo+0.05)>=1.9) break
      if(up){ br+=(255-br)*0.10; bg+=(255-bg)*0.10; bb+=(255-bb)*0.10 } else { br*=0.92; bg*=0.92; bb*=0.92 } }
    printf "#%02x%02x%02x", int(br+0.5), int(bg+0.5), int(bb+0.5)
  }'
}

# Install ImageMagick if missing (manual runs only; never prompts from the timer).
ensure_imagemagick() {
  [ -n "$(im_bin)" ] && return 0
  [ "$AUTO" = 1 ] && return 1
  local SUDO=""
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

# Primary screen resolution as "WxH": kernel DRM modes, then xrandr, then default.
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

# Percent-encode a path into a file:// URI (byte-wise under LC_ALL=C).
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

# Echo an image's pixel size as "W H" via ImageMagick, identify, then file; else return 1.
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

# Echo the fit mode from image/screen sizes: center (tiny), cover (crop<=35%), else contain.
fit_mode() {
  awk -v iw="$1" -v ih="$2" -v sw="$3" -v sh="$4" 'BEGIN{
    if(iw<=0||ih<=0||sw<=0||sh<=0){print "cover"; exit}
    if(iw < sw*0.5 && ih < sh*0.5){print "center"; exit}
    sx=sw/iw; sy=sh/ih;
    smin=(sx<sy)?sx:sy; smax=(sx>sy)?sx:sy;
    if(1-smin/smax<=0.35) print "cover"; else print "contain";
  }'
}

# Echo a path to the distro's logo (SVG preferred), or nothing.
distro_logo() {
  local id="" like="" logo="" c key
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    id="${ID:-}"; like="${ID_LIKE:-}"; logo="${LOGO:-}"
  fi
  # os-release LOGO icon name, SVG first.
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
  # Per-distro locations (ID, then ID_LIKE), SVG first.
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
  # Generic distributor logo, then Tux.
  for c in /usr/share/icons/hicolor/scalable/apps/distributor-logo.svg \
           /usr/share/pixmaps/distributor-logo.png \
           /usr/share/pixmaps/tux.png; do
    [ -r "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# Echo "<distro name>_<kernel>", spaces as underscores.
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

# Echo the desktop UI font family, else fontconfig sans, else DejaVu Sans.
ui_font() {
  local f=""
  case "$DE" in
    gnome|unity) f="$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null)" ;;
    cinnamon)    f="$(gsettings get org.cinnamon.desktop.interface font-name 2>/dev/null)" ;;
    mate)        f="$(gsettings get org.mate.interface font-name 2>/dev/null)" ;;
  esac
  f="${f#\'}"; f="${f%\'}"
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

# True on AC power, or on a desktop with no battery.
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

# Scheduled runs pause on battery when configured; manual runs never do.
if [ "$AUTO" = 1 ] && [ "$ON_BATTERY" != "yes" ] && ! on_ac; then
  echo "On battery power (ON_BATTERY=no) — leaving wallpaper unchanged."
  exit 0
fi

# Collect images from the given folders into the flat IMAGES[] (used by shuffle),
# plus each folder's slice ROOTS[]/ROOTSTART[]/ROOTLEN[] (used by sequential order).
gather() {
  ROOTS=(); IMAGES=(); ROOTSTART=(); ROOTLEN=()
  local r group
  for r in "$@"; do
    [ -d "$r" ] || continue
    group=()
    mapfile -d '' -t group < <(find -L "$r" -type f \
      \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.webp' \) -print0 | sort -z)
    [ ${#group[@]} -eq 0 ] && continue
    ROOTS+=("$r"); ROOTSTART+=("${#IMAGES[@]}"); ROOTLEN+=("${#group[@]}")
    IMAGES+=("${group[@]}")
  done
}
gather "${WALLPAPER_DIRS[@]}"

COUNT=${#IMAGES[@]}
[ "$COUNT" -eq 0 ] && [ -z "$FORCED_IMG" ] && {
  echo "No images found in your wallpaper directories. Add images, or add a directory to" >&2
  echo "WALLPAPER_DIRS in $CONF — leaving the wallpaper unchanged." >&2
  exit 1
}

# Choose the next image, giving every folder equal turns. A path argument skips this.
if [ -n "$FORCED_IMG" ]; then
  IMG="$FORCED_IMG"
else
  LAST=""
  [ -f "$STATE" ] && LAST="$(cat "$STATE")"
  NF=${#ROOTS[@]}
  case "$ORDER" in
    sequential)
      # Round-robin interleave of the per-folder lists, then advance past LAST.
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
      # Shuffle: play through a shuffled deck (all images) with no repeats until
      # every image is shown, then reshuffle. Deck file = count header + remaining
      # paths; rebuilt when the image count changes or it runs out.
      deck=(); [ -f "$DECK" ] && mapfile -t deck < "$DECK"
      if [ "${#deck[@]}" -lt 2 ] || [ "${deck[0]}" != "$COUNT" ]; then
        mapfile -t deck < <(printf '%s\n' "$COUNT"; printf '%s\n' "${IMAGES[@]}" | shuf)
      fi
      # Avoid repeating the last image across a reshuffle boundary.
      if [ "${#deck[@]}" -gt 2 ] && [ "${deck[1]}" = "$LAST" ]; then
        tmp="${deck[1]}"; deck[1]="${deck[2]}"; deck[2]="$tmp"
      fi
      IMG="${deck[1]}"
      rest=("${deck[@]:2}")
      if [ "${#rest[@]}" -eq 0 ]; then
        rm -f "$DECK"
      else
        { printf '%s\n' "$COUNT"; printf '%s\n' "${rest[@]}"; } > "$DECK"
      fi
      ;;
  esac
fi

# Screen and image geometry.
read -r SW SH < <(screen_res | tr 'x' ' ') || true
SW="${SW:-1920}"; SH="${SH:-1080}"
read -r IMGW IMGH < <(image_size "$IMG") || true
IMGW="${IMGW:-1920}"; IMGH="${IMGH:-1080}"

MODE="$(fit_mode "$IMGW" "$IMGH" "$SW" "$SH")"
[ -n "$MODE" ] || MODE="cover"

DLABEL="$(distro_label)"
LOGO="$(distro_logo || true)"

# Fast first paint: if the desktop isn't already showing one of our wallpapers,
# set the raw image now so stamping doesn't leave a visible gap.
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

# Stamp the label onto a copy and point the desktop at it (STATE keeps the original).
ORIG="$IMG"
if [ "$SHOW_LABEL" = "yes" ]; then
  ensure_imagemagick || true
  IM="$(im_bin)"
  if [ -n "$IM" ]; then
    mkdir -p "$CACHE"
    LABELED="$CACHE/labeled-$$-$(date +%s).png"   # unique name so the URI changes
    FONT="$(ui_font)"
    # Some libjpeg builds mis-decode progressive JPEGs into garbage. If this is one
    # and jpegtran is present, transcode it losslessly to baseline first.
    SRC="$IMG"
    if command -v jpegtran >/dev/null 2>&1 \
       && [ "$("$IM" "$IMG" -format '%[interlace]' info: 2>/dev/null)" = "JPEG" ] \
       && jpegtran -copy none "$IMG" > "$CACHE/src-$$.jpg" 2>/dev/null && [ -s "$CACHE/src-$$.jpg" ]; then
      SRC="$CACHE/src-$$.jpg"
    fi
    # Render the wallpaper onto a screen-sized canvas so the label is ALWAYS at the
    # same on-screen position and size, whatever the image's aspect. cover fills the
    # screen; a non-filling image (portrait, banner, small) keeps its real aspect,
    # centred on black bars.
    CANVAS="$CACHE/canvas-$$.png"
    if [ "$MODE" = cover ]; then
      "$IM" "$SRC" -resize "${SW}x${SH}^" -gravity center -extent "${SW}x${SH}" "$CANVAS" 2>/dev/null || true
    else
      # Letterbox bars use the system desktop background colour (default black); the
      # label's spot then samples that bar, so the colour rule makes it dark on a
      # light bar, light on a dark bar — still a colour taken from the wallpaper.
      case "$DE" in
        gnome|unity) BARCOLOR="$(gsettings get org.gnome.desktop.background primary-color 2>/dev/null)" ;;
        cinnamon)    BARCOLOR="$(gsettings get org.cinnamon.desktop.background primary-color 2>/dev/null)" ;;
        mate)        BARCOLOR="$(gsettings get org.mate.background primary-color 2>/dev/null)" ;;
        *)           BARCOLOR="" ;;
      esac
      BARCOLOR="${BARCOLOR#\'}"; BARCOLOR="${BARCOLOR%\'}"
      [ -n "$BARCOLOR" ] || BARCOLOR="black"
      [ "$MODE" = center ] && FIT=() || FIT=(-resize "${SW}x${SH}")
      "$IM" "$SRC" "${FIT[@]}" -background "$BARCOLOR" -gravity center -extent "${SW}x${SH}" "$CANVAS" 2>/dev/null || true
    fi
    rm -f "$CACHE/src-$$.jpg" 2>/dev/null || true
    [ -s "$CANVAS" ] || CANVAS="$IMG"
    # Fixed label geometry, in screen pixels (constant position + size for every image).
    PT=16; MR=36; MB=90; LH=$(( PT*4 + 8 ))
    TXTW="$("$IM" -background none -family "$FONT" -style Normal -pointsize "$PT" \
              label:"$DLABEL" -format '%w' info: 2>/dev/null)"
    MAXW=$(( SW - MR - 40 ))
    if [ -n "$TXTW" ] && [ "$MAXW" -gt 0 ] && [ "$TXTW" -gt "$MAXW" ]; then
      PT="$(awk -v pt="$PT" -v maxw="$MAXW" -v txtw="$TXTW" 'BEGIN{p=int(pt*maxw/txtw); print (p<8)?8:p}')"
      TXTW="$("$IM" -background none -family "$FONT" -style Normal -pointsize "$PT" \
                label:"$DLABEL" -format '%w' info: 2>/dev/null)"
    fi
    LDY=$(( MB + PT + PT/2 ))                          # emblem just above the text
    # Sample the spot behind the label (fixed bottom-right region of the canvas).
    SAMPW=$(( ${TXTW:-300} )); [ "$LH" -gt "$SAMPW" ] && SAMPW="$LH"; SAMPW=$(( SAMPW + 20 ))
    SAMPH=$(( LDY + LH - MB + 20 ))
    SPOTRGB="$("$IM" "$CANVAS" -gravity SouthEast -crop "${SAMPW}x${SAMPH}+${MR}+${MB}" +repage \
              -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: 2>/dev/null)"
    [ -n "$SPOTRGB" ] || SPOTRGB="128 128 128"
    # The actual dominant colours behind the label ("cnt,R,G,B;..."), so pick_colour can
    # measure worst-case readability against every colour in the patch, not just its average.
    PATCHCOL="$("$IM" "$CANVAS" -gravity SouthEast -crop "${SAMPW}x${SAMPH}+${MR}+${MB}" +repage \
              -resize 60x40 -colors 8 -depth 8 -format '%c' histogram:info:- 2>/dev/null \
              | awk '{ci=index($0,":"); c=substr($0,1,ci-1)+0; p1=index($0,"(");p2=index($0,")");
                      if(p1<=0||p2<=p1)next; t=substr($0,p1+1,p2-p1-1); gsub(/[^0-9,]/,"",t);
                      if(split(t,x,",")>=3) printf "%d,%d,%d,%d;", c, x[1], x[2], x[3]}')"
    # Whole-image average colour, so pick_colour can find the most salient tone.
    MEANRGB="$("$IM" "$CANVAS" -alpha off -resize 1x1! \
              -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: 2>/dev/null)"
    [ -n "$MEANRGB" ] || MEANRGB="128 128 128"
    # Pick a readable colour from the image's own palette (see pick_colour).
    COLOR="$("$IM" "$CANVAS" -alpha off -resize 300x300 -colors 64 -depth 8 \
              -format '%c' histogram:info:- 2>/dev/null | pick_colour $SPOTRGB $MEANRGB "$PATCHCOL")"
    [ -n "$COLOR" ] || COLOR="#f5f5f5"
    # Stamp emblem + text at the fixed position. -density 512 renders the SVG sharp;
    # reset to 72 before -annotate so the text point size is in pixels. Text-only fallback.
    STAMPED=0
    if [ -n "$LOGO" ] && "$IM" "$CANVAS" \
        \( -density 512 -background none "$LOGO" -resize "x${LH}" -fill "$COLOR" -colorize 100 -trim +repage \) \
        -gravity SouthEast -geometry "+${MR}+${LDY}" -composite \
        -density 72 -pointsize "$PT" -family "$FONT" -style Normal -fill "$COLOR" \
        -annotate "+${MR}+${MB}" "$DLABEL" "$LABELED" 2>/dev/null; then
      STAMPED=1
    fi
    if [ "$STAMPED" -eq 0 ] && "$IM" "$CANVAS" \
        -gravity SouthEast -pointsize "$PT" -family "$FONT" -style Normal -fill "$COLOR" \
        -annotate "+${MR}+${MB}" "$DLABEL" "$LABELED" 2>/dev/null; then
      STAMPED=1
    fi
    rm -f "$CACHE/canvas-$$.png" 2>/dev/null || true
    if [ "$STAMPED" -eq 1 ]; then
      IMG="$LABELED"; MODE="cover"     # canvas is screen-sized -> desktop shows it 1:1
    else
      echo "Could not stamp the label (ImageMagick error) — using original image." >&2
    fi
  else
    echo "SHOW_LABEL=yes but ImageMagick not installed — using unlabeled image." >&2
  fi
fi

# Fill mode per desktop; defaults are the "cover" values.
GSET="zoom"          # gnome/cinnamon/mate
XFS=5                # xfce  5=Zoomed 4=Scaled 3=Stretched 1=Centered
KFILL=2              # kde   2=Crop 1=Fit 0=Stretch 6=Pad(centre)
FEHBG="--bg-fill"    # feh
PCM="crop"           # pcmanfm
case "$MODE" in
  contain) GSET="scaled";    XFS=4; KFILL=1; FEHBG="--bg-max";    PCM="fit" ;;
  center)  GSET="centered";  XFS=1; KFILL=6; FEHBG="--bg-center"; PCM="center" ;;
esac

# Set a gsettings key only when it changed (rewriting picture-options flashes).
gset_if() { [ "$(gsettings get "$1" "$2" 2>/dev/null)" = "'$3'" ] || gsettings set "$1" "$2" "$3"; }

# Apply the image and the auto-chosen fill mode.
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

# Record the shown image for ordering.
printf '%s\n' "$ORIG" > "$STATE"

# Remove older labeled copies (keep the live one) and any leftover working files.
[ -d "$CACHE" ] && find "$CACHE" -maxdepth 1 \
  \( -name 'labeled-*.png' ! -name "$(basename -- "$IMG")" -o -name 'canvas-*.png' -o -name 'src-*.jpg' \) \
  -delete 2>/dev/null || true

if [ -n "$LOGO" ]; then EMBLEM="$(basename -- "$LOGO")"; else EMBLEM="none"; fi
echo "Wallpaper set  ($DLABEL, emblem: $EMBLEM, desktop: $DE, order: $ORDER, fit: $MODE, screen ${SW}x${SH})"

# Manual runs only: point at the config.
if [ "$AUTO" = 0 ]; then
  echo "Note: edit $CONF to change directories, interval, order, battery behaviour, or the label." >&2
fi
