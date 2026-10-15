#!/usr/bin/env python3
"""Read every herdr pane and report which agents are actually blocked.

State records and quota tools miss things only visible on screen (a free-tier
usage cap, a dialog waiting for input, an agent that fell back to a shell).
This reads each pane's visible tail and classifies it.

Layers:
  1. deterministic rules (authoritative; named patterns below)
  2. Laya (laya:en-fp32 via Ollaya) as a *secondary* guess for panes the rules
     did not recognise. Laya is weak (28% on queue routing), so its answer is
     only ever labelled `laya-guess` and never files a bead by itself.

Usage:
  bin/fm-pane-triage.py            # table to stdout, writes data/pane-triage/latest.{md,json}
  bin/fm-pane-triage.py --json     # JSON only
  bin/fm-pane-triage.py --file-beads   # also create one `task` bead per NEW rule-confirmed blocked pane
  bin/fm-pane-triage.py --no-laya  # rules only
Exit 0 when nothing is blocked, 3 when at least one pane is blocked.

Env: LAYA_URL (default http://lnx.hippo-tilapia.ts.net:11435/api/decide),
     FM_HOME (default: repo root).
"""
import argparse, hashlib, json, os, re, subprocess, sys, time
from urllib.request import Request, urlopen

ROOT = os.environ.get("FM_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "pane-triage")
SEEN = os.path.join(ROOT, "state", "pane-triage.seen.json")
LAYA_URL = os.environ.get("LAYA_URL", "http://lnx.hippo-tilapia.ts.net:11435/api/decide")
TAIL_LINES = 60

# (state, regex, why) -- first match wins; ordered most specific first.
RULES = [
    ("blocked_usage", r"(free usage exceeded|usage limit|rate limit(ed)?|quota (exceeded|exhausted)|out of credits|"
                      r"you'?ve hit your (usage )?limit|retrying in \d+\s*h|429 too many)", "usage/rate cap"),
    ("blocked_auth", r"(please (log ?in|sign ?in)|not logged in|credentials? (expired|invalid)|401 unauthorized|"
                     r"authentication (failed|required)|/login to)", "needs login/credential"),
    ("trust_dialog", r"(do you trust the files|trust this folder|trust the contents|yes, i trust|allow this workspace)",
     "trust dialog waiting"),
    ("waiting_human", r"(\(y/n\)|\[y/n\]|press enter to continue|do you want to proceed|waiting for (your|user) (input|approval|response)|"
                      r"pick one:|needs[- ]decision)", "waiting for a human answer"),
    ("crashed", r"(traceback \(most recent call last\)|panic(ked)? at|segmentation fault|fatal error:|unhandled exception)",
     "crash/trace on screen"),
]
SHELL_PROMPT = re.compile(r"(^|\n)[^\n]{0,80}[%$#❯➜]\s*$")
BLOCKED = {"blocked_usage", "blocked_auth", "trust_dialog", "waiting_human", "crashed", "agent_exited"}

LAYA_Q = {"s": {"type": "choice",
                "instructions": "What state is this terminal coding-agent session in?",
                "criteria": {"working": "actively making progress on a task",
                             "blocked_usage": "blocked by a usage, quota or rate limit",
                             "waiting_human": "waiting for a human to answer or approve",
                             "finished": "done and idle at a prompt"}}}


def sh(*cmd, timeout=20):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout


def panes():
    d = json.loads(sh("herdr", "pane", "list"))
    return d["result"]["panes"]


def read_tail(pane_id):
    try:
        txt = sh("herdr", "pane", "read", pane_id)
    except Exception as e:
        return ""
    lines = [l.rstrip() for l in txt.splitlines() if l.strip()]
    return "\n".join(lines[-TAIL_LINES:])


def classify_rules(tail, p):
    low = tail.lower()
    for state, rx, why in RULES:
        m = re.search(rx, low)
        if m:
            return state, f"{why}: '{m.group(0)[:60]}'"
    if not p.get("agent") and re.search(r"\.treehouse", p.get("cwd") or "") and SHELL_PROMPT.search(tail[-200:]) and p.get("agent_status") in (None, "unknown"):
        return "agent_exited", "shell prompt, no agent attached"
    return None, ""


def laya(tail):
    state = tail[-1200:]
    body = json.dumps({"model": "laya:en-fp32", "state": state, "questions": LAYA_Q}).encode()
    try:
        with urlopen(Request(LAYA_URL, body, {"Content-Type": "application/json"}), timeout=60) as r:
            a = json.loads(r.read())["answers"]["s"]
        return a["choice"], float(a["confidence"])
    except Exception as e:
        return None, 0.0


def fingerprint(p, state, tail):
    key = f"{p['pane_id']}|{state}|{tail[-200:]}"
    return hashlib.sha1(key.encode()).hexdigest()[:12]


def load_seen():
    try:
        return json.load(open(SEEN))
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-laya", action="store_true")
    ap.add_argument("--file-beads", action="store_true")
    a = ap.parse_args()

    seen, rows = load_seen(), []
    for p in panes():
        tail = read_tail(p["pane_id"])
        if not tail:
            continue
        state, why = classify_rules(tail, p)
        source = "rule"
        conf = None
        if state is None:
            state, source, why = "ok", "rule", "no blocker pattern"
            if not a.no_laya and p.get("agent_status") in ("idle", "unknown", None):
                g, conf = laya(tail)
                if g and g.startswith("blocked") or g == "waiting_human":
                    state, source, why = "suspect:" + g, "laya-guess", f"laya {g} conf={conf:.2f} (unverified)"
        rows.append({"pane": p["pane_id"], "workspace": p.get("workspace_id"), "agent": p.get("agent"),
                     "herdr_status": p.get("agent_status"), "cwd": (p.get("cwd") or "")[-60:],
                     "state": state, "source": source, "why": why, "fp": fingerprint(p, state, tail),
                     "tail": tail.splitlines()[-3:]})

    blocked = [r for r in rows if r["state"] in BLOCKED]
    suspect = [r for r in rows if r["state"].startswith("suspect")]

    new = []
    for r in blocked:
        if r["fp"] not in seen:
            new.append(r)
            seen[r["fp"]] = time.time()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.dirname(SEEN), exist_ok=True)
    json.dump(seen, open(SEEN, "w"))

    if a.file_beads:
        for r in new:
            t = f"Pane {r['pane']} blocked ({r['state']}): {r['why']}"[:140]
            body = f"cwd {r['cwd']}; agent {r['agent']}; last lines: " + " / ".join(r["tail"])[:500]
            out = sh("task", "create", t)
            m = re.search(r"task-[a-z0-9]+", out)
            if m:
                sh("task", "comment", m.group(0), body)

    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    json.dump({"at": stamp, "rows": rows}, open(os.path.join(OUT, "latest.json"), "w"), indent=1)
    md = [f"# Pane triage {stamp}", "", f"{len(rows)} panes read, {len(blocked)} blocked, {len(suspect)} laya-suspect", ""]
    for r in blocked + suspect:
        md.append(f"- **{r['pane']}** `{r['state']}` ({r['source']}) {r['agent']} {r['cwd']} -- {r['why']}")
    open(os.path.join(OUT, "latest.md"), "w").write("\n".join(md) + "\n")

    if a.json:
        print(json.dumps({"at": stamp, "blocked": blocked, "suspect": suspect, "total": len(rows)}, indent=1))
    else:
        print(f"{len(rows)} panes read: {len(blocked)} blocked, {len(suspect)} laya-suspect, {len(new)} new")
        for r in blocked + suspect:
            print(f"  {r['pane']:10} {r['state']:22} {r['source']:10} {r['agent'] or '-':9} {r['why']}")
    return 3 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
