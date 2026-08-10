#!/usr/bin/env bun
/**
 * fm-review-page.ts — give every review-store item an INTERACTIVE decision page.
 *
 * The captain's morning review should be *visiting pages* and *acting on them*,
 * not reading terse chat. Anything filed into the `review` federated store (the
 * "requires the captain's eyes" queue) gets a self-contained, phone-readable
 * HTML page under ~/pulse-pages/review/<id>/index.html, served by Pulse at
 * http://localhost:31337/review/<id>/ (and 100.74.138.74:31337/review/<id>/
 * over Tailscale). An index at ~/pulse-pages/review/index.html lists every open
 * item, reachable one click from /status/ (one-URL rule).
 *
 * INTERACTIVE DECISION LOOP (endpoint → wake-queue → drain → firstmate acts):
 *   Each page carries a decision panel — Approve / Decline buttons and a Comment
 *   textarea — plus a structured What / Why / Stakes / Recommendation / Artifact
 *   breakdown parsed from the body so the decision is answerable in place. The
 *   panel's inline JS POSTs { id, verdict, comment? } same-origin to
 *   POST /api/review/decision (PAI/PULSE, lib/review-decision.ts). That endpoint
 *   validates the id via `review show`, then shells to bin/fm-review-decision.sh
 *   (resolved via FM_HOME), which durably enqueues a `check`-kind wake into
 *   firstmate's state/.wake-queue (drained by bin/fm-wake-drain.sh), annotates
 *   the item via `review note`, and appends a JSONL audit record. So when the
 *   captain clicks Approve on /review/<id>/, firstmate is woken with an
 *   actionable `check: review-decision:<id>` wake on its next supervision cycle.
 *   A decision already recorded (parsed from the item's `Captain decision:`
 *   notes) renders as a standing-decision banner on the page. Fail-loud
 *   throughout: an unknown id or an undeliverable wake is a non-2xx error, never
 *   a false-positive ok (robots-5l8).
 *
 * SURFACE CHOICE — Pulse static pages, not lavish:
 *   lavish (~/.local/bin/lavish -> parlay) is a live, interactive review
 *   SESSION tool: it opens a browser, expects `lavish-axi poll` for feedback,
 *   and its only "shareable URL" path publishes to a third-party public host
 *   (ht-ml.app). It cannot be driven headlessly to emit a stable, persistent,
 *   Pulse-served, Tailscale-reachable URL. Pulse static pages are the robust,
 *   one-URL-rule-compliant path and match the existing /brain, /done, /brief
 *   pulse-page pattern. So this tool writes static HTML.
 *
 * WIRE-BACK: each rendered item is updated with `page_url` metadata AND a
 *   `Page: <url>` note, so the URL travels with the item and shows in
 *   `review show` / `review ready`. Both are idempotent (metadata is a set;
 *   the note is only appended when the page_url is new or changed).
 *
 * READ-ONLY on item CONTENT: the only writes to the store are the page_url
 *   metadata + note wire-back (a safe append). Everything else is `--json`
 *   reads. The intended file output lives entirely under the pulse-pages
 *   review root.
 *
 * IDEMPOTENT + SCHEDULABLE: `--all` re-renders every open item; re-running
 *   overwrites pages in place (no duplicates) and only re-notes changed URLs.
 *   Parameterized entirely by env, so it can run on a cadence or right after a
 *   review filing (e.g. after fm-idea-mine files its item).
 *
 *   Example cron (NOT installed by this tool — documented only):
 *     # every 15 min, render open review items to visitable pages
 *     *\/15 * * * * /opt/homebrew/bin/bun \
 *       ~/code/firstmate/bin/fm-review-page.ts --all >/dev/null 2>&1
 *
 * ENV OVERRIDES (all optional; defaults are the live surfaces):
 *   FM_REVIEW_PAGE_OUT       output root       (default ~/pulse-pages/review)
 *   FM_REVIEW_PAGE_BASE_URL  URL prefix         (default http://localhost:31337/review)
 *   FM_REVIEW_BIN            review CLI path    (default `review` on PATH)
 *   FM_REVIEW_PAGE_NO_WIRE   set to 1 to skip the store wire-back
 *
 * USAGE:
 *   fm-review-page.ts <id> [<id> ...]   render specific open items
 *   fm-review-page.ts --all             render every open review item
 *   fm-review-page.ts --help
 */

import { spawnSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// ─── Config (env-overridable) ────────────────────────────────────────────────

const HOME = homedir()
const OUT_ROOT = process.env.FM_REVIEW_PAGE_OUT || join(HOME, "pulse-pages", "review")
const BASE_URL = (process.env.FM_REVIEW_PAGE_BASE_URL || "http://localhost:31337/review").replace(/\/+$/, "")
const REVIEW_BIN = process.env.FM_REVIEW_BIN || "review"
const SKIP_WIRE = process.env.FM_REVIEW_PAGE_NO_WIRE === "1"
const CMD_TIMEOUT_MS = 20_000

// ─── Store types ─────────────────────────────────────────────────────────────

/** Shape of one `review list --json` / `review show --json` record we rely on. */
interface RawReviewItem {
  id: string
  title?: string
  description?: string
  /** Appended notes (carries `Captain decision:` lines once a decision lands). */
  notes?: string
  status?: string
  priority?: number
  issue_type?: string
  owner?: string
  created_at?: string
  updated_at?: string
  metadata?: Record<string, unknown> | null
}

/** A normalized item ready to render. */
interface ReviewItem {
  id: string
  title: string
  description: string
  notes: string
  status: string
  priority: number | null
  issueType: string
  owner: string
  createdAt: string
  updatedAt: string
  /** Any existing page_url already wired back (used to keep notes idempotent). */
  existingPageUrl: string
}

/** The most recent captain decision already recorded on the item, if any. */
interface RecordedDecision {
  verdict: string
  comment: string
  ts: string
}

/** An artifact link extracted from the body (URL, brain id, git branch). */
interface Artifact {
  kind: "url" | "brain" | "branch"
  label: string
  /** Clickable href when web-addressable, else null. */
  href: string | null
}

// ─── review CLI (read + wire-back) ───────────────────────────────────────────

/**
 * Run the review CLI and return trimmed stdout, or throw with context. The
 * subprocess is bounded by a timeout; a missing binary, non-zero exit, or a
 * timeout all raise so the caller can degrade explicitly rather than silently
 * writing a wrong page.
 */
function runReview(args: string[]): string {
  const res = spawnSync(REVIEW_BIN, args, {
    encoding: "utf8",
    timeout: CMD_TIMEOUT_MS,
    // Never inherit stdin; some bd verbs open a pager/editor if a tty is present.
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, PAGER: "cat", GIT_PAGER: "cat" },
  })
  if (res.error) {
    throw new Error(`review ${args.join(" ")}: ${res.error.message}`)
  }
  if (typeof res.status === "number" && res.status !== 0) {
    const stderr = (res.stderr || "").trim()
    throw new Error(`review ${args.join(" ")} exited ${res.status}${stderr ? `: ${stderr}` : ""}`)
  }
  return (res.stdout || "").trim()
}

