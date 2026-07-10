#!/usr/bin/env bash
# Remove the wallpaper rotator: stops/disables the timer + login service,
# deletes the installed script, units, config, state and cache, and resets the
# desktop back to its default wallpaper. Your wallpaper directories and images are
# never touched. No sudo needed.
set -e

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="$CFG/wallpaper-rotator.conf"
STATE="$CFG/wallpaper-rotator.last"
DECK="$CFG/wallpaper-rotator.deck"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-rotator"
BIN="$HOME/.local/bin/wallpaper-rotator.sh"
UNIT_DIR="$HOME/.config/systemd/user"

LINE="────────────────────────────────────────────────────────────"
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { echo; printf '%s\n' "$LINE"; bold "  $1"; printf '%s\n' "$LINE"; }
srow() { printf "    %-12s :  %s\n" "$1" "$2"; }

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
printf '%s\n' "$LINE"
bold "  WALLPAPER ROTATOR — UNINSTALL"
printf '%s\n' "$LINE"

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

# ---- stop + disable the systemd user units -------------------------------
step "Stopping services"
for unit in wallpaper-rotator.timer wallpaper-rotator-login.service wallpaper-rotator.service; do
  [ -e "$UNIT_DIR/$unit" ] || continue
  systemctl --user disable --now "$unit" >/dev/null 2>&1 \
    || systemctl --user stop "$unit" >/dev/null 2>&1 || true
  echo "  [OK]  Disabled and stopped $unit"
done
RESET=1; reset_wallpaper || RESET=0
if [ "$RESET" = 1 ]; then echo "  [OK]  Reset desktop wallpaper to the system default"; fi

# ---- remove installed files + cache --------------------------------------
step "Removing files"
for f in "$BIN" \
         "$UNIT_DIR/wallpaper-rotator.service" \
         "$UNIT_DIR/wallpaper-rotator.timer" \
         "$UNIT_DIR/wallpaper-rotator-login.service" \
         "$CONF" "$STATE" "$DECK"; do
  [ -e "$f" ] || continue
  rm -f "$f"
  echo "  [OK]  Removed  $f"
done
if [ -e "$CACHE" ]; then
  rm -rf "$CACHE"
  echo "  [OK]  Removed  $CACHE/"
fi

systemctl --user daemon-reload
systemctl --user reset-failed wallpaper-rotator.timer wallpaper-rotator-login.service >/dev/null 2>&1 || true

# ---- summary -------------------------------------------------------------
echo
printf '%s\n' "$LINE"
bold "  [SUCCESS]  Uninstall complete"
printf '%s\n' "$LINE"
echo
if [ "$RESET" = 1 ]; then
  srow "Wallpaper" "reset to system default"
else
  srow "Wallpaper" "unchanged (current stays)"
fi
srow "Services" "disabled and removed"
srow "Config"   "removed"
srow "Cache"    "removed"
if [ "${#WALLPAPER_DIRS[@]}" -gt 0 ]; then
  echo
  echo "    Your wallpaper images were left untouched in:"
  printf '      %s\n' "${WALLPAPER_DIRS[@]}"
fi
echo
printf '%s\n' "$LINE"
printf "    %-12s   →   %s\n" "Re-install" "./linux-wallpaper-rotator.setup.sh"
printf '%s\n' "$LINE"
echo
