#!/usr/bin/env bun
/**
 * fm-idea-mine.ts - automated INTAKE step of firstmate's crew-launch methodology.
 *
 * Mines the captain's recent chat/context history for ideas he expressed or
 * implied but never captured, RE-EVALUATES them in a distinct second inference
 * pass, files each surviving idea into the `ideas` store, and files one
 * consolidated "Morning idea harvest" item into the `review` store.
 *
 * The captain's ask: "an idea mining agent to run and evaluate based on past
 * chat and context history. These ideas that are generated should be internally
 * evaluated again after generation, and presented to me as a review item in the
 * morning."
 *
 * TWO SEPARATE INFERENCE CALLS, by design:
 *   PASS 1 (generate)      - extract candidate ideas/sparks from the transcript.
 *   PASS 2 (self-evaluate) - a distinct second call that critically scores,
 *                            dedups, drops weak ones, and recommends an action.
 * The second pass is the captain's explicit "internally evaluated again after
 * generation" - it is NOT a filter over pass 1's own output, it is a fresh
 * critical review with the existing idea store in context.
 *
 * RAILS (mirrors the fm-groom posture the crew methodology already uses):
 *   - Idempotent: a content marker over the mined transcript range prevents
 *     re-mining the identical tail; dedup prevents double-filing ideas.
 *   - Bounded: transcript token budget + message cap on the read side, kept-idea
 *     cap on the write side.
 *   - Read-and-append only: it reads transcripts and the idea store and APPENDS
 *     store items. It performs no destructive or irreversible action, so the
 *     default is LIVE-file; --dry-run previews without filing anything.
 *   - Schedulable: fully parameterized by env + idempotent, so it can be
 *     cron/launchd'd overnight. This script installs NO schedule. To run it
 *     overnight at 05:30 local, a crontab line is:
 *       30 5 * * * /usr/bin/env bun /ABSOLUTE/PATH/to/bin/fm-idea-mine.ts >> ~/fm-idea-mine.log 2>&1
 *     (adjust the absolute path to this file on the target machine).
 *
 * ENV OVERRIDES (all optional; sensible defaults):
 *   FM_IDEA_MINE_TRANSCRIPT_DIR  dir of .jsonl transcripts to mine the newest of
 *                                (default ~/.claude/projects/-Users-...-firstmate)
 *   FM_IDEA_MINE_TRANSCRIPT_FILE explicit transcript file (overrides the dir scan)
 *   FM_IDEA_MINE_MUSE_FILE       optional extra idea source (default ~/muse-overnight-ideas.md)
 *   FM_IDEA_MINE_INFER_CMD       inference command; two positional args appended:
 *                                <system_prompt> <user_prompt>; must print JSON on
 *                                stdout (default: bun Inference.ts --json --level <tier>)
 *   FM_IDEA_MINE_INFER_TIER      fast|standard|smart for the default infer cmd (default standard)
 *   FM_IDEA_MINE_INFER_TIMEOUT_MS  --timeout passed to the default Inference.ts cmd (default 150000)
 *   FM_IDEA_MINE_IDEAS_CMD       ideas store CLI (default: ideas)
 *   FM_IDEA_MINE_REVIEW_CMD      review store CLI (default: review)
 *   FM_IDEA_MINE_STATE_DIR       marker dir (default: <fm-home>/state, else ~/.cache/fm-idea-mine)
 *   FM_IDEA_MINE_MAX_KEPT        cap on kept ideas (default 15)
 *   FM_IDEA_MINE_TOKEN_BUDGET    approx token budget for the mined tail (default 40000)
 *   FM_IDEA_MINE_MSG_LIMIT       max messages from the tail (default 800)
 *   FM_HOME / FM_STATE_OVERRIDE  firstmate home / state dir, used for the marker
 *
 * FLAGS:
 *   --dry-run   compute the full harvest and print it; file nothing.
 *   --force     ignore the idempotency marker and re-mine even an unchanged tail.
 *   -h|--help   usage.
 *
 * EXIT: 0 on success (including a benign no-op); non-zero only on a hard error
 * (unreadable required input, inference command failure that is not fail-safe).
 * Malformed inference JSON is handled fail-safe: nothing is filed and the run
 * reports the problem, rather than filing garbage.
 */

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// --------------------------------------------------------------------------
// Config
// --------------------------------------------------------------------------

interface Config {
  transcriptDir: string;
  transcriptFile: string | null;
  museFile: string;
  inferCmd: string[];
  ideasCmd: string;
  reviewCmd: string;
  stateDir: string;
  maxKept: number;
  tokenBudget: number;
  msgLimit: number;
  dryRun: boolean;
  force: boolean;
}

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function defaultTranscriptDir(): string {
  return join(homedir(), ".claude", "projects", "-Users-trilliumsmith-code-firstmate");
}

function defaultStateDir(): string {
  const stateOverride = process.env.FM_STATE_OVERRIDE;
  if (stateOverride && stateOverride.trim() !== "") return stateOverride;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE;
  if (fmHome && fmHome.trim() !== "") return join(fmHome, "state");
  return join(homedir(), ".cache", "fm-idea-mine");
}

