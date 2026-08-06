# Checksum Probe Defect Inventory

**Date:** 2026-08-06
**Finding:** Name-based command probes that use flag-specific variations

## Problem Statement

This codebase has a pattern of using `command -v <tool>` to test for tool availability, then immediately using tool-specific flags that may not exist on all systems. This creates false-negative behavior when:
- The tool exists (name check passes)
- But a specific flag/option doesn't work (flag call fails silently or errors)
- Hash computation returns empty
- Stale timer never resets (wedge false alarms in fm-watch.sh/fm-supervise-daemon.sh)

## Defect Locations Found

### 1. **FIXED** - fm-watch.sh:180-186 (hash_pane)
- **Status:** FIXED - replaced name check with behavior probe
- **Command tested:** `md5` and `md5sum`
- **Flags used:** `md5 -q`
- **Risk:** GNU md5 exists but doesn't support `-q` flag
- **Impact:** Returns empty hash, disables stale detection

### 2. **FIXED** - fm-supervise-daemon.sh:244-247 (_hash_text)
- **Status:** FIXED - replaced name check with behavior probe
- **Command tested:** `md5`
- **Flags used:** `md5 -q`
- **Risk:** Same as above - GNU md5 lacks `-q` flag
- **Impact:** Returns empty hash, wedge alarms on healthy workers

### 3. **SIMILAR PATTERN** - SHA/MD5 multi-file occurrences
Files that test command name then use flags:

| File | Line | Command | Flag/Option | Behavior Probe Needed? |
|------|------|---------|-------------|------------------------|
| bin/fm-backend-hometag-lib.sh | 44,46 | `shasum`, `sha256sum` | `-a 256` | LOW - both flags are universal |
| bin/fm-backlog-handoff.sh | 33 | `shasum` | `-a 256` | LOW - fallback to sha256sum is solid |
| bin/fm-backlog-receive.sh | 33 | `shasum` | `-a 256` | LOW - fallback to sha256sum is solid |
| bin/fm-check-lib.sh | 8,10 | `shasum`, `sha256sum` | `-a 256` | LOW - tested flags are universal |
| bin/fm-config-inherit-lib.sh | 62,64 | `shasum`, `sha256sum` | `-a 256` | LOW - tested flags are universal |
| bin/fm-decision-hold.sh | 50,52 | `shasum`, `sha256sum` | `-a 256` | LOW - tested flags are universal |
| bin/fm-install-herdr.sh | 95,97 | `sha256sum`, `shasum` | `-a 256` | LOW - both are standard |
| bin/fm-install-treehouse.sh | 94,96 | `sha256sum`, `shasum` | `-a 256` | LOW - both are standard |
| bin/fm-pr-lib.sh | 12,14 | `shasum`, `sha256sum` | `-a 256` | LOW - tested flags are universal |

### 4. **ANALYSIS: timeout and perl patterns**
- `timeout` command usage: checked in ~7 files, all use same basic timeout behavior (safe)
- `perl` command usage: checked in ~5 files, mostly used for fallback hashing (safe)

## Risk Assessment

**CRITICAL (FIXED):**
- md5 probe defect (2 locations) - directly causes false wedge alarms

**LOW:**
- SHA patterns - while they use name checks, the flags tested (`-a 256` for algorithm specification) are universal across BSD shasum and GNU sha256sum/sha1sum
- Fallback chains are solid - sha256sum is nearly universal

**RECOMMENDATION:**
1. ✅ **DONE** - Replace md5 probes with behavior checks (fm-watch.sh, fm-supervise-daemon.sh)
2. **OPTIONAL** - Standardize sha/md5 patterns to use behavior probes for consistency, but current risk is low
3. **OPTIONAL** - Document this pattern in AGENTS.md as a known anti-pattern

## Prevention

Future probe patterns should:
- Test BEHAVIOR: `if printf '' | md5 -q >/dev/null 2>&1; then ...`
- Not just NAME: `if command -v md5 >/dev/null 2>&1; then ...`
- Include fallbacks for each variant
- Never silently fail (empty output, unset variables)
