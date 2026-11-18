#!/bin/bash
# Qosha upgrade for a Qosha installed before it could update itself (Mac). Made by Qosha's release tool.
# Everything it installs is checked against Qosha's signature first; if any check fails, nothing is changed.
#   bash upgrade-qosha.sh [--ring renato]
RING=everyone; ROOT="$HOME/Library/Application Support/Qosha"; EXTRA=()
# run from Qosha's own chat: the Qosha that runs it (its home is HERMES_HOME), else the standard place
if [ -n "$HERMES_HOME" ] && [ -f "$(dirname "$HERMES_HOME")/layer/setup_home.py" ]; then ROOT="$(dirname "$HERMES_HOME")"; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --ring) RING="$2"; shift 2;; --root) ROOT="$2"; shift 2;; --source) EXTRA+=(--source "$2"); shift 2;;
    --foreground) EXTRA+=(--foreground); shift;; *) echo "Unknown option $1. Nothing on this computer was changed."; exit 2;;
  esac
done
[ -f "$ROOT/layer/setup_home.py" ] || { echo "Qosha was not found on this computer. Nothing on this computer was changed."; exit 2; }
PY=""
while IFS= read -r c; do
  [ -n "$c" ] && "$c" -I -c 'import cryptography' 2>/dev/null && { PY="$c"; break; }