function defaultInferCmd(): string[] {
  const tier = process.env.FM_IDEA_MINE_INFER_TIER || "standard";
  // Inference.ts defaults to a 30s internal timeout, which is too short for a
  // ~40k-token mined tail on the standard tier. Give it a generous ceiling; the
  // spawnSync wall-clock timeout in runInference is the real outer bound.
  const timeout = process.env.FM_IDEA_MINE_INFER_TIMEOUT_MS || "150000";
  return [
    "bun",
    join(homedir(), ".claude", "PAI", "TOOLS", "Inference.ts"),
    "--json",
    "--level",
    tier,
    "--timeout",
    timeout,
  ];
}

/**
 * Split an env command string into argv the way a shell would for a simple
 * command: honor single and double quotes, no variable/glob expansion. This is
 * deliberately minimal - the override is a trusted operator/test value, not
 * untrusted input - but quoting support lets a mock be a real command with args.
 */
function splitCommand(raw: string): string[] {
  const out: string[] = [];
  let cur = "";
  let quote: '"' | "'" | null = null;
  let started = false;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (quote) {
      if (ch === quote) quote = null;
      else cur += ch;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      started = true;
      continue;
    }
    if (ch === " " || ch === "\t" || ch === "\n") {
      if (started) {
        out.push(cur);
        cur = "";
        started = false;
      }
      continue;
    }
    cur += ch;
    started = true;
  }
  if (started) out.push(cur);
  return out;
}

function parseArgs(argv: string[]): { dryRun: boolean; force: boolean; help: boolean } {
  let dryRun = false;
  let force = false;
  let help = false;
  for (const a of argv) {
    if (a === "--dry-run") dryRun = true;
    else if (a === "--force") force = true;
    else if (a === "-h" || a === "--help") help = true;
    else {
      throw new Error(`unknown argument: ${a}`);
    }
  }
  return { dryRun, force, help };
}

function loadConfig(argv: string[]): Config {
  const { dryRun, force } = parseArgs(argv);
  const inferRaw = process.env.FM_IDEA_MINE_INFER_CMD;
  return {
    transcriptDir: process.env.FM_IDEA_MINE_TRANSCRIPT_DIR || defaultTranscriptDir(),
    transcriptFile: process.env.FM_IDEA_MINE_TRANSCRIPT_FILE || null,
    museFile: process.env.FM_IDEA_MINE_MUSE_FILE || join(homedir(), "muse-overnight-ideas.md"),
    inferCmd: inferRaw && inferRaw.trim() !== "" ? splitCommand(inferRaw) : defaultInferCmd(),
    ideasCmd: process.env.FM_IDEA_MINE_IDEAS_CMD || "ideas",
    reviewCmd: process.env.FM_IDEA_MINE_REVIEW_CMD || "review",
    stateDir: process.env.FM_IDEA_MINE_STATE_DIR || defaultStateDir(),
    maxKept: envInt("FM_IDEA_MINE_MAX_KEPT", 15),
    tokenBudget: envInt("FM_IDEA_MINE_TOKEN_BUDGET", 40000),
    msgLimit: envInt("FM_IDEA_MINE_MSG_LIMIT", 800),
    dryRun,
    force,
  };
}

const USAGE = `fm-idea-mine.ts - mine recent chat history for uncaptured ideas, re-evaluate them,
and file a consolidated "Morning idea harvest" review item.

Usage:
  bin/fm-idea-mine.ts [--dry-run] [--force]

  --dry-run   compute the harvest and print it; file nothing.
  --force     re-mine even an unchanged transcript tail (ignore the idempotency marker).
  -h, --help  this help.

See the file header for the full env override list and a schedulable crontab line.`;

// --------------------------------------------------------------------------
// Transcript mining
// --------------------------------------------------------------------------

interface MinedMessage {
  role: "human" | "assistant";
  text: string;
}

interface MinedTail {
  file: string | null;
  messages: MinedMessage[];
  rangeHash: string;
  charCount: number;
}

/** Approx tokens ~= chars / 4. Cheap, deterministic, good enough for a budget. */
function approxTokens(chars: number): number {
  return Math.ceil(chars / 4);
}

function newestTranscript(cfg: Config): string | null {
  if (cfg.transcriptFile) {
    return existsSync(cfg.transcriptFile) ? cfg.transcriptFile : null;
  }
  if (!existsSync(cfg.transcriptDir)) return null;
  let newest: { path: string; mtime: number } | null = null;
  for (const name of readdirSync(cfg.transcriptDir)) {
    if (!name.endsWith(".jsonl")) continue;
    const p = join(cfg.transcriptDir, name);
    let st;
    try {
      st = statSync(p);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    if (!newest || st.mtimeMs > newest.mtime) newest = { path: p, mtime: st.mtimeMs };
  }
  return newest ? newest.path : null;
}

/** Strip base64/data-URI/image blobs and collapse whitespace from a text block. */
function sanitizeText(raw: string): string {
  let t = raw;
  // Drop data: URIs and long base64 runs (image/attachment noise).
  t = t.replace(/data:[a-zA-Z0-9/+;=.-]+base64,[A-Za-z0-9+/=]+/g, "[image]");
  t = t.replace(/[A-Za-z0-9+/]{200,}={0,2}/g, "[blob]");
  // Drop system-reminder envelopes.
  t = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "");
  t = t.replace(/[ \t]+/g, " ");
  t = t.replace(/\n{3,}/g, "\n\n");
  return t.trim();
}

