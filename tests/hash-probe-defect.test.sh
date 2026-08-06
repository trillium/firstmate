#!/usr/bin/env bash
# tests/hash-probe-defect.test.sh - test that md5 probe behavior check prevents
# false empty-hash on systems where md5 exists but does not support -q flag.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load the functions to test
source "$ROOT/bin/fm-watch.sh" || { echo "FAIL: could not load fm-watch.sh"; exit 1; }

# Create a temporary override of md5 that behaves like GNU md5 (no -q flag).
# This simulates the defect condition: md5 exists but -q fails.
setup_gnu_md5_simulation() {
  export PATH="/tmp/fm-test-md5-sim:$PATH"
  mkdir -p /tmp/fm-test-md5-sim

  # Create a fake md5 that doesn't support -q
  cat > /tmp/fm-test-md5-sim/md5 <<'EOF'
#!/usr/bin/env bash
# Simulate GNU md5sum (no -q flag support)
if [[ "$*" == *"-q"* ]]; then
  echo "md5: invalid option -- 'q'" >&2
  exit 1
fi
# Just pass through to md5sum
exec md5sum "$@"
EOF
  chmod +x /tmp/fm-test-md5-sim/md5

  # Also provide md5sum for fallback
  ln -sf "$(which md5sum)" /tmp/fm-test-md5-sim/md5sum 2>/dev/null || true
}

cleanup_gnu_md5_simulation() {
  rm -rf /tmp/fm-test-md5-sim
  export PATH="${PATH#/tmp/fm-test-md5-sim:}"
}

# Test 1: With the behavior probe, hash_pane should not return empty on GNU md5
test_hash_pane_with_gnu_md5_simulation() {
  local test_name="hash_pane with GNU md5 simulation (no -q support)"
  setup_gnu_md5_simulation

  local input="test_data_12345"
  local result
  result=$(printf '%s' "$input" | hash_pane)

  cleanup_gnu_md5_simulation

  # The result should NOT be empty - behavior probe should fall back to md5sum
  if [ -z "$result" ]; then
    echo "FAIL: $test_name - hash_pane returned empty string"
    return 1
  fi

  # Verify it's a valid hash (hex string, reasonable length)
  if ! [[ "$result" =~ ^[0-9a-f]+$ ]] || [ ${#result} -lt 16 ]; then
    echo "FAIL: $test_name - hash_pane returned invalid hash: $result"
    return 1
  fi

  echo "PASS: $test_name"
  return 0
}

# Test 2: Hash of same input should be consistent
test_hash_pane_consistency() {
  local test_name="hash_pane consistency"
  local input="test_data_12345"

  local hash1
  local hash2
  hash1=$(printf '%s' "$input" | hash_pane)
  hash2=$(printf '%s' "$input" | hash_pane)

  if [ "$hash1" != "$hash2" ]; then
    echo "FAIL: $test_name - hash_pane returned different values for same input"
    return 1
  fi

  echo "PASS: $test_name"
  return 0
}

# Test 3: Different inputs should produce different hashes
test_hash_pane_differentiates() {
  local test_name="hash_pane differentiates different inputs"

  local hash1
  local hash2
  hash1=$(printf '%s' "input1" | hash_pane)
  hash2=$(printf '%s' "input2" | hash_pane)

  if [ "$hash1" = "$hash2" ]; then
    echo "FAIL: $test_name - different inputs produced same hash"
    return 1
  fi

  echo "PASS: $test_name"
  return 0
}

# Load and test _hash_text from fm-supervise-daemon.sh
test_hash_text_with_gnu_md5_simulation() {
  local test_name="_hash_text with GNU md5 simulation"
  setup_gnu_md5_simulation

  source "$ROOT/bin/fm-supervise-daemon.sh" >/dev/null 2>&1 || { echo "FAIL: could not load fm-supervise-daemon.sh"; cleanup_gnu_md5_simulation; return 1; }

  local input="test_data_12345"
  local result
  result=$(_hash_text "$input")

  cleanup_gnu_md5_simulation

  if [ -z "$result" ]; then
    echo "FAIL: $test_name - _hash_text returned empty string"
    return 1
  fi

  if ! [[ "$result" =~ ^[0-9a-f]+$ ]] || [ ${#result} -lt 16 ]; then
    echo "FAIL: $test_name - _hash_text returned invalid hash: $result"
    return 1
  fi

  echo "PASS: $test_name"
  return 0
}

# Run all tests
main() {
  local failed=0

  test_hash_pane_with_gnu_md5_simulation || ((failed++))
  test_hash_pane_consistency || ((failed++))
  test_hash_pane_differentiates || ((failed++))
  test_hash_text_with_gnu_md5_simulation || ((failed++))

  if [ $failed -eq 0 ]; then
    echo "All tests passed!"
    return 0
  else
    echo "$failed test(s) failed"
    return 1
  fi
}

main "$@"