done < <(ls -t "$ROOT"/home/installs/*/environments/*/venv/bin/python 2>/dev/null)
[ -n "$PY" ] || { echo "Qosha cannot check the signature of the update on this computer. Nothing on this computer was changed."; exit 2; }
mkdir -p "$ROOT/run" "$ROOT/logs"; F="$ROOT/run/qosha-upgrade.py"
cat > "$F" <<'QOSHA_UPGRADE_PY_END'
"""Qosha upgrade for a Qosha installed before it could update itself (Mac and Windows; run by upgrade-qosha.ps1 /
upgrade-qosha.sh with the Python of the person's own Qosha that has `cryptography`).

1. Reads Qosha's signed update list from the update sources (the cloud bucket, then the public GitHub repository) and
   checks its Ed25519 signature with Qosha's public key written below. Nothing is used unless the signature matches.
2. Picks the newest release for this computer's ring, downloads its package and checks its size and sha256 against the
   signed list. Any mismatch: nothing is changed.
3. Takes Qosha's own updater out of that checked package, sets the ring, and hands over to it in a separate process:
   the updater backs up Qosha's layer and settings, applies the package exactly as the installer's layer step does
   (setup_home.py; no engine reinstall, no import, the person's data kept), starts Qosha again the way it was started,
   checks its health, and rolls back to the backup by itself if anything fails.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

PUBLIC_KEYS = {"3b379198e50e171e": "uY2TmE7t4rsP+i5ttCtQMpZI1PJ4oTlQYmEDqgprnTg="}
SOURCES = ["https://storage.googleapis.com/qosha-updates", "https://raw.githubusercontent.com/QoshaAi/qosha-updates/main"]
CHANNEL = "stable"
RINGS = ("ren-mac", "test-pc", "renato", "everyone")
VERSION_RE = re.compile(r"^\d{1,4}(\.\d{1,6}){1,3}$")
WIN = os.name == "nt"
NOTHING = " Nothing on this computer was changed."


def say(m):
    print(m, flush=True)


def stop(m, code=2):
    say(m + NOTHING)
    raise SystemExit(code)


def vt(v):
    return tuple(int(x) for x in v.split("."))


def get(url, limit):
    u = urllib.parse.urlsplit(url)
    local = u.hostname in ("127.0.0.1", "localhost", "::1")
    if not (u.scheme == "https" or (u.scheme == "http" and local)):
        raise OSError("address not allowed")
    op = urllib.request.build_opener(urllib.request.ProxyHandler({})) if local else urllib.request.build_opener()
    with op.open(urllib.request.Request(url, headers={"User-Agent": "Qosha-Upgrade/1", "Cache-Control": "no-cache"}),
                 timeout=120) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise OSError("too large")
    return data


def signed_by_qosha(data, sig_doc):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    try:
        d = json.loads(sig_doc.decode("utf-8"))
        sig = base64.b64decode(d["sig"], validate=True)
    except Exception:
        return False
    for pk in PUBLIC_KEYS.values():
        try:
            Ed25519PublicKey.from_public_bytes(base64.b64decode(pk)).verify(sig, data)
            return True
        except (InvalidSignature, ValueError):
            continue
    return False


def manifest(sources):
    last = "Qosha could not reach its update source (check the internet connection)."
    for base in sources:
        base = base.rstrip("/")
        try:
            t = "?t=%d" % int(time.time())
            data = get("%s/%s/manifest.json%s" % (base, CHANNEL, t), 256 * 1024)
            sig = get("%s/%s/manifest.json.sig%s" % (base, CHANNEL, t), 4096)
        except (OSError, urllib.error.URLError, ValueError):
            continue
        if not signed_by_qosha(data, sig):
            last = "The update list did not carry Qosha's signature, so it was not used."
            continue
        m = json.loads(data.decode("utf-8"))
        if m.get("schema") == 1 and m.get("product") == "qosha" and m.get("channel") == CHANNEL:
            return m, base
        last = "The update list was not for this Qosha."
    stop(last)


def pick(m, ring):
    if m.get("paused") is True:
        stop("Qosha's updates are paused right now; try again later.", 1)
    best = None
    for r in m.get("releases") or []:
        try:
            ok = (VERSION_RE.match(r["version"]) and not r.get("paused") and (ring in r["rings"] or "everyone" in r["rings"])
                  and any(f["name"] == "qosha-layer.zip" and f["path"] == "files/%s/qosha-layer.zip" % r["version"]
                          and re.fullmatch(r"[0-9a-f]{64}", f["sha256"]) for f in r["files"]))
        except Exception:
            ok = False
        if ok and (best is None or vt(r["version"]) > vt(best["version"])):
            best = r
    if not best:
        stop("There is no Qosha update for this computer yet.", 1)
    return best


def download(rel, sources, dest):
    f = [x for x in rel["files"] if x["name"] == "qosha-layer.zip"][0]
    for base in sources:
        try:
            data = get("%s/%s/%s" % (base.rstrip("/"), CHANNEL, f["path"]), f["size"] + 1)
        except (OSError, urllib.error.URLError, ValueError):
            continue
        if len(data) == f["size"] and hashlib.sha256(data).hexdigest() == f["sha256"]:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            return dest
        stop("The downloaded update did not match Qosha's signed list, so it was not installed.")
    stop("Qosha could not download the update (check the internet connection).")


def own_processes():
    rows = []
    if WIN:
        ps = "Get-CimInstance Win32_Process | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True, text=True,
                           creationflags=0x08000000)
        try:
            d = json.loads(r.stdout or "[]")
        except ValueError:
            d = []
        rows = [(int(x.get("ProcessId") or 0), x.get("CommandLine") or "") for x in (d if isinstance(d, list) else [d])]
    else:
        r = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True)
        for ln in r.stdout.splitlines():
            p = ln.strip().split(None, 1)
            if len(p) == 2 and p[0].isdigit():
                rows.append((int(p[0]), p[1]))
    return rows


def port_of(root):
    """The port this Qosha runs on: from its running dashboard's own command line (else its start entry, else 9219)."""
    try:
        pid = int((root / "run" / "dashboard.pid").read_text().strip())
        for p, cmd in own_processes():
            if p == pid and str(root).lower() in cmd.lower().replace("/", os.sep):
                m = re.search(r"--port\s+(\d+)", cmd)
                if m:
                    return int(m.group(1))
    except (OSError, ValueError):
        pass
    for f in [root / "start-qosha.cmd", root / "start-qosha.command"]:
        try:
            m = re.search(r"--port\s+(\d+)", f.read_text(errors="replace"))
            if m:
                return int(m.group(1))
        except OSError:
            pass
    return 9219


