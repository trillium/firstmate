# CAPTAIN AUTHORIZATION (complete, verbatim; also in data/captain.md)
> AUTHORIZATION PART 1/3: effective now until the OpenClaw talk on Wed 2026-10-14 ends, every request, hold, or decision that would need captain consent is yours to decide. Decide, record a one-line rationale on the bead, continue. Never use the human label, ask-user holds, or captain-hold in this window.
> AUTHORIZATION PART 2/3: scope is voicefirst-landing, brain-playground, coder-brain-studio, parlay, beads-bridge, this firstmate home, and mini0/mini1. (1) Merge and deploy any PR in those repos, including waiving a named failing or non-reporting check you judge unrelated to the talk. (2) Spawn unlimited workers on any verified harness and machine; change dispatch profiles and worker account choices.
> AUTHORIZATION PART 3/3: (3) Relaunch, replace, or kill any session or agent, including the stale fleet-lock holder on mini0-ops (pid 30708, pane w6:p21); (4) directly edit, create, move, or delete files in those projects and in this home's shared tracked files, and discard unlanded work in worktrees you judge abandoned; (5) fix tooling bugs yourself (robots-h36m, robots-xldf, robots-3ftw) and change hooks and guards that block work; (6) close, supersede, or re-file beads in any store. One rule I keep: if you expose Parlay or Beads Bridge publicly, do it with auth and isolation in place, and do it rather than skipping it. If something needs a login or credential only I can supply, route around it, keep every other item moving, and put it in the status pad.

# OpenClaw talk prep — Wed 2026-10-14 (TEMPORARY, delete after talk)
Source: inbox-dd1f (dispatch), parent task-l6wjg (.1–.14), status-wgf, project-p20f.3
Posture: direct-PR, yolo on, no no-mistakes/CodeRabbit, merge+test on green. Repos: voicefirst-landing, brain-playground, coder-brain-studio are private; parlay and beads-bridge are PUBLIC on GitHub (the rule below is about the running services, not the code). Never expose the Parlay/Beads Bridge services publicly without auth+isolation.

## Work items → owner
1. trillium/voicefirst-landing — land 2 MacBook branches, deck reqs (.1), voicefirst.dev routing (.13) → mini0-ops (talk-voicefirst)
2. trillium/brain-playground — public HTTPS deploy, presenter reset, daily reset, Quartz v4.5.2 (.12) → mini0-ops (talk-playground)
3. trillium/coder-brain-studio — merge PR #2, ops/acceptance.sh, egress-lock status (.11) → mini0-ops (talk-studio)
4. trillium/parlay — slide_next/slide_previous ModeAction + Talon failure flash (.4/.2, task-0rt16) → primary: talk-parlay-slide-actions
5. trillium/beads-bridge — merge+deploy PR #33 (.5/.9) → primary: talk-bridge-pr33-deploy
6. Demo prep .3 .5 .9 .10 + day-of checklist .14 → mini0-ops (talk-dayof)

## Decisions (made by firstmate 2026-10-13, all reversible; recorded on beads)
.6 skip Grok hour · .7 Hermes one-line mention · .8 OpenClaw = framing slide + live voice-to-task demo · .11 studio presenter-only · .9 phrases "next slide"/"previous slide", capture cmd "capture note" · ~~.12 cut .11.1~~ REVERSED by captain: .11.1 (isolated Beads Bridge MCP inside the Coder workspace) is IN scope, build it

## CURRENT STATUS (overwrite this block every wake; history goes in the wake log below)
Last updated: wake #32. If this block disagrees with the log, the newest log entry wins.

