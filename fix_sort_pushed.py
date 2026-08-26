#!/usr/bin/env python3
"""One-shot fix: re-queue photos marked 'pushed' that never reached the new
Photo Sort app (lost in the 2026-08-19 migration), and patch the feeder's
request-clear GET/POST bug. Safe: backs up state + feeder.py first.
Run:  curl -s <RAW_URL> | /usr/bin/python3
"""
import json, os, shutil, subprocess, time, urllib.request

PIPE = "/Volumes/SB-XTM5/photo-pipeline"
STATE = os.path.join(PIPE, "feeder-state.json")
FEEDER = os.path.join(PIPE, "feeder.py")
URL = "https://dst-photo-sort-production.up.railway.app"

# 1. cloud ids
req = urllib.request.Request(URL + "/api/photos-meta")
req.add_header("X-Pin", "1414")
meta = json.load(urllib.request.urlopen(req, timeout=60))
cloud = set(p["id"] for p in (meta.get("photos") or meta))
print("cloud photos:", len(cloud))

# 2. state backup + trim pushed list
st = json.load(open(STATE))
ts = time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(STATE, STATE + ".bak-" + ts)
pushed = st.get("pushed", [])
keep = [m for m in pushed if m in cloud]
print("pushed before: %d  after: %d  re-queued: %d" % (len(pushed), len(keep), len(pushed) - len(keep)))
st["pushed"] = keep
json.dump(st, open(STATE, "w"))

# 3. patch feeder request-clear bug (payload {} is falsy -> GET -> 404)
src = open(FEEDER).read()
bad = 'api("/api/request-clear", {})'
if bad in src:
    shutil.copy2(FEEDER, FEEDER + ".bak-" + ts)
    open(FEEDER, "w").write(src.replace(bad, 'api("/api/request-clear", {"clear": 1})'))
    print("feeder.py: request-clear bug patched")
else:
    print("feeder.py: request-clear already OK")

# 4. run feeder once to fill the queue now
print("running feeder...")
env = dict(os.environ, FEEDER_URL=URL)
r = subprocess.call(["/usr/bin/python3", FEEDER], env=env)
print("feeder exit", r)
