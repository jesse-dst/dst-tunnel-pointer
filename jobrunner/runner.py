#!/usr/bin/env python3
"""DST Mac mini job runner.

Every minute (launchd com.dst.jobrunner): pull the private repo jesse-dst/dst-mini-jobs,
run any jobs/<name>.sh|.py that has no out/<name>.done yet, push stdout/stderr back.
Runs as Joey with full network and launchctl access. One job at a time, 15 min cap.
"""
import os, sys, subprocess, time, datetime, glob, shutil

HOME = os.path.expanduser("~")
D = os.path.join(HOME, "dst-agent", "jobrunner")
R = os.path.join(D, "repo")
KEY = os.path.join(D, "id_ed25519")
LOG = os.path.join(D, "runner.log")
LOCK = os.path.join(D, "lock")
URL = "ssh://git@ssh.github.com:443/jesse-dst/dst-mini-jobs.git"
JOB_TIMEOUT = 900
MAX_OUT = 2_000_000

ENV = dict(os.environ)
ENV["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ENV["HOME"] = HOME
ENV["GIT_SSH_COMMAND"] = ("ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "
                          "-o ConnectTimeout=20 -o BatchMode=yes" % KEY)
ENV["GIT_TERMINAL_PROMPT"] = "0"

def log(*a):
    with open(LOG, "a") as f:
        f.write("[%s] %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), " ".join(str(x) for x in a)))

def git(*args, check=False, timeout=120):
    p = subprocess.run(["git", *args], cwd=R if os.path.isdir(R) else D, env=ENV,
                       capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError("git %s failed: %s %s" % (" ".join(args), p.stdout[-300:], p.stderr[-300:]))
    return p

def push():
    for attempt in range(3):
        p = git("push", "-q", "origin", "main")
        if p.returncode == 0:
            return True
        git("pull", "-q", "--rebase", "origin", "main")
    log("push failed:", p.stderr[-300:])
    return False

def utc():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

def main():
    os.makedirs(D, exist_ok=True)
    # single-instance lock (stale after 30 min)
    try:
        os.mkdir(LOCK)
    except FileExistsError:
        if time.time() - os.path.getmtime(LOCK) > 1800:
            shutil.rmtree(LOCK, ignore_errors=True); os.mkdir(LOCK)
        else:
            return
    try:
        run()
    except Exception as e:
        log("runner error:", repr(e)[:400])
    finally:
        shutil.rmtree(LOCK, ignore_errors=True)

def run():
    if not os.path.isdir(os.path.join(R, ".git")):
        p = subprocess.run(["git", "clone", "-q", URL, R], env=ENV, capture_output=True, text=True, timeout=120)
        if p.returncode != 0:
            log("clone failed (deploy key not added yet?):", p.stderr.strip()[-200:]); return
        log("cloned")
    p = git("fetch", "-q", "origin", "main")
    if p.returncode != 0:
        log("fetch failed:", p.stderr.strip()[-200:]); return
    git("reset", "-q", "--hard", "origin/main")
    git("config", "user.name", "dst-mini"); git("config", "user.email", "mini@deepsandtech.com")
    os.makedirs(os.path.join(R, "jobs"), exist_ok=True); os.makedirs(os.path.join(R, "out"), exist_ok=True)

    jobs = sorted(glob.glob(os.path.join(R, "jobs", "*.sh")) + glob.glob(os.path.join(R, "jobs", "*.py")))
    for f in jobs:
        name = os.path.splitext(os.path.basename(f))[0]
        done = os.path.join(R, "out", name + ".done")
        local_mark = os.path.join(D, "ran", name)
        if os.path.exists(done) or os.path.exists(local_mark):
            continue
        os.makedirs(os.path.dirname(local_mark), exist_ok=True)
        open(local_mark, "w").write(utc())
        out = os.path.join(R, "out", name + ".out")
        # claim it first so a crash never re-runs a job
        with open(done, "w") as fh: fh.write("started %s\n" % utc())
        git("add", "-A", "out"); git("commit", "-qm", "start %s" % name); push()
        log("run", name)
        cmd = ["python3", f] if f.endswith(".py") else ["bash", f]
        t0 = time.time(); code = None; err = ""
        try:
            with open(out, "w") as fh:
                p = subprocess.run(cmd, cwd=HOME, env=ENV, stdout=fh, stderr=subprocess.STDOUT, timeout=JOB_TIMEOUT)
            code = p.returncode
        except subprocess.TimeoutExpired:
            err = "TIMEOUT after %ss" % JOB_TIMEOUT
        except Exception as e:
            err = repr(e)
        if os.path.getsize(out) > MAX_OUT:
            data = open(out, "rb").read()
            with open(out, "wb") as fh: fh.write(data[:MAX_OUT // 2] + b"\n...[truncated]...\n" + data[-MAX_OUT // 2:])
        with open(done, "a") as fh:
            fh.write("exit=%s %s finished %s (%.0fs)\n" % (code, err, utc(), time.time() - t0))
        git("add", "-A", "out"); git("commit", "-qm", "out %s exit=%s" % (name, code)); push()
        log("done", name, "exit", code, err)

    hb = os.path.join(R, "out", "heartbeat.txt")
    if not os.path.exists(hb) or time.time() - os.path.getmtime(hb) > 600:
        with open(hb, "w") as fh:
            fh.write("%s host=%s\n" % (utc(), os.uname().nodename))
        git("add", hb); git("commit", "-qm", "heartbeat"); push()

if __name__ == "__main__":
    main()