/** Parse a `review ... --json` payload that may be a single object or a list. */
function parseJsonItems(raw: string): RawReviewItem[] {
  if (!raw) return []
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (err) {
    throw new Error(`review returned unparseable JSON: ${(err as Error).message}`)
  }
  if (Array.isArray(parsed)) return parsed as RawReviewItem[]
  if (parsed && typeof parsed === "object") return [parsed as RawReviewItem]
  return []
}

/** Normalize a raw record, filling defaults so rendering never sees undefined. */
function normalize(raw: RawReviewItem): ReviewItem {
  const meta = (raw.metadata ?? {}) as Record<string, unknown>
  const pageUrl = typeof meta.page_url === "string" ? meta.page_url : ""
  return {
    id: raw.id,
    title: (raw.title ?? "").trim() || raw.id,
    description: raw.description ?? "",
    notes: raw.notes ?? "",
    status: (raw.status ?? "open").trim(),
    priority: typeof raw.priority === "number" ? raw.priority : null,
    issueType: (raw.issue_type ?? "").trim(),
    owner: (raw.owner ?? "").trim(),
    createdAt: (raw.created_at ?? "").trim(),
    updatedAt: (raw.updated_at ?? "").trim(),
    existingPageUrl: pageUrl,
  }
}

/**
 * Extract the most recent recorded captain decision from the item's notes.
 * fm-review-decision.sh appends lines shaped:
 *   `Captain decision: <verdict> - <comment> @ <ts>`
 *   `Captain decision: <verdict> @ <ts>`           (no comment)
 * Returns the LAST such line (the standing decision), or null if none.
 */
function extractRecordedDecision(notes: string): RecordedDecision | null {
  if (!notes) return null
  const re = /Captain decision:\s*(approve|decline|comment)\s*(?:-\s*([\s\S]*?))?\s*@\s*(\S+)/gi
  let last: RecordedDecision | null = null
  for (const m of notes.matchAll(re)) {
    last = {
      verdict: m[1].toLowerCase(),
      comment: (m[2] ?? "").trim(),
      ts: (m[3] ?? "").trim(),
    }
  }
  return last
}

/** Fetch every OPEN review item (the `--all` set). */
function fetchAllOpen(): ReviewItem[] {
  // `list --json` returns non-closed items by default; keep only open-ish ones.
  const raws = parseJsonItems(runReview(["list", "--json", "--limit", "0"]))
  return raws
    .filter((r) => r.id && !isClosed(r.status))
    .map(normalize)
    .sort(byPriorityThenAge)
}

/** Fetch specific items by id (used for the positional-id path). */
function fetchByIds(ids: string[]): ReviewItem[] {
  const raws = parseJsonItems(runReview(["show", "--json", ...ids]))
  const found = new Map(raws.filter((r) => r.id).map((r) => [r.id, normalize(r)]))
  // Preserve caller order and surface any ids the store didn't return.
  const out: ReviewItem[] = []
  for (const id of ids) {
    const item = found.get(id)
    if (item) out.push(item)
    else console.error(`warning: review item not found: ${id}`)
  }
  return out
}

function isClosed(status: string | undefined): boolean {
  const s = (status ?? "").toLowerCase()
  return s === "closed" || s === "done" || s === "resolved"
}

/** Priority ascending (0 = highest), then oldest-first within a priority. */
function byPriorityThenAge(a: ReviewItem, b: ReviewItem): number {
  const pa = a.priority ?? 99
  const pb = b.priority ?? 99
  if (pa !== pb) return pa - pb
  return a.createdAt.localeCompare(b.createdAt)
}

/**
 * Wire the page URL back onto the item: set `page_url` metadata (idempotent
 * set) and append a `Page: <url>` note only when the URL is new or changed, so
 * re-runs never pile up duplicate notes. Best-effort: a wire-back failure is
 * reported but never fails the render (the page already exists on disk).
 */
function wireBack(item: ReviewItem, url: string): { ok: boolean; noted: boolean; error?: string } {
  if (SKIP_WIRE) return { ok: true, noted: false }
  try {
    runReview(["update", item.id, "--set-metadata", `page_url=${url}`])
    const changed = item.existingPageUrl !== url
    if (changed) {
      runReview(["note", item.id, `Page: ${url}`])
    }
    return { ok: true, noted: changed }
  } catch (err) {
    return { ok: false, noted: false, error: (err as Error).message }
  }
}

// ─── Artifact extraction ─────────────────────────────────────────────────────

/**
 * Pull artifact links out of the body prose: http(s) URLs, brain doc ids
 * (brain-xxxx), and git branch names (branch feat/foo or `feat/foo`). De-duped,
 * capped, and rendered as a small link/reference list on the page.
 */
