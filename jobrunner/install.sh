#!/bin/bash
# DST Mac mini job runner installer. Run as joey:  curl -fsSL <raw url> | bash
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
set -u
D="$HOME/dst-agent/jobrunner"
PL="$HOME/Library/LaunchAgents/com.dst.jobrunner.plist"
RAW="https://raw.githubusercontent.com/jesse-dst/dst-tunnel-pointer/main/jobrunner"
mkdir -p "$D"
echo "== DST job runner install =="

# 1. SSH deploy key (never leaves this Mac; only the public half is published)
if [ ! -f "$D/id_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "dst-mini-jobrunner" -f "$D/id_ed25519"
  echo "generated deploy key"
fi
chmod 600 "$D/id_ed25519"

# 2. runner script
curl -fsSL "$RAW/runner.py?$(date +%s)" -o "$D/runner.py" || { echo "download of runner.py failed"; exit 1; }
python3 -m py_compile "$D/runner.py" || { echo "runner.py does not compile"; exit 1; }

# 3. launchd job, every 60 s
PY3="$(command -v python3)"
cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.dst.jobrunner</string>
  <key>ProgramArguments</key><array><string>$PY3</string><string>$D/runner.py</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/dst-jobrunner.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/dst-jobrunner.err</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/com.dst.jobrunner" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PL" && echo "launchd job com.dst.jobrunner loaded"

# 4. publish the PUBLIC key to the pointer repo so Perplexity can register it as a deploy key
PUB="$(cat "$D/id_ed25519.pub")"
python3 - "$PUB" <<'PY'
import sys, json, base64, urllib.request, os
pub = sys.argv[1]
tok = open(os.path.expanduser("~/dst-agent/gh_token")).read().strip()
url = "https://api.github.com/repos/jesse-dst/dst-tunnel-pointer/contents/jobrunner/pubkey.txt"
hdr = {"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json", "User-Agent": "dst-mini"}
sha = None
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=20) as r:
        sha = json.load(r).get("sha")
except Exception:
    pass
body = {"message": "jobrunner public key from Mac mini", "content": base64.b64encode((pub + "\n").encode()).decode()}
if sha: body["sha"] = sha
req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={**hdr, "Content-Type": "application/json"}, method="PUT")
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print("public key published (HTTP %s)" % r.status)
except Exception as e:
    print("could not publish public key automatically (%s). Paste this line to Perplexity:" % e)
    print(pub)
PY

# 5. quick status so you can see where things stand
echo; echo "== status =="
lark-cli auth status 2>&1 | head -4
launchctl list 2>/dev/null | grep -E "dst\.(lark|jobrunner|photo)" | awk '{print $3, "pid="$1, "last_exit="$2}'
echo "reader log:"; tail -n 2 "$HOME/Library/Logs/dst-lark-reader.log" 2>/dev/null
echo "done. Perplexity will take it from here."