/**
 * Extract a plain-text block from a message content value that may be a string
 * or an array of content blocks. Returns "" when there is no human/assistant
 * prose (e.g. a tool_result-only user turn or a thinking-only assistant turn).
 */
function extractText(content: unknown): string {
  if (typeof content === "string") return sanitizeText(content);
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (block && typeof block === "object" && (block as { type?: string }).type === "text") {
      const v = (block as { text?: unknown }).text;
      if (typeof v === "string") parts.push(v);
    }
    // Deliberately skip tool_use, tool_result, thinking, image blocks.
  }
  return sanitizeText(parts.join("\n"));
}

/** Content that is only a tool result carries no idea signal; detect it to skip. */
function isToolResultOnly(content: unknown): boolean {
  if (!Array.isArray(content)) return false;
  if (content.length === 0) return false;
  return content.every(
    (b) => b && typeof b === "object" && (b as { type?: string }).type === "tool_result",
  );
}

function mineTranscript(cfg: Config): MinedTail {
  const file = newestTranscript(cfg);
  if (!file) return { file: null, messages: [], rangeHash: "", charCount: 0 };

  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    return { file, messages: [], rangeHash: "", charCount: 0 };
  }

  const lines = raw.split("\n").filter((l) => l.trim() !== "");
  const all: MinedMessage[] = [];
  for (const line of lines) {
    let obj: unknown;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (!obj || typeof obj !== "object") continue;
    const rec = obj as { type?: string; message?: { role?: string; content?: unknown } };
    if (rec.type !== "user" && rec.type !== "assistant") continue;
    const content = rec.message?.content;
    if (rec.type === "user") {
      if (isToolResultOnly(content)) continue;
      const text = extractText(content);
      if (text) all.push({ role: "human", text });
    } else {
      const text = extractText(content);
      if (text) all.push({ role: "assistant", text });
    }
  }

  // Take a bounded tail: last N messages, then trim from the front to the token
  // budget so the most recent conversation always survives.
  let tail = all.slice(-cfg.msgLimit);
  let charCount = tail.reduce((n, m) => n + m.text.length, 0);
  while (tail.length > 1 && approxTokens(charCount) > cfg.tokenBudget) {
    const dropped = tail.shift();
    if (dropped) charCount -= dropped.text.length;
  }

  const hash = createHash("sha256");
  for (const m of tail) hash.update(`${m.role} ${m.text} `);
  const rangeHash = tail.length > 0 ? `sha256:${hash.digest("hex")}` : "";

  return { file, messages: tail, rangeHash, charCount };
}

function readMuse(cfg: Config): string {
  if (!existsSync(cfg.museFile)) return "";
  try {
    // Bound the muse contribution too, so a huge file can't blow the prompt.
    const raw = readFileSync(cfg.museFile, "utf8");
    const capped = raw.slice(0, 12000);
    return sanitizeText(capped);
  } catch {
    return "";
  }
}

// --------------------------------------------------------------------------
// Existing-idea store (dedup source)
// --------------------------------------------------------------------------

interface ExistingIdea {
  id: string;
  title: string;
}

function listExistingIdeas(cfg: Config): ExistingIdea[] {
  const res = spawnSync(cfg.ideasCmd, ["list", "--all", "--json"], {
    encoding: "utf8",
    timeout: 30000,
  });
  if (res.status !== 0 || !res.stdout) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(res.stdout);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: ExistingIdea[] = [];
  for (const item of parsed) {
    if (item && typeof item === "object") {
      const id = (item as { id?: unknown }).id;
      const title = (item as { title?: unknown }).title;
      if (typeof title === "string") {
        out.push({ id: typeof id === "string" ? id : "", title });
      }
    }
  }
  return out;
}

/** Normalize a title for fuzzy comparison: lowercase, alnum tokens only. */
function normalizeTitle(title: string): Set<string> {
  const tokens = title
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter((t) => t.length > 2);
  return new Set(tokens);
}

/** Jaccard token overlap; >= threshold means "the same idea". */
function titleSimilarity(a: string, b: string): number {
  const sa = normalizeTitle(a);
  const sb = normalizeTitle(b);
  if (sa.size === 0 || sb.size === 0) return 0;
  let inter = 0;
  for (const t of sa) if (sb.has(t)) inter++;
  const union = sa.size + sb.size - inter;
  return union === 0 ? 0 : inter / union;
}