function extractArtifacts(body: string): Artifact[] {
  const seen = new Set<string>()
  const out: Artifact[] = []

  const push = (a: Artifact) => {
    const key = `${a.kind}:${a.label}`
    if (seen.has(key)) return
    seen.add(key)
    out.push(a)
  }

  // URLs first — strip trailing punctuation that clings to prose links.
  const urlRe = /https?:\/\/[^\s<>"')\]]+/g
  for (const m of body.matchAll(urlRe)) {
    const url = m[0].replace(/[.,;:]+$/, "")
    push({ kind: "url", label: url, href: url })
  }

  // brain/robots/decision-style doc ids: <word>-<alnum> tokens like brain-k0zr4.
  const brainRe = /\b(brain|robots|review|decisions?|ideas?|task|isa)-[a-z0-9]{3,}\b/gi
  for (const m of body.matchAll(brainRe)) {
    push({ kind: "brain", label: m[0], href: null })
  }

  // git branches: `feat/...` in backticks or after the word "branch".
  const branchRe = /\b(?:branch\s+)?((?:feat|fix|chore|refactor|docs|test)\/[A-Za-z0-9._\-/]+)/g
  for (const m of body.matchAll(branchRe)) {
    push({ kind: "branch", label: m[1], href: null })
  }

  return out.slice(0, 20)
}

// ─── Minimal, self-contained markdown → HTML ─────────────────────────────────

/** HTML-escape text for safe insertion into element bodies and attributes. */
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

/**
 * Render inline markdown (already HTML-escaped input is NOT assumed — this
 * escapes as it goes): `code`, **bold**, *italic*, [text](url), and bare URLs.
 * Order matters: code spans are extracted first so their contents are never
 * re-processed as emphasis or links.
 */
function renderInline(text: string): string {
  // Split on `code` spans so their contents are never re-processed as emphasis
  // or links, and are HTML-escaped independently. Splitting with a capture group
  // keeps the delimiters: even indices are prose, odd indices are raw code. This
  // is structurally leak-proof — there is no placeholder token that could survive
  // to the output (an earlier placeholder scheme corrupted into NUL bytes and
  // leaked `CODE0` markers into rendered pages).
  const parts = text.split(/`([^`]+)`/g)
  const out: string[] = []
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) {
      out.push(`<code>${esc(parts[i])}</code>`)
      continue
    }
    let seg = esc(parts[i])
    // Markdown links [label](href) — href restricted to http(s)/relative.
    seg = seg.replace(
      /\[([^\]]+)\]\((https?:\/\/[^\s)]+|\/[^\s)]*)\)/g,
      (_m, label: string, href: string) => `<a href="${href}" rel="noopener">${label}</a>`,
    )
    // Bare URLs (not already inside an <a>).
    seg = seg.replace(
      /(^|[\s(])(https?:\/\/[^\s<>"')]+)/g,
      (_m, pre: string, url: string) => `${pre}<a href="${url}" rel="noopener">${url}</a>`,
    )
    // Bold then italic.
    seg = seg.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    seg = seg.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
    out.push(seg)
  }
  return out.join("")
}

/**
 * Render a markdown block into HTML: ATX headings, fenced code, unordered and
 * ordered lists, blockquotes, horizontal rules, and paragraphs. Deliberately
 * small — enough for the review-item bodies (which are WHY/ARTIFACT/STAKES
 * prose with occasional code and lists), self-contained, no dependencies.
 */
function renderMarkdown(md: string): string {
  const lines = md.replace(/\r\n/g, "\n").split("\n")
  const html: string[] = []
  let i = 0

  const flushList = (buf: string[], ordered: boolean) => {
    if (!buf.length) return
    const tag = ordered ? "ol" : "ul"
    html.push(`<${tag}>${buf.map((li) => `<li>${renderInline(li)}</li>`).join("")}</${tag}>`)
    buf.length = 0
  }

  while (i < lines.length) {
    const line = lines[i]

    // Fenced code block.
    const fence = line.match(/^```(\w*)\s*$/)
    if (fence) {
      const lang = fence[1] || ""
      const code: string[] = []
      i++
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        code.push(lines[i])
        i++
      }
      i++ // consume closing fence
      const cls = lang ? ` class="lang-${esc(lang)}"` : ""
      html.push(`<pre class="codeblock"><code${cls}>${esc(code.join("\n"))}</code></pre>`)
      continue
    }

    // ATX heading.
    const heading = line.match(/^(#{1,6})\s+(.*)$/)
    if (heading) {
      const level = heading[1].length
      html.push(`<h${level}>${renderInline(heading[2].trim())}</h${level}>`)
      i++
      continue
    }

    // Horizontal rule.
    if (/^(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      html.push("<hr>")
      i++
      continue
    }

    // Blockquote (consecutive `>` lines).
    if (/^>\s?/.test(line)) {
      const quote: string[] = []
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        quote.push(lines[i].replace(/^>\s?/, ""))
        i++
      }
      html.push(`<blockquote>${renderInline(quote.join(" "))}</blockquote>`)
      continue
    }

    // Unordered list.
    if (/^\s*[-*+]\s+/.test(line)) {
      const buf: string[] = []
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        buf.push(lines[i].replace(/^\s*[-*+]\s+/, ""))
        i++
      }
      flushList(buf, false)
      continue
    }

    // Ordered list.
    if (/^\s*\d+[.)]\s+/.test(line)) {
      const buf: string[] = []
      while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) {
        buf.push(lines[i].replace(/^\s*\d+[.)]\s+/, ""))
        i++
      }
      flushList(buf, true)
      continue
    }

    // Blank line.
    if (/^\s*$/.test(line)) {
      i++
      continue
    }

    // Paragraph: gather until a blank line or a block-starting line.
    const para: string[] = []
    while (
      i < lines.length &&
      !/^\s*$/.test(lines[i]) &&
      !/^(#{1,6}\s|```|>|\s*[-*+]\s+|\s*\d+[.)]\s+)/.test(lines[i]) &&
      !/^(-{3,}|\*{3,}|_{3,})\s*$/.test(lines[i])
    ) {
      para.push(lines[i])
      i++
    }
    html.push(`<p>${renderInline(para.join(" "))}</p>`)
  }

  return html.join("\n")
}

