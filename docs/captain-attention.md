# Captain-attention observer

A side observer that puts captain-needing signals on the jumbotron
(displayd) without changing firstmate's flow. Firstmate keeps running the
existing tools; this notices and takes action on the side.

## What it watches (read-only, never written)

- `state/<id>.status` wake-event lines, folded through
  `bin/fm-classify-lib.sh`'s `status_open_decisions` - the same fold
  firstmate itself uses, so "needs the captain" cannot drift. Only
  `needs-decision` and `blocked` opens fire. Ordinary `working`/`done`
  lines never reach the panel.
- New open items in the `review` federated store (read via the `review`
  CLI, never written).
- `state/.afk` needs no handling: when the captain is away the panel is
  MORE important, and the takeover is identical.

## What it does

- `POST /notify` to displayd (the existing transient notice view - no new
  renderer). Title names the verb and task, body carries the key and the
  ask, bounded to glanceable length. The notice returns to the previous
  view automatically after `NOTICE_DURATION` seconds.
- Fires at most once per signal (tracked in
  `state/.captain-attention.seen`). A re-opened or re-worded ask fires
  again; an unchanged one never re-fires. Resolved signals are forgotten.
- displayd unreachable: exits 0, logs one throttled line, keeps its place
  and lands the signal once when displayd returns (no replay flood).
- No secrets anywhere: the displayd API is unauthenticated tailnet-only
  and the observer sends only titles and status text.

## Install / uninstall (macOS, survives reboot)

```sh
bin/fm-captain-attention.sh --install     # launchd KeepAlive + RunAtLoad
bin/fm-captain-attention.sh --status      # loaded / not loaded
bin/fm-captain-attention.sh --uninstall   # unload; seen/log state is kept
```

The first `watch` start bootstraps silently: everything already open or
already needing eyes is recorded WITHOUT notifying, so install day is not
a hundred takeovers. Only genuinely new signals take over after that.

Manual single scans:

```sh
bin/fm-captain-attention.sh once                          # notify now
bin/fm-captain-attention.sh once --dry-run                # print, no POST
bin/fm-captain-attention.sh once --bootstrap              # record, no POST
```

## Configuration (no code edits)

Optional file `$FM_HOME/config/captain-attention.env` (gitignored,
`KEY=value` per line; only the keys below are honoured):

```sh
CAPTAIN_ATTENTION_ENABLED=0    # off switch (default 1)
DISPLAYD_URL=http://100.81.88.113:8980
POLL_SECS=5
NOTICE_DURATION=120            # 1-300, displayd's own range
```

Precedence: CLI flags (`--state-dir`, `--displayd-url`) beat environment,
which beats this file, which beats built-ins.

## Cost

One status-fold plus one `review list` every 5 seconds, plus a POST only
when something new needs the captain. Quiet log
(`state/.captain-attention.log`, last ~200 lines); failures log at most
one line per 10 minutes.

## Verification (2026-09-28, live panel)

Against the real displayd with a scratch state dir, all proven:

1. A real `needs-decision` event took over the panel (`renderer: notice`,
   transient active) with the decision text.
2. The same open decision on re-scan produced no second takeover.
3. After `resolved`, no takeover and the seen entry was pruned.
4. Re-opening the identical text took over again (open-count bump).
5. displayd down: exit 0, no crash, nothing recorded, one throttled log
   line - the signal lands once when displayd returns.

NOT verified: the launchd install running overnight on the MacBook (the
captain's install step), and a real review-store item firing (covered by
the same once-only path as decisions, but only exercised as dry-run
against the live home).