const DEDUP_THRESHOLD = 0.6;

function findDuplicate(title: string, existing: ExistingIdea[]): ExistingIdea | null {
  let best: { idea: ExistingIdea; score: number } | null = null;
  for (const e of existing) {
    const score = titleSimilarity(title, e.title);
    if (score >= DEDUP_THRESHOLD && (!best || score > best.score)) best = { idea: e, score };
  }
  return best ? best.idea : null;
}

// --------------------------------------------------------------------------
// Inference
// --------------------------------------------------------------------------

interface Candidate {
  title: string;
  spark: string;
  rationale: string;
  source_hint: string;
}

interface Scores {
  novelty: number;
  impact: number;
  feasibility: number;
  alignment: number;
}

interface KeptIdea {
  title: string;
  spark: string;
  scores: Scores;
  overall: number;
  why: string;
  recommended_action: string;
  dupe_of?: string;
}

interface DroppedIdea {
  title: string;
  reason: string;
}

interface EvalResult {
  kept: KeptIdea[];
  dropped: DroppedIdea[];
}

class InferenceError extends Error {}

/**
 * Run the configured inference command with (system, user) prompts appended as
 * the final two positional args. Returns parsed JSON. The command MUST print
 * a single JSON value on stdout. Any non-JSON / non-zero result is an
 * InferenceError so the caller can fail safe (file nothing).
 */
function runInference(cfg: Config, system: string, user: string): unknown {
  const [cmd, ...base] = cfg.inferCmd;
  if (!cmd) throw new InferenceError("empty inference command");
  const res = spawnSync(cmd, [...base, system, user], {
    encoding: "utf8",
    timeout: 180000,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (res.error) throw new InferenceError(`inference spawn failed: ${res.error.message}`);
  if (res.status !== 0) {
    throw new InferenceError(
      `inference exited ${res.status}: ${(res.stderr || "").slice(0, 400)}`,
    );
  }
  const out = (res.stdout || "").trim();
  if (!out) throw new InferenceError("inference produced no output");
  const json = extractJson(out);
  if (json === undefined) {
    throw new InferenceError(`inference output was not JSON: ${out.slice(0, 200)}`);
  }
  return json;
}

/**
 * Pull the first balanced JSON array or object out of a text blob. The infer
 * command is asked to emit bare JSON, but a chatty model may wrap it in prose or
 * a ```json fence; this recovers the payload without trusting exact formatting.
 */
function extractJson(text: string): unknown {
  // Fast path: whole thing parses.
  try {
    return JSON.parse(text);
  } catch {
    // fall through
  }
  // Strip a code fence if present.
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const body = fence ? fence[1] : text;
  const startIdx = firstJsonStart(body);
  if (startIdx < 0) return undefined;
  const open = body[startIdx];
  const close = open === "[" ? "]" : "}";
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = startIdx; i < body.length; i++) {
    const ch = body[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === "\\") esc = true;
      else if (ch === '"') inStr = false;
      continue;
    }
    if (ch === '"') inStr = true;
    else if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) {
        const slice = body.slice(startIdx, i + 1);
        try {
          return JSON.parse(slice);
        } catch {
          return undefined;
        }
      }
    }
  }
  return undefined;
}

function firstJsonStart(text: string): number {
  const arr = text.indexOf("[");
  const obj = text.indexOf("{");
  if (arr < 0) return obj;
  if (obj < 0) return arr;
  return Math.min(arr, obj);
}

function buildTranscriptDigest(mined: MinedTail, muse: string): string {
  const parts: string[] = [];
  for (const m of mined.messages) {
    const speaker = m.role === "human" ? "CAPTAIN" : "ASSISTANT";
    parts.push(`[${speaker}] ${m.text}`);
  }
  let digest = parts.join("\n\n");
  if (muse) digest += `\n\n[OVERNIGHT NOTES]\n${muse}`;
  return digest;
}

const GEN_SYSTEM = [
  "You review a work-chat transcript between a captain (the human) and his assistant.",
  "Your one job: surface ideas, sparks, half-formed wants, and unaddressed problems the",
  "captain raised or implied but that were never turned into a captured task or idea.",
  "Focus on the captain's own wishes and frustrations, not the assistant's suggestions.",
  "Ignore small talk, status updates, and anything that was already acted on.",
  "Return ONLY a JSON array. Each element: {\"title\": short idea name,",
  '"spark": the raw thing he said/implied, "rationale": why it looks like an uncaptured idea,',
  '"source_hint": a short quote or paraphrase locating it}. No prose outside the JSON.',
].join(" ");