// ─── Presentation helpers ────────────────────────────────────────────────────

/** Human date like "Jul 15, 2026 · 07:47 UTC" from an ISO timestamp. */
function formatDate(iso: string): string {
  if (!iso) return "unknown"
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  const date = d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  })
  const time = d.toLocaleTimeString("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  })
  return `${date} · ${time} UTC`
}

/** Days waited since createdAt, floored at 0. */
function ageDays(iso: string): number {
  if (!iso) return 0
  const then = new Date(iso).getTime()
  if (Number.isNaN(then)) return 0
  return Math.max(0, Math.floor((Date.now() - then) / 86_400_000))
}

function priorityLabel(p: number | null): string {
  if (p === null) return "—"
  return `P${p}`
}

/**
 * Extract a "recommended action" / "stakes" hint from the body if present.
 * These review items conventionally carry `## Stakes` and action lines; we
 * surface the first Stakes block as a callout. Returns "" when absent.
 */
function extractStakes(body: string): string {
  // A `## Stakes` (or STAKES:) section up to the next heading/blank-run.
  const m = body.match(/(?:^|\n)#{0,6}\s*stakes[:\s]*\n?([\s\S]*?)(?=\n#{1,6}\s|\n\s*\n#|$)/i)
  if (m && m[1].trim()) return m[1].trim()
  // Inline "STAKES: ..." single line.
  const inline = body.match(/\bSTAKES:\s*([^\n]+)/i)
  return inline ? inline[1].trim() : ""
}

/** One extracted decision-context field, in the fixed What→Why→…→Artifact order. */
interface ContextField {
  label: string
  /** Rendered inline-markdown HTML for the field's prose. */
  html: string
}

/**
 * Break the body into a skimmable What / Why / Stakes / Recommendation /
 * Artifact breakdown so the decision is answerable on the page. Review bodies
 * carry these signals in two shapes: markdown headings (`## What`, `## Stakes`)
 * or inline uppercase labels (`ARTIFACT: ...`, `STAKES: ...`). Each field is
 * matched by a set of synonyms and rendered with inline markdown. Returns [] if
 * NONE of the fields are found, so the caller can fall back to the flat body.
 */
function extractContextFields(body: string): ContextField[] {
  // label -> matcher synonyms (case-insensitive), in display order.
  const spec: { label: string; keys: string[] }[] = [
    { label: "What", keys: ["what", "summary", "proposal", "decide", "decision"] },
    { label: "Why", keys: ["why", "rationale", "context", "background"] },
    { label: "Stakes", keys: ["stakes", "risk", "risks", "impact"] },
    { label: "Recommendation", keys: ["recommendation", "recommended action", "recommended", "action"] },
    { label: "Artifact", keys: ["artifact", "artifacts", "evidence", "branch", "pr"] },
  ]

  const found: ContextField[] = []
  const usedRanges: [number, number][] = []

  const claim = (start: number, end: number): boolean => {
    // Reject a match that overlaps a field we already claimed (so "action"
    // inside a Stakes block can't be re-extracted as Recommendation).
    for (const [s, e] of usedRanges) {
      if (start < e && end > s) return false
    }
    usedRanges.push([start, end])
    return true
  }

  for (const { label, keys } of spec) {
    let picked = ""
    for (const key of keys) {
      const esc = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
      // (1) Heading form: `## What\n...` up to the next heading, a blank-line
      // paragraph break, or end of body. Stopping at a blank line keeps the last
      // heading section from swallowing a following inline-label line (e.g. a
      // trailing `ARTIFACT: ...`).
      const headRe = new RegExp(
        `(?:^|\\n)#{1,6}\\s*${esc}\\b[:\\s]*\\n([\\s\\S]*?)(?=\\n#{1,6}\\s|\\n\\s*\\n|$)`,
        "i",
      )
      const hm = body.match(headRe)
      if (hm && hm[1].trim() && claim(hm.index ?? 0, (hm.index ?? 0) + hm[0].length)) {
        picked = hm[1].trim()
        break
      }
      // (2) Inline label form: `ARTIFACT: ...` to end of line (or paragraph for
      // the last field). Kept to a single line so it doesn't swallow the body.
      const inlineRe = new RegExp(`(?:^|\\n)\\s*${esc}\\s*:\\s*([^\\n]+)`, "i")
      const im = body.match(inlineRe)
      if (im && im[1].trim() && claim(im.index ?? 0, (im.index ?? 0) + im[0].length)) {
        picked = im[1].trim()
        break
      }
    }
    if (picked) found.push({ label, html: renderInline(picked) })
  }

  return found
}

// ─── Page rendering ──────────────────────────────────────────────────────────

/** Shared CSS — GitHub-dark house palette matching ~/pulse-pages/brain style. */
const PAGE_CSS = `
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --ink: #0D1117; --surf: #161B22; --surf2: #1C2128; --surf3: #21262D;
  --border: #30363D; --muted: #7D8590; --body: #E6EDF3;
  --green: #3FB950; --blue: #58A6FF; --amber: #F0B429;
  --red: #FF7B72; --purple: #D2A8FF;
  --mono: 'SFMono-Regular','SF Mono',Menlo,Consolas,'Courier New',monospace;
  --sans: -apple-system,'SF Pro Text','Segoe UI',system-ui,sans-serif;
}
html { background: var(--ink); color: var(--body); font-family: var(--sans); font-size: 15px; -webkit-text-size-adjust: 100%; }
body { min-height: 100dvh; line-height: 1.55; }
a { color: var(--blue); text-decoration: none; word-break: break-word; }
a:hover { text-decoration: underline; }
.wrap { max-width: 760px; margin: 0 auto; padding: 1.25rem 1.1rem 5rem; }

.topbar { display: flex; align-items: center; gap: .6rem; flex-wrap: wrap; margin-bottom: 1.25rem; }
.topbar .back { font-family: var(--mono); font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
.crumb { font-family: var(--mono); font-size: 11px; color: var(--muted); }

.badges { display: flex; gap: .4rem; flex-wrap: wrap; margin: .4rem 0 1rem; }
.badge {
  font-family: var(--mono); font-size: 10px; font-weight: 700; letter-spacing: .07em;
  text-transform: uppercase; padding: 3px 9px; border: 1px solid var(--border);
  color: var(--muted); background: var(--ink); border-radius: 3px; white-space: nowrap;
}
.badge.p0, .badge.p1 { color: var(--red); border-color: color-mix(in srgb, var(--red) 55%, var(--border)); }
.badge.p2 { color: var(--amber); border-color: color-mix(in srgb, var(--amber) 55%, var(--border)); }
.badge.status { color: var(--green); border-color: color-mix(in srgb, var(--green) 45%, var(--border)); }
.badge.age-stale { color: var(--red); border-color: color-mix(in srgb, var(--red) 55%, var(--border)); }
.badge.age-aging { color: var(--amber); border-color: color-mix(in srgb, var(--amber) 55%, var(--border)); }

h1.item-title { font-size: 1.5rem; line-height: 1.25; font-weight: 700; margin-bottom: .35rem; }

.callout {
  border: 1px solid color-mix(in srgb, var(--amber) 45%, var(--border));
  background: color-mix(in srgb, var(--amber) 8%, var(--surf));
  border-left: 3px solid var(--amber);
  padding: .7rem .9rem; border-radius: 4px; margin: 1rem 0;
}
.callout .label { font-family: var(--mono); font-size: 10px; font-weight: 700; letter-spacing: .1em; text-transform: uppercase; color: var(--amber); display: block; margin-bottom: .3rem; }

.artifacts { margin: 1rem 0; }
.artifacts .label { font-family: var(--mono); font-size: 10px; font-weight: 700; letter-spacing: .1em; text-transform: uppercase; color: var(--muted); display: block; margin-bottom: .45rem; }
.artifacts ul { list-style: none; display: flex; flex-direction: column; gap: .3rem; }
.artifacts li { display: flex; align-items: baseline; gap: .5rem; font-size: .9rem; }
.artifacts .k { font-family: var(--mono); font-size: 9px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); border: 1px solid var(--border); padding: 1px 5px; border-radius: 3px; flex-shrink: 0; }
.artifacts code { font-family: var(--mono); font-size: .85rem; color: var(--purple); }

.body { margin-top: 1.4rem; }
.body h1, .body h2, .body h3, .body h4 { margin: 1.4rem 0 .5rem; line-height: 1.3; }
.body h1 { font-size: 1.3rem; } .body h2 { font-size: 1.15rem; }
.body h3 { font-size: 1rem; } .body h4 { font-size: .92rem; color: var(--muted); }
.body h2 { border-bottom: 1px solid var(--border); padding-bottom: .3rem; }
.body p { margin: .7rem 0; }
.body ul, .body ol { margin: .7rem 0 .7rem 1.4rem; }
.body li { margin: .25rem 0; }
.body blockquote { border-left: 3px solid var(--border); padding: .2rem .9rem; margin: .8rem 0; color: var(--muted); }
.body hr { border: none; border-top: 1px solid var(--border); margin: 1.4rem 0; }
.body a { }
.body code { font-family: var(--mono); font-size: .86em; background: var(--surf3); padding: 1px 5px; border-radius: 3px; color: var(--purple); }
.body pre.codeblock {
  background: var(--surf); border: 1px solid var(--border); border-radius: 5px;
  padding: .8rem .9rem; margin: .9rem 0; overflow-x: auto; -webkit-overflow-scrolling: touch;
}
.body pre.codeblock code { background: none; padding: 0; color: var(--body); font-size: .82rem; line-height: 1.5; white-space: pre; }

.meta-foot { margin-top: 2.2rem; padding-top: 1rem; border-top: 1px solid var(--border); font-family: var(--mono); font-size: 11px; color: var(--muted); display: flex; flex-direction: column; gap: .3rem; }

/* Structured decision-context breakdown (What / Why / Stakes / …). */
.context { margin: 1.2rem 0; display: flex; flex-direction: column; gap: .1rem; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
.context .field { padding: .7rem .9rem; border-top: 1px solid var(--border); }
.context .field:first-child { border-top: none; }
.context .field .k { font-family: var(--mono); font-size: 10px; font-weight: 700; letter-spacing: .1em; text-transform: uppercase; color: var(--blue); display: block; margin-bottom: .3rem; }
.context .field .v { font-size: .95rem; line-height: 1.5; }
.context .field.stakes .k { color: var(--amber); }
.context .field.stakes { background: color-mix(in srgb, var(--amber) 6%, var(--surf)); }

/* Interactive decision panel — the loop-closer. */
.decision { margin: 1.6rem 0; border: 1px solid var(--border); border-radius: 8px; background: var(--surf); padding: 1rem 1rem 1.1rem; }
.decision .dlabel { font-family: var(--mono); font-size: 10px; font-weight: 700; letter-spacing: .1em; text-transform: uppercase; color: var(--muted); display: block; margin-bottom: .7rem; }
.decision .buttons { display: flex; gap: .6rem; flex-wrap: wrap; }
.decision button {
  flex: 1 1 auto; min-height: 48px; min-width: 120px; font-size: 1rem; font-weight: 600;
  font-family: var(--sans); border-radius: 6px; border: 1px solid var(--border);
  background: var(--surf2); color: var(--body); cursor: pointer; padding: .6rem 1rem;
  -webkit-tap-highlight-color: transparent; touch-action: manipulation; transition: filter .12s, opacity .12s;
}
.decision button:hover:not(:disabled) { filter: brightness(1.15); }
.decision button:active:not(:disabled) { filter: brightness(.92); }
.decision button:disabled { opacity: .45; cursor: default; }
.decision button.approve { border-color: color-mix(in srgb, var(--green) 60%, var(--border)); color: var(--green); }
.decision button.decline { border-color: color-mix(in srgb, var(--red) 60%, var(--border)); color: var(--red); }
.decision button.comment { border-color: color-mix(in srgb, var(--blue) 55%, var(--border)); color: var(--blue); }
.decision .comment-box { margin-top: .8rem; }
.decision textarea {
  width: 100%; min-height: 84px; resize: vertical; font-family: var(--sans); font-size: 1rem;
  line-height: 1.5; color: var(--body); background: var(--ink); border: 1px solid var(--border);
  border-radius: 6px; padding: .6rem .7rem;
}
.decision textarea:focus { outline: none; border-color: var(--blue); }
.decision .hint { font-size: .82rem; color: var(--muted); margin-top: .45rem; }
.decision .feedback { margin-top: .85rem; padding: .65rem .8rem; border-radius: 6px; font-size: .92rem; line-height: 1.45; display: none; }
.decision .feedback.show { display: block; }
.decision .feedback.ok { border: 1px solid color-mix(in srgb, var(--green) 45%, var(--border)); background: color-mix(in srgb, var(--green) 8%, var(--surf)); color: var(--green); }
.decision .feedback.err { border: 1px solid color-mix(in srgb, var(--red) 50%, var(--border)); background: color-mix(in srgb, var(--red) 8%, var(--surf)); color: var(--red); }
.decision .feedback.pending { border: 1px solid var(--border); color: var(--muted); }
.decision .recorded { margin-top: .85rem; padding: .65rem .8rem; border-radius: 6px; font-size: .9rem; border: 1px solid color-mix(in srgb, var(--green) 40%, var(--border)); background: color-mix(in srgb, var(--green) 7%, var(--surf)); color: var(--body); }
.decision .recorded .rv { font-family: var(--mono); font-weight: 700; text-transform: uppercase; letter-spacing: .06em; color: var(--green); }
.decision .recorded.decline .rv { color: var(--red); }
.decision .recorded .rc { display: block; margin-top: .3rem; color: var(--muted); }

/* Index page. */
.index-head { margin-bottom: 1.4rem; }
.index-head h1 { font-size: 1.35rem; font-weight: 700; }
.index-head .sub { color: var(--muted); font-size: .9rem; margin-top: .25rem; }
.list { display: flex; flex-direction: column; gap: .7rem; }
.card {
  display: block; border: 1px solid var(--border); background: var(--surf);
  border-radius: 6px; padding: .85rem 1rem; text-decoration: none; color: var(--body);
}
.card:hover { border-color: var(--blue); text-decoration: none; }
.card .row1 { display: flex; align-items: baseline; gap: .55rem; flex-wrap: wrap; }
.card .ct { font-weight: 600; font-size: 1rem; line-height: 1.3; }
.card .cmeta { margin-top: .35rem; display: flex; gap: .5rem; flex-wrap: wrap; }
.empty { color: var(--muted); font-style: italic; padding: 2rem 0; text-align: center; }
`.trim()

/** Age tier -> badge class + label. */
function ageTier(days: number): { cls: string; label: string } {
  if (days >= 3) return { cls: "age-stale", label: `${days}d waiting` }
  if (days >= 1) return { cls: "age-aging", label: `${days}d waiting` }
  return { cls: "", label: "today" }
}

/** Render the structured What/Why/Stakes/Recommendation/Artifact breakdown. */
function renderContext(fields: ContextField[]): string {
  if (!fields.length) return ""
  const rows = fields
    .map((f) => {
      const cls = f.label.toLowerCase() === "stakes" ? " stakes" : ""
      return `<div class="field${cls}"><span class="k">${esc(f.label)}</span><div class="v">${f.html}</div></div>`
    })
    .join("\n      ")
  return `\n    <div class="context">
      ${rows}
    </div>`
}

/**
 * Render the interactive decision panel: Approve / Decline buttons, a Comment
 * textarea + submit, in-page feedback, and — when a decision was already
 * recorded — a standing-decision banner. The inline JS POSTs same-origin to
 * /api/review/decision and reflects success/failure without a page reload. The
 * item id is embedded as a data attribute (JSON-encoded) so no server value is
 * interpolated into a JS string.
 */
function renderDecisionPanel(item: ReviewItem, recorded: RecordedDecision | null): string {
  const idJson = JSON.stringify(item.id)
  const recordedHtml = recorded
    ? `\n      <div class="recorded ${recorded.verdict === "decline" ? "decline" : ""}" id="recorded">
        Standing decision: <span class="rv">${esc(recorded.verdict)}</span>${
          recorded.ts ? ` · ${esc(recorded.ts)}` : ""
        }${recorded.comment ? `<span class="rc">“${esc(recorded.comment)}”</span>` : ""}
      </div>`
    : `\n      <div class="recorded" id="recorded" style="display:none"></div>`

  // The inline script is self-contained (CSP-safe, no external fetch host) and
  // idempotent-friendly: after a successful decision it disables the buttons so
  // the captain doesn't double-submit, and re-enables on error so a transient
  // failure is retryable.
  return `
    <div class="decision" data-review-id='${esc(idJson)}'>
      <span class="dlabel">Your decision</span>
      <div class="buttons">
        <button type="button" class="approve" data-verdict="approve">Approve</button>
        <button type="button" class="decline" data-verdict="decline">Decline</button>
        <button type="button" class="comment" data-verdict="comment">Comment</button>
      </div>
      <div class="comment-box">
        <textarea id="comment" placeholder="Optional note for Approve/Decline — required to Comment"></textarea>
        <div class="hint">Approve and Decline may include a note. Comment sends the note without deciding.</div>
      </div>
      <div class="feedback" id="feedback" role="status" aria-live="polite"></div>${recordedHtml}
    </div>
    <script>
    (function () {
      var panel = document.querySelector('.decision');
      if (!panel) return;
      var reviewId = JSON.parse(panel.getAttribute('data-review-id'));
      var buttons = panel.querySelectorAll('button[data-verdict]');
      var textarea = panel.querySelector('#comment');
      var feedback = panel.querySelector('#feedback');
      var recorded = panel.querySelector('#recorded');

      function setFeedback(kind, msg) {
        feedback.className = 'feedback show ' + kind;
        feedback.textContent = msg;
      }
      function setButtons(disabled) {
        buttons.forEach(function (b) { b.disabled = disabled; });
      }
      function lockAfterDecision(verdict, comment, ts) {
        setButtons(true);
        recorded.style.display = 'block';
        recorded.className = 'recorded' + (verdict === 'decline' ? ' decline' : '');
        var html = 'Standing decision: <span class="rv"></span>';
        recorded.innerHTML = html;
        recorded.querySelector('.rv').textContent = verdict;
        if (ts) { recorded.appendChild(document.createTextNode(' · ' + ts)); }
        if (comment) {
          var rc = document.createElement('span');
          rc.className = 'rc';
          rc.textContent = '\\u201c' + comment + '\\u201d';
          recorded.appendChild(rc);
        }
      }

      function submit(verdict) {
        var comment = (textarea.value || '').trim();
        if (verdict === 'comment' && !comment) {
          setFeedback('err', 'A comment needs some text before you send it.');
          textarea.focus();
          return;
        }
        setButtons(true);
        setFeedback('pending', 'Recording your ' + verdict + '\\u2026');
        fetch('/api/review/decision', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ id: reviewId, verdict: verdict, comment: comment })
        }).then(function (res) {
          return res.json().then(function (data) { return { ok: res.ok, data: data }; });
        }).then(function (r) {
          if (r.ok && r.data && r.data.ok) {
            setFeedback('ok', 'Recorded — the first mate has been notified.');
            var ts = new Date().toISOString().replace(/\\.\\d+Z$/, 'Z');
            lockAfterDecision(verdict, comment, ts);
          } else {
            var err = (r.data && r.data.error) ? r.data.error : ('request failed (' + '' + ')');
            setFeedback('err', 'Could not record that: ' + err);
            setButtons(false);
          }
        }).catch(function (e) {
          setFeedback('err', 'Network error — could not reach the first mate. ' + (e && e.message ? e.message : ''));
          setButtons(false);
        });
      }

      buttons.forEach(function (b) {
        b.addEventListener('click', function () { submit(b.getAttribute('data-verdict')); });
      });
    })();
    </script>`
}

/** Full self-contained HTML document for one review item. */
function renderItemPage(item: ReviewItem): string {
  const days = ageDays(item.createdAt)
  const tier = ageTier(days)
  const stakes = extractStakes(item.description)
  const artifacts = extractArtifacts(item.description)
  const contextFields = extractContextFields(item.description)
  const recorded = extractRecordedDecision(item.notes)
  const bodyHtml = item.description.trim()
    ? renderMarkdown(item.description)
    : `<p class="empty">No description was filed with this item.</p>`

  const pClass = item.priority !== null ? ` p${item.priority}` : ""

  const badges = [
    `<span class="badge status">${esc(item.status)}</span>`,
    `<span class="badge${pClass}">priority ${esc(priorityLabel(item.priority))}</span>`,
    item.issueType ? `<span class="badge">${esc(item.issueType)}</span>` : "",
    `<span class="badge ${tier.cls}">${esc(tier.label)}</span>`,
    `<span class="badge">${esc(item.id)}</span>`,
  ]
    .filter(Boolean)
    .join("\n      ")

  const calloutHtml = stakes
    ? `\n    <div class="callout">
      <span class="label">Stakes / recommended action</span>
      ${renderInline(stakes)}
    </div>`
    : ""

  const artifactsHtml = artifacts.length
    ? `\n    <div class="artifacts">
      <span class="label">Artifacts</span>
      <ul>
        ${artifacts
          .map((a) => {
            const val = a.href
              ? `<a href="${esc(a.href)}" rel="noopener">${esc(a.label)}</a>`
              : `<code>${esc(a.label)}</code>`
            return `<li><span class="k">${esc(a.kind)}</span>${val}</li>`
          })
          .join("\n        ")}
      </ul>
    </div>`
    : ""

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Opt out of the Pulse portal shell injection. These pages are fully self-
     contained (their own single top bar + dark theme), exactly like the /status
     and /plans pages render one nav themselves. Without opting out, portal's
     shell injection would add a SECOND global nav bar plus the chat widget on
     top of this page's own .topbar — two stacked bars. One page, one bar. -->
<meta name="pulse-shell" content="off">
<title>Review · ${esc(item.title)}</title>
<style>
${PAGE_CSS}
</style>
</head>
<body>
  <div class="wrap">
    <div class="topbar">
      <a class="back" href="../">‹ Review queue</a>
      <span class="crumb">for the captain's eyes</span>
    </div>
    <h1 class="item-title">${esc(item.title)}</h1>
    <div class="badges">
      ${badges}
    </div>${calloutHtml}${renderContext(contextFields)}${renderDecisionPanel(item, recorded)}${artifactsHtml}
    <div class="body">
${bodyHtml}
    </div>
    <div class="meta-foot">
      <span>filed ${esc(formatDate(item.createdAt))}${
    item.owner ? ` · for ${esc(item.owner)}` : ""
  }</span>
      <span>updated ${esc(formatDate(item.updatedAt))}</span>
      <span>item ${esc(item.id)}</span>
    </div>
  </div>
</body>
</html>
`
}

/** Full self-contained HTML index listing every open review item. */
function renderIndexPage(items: ReviewItem[]): string {
  const now = new Date().toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  })

  const cards = items.length
    ? items
        .map((item) => {
          const days = ageDays(item.createdAt)
          const tier = ageTier(days)
          const pClass = item.priority !== null ? ` p${item.priority}` : ""
          return `<a class="card" href="./${esc(item.id)}/">
      <div class="row1">
        <span class="ct">${esc(item.title)}</span>
      </div>
      <div class="cmeta">
        <span class="badge status">${esc(item.status)}</span>
        <span class="badge${pClass}">priority ${esc(priorityLabel(item.priority))}</span>
        <span class="badge ${tier.cls}">${esc(tier.label)}</span>
        <span class="badge">${esc(item.id)}</span>
      </div>
    </a>`
        })
        .join("\n    ")
    : `<div class="empty">The review queue is clear — nothing needs your eyes right now.</div>`

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Opt out of the Pulse portal shell injection. These pages are fully self-
     contained (their own single top bar + dark theme), exactly like the /status
     and /plans pages render one nav themselves. Without opting out, portal's
     shell injection would add a SECOND global nav bar plus the chat widget on
     top of this page's own .topbar — two stacked bars. One page, one bar. -->
<meta name="pulse-shell" content="off">
<title>Review queue · needs your eyes</title>
<style>
${PAGE_CSS}
</style>
</head>
<body>
  <div class="wrap">
    <div class="index-head">
      <h1>Review queue</h1>
      <div class="sub">${items.length} item${items.length === 1 ? "" : "s"} waiting on your decision · as of ${esc(
        now,
      )} UTC</div>
    </div>
    <div class="list">
    ${cards}
    </div>
    <div class="meta-foot">
      <span>each card opens the full item on its own page</span>
      <span>served by Pulse · reachable from /status/</span>
    </div>
  </div>
</body>
</html>
`
}

// ─── Filesystem output ───────────────────────────────────────────────────────

/** Write one item's page and return its public URL. Idempotent (overwrite). */
function writeItemPage(item: ReviewItem): string {
  const dir = join(OUT_ROOT, item.id)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, "index.html"), renderItemPage(item))
  return `${BASE_URL}/${item.id}/`
}

