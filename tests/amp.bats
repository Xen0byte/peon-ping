#!/usr/bin/env bats

load setup.bash

setup() {
  setup_test_env

  # Create a mock Amp threads directory
  export AMP_THREADS_DIR="$TEST_DIR/threads"
  mkdir -p "$AMP_THREADS_DIR"

  # Copy peon.sh into test dir so the adapter can find it
  cp "$PEON_SH" "$TEST_DIR/peon.sh"

  # Mock fswatch so preflight passes
  cat > "$MOCK_BIN/fswatch" <<'SCRIPT'
#!/bin/bash
sleep 999
SCRIPT
  chmod +x "$MOCK_BIN/fswatch"

  ADAPTER_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/adapters/amp.sh"
}

teardown() {
  teardown_test_env
}

# Helper: source the adapter in test mode so all functions are available
# but the main watcher loop is skipped.
source_adapter() {
  export PEON_ADAPTER_TEST=1
  export TMPDIR="$TEST_DIR"
  source "$ADAPTER_SH" 2>/dev/null
  # Restore BATS-friendly settings (adapter sets -euo pipefail)
  set +e +u
  set +o pipefail 2>/dev/null || true
}

# Helper: create a mock Amp thread JSON file
create_thread() {
  local tid="$1"
  local last_role="${2:-assistant}"
  local last_type="${3:-text}"

  local content_item
  if [ "$last_type" = "tool_use" ]; then
    content_item='{"type": "tool_use", "id": "tu_1", "name": "Read", "input": {}}'
  else
    content_item='{"type": "text", "text": "Done!"}'
  fi

  cat > "$AMP_THREADS_DIR/${tid}.json" <<JSON
{
  "v": 1,
  "id": "$tid",
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "hello"}]},
    {"role": "$last_role", "content": [$content_item]}
  ]
}
JSON
}

# ============================================================
# Syntax validation
# ============================================================

@test "adapter script has valid bash syntax" {
  run bash -n "$ADAPTER_SH"
  [ "$status" -eq 0 ]
}

# ============================================================
# Preflight: missing peon.sh
# ============================================================

@test "exits with error when peon.sh is not found" {
  local empty_dir
  empty_dir="$(mktemp -d)"
  CLAUDE_PEON_DIR="$empty_dir" run bash "$ADAPTER_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"peon.sh not found"* ]]
  rm -rf "$empty_dir"
}

# ============================================================
# Preflight: missing filesystem watcher
# ============================================================

@test "exits with error when no filesystem watcher is available" {
  rm -f "$MOCK_BIN/fswatch"
  rm -f "$MOCK_BIN/inotifywait"
  PATH="$MOCK_BIN:/usr/bin:/bin" run bash "$ADAPTER_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No filesystem watcher found"* ]]
}

# ============================================================
# State tracking: thread_get / thread_set
# ============================================================

@test "thread_get returns empty for unknown thread" {
  source_adapter
  result=$(thread_get "T-unknown-1234")
  [ -z "$result" ]
}

@test "thread_set and thread_get round-trip correctly" {
  source_adapter
  thread_set "T-test-aaaa" "active"
  result=$(thread_get "T-test-aaaa")
  [ "$result" = "active" ]

  thread_set "T-test-aaaa" "idle"
  result=$(thread_get "T-test-aaaa")
  [ "$result" = "idle" ]
}

# ============================================================
# Cooldown tracking: stop_time_get / stop_time_set
# ============================================================

@test "stop_time_get returns 0 for unknown thread" {
  source_adapter
  result=$(stop_time_get "T-unknown-5678")
  [ "$result" = "0" ]
}

@test "stop_time_set and stop_time_get round-trip correctly" {
  source_adapter
  stop_time_set "T-test-bbbb" "1700000000"
  result=$(stop_time_get "T-test-bbbb")
  [ "$result" = "1700000000" ]
}

# ============================================================
# thread_is_waiting: detects agent state from thread JSON
# ============================================================

@test "thread_is_waiting returns true when last message is assistant text" {
  source_adapter
  create_thread "T-waiting-0001" "assistant" "text"
  thread_is_waiting "$AMP_THREADS_DIR/T-waiting-0001.json"
}

@test "thread_is_waiting returns false when last message is assistant tool_use" {
  source_adapter
  create_thread "T-working-0002" "assistant" "tool_use"
  ! thread_is_waiting "$AMP_THREADS_DIR/T-working-0002.json"
}

@test "thread_is_waiting returns false when last message is from user" {
  source_adapter
  create_thread "T-user-0003" "user" "text"
  ! thread_is_waiting "$AMP_THREADS_DIR/T-user-0003.json"
}