const EVAL_SYSTEM = [
  "You are a critical second-pass reviewer of freshly generated candidate ideas for a",
  "captain whose focus is voice-first computing, accessibility, PAI / life-OS tooling,",
  "shipping projects, landing a tech job, and income.",
  "For each candidate: score novelty, impact, feasibility, and goal-alignment from 1 to 10;",
  "compute an overall score; write one honest sentence of why; and recommend one action of",
  "research, build, design, or discuss. Drop candidates that are vague, trivial, already",
  "captured, or duplicate an existing idea. When a candidate duplicates an existing idea,",
  "put it in dropped with the reason naming the duplicate, OR keep it with dupe_of set if it",
  "meaningfully extends the existing one.",
  "Return ONLY a JSON object: {\"kept\":[{\"title\",\"spark\",\"scores\":{\"novelty\",\"impact\",",
  '"feasibility","alignment"},"overall","why","recommended_action","dupe_of"?}],',
  '"dropped":[{"title","reason"}]}. No prose outside the JSON.',
].join(" ");

function generateCandidates(cfg: Config, digest: string): Candidate[] {
  const user = `Transcript to mine (most recent last):\n\n${digest}\n\nReturn the JSON array of uncaptured ideas now.`;
  const parsed = runInference(cfg, GEN_SYSTEM, user);
  if (!Array.isArray(parsed)) {
    throw new InferenceError("generate pass did not return a JSON array");
  }
  const out: Candidate[] = [];
  for (const item of parsed) {
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const title = typeof o.title === "string" ? o.title.trim() : "";
    if (!title) continue;
    out.push({
      title,
      spark: typeof o.spark === "string" ? o.spark.trim() : "",
      rationale: typeof o.rationale === "string" ? o.rationale.trim() : "",
      source_hint: typeof o.source_hint === "string" ? o.source_hint.trim() : "",
    });
  }
  return out;
}

function clampScore(v: unknown): number {
  const n = typeof v === "number" ? v : Number.parseFloat(String(v));
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(10, Math.round(n * 10) / 10));
}

const ACTIONS = new Set(["research", "build", "design", "discuss"]);

function evaluateCandidates(cfg: Config, candidates: Candidate[], existing: ExistingIdea[]): EvalResult {
  const existingTitles = existing.map((e) => e.title);
  const user = [
    "Existing captured idea titles (for dedup):",
    existingTitles.length ? existingTitles.map((t) => `- ${t}`).join("\n") : "(none)",
    "",
    "Candidate ideas to critically evaluate:",
    JSON.stringify(candidates, null, 2),
    "",
    "Return the JSON object with kept and dropped now.",
  ].join("\n");
  const parsed = runInference(cfg, EVAL_SYSTEM, user);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new InferenceError("evaluate pass did not return a JSON object");
  }
  const o = parsed as Record<string, unknown>;
  const kept: KeptIdea[] = [];
  const dropped: DroppedIdea[] = [];

  if (Array.isArray(o.kept)) {
    for (const item of o.kept) {
      if (!item || typeof item !== "object") continue;
      const k = item as Record<string, unknown>;
      const title = typeof k.title === "string" ? k.title.trim() : "";
      if (!title) continue;
      const rawScores = (k.scores && typeof k.scores === "object" ? k.scores : {}) as Record<string, unknown>;
      const scores: Scores = {
        novelty: clampScore(rawScores.novelty),
        impact: clampScore(rawScores.impact),
        feasibility: clampScore(rawScores.feasibility),
        alignment: clampScore(rawScores.alignment),
      };
      const overallRaw = clampScore(k.overall);
      const overall =
        overallRaw > 0
          ? overallRaw
          : Math.round(((scores.novelty + scores.impact + scores.feasibility + scores.alignment) / 4) * 10) / 10;
      let action = typeof k.recommended_action === "string" ? k.recommended_action.trim().toLowerCase() : "";
      if (!ACTIONS.has(action)) action = "discuss";
      const dupe = typeof k.dupe_of === "string" && k.dupe_of.trim() ? k.dupe_of.trim() : undefined;
      const entry: KeptIdea = {
        title,
        spark: typeof k.spark === "string" ? k.spark.trim() : "",
        scores,
        overall,
        why: typeof k.why === "string" ? k.why.trim() : "",
        recommended_action: action,
      };
      if (dupe) entry.dupe_of = dupe;
      kept.push(entry);
    }
  }

  if (Array.isArray(o.dropped)) {
    for (const item of o.dropped) {
      if (!item || typeof item !== "object") continue;
      const d = item as Record<string, unknown>;
      const title = typeof d.title === "string" ? d.title.trim() : "";
      if (!title) continue;
      dropped.push({ title, reason: typeof d.reason === "string" ? d.reason.trim() : "" });
    }
  }

  // Rank kept by overall desc and enforce the kept cap.
  kept.sort((a, b) => b.overall - a.overall);
  const capped = kept.slice(0, cfg.maxKept);
  const overflow = kept.slice(cfg.maxKept);
  for (const o2 of overflow) dropped.push({ title: o2.title, reason: `below the top ${cfg.maxKept} by score` });

  return { kept: capped, dropped };
}

// --------------------------------------------------------------------------
// Idempotency marker
// --------------------------------------------------------------------------

function markerPath(cfg: Config): string {
  return join(cfg.stateDir, ".idea-mine-marker");
}

