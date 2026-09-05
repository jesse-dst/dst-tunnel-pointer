#!/bin/bash
# dst-harden.sh — make Joey's Mac mini keep DST services alive without babysitting.
#
# One-time install (run in Terminal on the Mac mini):
#   curl -fsSL https://raw.githubusercontent.com/jesse-dst/dst-tunnel-pointer/main/mac/dst-harden.sh | bash
#
# What it does (idempotent, safe to re-run):
#   1. Power: never sleep, wake for network, auto-restart after power loss / freeze.
#   2. launchd: force KeepAlive + RunAtLoad on com.dst.brain / com.dst.tunnel /
#      com.dst.fleet-tunnel (and any other com.dst.* agent) so a crash = auto restart.
#   3. Installs com.dst.watchdog (every 2 min): checks the brain on :8091, the
#      brain/fleet tunnels, the SB-XTM5 drive, and restarts whatever is dead.
#      Also publishes the fleet tunnel URL to the public pointer repo (fleet.json)
#      so the Railway /fleet link survives redeploys. Logs: ~/Library/Logs/dst-watchdog.log
#   4. Prints a status summary.
#
# No secrets in this file. The watchdog reuses the existing GitHub token at
# ~/dst-agent/gh_token (same one dst-tunnel-zero.sh uses) and never prints it.

set -u
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
DSTDIR="$HOME/dst-agent"
mkdir -p "$AGENTS" "$LOGS" "$DSTDIR"
UID_N="$(id -u)"

say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. power
say "Power settings (will ask for your Mac password once)"
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 womp 1 autorestart 1 powernap 0 standby 0 hibernatemode 0 2>/dev/null \
  && echo "pmset: no sleep, wake-on-LAN, auto-restart after power failure" \
  || echo "pmset skipped (no sudo) - set System Settings > Energy > Prevent automatic sleeping"
# Auto-reboot if macOS hangs (watchdog timer)
sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 && echo "systemsetup: restart on freeze = on" || true
sudo systemsetup -setrestartpowerfailure on >/dev/null 2>&1 || true
# Keep the login-window from killing agents: don't log out after inactivity
sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0 2>/dev/null || true

# ---------------------------------------------------------------- 2. keepalive
say "launchd KeepAlive / RunAtLoad on all com.dst.* agents"
for p in "$AGENTS"/com.dst.*.plist; do
  [ -f "$p" ] || continue
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$p" 2>/dev/null)"
  case "$label" in
    com.dst.mapsync|com.dst.watchdog) continue ;;  # interval jobs, not daemons
  esac
  # Remove any dict-style KeepAlive, then set the simple boolean form.
  /usr/libexec/PlistBuddy -c 'Delete :KeepAlive' "$p" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$p" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Delete :RunAtLoad' "$p" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$p" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Delete :ThrottleInterval' "$p" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 15' "$p" >/dev/null 2>&1
  plutil -lint "$p" >/dev/null && echo "  $label: KeepAlive=true RunAtLoad=true"
  # Reload so the new keys take effect (harmless if already loaded).
  launchctl bootout "gui/$UID_N/$label" >/dev/null 2>&1
  launchctl bootstrap "gui/$UID_N" "$p" >/dev/null 2>&1 || launchctl kickstart -k "gui/$UID_N/$label" >/dev/null 2>&1
done

# ---------------------------------------------------------------- 3. watchdog
say "Installing watchdog"
cat > "$DSTDIR/dst-watchdog.sh" <<'WD'
#!/bin/bash
# dst-watchdog.sh — runs every 2 minutes via com.dst.watchdog. Restarts dead DST
# services, keeps the fleet pointer fresh. Never prints tokens.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
UID_N="$(id -u)"
LOG="$HOME/Library/Logs/dst-watchdog.log"
DSTDIR="$HOME/dst-agent"
STATE="$DSTDIR/.watchdog-state"; mkdir -p "$STATE"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
# keep the log small
[ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2000000 ] && tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

ok()   { curl -fsS -m 8 -o /dev/null "$1" 2>/dev/null; }
ok_any() { c=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null); [ "${c:-000}" != "000" ] && [ "$c" -lt 500 ]; }
kick() { launchctl kickstart -k "gui/$UID_N/$1" 2>>"$LOG" && log "kickstart $1" ; }
loaded() { launchctl print "gui/$UID_N/$1" >/dev/null 2>&1; }
ensure_loaded() { loaded "$1" || { [ -f "$HOME/Library/LaunchAgents/$1.plist" ] && launchctl bootstrap "gui/$UID_N" "$HOME/Library/LaunchAgents/$1.plist" 2>>"$LOG" && log "bootstrap $1"; }; }

# fail counters so we only restart after 2 consecutive misses (avoid flapping)
bump() { f="$STATE/$1"; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $n > "$f"; echo $n; }
clear_() { rm -f "$STATE/$1"; }

# ---- brain (port 8091) ----
ensure_loaded com.dst.brain
if ok http://127.0.0.1:8091/health; then clear_ brain
else
  n=$(bump brain); log "brain health FAIL ($n)"
  if [ "$n" -ge 2 ]; then
    if grep -q "Address already in use" "$HOME/Library/Logs/dst-brain.err" 2>/dev/null || pgrep -f dst_brain_server.py >/dev/null; then
      pkill -f dst_brain_server.py; sleep 2; log "killed stale dst_brain_server.py"
    fi
    kick com.dst.brain; clear_ brain
  fi
fi

