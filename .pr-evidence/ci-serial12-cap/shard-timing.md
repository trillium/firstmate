# Serial shard script time, before and after (CI-measured hints)

Before: 13 shards, stale hints. Serial shard 12 measured 28.4-29.8 min of script time
(runs 42423070092, 42423792144, 42412584983) against the 30 min job cap.
After: 15 shards, refreshed hints. `bin/fm-test-run.sh --check-coverage`:

    FM_TEST_COVERAGE ok total=365 parallel=26 ... serial=323 serial_shards=15 serial_unhinted=0 serial_max_ms=1133957 serial_budget_ms=1200000 herdr=16