function readMarker(cfg: Config): string | null {
  const p = markerPath(cfg);
  if (!existsSync(p)) return null;
  try {
    return readFileSync(p, "utf8").trim();
  } catch {
    return null;
  }
}

function writeMarker(cfg: Config, rangeHash: string): void {
  try {
    mkdirSync(cfg.stateDir, { recursive: true });
    writeFileSync(markerPath(cfg), `${rangeHash}\n`, "utf8");
  } catch {
    // A missing marker only costs one redundant re-mine; never fatal.
  }
}

// --------------------------------------------------------------------------
// Filing
// --------------------------------------------------------------------------

function today(): string {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function ideaDescription(k: KeptIdea): string {
  const s = k.scores;
  const scoreLine = `scores novelty=${s.novelty} impact=${s.impact} feasibility=${s.feasibility} alignment=${s.alignment} overall=${k.overall}`;
  const lines = [
    `${today()}. Mined from recent chat + context history by fm-idea-mine.`,
    "",
    k.spark ? `Spark: ${k.spark}` : "",
    k.why ? `Why: ${k.why}` : "",
    `Recommended action: ${k.recommended_action}`,
    scoreLine,
    k.dupe_of ? `Extends existing idea: ${k.dupe_of}` : "",
  ].filter((l) => l !== "");
  return lines.join("\n");
}

interface FileResult {
  filedIdeas: { title: string; id: string }[];
  skippedDuplicates: { title: string; dupeOf: string }[];
  reviewId: string | null;
}

/** Run a store `create` and return the created id (from --silent stdout). */
function createIssue(cmd: string, title: string, description: string): string {
  const res = spawnSync(cmd, ["create", title, "-d", description, "--silent"], {
    encoding: "utf8",
    timeout: 30000,
  });
  if (res.error) throw new Error(`${cmd} create failed: ${res.error.message}`);
  if (res.status !== 0) {
    throw new Error(`${cmd} create exited ${res.status}: ${(res.stderr || "").slice(0, 300)}`);
  }
  return (res.stdout || "").trim().split(/\s+/).pop() || "";
}

function reviewDescription(result: EvalResult, filed: FileResult, mined: MinedTail): string {
  const lines: string[] = [];
  lines.push(`Morning idea harvest for ${today()}.`);
  lines.push(
    `Mined ${mined.messages.length} messages (~${approxTokens(mined.charCount)} tokens) from ${
      mined.file ? mined.file.split("/").pop() : "no transcript"
    }.`,
  );
  lines.push(
    `Kept ${result.kept.length}, filed ${filed.filedIdeas.length} new, skipped ${filed.skippedDuplicates.length} duplicates, dropped ${result.dropped.length}.`,
  );
  lines.push("");
  lines.push("## Ranked ideas");
  if (result.kept.length === 0) {
    lines.push("(none survived evaluation)");
  } else {
    result.kept.forEach((k, i) => {
      const s = k.scores;
      const filedId = filed.filedIdeas.find((f) => f.title === k.title);
      const dupSkip = filed.skippedDuplicates.find((f) => f.title === k.title);
      const status = filedId ? `filed ${filedId.id}` : dupSkip ? `dup of ${dupSkip.dupeOf}` : "not filed";
      lines.push(
        `${i + 1}. [${k.overall}] ${k.title} — action: ${k.recommended_action} (n${s.novelty}/i${s.impact}/f${s.feasibility}/a${s.alignment}) [${status}]`,
      );
      if (k.why) lines.push(`   why: ${k.why}`);
    });
  }
  lines.push("");
  lines.push("## Dropped");
  if (result.dropped.length === 0) {
    lines.push("(none)");
  } else {
    for (const d of result.dropped) lines.push(`- ${d.title} — ${d.reason}`);
  }
  return lines.join("\n");
}

<<<<<<< HEAD
function fileHarvest(cfg: Config, result: EvalResult, existing: ExistingIdea[], mined: MinedTail): FileResult {
  const filed: FileResult = { filedIdeas: [], skippedDuplicates: [], reviewId: null };

  // File each kept idea that is not a duplicate of an existing one.
  for (const k of result.kept) {
    const dup = findDuplicate(k.title, existing);
    if (dup) {
      filed.skippedDuplicates.push({ title: k.title, dupeOf: dup.id || dup.title });
      continue;
    }
    const id = createIssue(cfg.ideasCmd, k.title, ideaDescription(k));
    filed.filedIdeas.push({ title: k.title, id });
    // Track it locally so two similar kept ideas in one run don't both file.
    existing.push({ id, title: k.title });
  }

  // One consolidated review item, created with its final body.
  const reviewTitle = `Morning idea harvest — ${today()}`;
  filed.reviewId = createIssue(cfg.reviewCmd, reviewTitle, reviewDescription(result, filed, mined));
  return filed;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

function printDryRun(result: EvalResult, existing: ExistingIdea[], mined: MinedTail): void {
  console.log("=== fm-idea-mine DRY RUN — nothing filed ===");
  console.log(
    `mined ${mined.messages.length} messages (~${approxTokens(mined.charCount)} tokens) from ${
      mined.file ? mined.file.split("/").pop() : "no transcript"
    }`,
  );
  console.log(`kept ${result.kept.length}, dropped ${result.dropped.length}\n`);
  result.kept.forEach((k, i) => {
    const dup = findDuplicate(k.title, existing);
    const s = k.scores;
    const tag = dup ? `(dup of ${dup.id || dup.title} — would skip)` : "(would file)";
    console.log(
      `${i + 1}. [${k.overall}] ${k.title} — ${k.recommended_action} (n${s.novelty}/i${s.impact}/f${s.feasibility}/a${s.alignment}) ${tag}`,
    );
    if (k.why) console.log(`   why: ${k.why}`);
  });
  if (result.dropped.length) {
    console.log("\ndropped:");
    for (const d of result.dropped) console.log(`- ${d.title} — ${d.reason}`);
  }
}

function main(): number {
  let parsedArgs: { dryRun: boolean; force: boolean; help: boolean };
  try {
    parsedArgs = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error((e as Error).message);
    console.error(USAGE);
    return 2;
  }
  if (parsedArgs.help) {
    console.log(USAGE);
    return 0;
  }

  const cfg = loadConfig(process.argv.slice(2));

  const mined = mineTranscript(cfg);
  if (mined.messages.length === 0) {
    console.log("fm-idea-mine: no transcript history to mine; nothing to do.");
    return 0;
  }

  // Idempotency: skip an identical tail unless forced. Dry-run always computes.
  if (!cfg.force && !cfg.dryRun) {
    const prev = readMarker(cfg);
    if (prev && prev === mined.rangeHash) {
      console.log("fm-idea-mine: transcript tail unchanged since last run; nothing to do (use --force to re-mine).");
      return 0;
    }
  }

  const muse = readMuse(cfg);
  const digest = buildTranscriptDigest(mined, muse);
  const existing = listExistingIdeas(cfg);

  let candidates: Candidate[];
  try {
    candidates = generateCandidates(cfg, digest);
  } catch (e) {
    console.error(`fm-idea-mine: generate pass failed (nothing filed): ${(e as Error).message}`);
    return 1;
  }

  if (candidates.length === 0) {
    console.log("fm-idea-mine: no candidate ideas surfaced from history; nothing to file.");
    if (!cfg.dryRun) writeMarker(cfg, mined.rangeHash);
    return 0;
  }

  let result: EvalResult;
  try {
    result = evaluateCandidates(cfg, candidates, existing);
  } catch (e) {
    console.error(`fm-idea-mine: evaluate pass failed (nothing filed): ${(e as Error).message}`);
    return 1;
  }

  if (cfg.dryRun) {
    printDryRun(result, existing, mined);
    return 0;
  }

  if (result.kept.length === 0) {
    console.log("fm-idea-mine: no ideas survived evaluation; filing an empty harvest review for the record.");
  }

  let filed: FileResult;
  try {
    filed = fileHarvest(cfg, result, existing, mined);
  } catch (e) {
    console.error(`fm-idea-mine: filing failed: ${(e as Error).message}`);
    return 1;
||||||| 68641a33
=======
function fileHarvest(cfg: Config, result: EvalResult, existing: ExistingIdea[]): FileResult {
  const filed: FileResult = { filedIdeas: [], skippedDuplicates: [], reviewId: null };

  // File each kept idea that is not a duplicate of an existing one.
  for (const k of result.kept) {
    const dup = findDuplicate(k.title, existing);
    if (dup) {
      filed.skippedDuplicates.push({ title: k.title, dupeOf: dup.id || dup.title });
      continue;
    }
    const id = createIssue(cfg.ideasCmd, k.title, ideaDescription(k));
    filed.filedIdeas.push({ title: k.title, id });
    // Track it locally so two similar kept ideas in one run don't both file.
    existing.push({ id, title: k.title });
  }

  // One consolidated review item.
  const reviewTitle = `Morning idea harvest — ${today()}`;
  filed.reviewId = createIssue(cfg.reviewCmd, reviewTitle, "PLACEHOLDER");
  return filed;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

function printDryRun(result: EvalResult, existing: ExistingIdea[], mined: MinedTail): void {
  console.log("=== fm-idea-mine DRY RUN — nothing filed ===");
  console.log(
    `mined ${mined.messages.length} messages (~${approxTokens(mined.charCount)} tokens) from ${
      mined.file ? mined.file.split("/").pop() : "no transcript"
    }`,
  );
  console.log(`kept ${result.kept.length}, dropped ${result.dropped.length}\n`);
  result.kept.forEach((k, i) => {
    const dup = findDuplicate(k.title, existing);
    const s = k.scores;
    const tag = dup ? `(dup of ${dup.id || dup.title} — would skip)` : "(would file)";
    console.log(
      `${i + 1}. [${k.overall}] ${k.title} — ${k.recommended_action} (n${s.novelty}/i${s.impact}/f${s.feasibility}/a${s.alignment}) ${tag}`,
    );
    if (k.why) console.log(`   why: ${k.why}`);
  });
  if (result.dropped.length) {
    console.log("\ndropped:");
    for (const d of result.dropped) console.log(`- ${d.title} — ${d.reason}`);
  }
}

function main(): number {
  let parsedArgs: { dryRun: boolean; force: boolean; help: boolean };
  try {
    parsedArgs = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error((e as Error).message);
    console.error(USAGE);
    return 2;
  }
  if (parsedArgs.help) {
    console.log(USAGE);
    return 0;
  }

  const cfg = loadConfig(process.argv.slice(2));

  const mined = mineTranscript(cfg);
  if (mined.messages.length === 0) {
    console.log("fm-idea-mine: no transcript history to mine; nothing to do.");
    return 0;
  }

  // Idempotency: skip an identical tail unless forced. Dry-run always computes.
  if (!cfg.force && !cfg.dryRun) {
    const prev = readMarker(cfg);
    if (prev && prev === mined.rangeHash) {
      console.log("fm-idea-mine: transcript tail unchanged since last run; nothing to do (use --force to re-mine).");
      return 0;
    }
  }

  const muse = readMuse(cfg);
  const digest = buildTranscriptDigest(mined, muse);
  const existing = listExistingIdeas(cfg);

  let candidates: Candidate[];
  try {
    candidates = generateCandidates(cfg, digest);
  } catch (e) {
    console.error(`fm-idea-mine: generate pass failed (nothing filed): ${(e as Error).message}`);
    return 1;
  }

  if (candidates.length === 0) {
    console.log("fm-idea-mine: no candidate ideas surfaced from history; nothing to file.");
    if (!cfg.dryRun) writeMarker(cfg, mined.rangeHash);
    return 0;
  }

  let result: EvalResult;
  try {
    result = evaluateCandidates(cfg, candidates, existing);
  } catch (e) {
    console.error(`fm-idea-mine: evaluate pass failed (nothing filed): ${(e as Error).message}`);
    return 1;
  }

  if (cfg.dryRun) {
    printDryRun(result, existing, mined);
    return 0;
  }

  if (result.kept.length === 0) {
    console.log("fm-idea-mine: no ideas survived evaluation; filing an empty harvest review for the record.");
  }

  let filed: FileResult;
  try {
    filed = fileHarvest(cfg, result, existing);
  } catch (e) {
    console.error(`fm-idea-mine: filing failed: ${(e as Error).message}`);
    return 1;
  }

  // The review item needs the filed ids, so re-write its body now that we have them.
  if (filed.reviewId) {
    const body = reviewDescription(result, filed, mined);
    const res = spawnSync(cfg.reviewCmd, ["update", filed.reviewId, "-d", body], {
      encoding: "utf8",
      timeout: 30000,
    });
    if (res.status !== 0) {
      // Non-fatal: the review item exists; only its body is the placeholder.
      console.error(
        `fm-idea-mine: warning — could not update review body (${filed.reviewId}): ${(res.stderr || "").slice(0, 200)}`,
      );
    }
>>>>>>> town-base
  }

  writeMarker(cfg, mined.rangeHash);

  // Summary to stdout.
  console.log("=== fm-idea-mine harvest ===");
  console.log(
    `mined ${mined.messages.length} messages; kept ${result.kept.length}; filed ${filed.filedIdeas.length} new ideas; skipped ${filed.skippedDuplicates.length} duplicates; dropped ${result.dropped.length}.`,
  );
  if (filed.reviewId) console.log(`review item: ${filed.reviewId}`);
  for (const f of filed.filedIdeas) console.log(`  idea ${f.id}: ${f.title}`);
  for (const s of filed.skippedDuplicates) console.log(`  skipped (dup of ${s.dupeOf}): ${s.title}`);
  return 0;
}

// `update` may not be a verb on every bd build; fall back gracefully by using a
// body-file create if needed is out of scope — bd exposes `update -d` (verified
// via --help family), so the direct update above is correct.

// Run only when executed directly (not when imported by the test harness).
// `import.meta.main` is bun's direct-execution flag; the cast keeps this
// typecheckable without the bun type package present, and it falls back to an
// argv comparison so a plain-tsc/node build still behaves.
const runDirectly = (() => {
  const meta = import.meta as unknown as { main?: boolean; url?: string };
  if (typeof meta.main === "boolean") return meta.main;
  const entry = process.argv[1] ? resolve(process.argv[1]) : "";
  const self = meta.url ? resolve(fileURLToPath(meta.url)) : "";
  return entry !== "" && entry === self;
})();

if (runDirectly) {
  process.exit(main());
}

export {
  splitCommand,
  sanitizeText,
  extractText,
  isToolResultOnly,
  titleSimilarity,
  findDuplicate,
  extractJson,
  clampScore,
  approxTokens,
};