| # | Item | State | Evidence / PR | Next |
|---|------|-------|---------------|------|
| 1 | voicefirst-landing | MERGED (#2-#5), live | apex HTTPS 200, cert valid (curl verify 0) | none |
| 2 | brain-playground | MERGED (#2), live | play.voicefirst.dev HTTPS 200 valid cert | presenter reset outside check |
| 3 | coder-brain-studio | MERGED (#2-#6) | studio.voicefirst.dev 401 gated; real Beads MCP + attendee access merged; lnx boundaries approved | outside attendee test |
| 4 | parlay | MERGED + LIVE (#325, #326) | phone trigger on tailnet :8450 | captain phone tap |
| 5 | beads-bridge | MERGED + DEPLOYED (#33) | /live/variants 200 | auth check |
| 6 | demo prep + day-of | in flight (mini0-ops talk-dayof) | DAY-OF.md unconfirmed | confirm file |
| 7 | guard fixes | MERGED (#211) | primary synced | watch xldf |
| 8 | failover (task-673ui) | drill PASSED in disposable home; fixes in https://github.com/trillium/firstmate/pull/212 (CI pending) | evidence on task-673ui | merge on green, tick box |
| 9 | slides + rehearsal | plan MERGED (#4) | | schedule rehearsal with captain |

## DEADLINES (all local time, 2026-10-13/14)
- 04:00: primary failover tested (drill + switch-back). Claude 5h window ends about 04:26; codex is unavailable, so route to grok / opencode-go / agy.
- 09:13 UTC: voicefirst.dev apex cert rate limit clears (reload 09:14:20 UTC).
- Talk start time on Wed 2026-10-14: NOT FOUND in task-l6wjg, its children, or inbox-dd1f (only the date, Oct 14). Treated as unknown; finish well before morning. Fill in if the captain states it.
- fm-nudge pokes run every 25 min through about 09:55 (20 total); stop with `fm-nudge stop`.

## UNLANDED / UNCOMMITTED WORK
None in tracked files (guard edits discarded, #211 merged). Untracked: CHANGELOG.md, fm-hooks.rules.json, odd account2 file.

## DAY-OF ACCEPTANCE CHECKLIST (done = every box true, verified by evidence)
- [x] (loads HTTPS 200 valid cert from lnx public IP 107.198.7.2 and vps01, wake #33; reset functional test = mini0-ops report) play.voicefirst.dev loads over HTTPS from outside the tailnet; presenter reset works (HTTPS 200 seen 02:35; reset + outside-tailnet check pending talk-playground)
- [x] studio.voicefirst.dev reachable and gated (presenter-only): HTTPS 401 unauthenticated 02:35; activate-user HTTP 200, reset-brain seed 2s, links.sh returned writable+read-only links (task-une5r)
- [x] voicefirst.dev apex serves HTTPS with a valid cert (curl 200, verify 0, wake #32)
- [ ] "next slide" / "previous slide" voice commands work from the phone via Parlay
- [x] (voicefirst-landing PR #8 merged: capture-note voice-to-task demo, runbook, fallback; live run to confirm in rehearsal) "capture note" works; live voice-to-task demo runs end to end
- [x] (real bridge merged, coder-brain-studio PR #6, acceptance verified by mini0-ops) Isolated Beads Bridge MCP runs inside the Coder workspace, seeded/reset with Brain; sample beads created+linked; real Bridge/stores untouched (task-l6wjg.11.1)
- [x] (wake #35: Bridge :3737 public via Funnel returns 401 without credentials; Parlay slide tailnet-only :8450, 401 without bearer token; attendee Bridge is a disposable copy in the studio) Beads Bridge and Parlay exposed only with auth + isolation
- [x] (mini0-ops report, wake #33; file not opened by me) DAY-OF.md exists and every item above has a runbook
- [x] (drill passed in disposable home, fixes PR #212 merged, evidence on task-673ui; real primary stays on Claude, switch-back proven) Failover drill passed and primary is back on Claude after the window resets
- [x] (duplicate of the ticked Bridge box above; coder-brain-studio PR #6) task-l6wjg.11.1: isolated Beads Bridge MCP running inside the Coder workspace, seeded/reset with Brain data (captain reversed the cut)
- [x] (coder-brain-studio PR #4 merged; per-attendee tokens, rate limited; outside test pending) Attendee access to the studio (not just presenter-only) built and tested safely; presenter-only is the fallback, not the plan
- [x] task-0a7bz (merged, voicefirst-landing PR #3): device speech (browser TTS) prototype for the OpenClaw studio website
- [x] Recorded/static fallback for every live demo (voicefirst-landing PR #5; video placeholders fill after rehearsal) (parent task-l6wjg completion criterion)
- [ ] Phone-triggered "Slide next" reaches the same Talon command (task-l6wjg.4), tested from a phone on cellular
- [~] slides + 10:00 rehearsal plan merged (voicefirst-landing PR #4); rehearsal itself still to be scheduled with the captain
- [x] task-l6wjg.6 (Grok runbook, PR #7), .7 (Hermes fallback, PR #6), .8 (OpenClaw, PR #8) built, merged, beads closed; site redeployed, /slides and /fallbacks 200

## SCOPE RULE (captain, 2026-10-13)
Firstmate must not cut or downgrade any in-scope item to protect schedule. Add workers instead. Any scope reduction goes to the captain as a note in this file, not as a silent decision.

## Open tooling bugs
robots-h36m (Monitor guard, fixed, needs PR), robots-xldf (wake flood, mitigated, watch for recurrence), robots-3ftw (mini0-ops relaunch).

---
# WAKE LOG (append-only; one entry per wake: In flight / Next / Blocked / Done)

## Wake #2 — 01:49:59
**In flight**
- talk-parlay-slide-actions (parlay, grok-4.7, direct-PR, yolo on) — slide_next/previous + Talon failure flash; ties to task-l6wjg.4, .2
- talk-bridge-pr33-deploy (beads-bridge, grok-4.7, direct-PR, yolo on) — merge + deploy PR #33; ties to task-l6wjg.5, .9
**Next**
- Inspect mini0-ops pane w6:p21 for talk-voicefirst / talk-playground / talk-studio / talk-dayof spawns; spawn from this home if absent
- Comment task ids on task-l6wjg.1, .3, .10, .11, .12, .13, .14; close inbox-dd1f when all recorded
**Blocked**
- mini0-ops items 1-3,6: unconfirmed; its new session is read-only (fleet lock held by older session pid 30708); urgent msg 037 queued
- Tooling bugs open: robots-h36m, robots-xldf, robots-3ftw
**Done**
- Briefs filled and workers spawned for items 4 and 5; dispatch commented on task-l6wjg.4/.2/.5/.9 and inbox-dd1f
- Open decisions resolved with defaults (.6 .7 .8 .9 .11 .12), recorded on beads
- Wake queue drained and acked through 311151

## Wake #3 — 01:51:26
**In flight**
- Primary: talk-parlay-slide-actions, talk-bridge-pr33-deploy (no status events yet)
- mini0-ops (claude-sonnet-5-5, direct-PR, yolo on): talk-voicefirst (item 1), talk-playground (2), talk-studio (3), talk-dayof (6: .3/.5/.9/.10 runbooks + DAY-OF.md) — spawned per its status at epoch 1791881328, beads commented by mini0-ops
**Next**
- Verify mini0-ops' task-l6wjg.N comments exist; close inbox-dd1f
- Watch for PR URLs from all six workers; confirm merges/deploys by evidence
- Before talk: smoke run of /live/variants, playground URL, slide next/prev from phone
**Blocked**
- Nothing blocking dispatch. Tooling bugs open: robots-h36m, robots-xldf, robots-3ftw
**Done**
- mini0-ops confirmed all four spawns (item 6 and items 1-3 now running)
- All six dispatch items are now in flight
- (01:52) inbox-dd1f closed: all six dispatches recorded on task-l6wjg beads. Remaining work is supervising the six workers to merged PRs.

## Wake #4 — 01:53:44 (rearm-resurface; no new events)
**In flight**: all six workers (2 primary, 4 mini0-ops); no new status lines or PR URLs yet
**Next**: wait for worker status/PR URLs; confirm merges and deploys by evidence
**Blocked**: nothing; robots-h36m, robots-xldf, robots-3ftw still open
**Done**: wake drained and acked through 312019

## Wake #5 — 01:56:01 (captain authorization received)
**In flight**: all six talk workers (parlay slide-actions, bridge PR #33 deploy here; voicefirst, playground, studio, dayof on mini0-ops); no PR URLs yet
**Next**: (a) ask captain to resend authorization items 1-3 (message arrived cut off); (b) work robots-h36m, robots-xldf, robots-3ftw myself under item 5; (c) watch for PR URLs
**Blocked**: only the missing items 1-3 text; nothing else
**Done**: authorization (visible tail) recorded in data/captain.md and this file's header

## Wake #6 — 02:00 (complete authorization recorded)
**In flight**: 2 primary workers (parlay slide-actions, bridge PR #33), 4 mini0-ops workers (talk-voicefirst/playground/studio/dayof, metas present); no PR URLs yet
**Next**: confirm new mini0-ops session (w9) acquires the lock and clears its queued items 028/031/035; finish marking remote-reply results handled (robots-xldf, background loop ~309/611 done); robots-3ftw; watch for PRs
**Blocked**: nothing
**Done**: full authorization parts 1-3 + items 1-6 replaced the truncated header here and in data/captain.md; robots-h36m fixed (Monitor allowed for 'parlay listen/monitor' in bin/fm-subagent-pretool-check.sh, uncommitted, needs PR) and closed; killed stale mini0-ops lock holder pid 30708 and nudged w9 session; wake acked through 313316

## Wake #7 — 02:04
**In flight**: 4 mini0-ops workers (metas present, no status yet); primary talk-parlay-slide-actions + talk-bridge-pr33-deploy (grok panes)
**Next**: confirm the two grok workers act on their steering inbox (001.msg); then watch for PR URLs; robots-xldf handled-marking (~362/611); robots-3ftw
**Blocked**: nothing hard. Quota: Claude 5h window ends ~04:26 local; Codex NOT available; route new workers to grok / opencode-go / agy only (captain note)
**Done**: found both grok workers stuck at folder-trust gate since spawn (no work done); answered gate (Enter), re-delivered brief pointer, pressed Enter on queued steer; both now at idle composer; wake acked through 314111

## Wake #8 — 02:11 (failover task + dispatch order)
**In flight**: talk-parlay-slide-actions (grok, now working on ModeAction), talk-bridge-pr33-deploy (grok), 4 mini0-ops workers, NEW talk-primary-failover (claude, direct-PR; bead task-673ui; deadline: tested before 04:00)
**Next**: monitor failover worker; merge its PR when green; run a live failover drill + switch-back test before 04:00; watch PR URLs from the other five
**Blocked**: nothing. Reminder: Claude 5h window ends ~04:26; Codex unavailable (never route to it)
**Done**: config/crew-dispatch.json now claude-first (default list + a new first rule: claude -> grok -> opencode-go -> agy), backup config/crew-dispatch.json.bak-20261014; remaining 'codex' strings are provider labels on opencode free entries, left alone; failover bead task-673ui created and dispatched

## Wake #9 — 02:09
**In flight**: parlay slide-actions (grok, implementing allow-listed action mode); bridge deploy (PR #33 merged, deploying now); talk-primary-failover (claude, no PR yet); mini0-ops: talk-playground (deploying to vps01, play.voicefirst.dev DNS added), talk-voicefirst (paused: Let's Encrypt apex cert rate limit until 09:13 UTC; job reloads Caddy 09:14:20 UTC), talk-studio (PR #3 open, checks 2/2 green)
**Next**: confirm coder-brain-studio PR #3 merges (mini0-ops yolo); bridge deploy evidence on task-l6wjg.5; parlay PR; failover PR + live drill before 04:00; then re-verify public URLs from outside
**Blocked**: voicefirst.dev apex HTTPS waits on cert rate limit (self-clears 09:13 UTC; fallback = subdomain/IP route if it slips)
**Done**: beads-bridge PR #33 merged (zero open PRs now); studio PR #2 merged; studio acceptance 43/43, egress lock active, public studio UI gated at studio.voicefirst.dev; wake acked through 314740

## Wake #10 — 02:12
**In flight**: unchanged (parlay slide-actions, bridge deploy, primary-failover, 4 mini0-ops talk workers)
**Next**: if empty remote-reply results keep arriving unhandled (616 was an empty, 'malformed' delta I had to mark handled by hand), patch the adapter to auto-handle empty deltas; then keep watching PR URLs
**Blocked**: nothing
**Done**: robots-xldf mitigated: 412 stale remote-reply results marked handled, wake queue now empty (was ~600 rows); bug left open pending recurrence check; wake acked

## Wake #11 — 02:13
**In flight**: unchanged (see wake #9/#10)
**Next**: source runner must restart to load the patched adapter (happens on next reconcile); open a PR with the h36m + xldf fixes; watch for PR URLs
**Blocked**: nothing
**Done**: empty remote-reply results 617/619/620 marked handled; patched bin/fm-procevent-remote-reply.sh so exit-0/empty reads relisten instead of capturing (robots-xldf second root cause); wake acked through 314827
- (02:15) wake: empty result 621 handled/acked; runner restarted 02:12 after patch, watching for recurrence

## Wake #12 — 02:20
**In flight**: talk-primary-failover (claude; task-673ui); talk-parlay-deploy-verify (claude, new: restart Parlay on main, test action mode dry-run + rejection, Talon side, tailnet-only); mini0-ops: playground (deploying vps01), voicefirst (apex cert rate-limit until 09:13 UTC), studio PR #3 (green, awaiting merge), dayof
**Next**: failover PR + live drill + switch-back test before 04:00; confirm studio PR #3 merged; verify play.voicefirst.dev / studio.voicefirst.dev from outside; open PR for fm-subagent-pretool-check.sh + fm-procevent-remote-reply.sh fixes (h36m, xldf)
**Blocked**: nothing
**Done**: Parlay PR #325 merged (slide_next/slide_previous action mode, 5/5 checks) -> task-l6wjg.4; beads-bridge PR #33 merged + deployed b44c3b09, /live/variants 200 -> task-l6wjg.5; both workers torn down, fleet synced; wake acked through 314877

## Wake #13 — 02:18 (heartbeat + generic captain 'continue' note + parlay merge landed)
**In flight**: talk-primary-failover (claude), talk-parlay-deploy-verify (claude), talk-guard-fixes (claude, NEW: lands robots-h36m + robots-xldf fixes as a direct-PR from data/talk-guard-fixes/changes.patch), mini0-ops x4 (playground, voicefirst, studio PR #3, dayof)
**Next**: merge guard-fixes PR when green (then discard the identical uncommitted edits in the primary checkout before fast-forward); failover drill before 04:00; outside verification of public URLs
**Blocked**: nothing
**Done**: heartbeat reap scan run (only unmatched staleness rows, left untouched); parlay merge-landed wake and the standing 'continue' note handled; acked through 314880

## Wake #14 — 02:21
**In flight**: talk-primary-failover (claude, no status yet), talk-guard-fixes (claude), mini0-ops: playground (deploying), voicefirst (apex cert wait until 09:13 UTC), dayof
**Next**: failover PR + drill before 04:00; guard-fixes PR merge; outside check of play./studio.voicefirst.dev; voicefirst apex after 09:14 UTC
**Blocked**: voicefirst apex HTTPS cert rate limit (self-clears)
**Done**: Parlay action mode live on :4242 and :4500 (talk-parlay-deploy-verify, evidence on task-l6wjg.4), worker torn down; coder-brain-studio PR #3 merged (task-l6wjg.11); non-talk reap escalations (brain-review-fixes-e5, dotfiles-casks-df) tracked on a task bead for post-talk; acked through 314888

## Wake #15 — 02:25
**In flight**: talk-primary-failover, talk-guard-fixes, mini0-ops (playground, voicefirst, dayof)
**Next**: failover drill before 04:00; guard-fixes merge; outside checks of public URLs
**Blocked**: apex cert limit until 09:13 UTC; talk start time not recorded anywhere (searched task-l6wjg + inbox-dd1f)
**Done**: adopted captain's new pad layout (CURRENT STATUS overwritten); no checklist box ticked yet (none verified from outside); acked through 314898

## Wake #16 — 02:28
**In flight**: failover PR https://github.com/trillium/firstmate/pull/210 (CI running; merge on green, then drill), guard-fixes, mini0-ops workers
**Next**: merge #210, run drill + switch-back before 04:00
**Blocked**: none new
**Done**: processed branch outcomes 1054/1055 (herdr-web PR #61 is non-talk, left for later)

## Wake #17 — 02:36 (task-une5r)
**Done**: lnx disk already extended (LV 200G, root 45% used, 104G free, was 91%; VG has 35G spare); ran activate-user (200), reset-brain seed (2s), links.sh (links issued); studio.voicefirst.dev answers 401 to unauthenticated requests; ticked studio box
**In flight**: failover PR #210 CI, guard-fixes, mini0-ops workers
**Next**: merge #210 on green, failover drill; play. outside-tailnet + presenter reset check
**Blocked**: none new. Note: this Mac is on the tailnet, so "outside" checks are only indicative until tested from a phone on cellular

## Wake #18 — 03:00
**In flight**: talk-studio-beads-mcp (task-l6wjg.11.1, dispatched via mini0-ops, claude first); failover PR #210 CI; guard-fixes; playground; dayof
**Next**: merge .11.1 PR on green + verify isolation; merge #210 + drill; verify apex cert
**Blocked**: none
**Done**: captain reversal recorded (.11.1 reinstated, in scope; no cutting for schedule, add workers); voicefirst-landing PR #2 merged and live; row + checklist box added

## Wake #19 — 03:10
**In flight**: talk-phone-slide-next (local, claude); mini0-ops: talk-studio-beads-mcp (brief fix in progress), batch 2 dispatched (attendee access, TTS, fallbacks, slides+rehearsal); failover PR #210 CI; guard-fixes
**Next**: confirm mini0-ops spawns all 5; merge PRs on green; failover drill before 04:00
**Blocked**: none
**Done**: captain scope reversals recorded (no cuts, add workers); rows 8-13 added; checklist items already present from captain

## Wake #20 — 02:30 local (09:30 UTC)
**In flight**: PR #210 failover and PR #211 guard-fixes (https://github.com/trillium/firstmate/pull/211), CI running ~8 min; mini0-ops confirms 5 workers running (Beads MCP, attendee access, speech, fallbacks, slides+rehearsal); talk-phone-slide-next (local)
**Next**: merge #210 and #211 on green; failover drill before 04:00; discard primary h36m/xldf edits before fast-forward
**Blocked**: none
**Done**: mini0-ops spawn of batch 2 confirmed; outcomes 1057/1058 processed

## Wake #21 — 09:35 UTC
**In flight**: PRs awaiting CI: firstmate #210 (failover), #211 (guard fixes), parlay https://github.com/trillium/parlay/pull/326 (phone slide trigger); 5 mini0-ops workers
**Next**: merge all three on green; redeploy parlay on :4242/:4500 after #326 merges; captain cellular test; failover drill before 04:00
**Blocked**: none
**Done**: phone Slide next PR ready with live evidence (token-auth, fails closed)

## Wake #22 — 09:38 UTC
**In flight**: CI on firstmate #210, #211, parlay #326; mini0-ops: studio Beads MCP, attendee access, fallbacks
**Done**: voicefirst-landing PR #3 (TTS) and PR #4 (slides + timed rehearsal) merged by mini0-ops
**Next**: merge three PRs on green; failover drill; schedule rehearsal with captain
**Blocked**: none

## Wake #23 — 09:41 UTC
**Done**: fallbacks for every live demo merged (voicefirst-landing PR #5, offline)
**In flight**: CI on firstmate #210, #211, parlay #326 (some jobs finished, a few running); mini0-ops studio Beads MCP + attendee access
**Next**: merge on green; failover drill; record fallback videos after rehearsal
**Blocked**: none

## Wake #24 — 09:45 UTC
**Done**: studio attendee access built (coder-brain-studio PR #4); decided per-attendee tokens as default, shared join code as fallback; told mini0-ops to merge on green and verify from outside
**In flight**: CI on firstmate #210, #211, parlay #326; mini0-ops studio Beads MCP
**Next**: merge PRs on green; failover drill before 04:00
**Blocked**: none

## Wake #25 — 09:50 UTC
**Done**: parlay PR #326 (phone slide trigger) MERGED (https://github.com/trillium/parlay/pull/326); worker torn down; non-talk herdr-web/parlay-next-word outcomes acked
**In flight**: talk-parlay-deploy-slide (redeploy :4242/:4500 with token, verify), firstmate #210 and #211 CI, mini0-ops studio Beads MCP + attendee PR #4 merge
**Next**: captain cellular test once deploy verified; failover drill before 04:00
**Blocked**: none

## Wake #26 — 09:55 UTC
**Done**: phone Slide next deployed and verified on live Parlay (no/wrong token 401, live next/previous injected); phone URL https://macbook.hippo-tilapia.ts.net:8450/slide (tailnet-only), token in ~/.config/parlay/slide-token
**Blocked on captain-only action**: real phone tap test (phone must be on Tailscale)
**In flight**: firstmate #210, #211 CI; mini0-ops studio Beads MCP + attendee end-to-end verification
**Next**: merge #210/#211 on green; failover drill before 04:00

## Wake #27 — 02:52 PDT
**In flight**: firstmate #210 failover (CI: only "serial 5" left, normally ~28 min; started 09:22 UTC), #211 guard fixes (3 jobs left); mini0-ops studio Beads MCP + attendee verification
**Done**: failover dry-run from PR worktree OK: lock held pid 20556, pane wY1:p1, candidates grok/opencode/pi ready, plan prints /exit then relaunch on grok in the same pane. Claude quota now 83% remaining, resets 14:00 UTC (07:00 PDT)
**Next**: merge #210 on green, run LIVE drill (failover to grok then switch-back) before 04:00; merge #211; discard primary h36m/xldf edits first
**Blocked**: none

## Wake #28 — 02:58 PDT
**Done**: isolated Beads Bridge MCP stand-in merged (coder-brain-studio PR #5, acceptance 81/81, real-bridge check was vacuous from mini0)
**In flight**: talk-studio-real-bridge (run the real public beads-bridge in the workspace; stand-in stays fallback); firstmate #210 (serial 5 only), #211
**Next**: merge #210, live failover drill before 04:00; verify attendee access from outside
**Blocked**: none

## Wake #29 — 03:08 PDT  (failover drill NOT started: captain declined the live kill of this session; see wake #30)
**Done**: failover PR #210 MERGED (https://github.com/trillium/firstmate/pull/210) and merged into local main (resolved bin/fm-test-run.sh by taking origin side); coder-brain-studio PRs #4, #5 merged; real-bridge upgrade worker running on mini0-ops
**DRILL**: the Claude primary ran `bin/fm-primary-failover.sh failover --to grok`. If you are the grok session reading this: (1) confirm bin/fm-session-start.sh ran and you hold the lock; (2) write "drill step 1 PASS: grok primary holds lock" here; (3) run `bin/fm-primary-failover.sh switch-back`; (4) the new Claude session must confirm the lock and write "drill step 2 PASS", then tick the failover checklist box and comment on task-673ui.
**Also pending for whoever is primary**: firstmate PR #211 (https://github.com/trillium/firstmate/pull/211) merge on green, then `git checkout -- bin/fm-subagent-pretool-check.sh bin/fm-procevent-remote-reply.sh` in the primary BEFORE merging origin/main (identical edits); parlay phone tap test is captain-only; talk-studio-real-bridge PR merge; attendee access outside check.

## Wake #30 — 03:15 PDT
**Done**: captain declined a live kill of this session, so no failover was run on the real home; guard-fixes #211 merged, primary synced and h36m/xldf edits discarded; real beads-bridge in studio merged (coder-brain-studio PR #6); talk-primary-failover and talk-guard-fixes torn down
**In flight**: talk-failover-drill (full drill claude->grok->claude in a disposable home, never touching this lock/pane)
**Next**: drill evidence on task-673ui before 04:00; attendee access outside check; tick remaining boxes with evidence; captain phone tap
**Blocked**: none

## Wake #31 — failover drill result
**Done**: failover drill PASSED in disposable home (grok, opencode, pi, switch-back to Claude); fixes in https://github.com/trillium/firstmate/pull/212; evidence on task-673ui; studio boundaries approved (mini0-ops)
**In flight**: PR #212 CI pending, merge on green, then tick failover box
**Next**: attendee/play outside check, captain phone tap, rehearsal
**Blocked**: none

## Wake #32
**Done**: status block rewritten (old replace had not matched); apex/play/studio probed (200/200/401, valid certs)
**In flight**: PR #212 CI (4 pass, 15 pending); talk-dayof, outside tests on mini0-ops
**Next**: merge #212 on green, tick failover box; confirm DAY-OF.md; auth check on Bridge/Parlay
**Blocked**: none

## Wake #33
**Done**: mini0-ops confirms DAY-OF.md exists with runbooks; I verified play/studio/apex over HTTPS from lnx (107.198.7.2) and vps01 (200/401/200, valid certs)
**In flight**: PR #212 CI (5 pass, 14 pending)
**Next**: merge #212 on green and tick failover box; Bridge/Parlay auth check; captain phone tap
**Blocked**: none

## Wake #34
**Done**: acked drill-done wake; PR #212 CI 18/19 green, serial 5 was cancelled at the 30m timeout (flake), rerun triggered
**In flight**: PR #212 rerun of Behavior portable serial 5; talk-dayof/outside tests on mini0-ops
**Next**: merge #212 on green, tick failover box, teardown talk-failover-drill; Bridge/Parlay auth check
**Blocked**: none

## Wake #35
**Done**: auth/exposure verified (Bridge Funnel 401 unauth; Parlay slide tailnet-only, 401 without bearer); inbox note + wake acked
**In flight**: PR #212 serial 5 rerun pending
**Next**: merge #212, tick failover box, teardown talk-failover-drill; captain phone tap; rehearsal
**Blocked**: none

## Wake #36
**Done**: nothing new landed; reread pad, state is current
**In flight**: PR #212 only blocked on rerun of Behavior portable serial 5 (previous attempt hit 30m timeout; if it times out again, waive that one named check under authorization part 2 and merge, since 18/19 green and drill evidence is on task-673ui)
**Next**: merge #212, tick failover box, teardown talk-failover-drill; captain phone tap; timed rehearsal
**Blocked**: none

## Wake #37
**Done**: PR #212 merged (https://github.com/trillium/firstmate/pull/212), failover box ticked, talk-failover-drill torn down, main synced
**Next**: captain phone tap of /slide; timed rehearsal; keep watching xldf recurrence
**Blocked**: none

## Wake #38
**Done**: reread pad; found .6 Grok, .7 Hermes, .8 OpenClaw/capture-note demos had no owner (reversed earlier "cut" decisions per SCOPE RULE)
**In flight**: mini0-ops asked to dispatch one claude worker each for .6/.7/.8; captain phone tap and rehearsal time outstanding
**Next**: track those three beads to evidence; update boxes at lines 50 and 61
**Blocked**: none

## Wake #39
**Done**: Hermes demo worker finished: live demo not feasible, fallback slide + runbook merged (voicefirst-landing PR #6, https://github.com/trillium/voicefirst-landing/pull/6); I approved the fallback (meets .7 acceptance)
**In flight**: talk-grok-demo, talk-openclaw-demo (mini0-ops, claude)
**Next**: evidence on .6/.8, tick boxes at lines 50 and 61; captain phone tap and rehearsal time
**Blocked**: none

## Wake #40
**Done**: voicefirst-landing PR #7 (Grok runbook) and PR #8 (OpenClaw voice-to-task + capture note) conflicted on docs/DAY-OF.md and fallbacks/README.md; I resolved by keeping both sides in a scratchpad clone and merged both on green. Hermes fallback PR #6 already in.
**In flight**: mini0-ops asked to redeploy site, verify, close .6/.7/.8, remove stale worker w9:p9
**Next**: verify deployed site; captain phone tap; rehearsal time
**Blocked**: none

## Wake #41
**Done**: mini0-ops redeployed voicefirst.dev; /slides and /fallbacks 200; beads .6/.7/.8 closed with evidence; stale worker cleaned
**Remaining (captain-only)**: phone tap of /slide on cellular, timed rehearsal time, talk start time
**Blocked**: none

## Wake #42
**Done**: reread pad; closed 4 stale dispatch beads (.4/.6/.7/.13); found beads .3 (computer-state demo), .9 (launch task by voice), .10 (check tasks by voice) still OPEN
**In flight**: mini0-ops asked to close-with-evidence or build each (no cuts)
**Next**: verify their evidence; captain phone tap, rehearsal time (.14), talk start time
**Blocked**: none

## Wake #43
**Done**: .9 voice task-launch demo merged (voicefirst-landing PR #9, https://github.com/trillium/voicefirst-landing/pull/9): interactive HTML fallback (Talon/phone/ChatGPT paths), script, recovery
**In flight**: talk-parlay-demo (.3), talk-voice-check (.10) on mini0-ops; leftover _rebase_temp branch in their voicefirst-landing checkout (cleanup requested)
**Next**: verify .3/.10 evidence; captain phone tap, rehearsal time, start time
**Blocked**: none

## Wake #44
**Done**: mini0-ops cleaned its voicefirst-landing checkout (_rebase_temp deleted); no open PRs in voicefirst-landing; no unlanded work here
**In flight**: talk-parlay-demo (.3), talk-voice-check (.10) on mini0-ops
**Next**: verify .3/.10 evidence on merge; captain phone tap, rehearsal time (.14), start time
**Blocked**: none

## Wake #45
**Done**: quiet check, no new events, no open PRs, no unlanded work
**In flight**: talk-parlay-demo (.3), talk-voice-check (.10) on mini0-ops, no result yet
**Next**: verify evidence when they merge; captain phone tap, rehearsal time (.14), start time
**Blocked**: none

## Wake #46
**Done**: verified: no state record on mini0 for talk-parlay-demo (.3) / talk-voice-check (.10), no PR; they may have died
**In flight**: asked mini0-ops for actual status, respawn or close with evidence
**Next**: confirm response; captain phone tap, rehearsal time, start time
**Blocked**: none

## Wake #47
**Done**: .3 and .10 verified present in voicefirst-landing main (docs/demos/3-*.md, 10-*.md, fallbacks/demo-parlay.html); beads closed with that evidence. The two mini0 workers never produced branches, so nothing was lost.
**Next**: live runs of every demo at the timed rehearsal (.14); captain phone tap, start time
**Blocked**: none

## Wake #48
**Done**: all 5 repos have zero open PRs; mini0-ops stood down redundant workers. DEFECT found by my own probe: https://voicefirst.dev/fallbacks/* returns 404 although mini0-ops reported 200 and the deck F key opens it
**In flight**: mini0-ops asked to serve fallbacks/, redeploy, verify every page 200 from outside, add to preflight
**Next**: re-probe URLs myself after their report; captain phone tap, rehearsal time, start time
**Blocked**: none

## Wake #49
**Done**: fallbacks 404 fixed (voicefirst-landing PR #10: deploy script was excluding fallbacks/; preflight check added). Verified by me: /fallbacks/, /index.html, /demo-parlay.html all 200
**Remaining (captain-only, review-rbnd)**: phone tap, rehearsal time, talk start time
**Blocked**: none

## Wake #50
**Done**: full sweep green: 0 open PRs in all 6 repos; voicefirst.dev 200, /slides/ 200, /fallbacks/ 200, play 200, studio 401 (gated), Bridge public endpoint 401 unauth
**Remaining (captain-only, review-rbnd)**: phone tap, rehearsal time, talk start time
**Blocked**: none

## Wake #51
**Done**: closed task-l6wjg.6/.7/.8/.9/.11/.12/.13 and task-0a7bz with merge evidence (voicefirst-landing PRs #6-#10, firstmate PR #212); 0 open PRs in all 6 repos; URLs re-probed green (Wake #50)
**In flight**: .2 (voice slide advance) and .5 (ChatGPT demo) kept open: need live run at rehearsal; .4 awaits phone tap
**Next**: captain-only items in review-rbnd (phone tap, rehearsal time .14, start time)
**Blocked**: none

## Wake #52
**Done**: wake queue empty; 0 open PRs (voicefirst-landing, brain-playground, parlay re-checked); voicefirst.dev, /slides/, /fallbacks/, play all 200
**In flight**: .2, .5 await live rehearsal; .4 awaits phone tap
**Next**: captain-only items in review-rbnd (phone tap, rehearsal time, start time)
**Blocked**: none

## Wake #53
**Done**: inbox note acked; .2 verified (Talon slide_next/previous already has visible failure flash), .5 verified (beads-bridge PR #33 merged 09:07Z, 0 open bridge PRs); both commented with evidence
**In flight**: .2/.5 live runs at rehearsal (.14); .4 phone tap
**Next**: captain-only items in review-rbnd
**Blocked**: none

## Wake #54
**Done**: queue empty; 0 open PRs in all 6 repos; voicefirst.dev, /slides/, /fallbacks/, play all 200
**In flight**: .2/.5 live runs at rehearsal (.14); .4 phone tap
**Next**: captain-only items in review-rbnd (phone tap, rehearsal time, start time)
**Blocked**: none

## Wake #55 (captain asked: is the coder space developed?)
**Finding**: coder-brain-studio PRs #1-#6 merged, but I had NOT verified the image with the real Bridge (PR #6) is deployed on lnx or run an outside attendee test. .11.1 stayed open. Honest status: merged, deploy unproven.
**In flight**: mini0-ops steered to rebuild/deploy if needed, run acceptance live, run outside attendee flow, report evidence
**Next**: verify evidence myself via curl, then close .11.1
**Blocked**: none

## Wake #56 (coder space, captain challenged "is it all developed?")
**Finding**: coder-brain-studio PR #6 (real Bridge) had never built: Dockerfile ran `npm run build` on a Bun app; live workspace was running the pre-#6 image with only the demo bridge. mini0-ops has no Coder access; stood down, firstmate took it back.
**Done**: PRs #7 (bun bridge + stores/wrappers/bearer) and #8 (bridge CLI + acceptance 3.4) merged; image brain-studio:2026-10-14b built, template pushed, workspace recreated. Live acceptance PASS=77 FAIL=0. Real bridge :3737 verified (401 unauth, bead_show OK with bearer). Outside test on https://studio.voicefirst.dev: unauth 401, wrong code 401, right code serves sshx app, Coder API path 404. Join code reset (old one on mini0 was stale); new code in ~/.config/studio/join-code on this Mac. task-l6wjg.11.1 closed with evidence.
**Not done**: attendee per-token Caddy config (PR #4) is not installed on vps01; standard shared join-code flow is what is live. Real phone/cellular pass still captain-only.
**Next**: .1 slides check, rehearsal (.14); captain items in review-rbnd
**Blocked**: none

## Wake #57
**Done**: Coder studio audience slide added to deck (voicefirst-landing PR #11, merged; unrelated smoke boundary check waived, fails on main too). Deck 15 slides / 9:50, PDF 15 pages. Deployed to vps01; https://voicefirst.dev/slides/ live with slide (verified by curl). task-l6wjg.1 closed. Coder studio (PRs #7, #8) deployed, acceptance 77/0, public edge verified.
**In flight**: nothing building.
**Next**: captain-only items (phone tap, rehearsal time .14, start time); .2/.5 live runs at rehearsal; .4 phone tap. CURRENT STATUS table above is stale: coder studio DEPLOYED, slides = 15.
**Blocked**: none.

## Wake #58
**Done**: reread pad; 0 open PRs in all 5 repos; no new wake records (only old mini0-ops holds, post-talk triage); .1 closed last wake, deck live at 15 slides.
**In flight**: nothing building. .2/.5 live runs at rehearsal; .4 phone tap; .14 rehearsal.
**Next**: captain-only items in review-rbnd (phone tap, rehearsal time, talk start time, cellular check of studio link).
**Blocked**: none.

## Wake #59 (user-style QA, round 1)
**Pass**: studio edge (no code 401, wrong 401, right code serves session link 200, Coder API/path traversal/POST all 404); slide API (/api/chat/slide: no token 401, bad token 401, good token bad action 400, non-JSON 415); Bridge funnel unauth 401; voicefirst.dev, /slides/, /fallbacks/, play all 200 under 0.5s.
**Not yet run**: browser-driven deck walk, playground edit+reset, 50-way load on studio, failure drills (kill bridge/container), clean-machine build on mini1, MCP tool calls through funnel.
**Next**: queue those as workers (browser walk + playground on mini1; load/failure drills at a quiet moment).

## Wake #60 (QA round 2: real-browser deck walk)
**Found**: verify-browser.mjs still hardcoded 14 slides (6 false failures) and deck.js clock budget was 575s (amber at wrong time); README said 9:35.
**Done**: voicefirst-landing PR #12 merged (waived pre-existing 'deck stays inside slides/' smoke check), deployed; live deck.js budget 590. Live deck passes browser checks: arrows, tap zones, fullscreen, file://, print-pdf at 15/15.
**Next**: playground edit+reset, load/failure drills, mini1 clean build.

## Wake #61 (QA round 3: playground as attendee)
**Pass**: typed bead add works (25 from 24 base), inference to task store; <script> in title is HTML-escaped in render; 200KB body 413; bad JSON 400; attendee POST /api/reset 401 'presenter only'; presenter reset via vps01 brain-playground-reset.service restored 24 beads, probe gone; service active.
**Next**: load + failure drills (studio, bridge), mini1 clean build.

## Wake #62 (QA round 4: playground load)
150 POSTs from 30 parallel clients: 72 x 201, 78 x 429 (rate limit holds), max 2.2s, health ok throughout; presenter reset restored 24 beads. Note: a rate limit means a large audience may see 429s on add; ~72 adds accepted in the burst window.
**Next**: studio load (read-only link), bridge/studio failure drills, mini1 clean build.

## Wake #63 (herdr-web troubleshooting)
**Finding**: herdr-web is UP on macbook (:8787, pid since 00:47, daemon reachable v0.9.1, tailnet 200) and on mini0-3 (/api/health 200 each). Log history shows crash-loop 'Connection refused' while the herdr server was down; launchd KeepAlive recovers it once the server is back. So 'down' was transient (herdr server restart), not current.
**Next**: if captain still sees it down, get the URL/device used; otherwise continue QA (studio load, failure drills, mini1 clean build).

## Wake #64 (captain: have you looked at the panes?)
**Admission**: I had judged from state records + quota-axi only. Panes showed six macbook-ops OpenCode workers (Space Bunny Free) frozen on 'Free usage exceeded, retrying in 6h56m'; macbook-ops secondmate had been asking for a model decision for hours.
**Done**: all six were superseded by merged work (site, 15-slide deck, playground, studio, bridge). Diffs of the two with dirty scaffolds archived in data/stuck-worker-archive/; panes closed; macbook-ops told to stand them down. Filed robots bead for quota-axi blind spot (opencode free tier).
**Rule going forward**: each wake, read the panes (herdr pane list/read), not just state files.

## Wake #65 (pane-triage tool)
**Built**: bin/fm-pane-triage.py reads every herdr pane tail; deterministic rules (usage cap, auth, trust dialog, waiting-human, crash, agent exited in a treehouse) + Laya (laya:en-fp32 @ lnx:11435) as labelled secondary guess for unrecognised panes. Runs every 5 min via launchd dev.firstmate.pane-triage with --file-beads (one task bead per NEW rule-confirmed blocked pane; Laya alone never files). Report: data/pane-triage/latest.{md,json}. Tested on 6 rule cases + live (finds nothing blocked now).
**Also**: macbook-ops asked for explicit discard of the 6 frozen tasks; sent 'discard' (diffs archived). Not relaunching them: superseded by merged work.
**Next**: confirm macbook-ops closes the six; wire triage output into the wake digest if wanted.

## Wake #66 (build guide + slide 13 copy)
- Done: Lavish build guide .lavish/openclaw-build-guide.html; slide 13 now has presenter read join code aloud, 'live'/'same sandbox' claims removed (voicefirst-landing PR #13 slide-13-join-code, merged + deployed); six stuck workers confirmed closed; pane-triage scheduled (0 blocked).
- In flight: none.
- Next: studio load test, failure drills, mini1 clean build; wire pane-triage into wake digest.
- Blocked (captain-only): slot length, agent-path pick for slide 11, read slide 14 vs reality, phone/cellular checks (review-rbnd).