# ============================================================
# handle_thread_change: new thread triggers SessionStart
# ============================================================

@test "new thread file triggers SessionStart and plays sound" {
  source_adapter
  local tid="T-brand-new-0001"
  create_thread "$tid" "assistant" "text"

  handle_thread_change "$AMP_THREADS_DIR/${tid}.json"

  # State should be active
  result=$(thread_get "$tid")
  [ "$result" = "active" ]

  # Give async audio a moment (peon.sh uses nohup &)
  sleep 0.5

  afplay_was_called
  sound=$(afplay_sound)
  [[ "$sound" == *"/packs/peon/sounds/Hello"* ]]
}

# ============================================================
# handle_thread_change: known thread no duplicate SessionStart
# ============================================================

@test "known thread update does not emit duplicate SessionStart" {
  source_adapter
  local tid="T-known-0002"

  # Pre-register as known
  thread_set "$tid" "idle"
  create_thread "$tid" "assistant" "text"

  handle_thread_change "$AMP_THREADS_DIR/${tid}.json"

  # State should be active now
  result=$(thread_get "$tid")
  [ "$result" = "active" ]

  # No sound should play (no SessionStart for known thread)
  sleep 0.3
  count=$(afplay_call_count)
  [ "$count" -eq 0 ]
}

# ============================================================
# handle_thread_change: ignores non-thread files
# ============================================================

@test "ignores non-thread files (amptmp, non-T- prefix)" {
  source_adapter

  handle_thread_change "$AMP_THREADS_DIR/T-foo.json.amptmp"
  handle_thread_change "$AMP_THREADS_DIR/session.json"
  handle_thread_change "$AMP_THREADS_DIR/history.jsonl"

  # No state changes
  sleep 0.3
  count=$(afplay_call_count)
  [ "$count" -eq 0 ]
}

# ============================================================
# check_idle_threads: emits Stop only when agent is waiting
# ============================================================

@test "idle thread with assistant text emits Stop event" {
  export AMP_IDLE_SECONDS=1
  source_adapter
  local tid="T-idle-text-0003"

  create_thread "$tid" "assistant" "text"
  thread_set "$tid" "active"

  # Wait past the idle threshold
  sleep 2

  check_idle_threads

  # State should now be idle
  result=$(thread_get "$tid")
  [ "$result" = "idle" ]

  # peon.sh should have played a completion sound
  sleep 0.5
  afplay_was_called
}

@test "idle thread with tool_use does NOT emit Stop" {
  export AMP_IDLE_SECONDS=1
  source_adapter
  local tid="T-idle-tool-0004"

  create_thread "$tid" "assistant" "tool_use"
  thread_set "$tid" "active"

  # Wait past the idle threshold
  sleep 2

  check_idle_threads

  # State should remain active (tool_use means still working)
  result=$(thread_get "$tid")
  [ "$result" = "active" ]

  # No sound should play
  sleep 0.3
  count=$(afplay_call_count)
  [ "$count" -eq 0 ]
}

# ============================================================
# check_idle_threads: cooldown prevents duplicate Stop
# ============================================================

@test "cooldown prevents duplicate Stop events" {
  export AMP_IDLE_SECONDS=1
  export AMP_STOP_COOLDOWN=60
  source_adapter
  local tid="T-cooldown-0005"

  create_thread "$tid" "assistant" "text"
  thread_set "$tid" "active"

  # Set a recent stop time (within cooldown window)
  local now
  now=$(date +%s)
  stop_time_set "$tid" "$now"

  # Wait past idle threshold
  sleep 2

  check_idle_threads

  # State should be idle (marked idle despite cooldown)
  result=$(thread_get "$tid")
  [ "$result" = "idle" ]

  # No sound should play (cooldown suppressed the Stop event)
  sleep 0.3
  count=$(afplay_call_count)
  [ "$count" -eq 0 ]
}

# ============================================================
# Pre-existing threads: not treated as new sessions
# ============================================================

@test "pre-existing threads at startup are not treated as new sessions" {
  # Create thread files BEFORE sourcing the adapter
  create_thread "T-existing-0006" "assistant" "text"

  source_adapter

  # The thread should already be in state as "idle" (pre-registered)
  result=$(thread_get "T-existing-0006")
  [ "$result" = "idle" ]

  # Triggering a change should NOT fire SessionStart
  handle_thread_change "$AMP_THREADS_DIR/T-existing-0006.json"
  sleep 0.3
  count=$(afplay_call_count)
  [ "$count" -eq 0 ]
}
