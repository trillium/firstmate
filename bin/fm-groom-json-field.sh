#!/usr/bin/env bash
# fm-groom-json-field.sh - extract one string field from a JSON document on stdin.
#
# `ideas show --json` emits an array of one issue object whose `description` can
# contain quotes, newlines, and unicode -- none of which a grep/sed pipeline reads
# reliably. This helper does a real JSON parse and prints the requested field's
# string value (empty string if absent), so the groom pipeline never mangles a
# spark's text before formulating a brief from it.
#
# Usage: FM_KEY=<field> fm-groom-json-field.sh   (JSON on stdin, value on stdout)
# The field is read from FM_KEY (not argv) so no shell quoting can corrupt it.
set -eu

exec bun -e '
const key = process.env.FM_KEY;
if (!key) { process.stderr.write("FM_KEY unset\n"); process.exit(2); }
let raw = "";
process.stdin.setEncoding("utf-8");
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  let doc;
  try { doc = JSON.parse(raw); } catch { process.exit(0); }
  const obj = Array.isArray(doc) ? doc[0] : doc;
  if (obj && typeof obj === "object" && typeof obj[key] === "string") {
    process.stdout.write(obj[key], () => process.exit(0));
    return;
  }
  process.exit(0);
});
'
