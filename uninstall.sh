#!/usr/bin/env bash
# Remove the wallpaper rotator: stops/disables the timer + login service,
# deletes the installed script, units, config, state and cache, and resets the
# desktop back to its default wallpaper. Your wallpaper directories and images are
# never touched. No sudo needed.
set -e

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="$CFG/wallpaper-rotator.conf"
STATE="$CFG/wallpaper-rotator.last"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-rotator"
BIN="$HOME/.local/bin/wallpaper-rotator.sh"
UNIT_DIR="$HOME/.config/systemd/user"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# Read the desktop + directory list from the config before we delete it.
DE="gnome"; WALLPAPER_DIRS=()
[ -f "$CONF" ] && . "$CONF" 2>/dev/null || true

# Reach the session bus so the wallpaper reset lands (same as the main script).
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
export DISPLAY="${DISPLAY:-:0}"

# Reset the desktop to its default wallpaper. `gsettings reset` restores the
# distro default (honouring vendor overrides). Returns non-zero for desktops
# with no simple default to restore (KDE/LXDE/feh).
reset_wallpaper() {
  case "$DE" in
    gnome|unity)
      gsettings reset org.gnome.desktop.background picture-uri      2>/dev/null || true
      gsettings reset org.gnome.desktop.background picture-uri-dark 2>/dev/null || true
      gsettings reset org.gnome.desktop.background picture-options  2>/dev/null || true
      ;;
    cinnamon)
      gsettings reset org.cinnamon.desktop.background picture-uri     2>/dev/null || true
      gsettings reset org.cinnamon.desktop.background picture-options 2>/dev/null || true
      ;;
    mate)
      gsettings reset org.mate.background picture-filename 2>/dev/null || true
      gsettings reset org.mate.background picture-options  2>/dev/null || true
      ;;
    xfce)
      for prop in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$'); do
        xfconf-query -c xfce4-desktop -p "$prop" -r 2>/dev/null || true
      done
      ;;
    *) return 1 ;;
  esac
  return 0
}

echo
bold "== Wallpaper Rotator uninstall =="

# Nothing to do if none of the installed artifacts are present.
if [ ! -e "$BIN" ] && [ ! -e "$CONF" ] && [ ! -e "$STATE" ] \
   && [ ! -e "$UNIT_DIR/wallpaper-rotator.timer" ] \
   && [ ! -e "$UNIT_DIR/wallpaper-rotator.service" ] \
   && [ ! -e "$UNIT_DIR/wallpaper-rotator-login.service" ] \
   && [ ! -e "$CACHE" ]; then
  echo
  echo "  Nothing to remove — the wallpaper rotator is not installed."
  echo
  exit 0
fi

# ---- stop + disable all units (ignore if already gone) -------------------
systemctl --user disable --now wallpaper-rotator.timer         >/dev/null 2>&1 || true
systemctl --user disable --now wallpaper-rotator-login.service >/dev/null 2>&1 || true
systemctl --user stop          wallpaper-rotator.service       >/dev/null 2>&1 || true

# ---- reset to the system default wallpaper (timer is already stopped) -----
RESET=1; reset_wallpaper || RESET=0

# ---- remove installed files + cache --------------------------------------
rm -f "$BIN" \
      "$UNIT_DIR/wallpaper-rotator.service" \
      "$UNIT_DIR/wallpaper-rotator.timer" \
      "$UNIT_DIR/wallpaper-rotator-login.service" \
      "$CONF" \
      "$STATE"
rm -rf "$CACHE"

systemctl --user daemon-reload
systemctl --user reset-failed wallpaper-rotator.timer wallpaper-rotator-login.service >/dev/null 2>&1 || true

# ---- summary -------------------------------------------------------------
echo
bold "== Removed =="
echo "  timer, login service, script, units, config and cache are gone."
if [ "$RESET" = 1 ]; then
  echo "  The desktop has been reset to its default wallpaper."
else
  echo "  Rotation has stopped; your current wallpaper stays as-is."
fi
if [ "${#WALLPAPER_DIRS[@]}" -gt 0 ]; then
  echo
  echo "  Your images were left untouched in:"
  printf '    %s\n' "${WALLPAPER_DIRS[@]}"
  echo "  (delete those directories yourself if you no longer want them)"
fi
echo
echo "Re-install anytime with: ./setup.sh"
echo