# ---- brain tunnel (pointer api.json -> trycloudflare) ----
ensure_loaded com.dst.tunnel
BRAIN_URL=$(curl -fsS -m 8 "https://raw.githubusercontent.com/jesse-dst/dst-tunnel-pointer/main/api.json?t=$(date +%s)" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("url",""))' 2>/dev/null)
if [ -n "$BRAIN_URL" ] && ok "$BRAIN_URL/health"; then clear_ tunnel
elif ! pgrep -f "cloudflared.*8091" >/dev/null; then
  log "brain tunnel process missing"; kick com.dst.tunnel; clear_ tunnel
else
  n=$(bump tunnel); log "brain tunnel unreachable via pointer ($n)"
  [ "$n" -ge 3 ] && { kick com.dst.tunnel; clear_ tunnel; }
fi

# ---- fleet app + tunnel ----
FLEET_DIR="/Volumes/SB-XTM5/dst-fleet-data/dst-fleet-reports"
if [ ! -d "$FLEET_DIR" ]; then
  n=$(bump volume); [ "$n" -eq 1 ] || [ $((n % 30)) -eq 0 ] && log "SB-XTM5 drive NOT mounted - fleet app cannot run (plug it in / remount)"
else
  clear_ volume
  ensure_loaded com.dst.fleet-tunnel
  if ok_any http://127.0.0.1:5050/; then clear_ fleetlocal
  else
    n=$(bump fleetlocal); log "fleet app :5050 FAIL ($n)"
    [ "$n" -ge 2 ] && { for l in com.dst.fleet com.dst.fleet-app com.dst.fleet-reports; do loaded $l && kick $l; done; clear_ fleetlocal; }
  fi
  FLEET_URL=$(tr -d '[:space:]' < "$FLEET_DIR/tunnel-url.txt" 2>/dev/null)
  if [ -n "$FLEET_URL" ] && ok_any "$FLEET_URL/"; then
    clear_ fleettunnel
    # publish to pointer repo when changed
    if [ "$FLEET_URL" != "$(cat "$STATE/fleet-published" 2>/dev/null)" ] && [ -f "$DSTDIR/gh_token" ]; then
      TOKEN="$(tr -d '[:space:]' < "$DSTDIR/gh_token")"
      API="https://api.github.com/repos/jesse-dst/dst-tunnel-pointer/contents/fleet.json"
      SHA=$(curl -fsS -m 10 -H "Authorization: Bearer $TOKEN" "$API" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sha",""))' 2>/dev/null)
      BODY=$(python3 - "$FLEET_URL" "$SHA" <<'PY'
import sys,json,base64,datetime
url,sha=sys.argv[1],sys.argv[2]
content={"url":url,"updated":datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ'),"note":"DST Fleet Reports tunnel URL - auto-updated by the Mac mini watchdog"}
b=base64.b64encode(json.dumps(content,indent=1).encode()).decode()
d={"message":"fleet tunnel url update","content":b}
if sha: d["sha"]=sha
print(json.dumps(d))
PY
)
      if curl -fsS -m 15 -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$BODY" "$API" -o /dev/null 2>>"$LOG"; then
        echo "$FLEET_URL" > "$STATE/fleet-published"; log "published fleet.json -> $FLEET_URL"
      else log "fleet.json publish failed"; fi
      unset TOKEN BODY
    fi
  else
    n=$(bump fleettunnel); log "fleet tunnel dead/unknown ($n) url=${FLEET_URL:-none}"
    [ "$n" -ge 2 ] && { kick com.dst.fleet-tunnel; rm -f "$STATE/fleet-published"; clear_ fleettunnel; }
  fi
fi

# ---- any other com.dst.* daemon that launchd shows as not running ----
for p in "$HOME"/Library/LaunchAgents/com.dst.*.plist; do
  l="$(basename "$p" .plist)"
  case "$l" in com.dst.watchdog|com.dst.mapsync) continue;; esac
  loaded "$l" || { launchctl bootstrap "gui/$UID_N" "$p" 2>>"$LOG" && log "bootstrap $l (was unloaded)"; }
done
exit 0
WD
chmod +x "$DSTDIR/dst-watchdog.sh"

cat > "$AGENTS/com.dst.watchdog.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.dst.watchdog</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DSTDIR/dst-watchdog.sh</string></array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGS/dst-watchdog.out</string>
  <key>StandardErrorPath</key><string>$LOGS/dst-watchdog.err</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict></plist>
PL
plutil -lint "$AGENTS/com.dst.watchdog.plist" >/dev/null && echo "watchdog plist ok"
launchctl bootout "gui/$UID_N/com.dst.watchdog" >/dev/null 2>&1
launchctl bootstrap "gui/$UID_N" "$AGENTS/com.dst.watchdog.plist" && echo "watchdog loaded (runs every 2 min)"
# run once now
bash "$DSTDIR/dst-watchdog.sh"

# ---------------------------------------------------------------- 4. status
say "Status"
launchctl list | grep -E 'com\.dst' | awk '{printf "  pid=%-6s exit=%-3s %s\n",$1,$2,$3}'
echo "  brain :8091  -> $(curl -s -m 5 http://127.0.0.1:8091/health || echo DOWN)"
echo "  fleet :5050  -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:5050/ || echo DOWN)"
echo "  SB-XTM5      -> $([ -d /Volumes/SB-XTM5 ] && echo mounted || echo NOT MOUNTED)"
echo "  pmset sleep  -> $(pmset -g | awk '/^ sleep/{print $2}')"
echo "  FileVault    -> $(fdesetup status 2>/dev/null | head -1)"
echo
echo "Watchdog log: tail -f ~/Library/Logs/dst-watchdog.log"
echo "NOTE: launchd user agents only run after you are logged in. If FileVault is on and the"
echo "      Mac reboots, nothing starts until someone types the password at the FileVault screen."
echo "      To make it fully hands-off: turn FileVault OFF (System Settings > Privacy & Security),"
echo "      then System Settings > Users & Groups > Automatic login: joey."
echo "Done."