/** Write the index page and return its URL. */
function writeIndexPage(items: ReviewItem[]): string {
  mkdirSync(OUT_ROOT, { recursive: true })
  writeFileSync(join(OUT_ROOT, "index.html"), renderIndexPage(items))
  return `${BASE_URL}/`
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

const HELP = `fm-review-page.ts — render review-store items to visitable Pulse pages.

USAGE
  fm-review-page.ts <id> [<id> ...]   render specific open review items
  fm-review-page.ts --all             render every open review item + index
  fm-review-page.ts --help

Each rendered page lives at \${FM_REVIEW_PAGE_OUT}/<id>/index.html and is served
at \${FM_REVIEW_PAGE_BASE_URL}/<id>/. An index at the root lists all open items.
The item is wired back with its page_url (metadata + a "Page: <url>" note) so the
URL travels with it in \`review show\` / \`review ready\`.

ENV
  FM_REVIEW_PAGE_OUT       output root      (default ~/pulse-pages/review)
  FM_REVIEW_PAGE_BASE_URL  URL prefix       (default http://localhost:31337/review)
  FM_REVIEW_BIN            review CLI path  (default \`review\` on PATH)
  FM_REVIEW_PAGE_NO_WIRE   set 1 to skip the store wire-back
`

function main(argv: string[]): number {
  const args = argv.slice(2)
  if (args.includes("--help") || args.includes("-h")) {
    console.log(HELP)
    return 0
  }

  const all = args.includes("--all")
  const ids = args.filter((a) => !a.startsWith("-"))

  if (!all && ids.length === 0) {
    console.error("error: pass one or more item ids, or --all")
    console.error("run with --help for usage")
    return 2
  }

  let items: ReviewItem[]
  try {
    items = all ? fetchAllOpen() : fetchByIds(ids)
  } catch (err) {
    console.error(`error: could not read review store: ${(err as Error).message}`)
    return 1
  }

  if (items.length === 0) {
    // --all over an empty queue still (re)writes an accurate empty index.
    if (all) {
      const indexUrl = writeIndexPage(items)
      console.log(`index: ${indexUrl} (queue empty)`)
      return 0
    }
    console.error("error: no matching open review items")
    return 1
  }

  let wireFailures = 0
  for (const item of items) {
    const url = writeItemPage(item)
    const wired = wireBack(item, url)
    if (!wired.ok) {
      wireFailures++
      console.error(`  wire-back failed for ${item.id}: ${wired.error}`)
    }
    const noteFlag = wired.noted ? " (noted)" : wired.ok ? " (url unchanged)" : " (wire-back failed)"
    console.log(`page: ${url}${noteFlag}  — ${item.title}`)
  }

  // Always refresh the index so it reflects the full open set, even when
  // rendering a single id (the queue may have changed around it).
  let indexItems = items
  if (!all) {
    try {
      indexItems = fetchAllOpen()
    } catch {
      // Fall back to just the rendered items if the full re-read fails.
      indexItems = items
    }
  }
  const indexUrl = writeIndexPage(indexItems)
  console.log(`index: ${indexUrl}`)

  if (wireFailures > 0) {
    console.error(`warning: ${wireFailures} wire-back(s) failed; pages were still written`)
    return 3
  }
  return 0
}

process.exit(main(process.argv))