def prepare(a):
    root = Path(a.root).resolve()
    home = root / "home"
    if not ((root / "layer" / "setup_home.py").is_file() and (root / "engine").is_dir() and home.is_dir()):
        stop("Qosha was not found on this computer (%s)." % root)
    if a.ring not in RINGS:
        stop("Unknown update group %r." % a.ring)
    sources = a.source or SOURCES
    say("Checking Qosha's update (signed by Qosha)...")
    m, base = manifest(sources)
    rel = pick(m, a.ring)
    try:
        cur = json.loads((root / "layer" / "RELEASE.json").read_text()).get("version") or "0"
    except Exception:
        cur = "0"
    if VERSION_RE.match(cur) and vt(cur) >= vt(rel["version"]):
        stop("Qosha is already up to date (version %s)." % cur, 0)
    order = [base] + [s for s in sources if s.rstrip("/") != base]
    z = download(rel, order, root / "updates" / "downloads" / rel["version"] / "qosha-layer.zip")
    with zipfile.ZipFile(z) as zz:
        names = zz.namelist()
        if "candidate/plugin/qosha_guard/updater.py" not in names or "RELEASE.json" not in names:
            stop("The update package is not a Qosha package.")
        upd = zz.read("candidate/plugin/qosha_guard/updater.py")
    if list(PUBLIC_KEYS)[0].encode() not in upd:
        stop("The update's own updater does not trust Qosha's key.")
    (root / "run").mkdir(exist_ok=True)
    (root / "run" / "qosha-updater.py").write_bytes(upd)
    cfgp = home / "qosha" / "updates-config.json"
    cfgp.parent.mkdir(parents=True, exist_ok=True)
    try:
        cfg = json.loads(cfgp.read_text(encoding="utf-8"))
    except Exception:
        cfg = {}
    cfg["ring"] = a.ring
    if a.source:                       # tests only: the stand-in sources
        cfg["primary"], cfg["fallback"] = a.source[0], (a.source[1] if len(a.source) > 1 else "")
    cfgp.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
    port = a.port or port_of(root)
    me = root / "run" / "qosha-upgrade.py"
    if Path(__file__).resolve() != me.resolve():
        shutil.copyfile(__file__, me)
    cmd = [sys.executable, "-I", str(me), "--apply", "--root", str(root), "--port", str(port), "--ring", a.ring]
    log = open(root / "logs" / "upgrade.log", "ab")
    if a.foreground:
        log.close()
        return apply(root, port)
    kw = {"start_new_session": True} if not WIN else {}
    flags = [0x00000008 | 0x00000200 | 0x01000000, 0x00000008 | 0x00000200] if WIN else [0]
    for fl in flags:                   # detached; on Windows also out of the chat's job when allowed
        try:
            if WIN:
                kw = {"creationflags": fl}
            subprocess.Popen(cmd, cwd=str(root), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, **kw)
            break
        except OSError:
            continue
    log.close()
    say("Qosha checked the update (version %s, signed by Qosha) and is installing it now. Qosha restarts in about "
        "a minute; your chats, memory, sign-ins and settings stay as they are. If anything goes wrong it goes back "
        "to the version you have by itself." % rel["version"])
    return 0


def apply(root, port):
    import importlib.util
    os.environ["HERMES_HOME"] = str(root / "home")
    time.sleep(3)                      # the chat's answer finishes before Qosha restarts
    spec = importlib.util.spec_from_file_location("qosha_updater_run", root / "run" / "qosha-updater.py")
    u = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(u)
    rc = u.apply(root, port, "upgrade")
    r = u.load_state(root / "home").get("last_result") or {}
    line = "%s upgrade %s: %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), "ok" if rc == 0 else "rc=%d" % rc, r.get("message", ""))
    with open(root / "logs" / "upgrade.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")
    say(line)
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--ring", default="everyone")
    ap.add_argument("--port", type=int)
    ap.add_argument("--source", action="append", help="tests only: update source (repeat for the fallback)")
    ap.add_argument("--foreground", action="store_true", help="tests: install in this process and wait")
    ap.add_argument("--apply", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args()
    try:
        import cryptography  # noqa: F401
    except ImportError:
        stop("This Python cannot check Qosha's signature.")
    if a.apply:
        return apply(Path(a.root).resolve(), a.port)
    return prepare(a)


if __name__ == "__main__":
    raise SystemExit(main())
QOSHA_UPGRADE_PY_END
rc=0; "$PY" -I "$F" --root "$ROOT" --ring "$RING" ${EXTRA[@]+"${EXTRA[@]}"} || rc=$?
case "$0" in */qosha-upgrade.sh) rm -f "$0";; esac
exit $rc
