#!/usr/bin/env bats
#
# Unit tests for scripts/tts-native.sh (Unix TTS backend).
#
# Unlike tests/tts.bats which exercises the integration layer with a mock
# backend, this suite runs the real script against PATH-mocked engines
# (uname, say, espeak-ng, piper, aplay, powershell.exe, python3) to verify:
#   - platform branching via uname -s (Darwin / Linux / MINGW*/MSYS* / unknown)
#   - engine priority on Linux (piper > espeak-ng > silent exit)
#   - unit conversions (rate to wpm / length-scale, volume to amplitude)
#   - contract behavior (empty stdin, default args, metacharacter safety,
#     always-exit-0)
#   - --list-voices output per platform
#   - piper sample-rate sidecar handling

# Locate the script under test and isolate each test in its own TEST_DIR.
TTS_SCRIPT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/scripts/tts-native.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR
  MOCK_BIN="$TEST_DIR/mock_bin"
  mkdir -p "$MOCK_BIN"
  export PEON_DIR="$TEST_DIR"
  # Ensure no stray env from caller leaks in
  unset PEON_DEBUG PEON_PIPER_MODEL
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- Helpers ---

# Install a mock binary at $MOCK_BIN/<name> that logs args and stdin to
# $TEST_DIR/<name>.log, then exits with $exit_code (default 0).
mock_cmd() {
  local name="$1" exit_code="${2:-0}" stdout="${3:-}"
  local path="$MOCK_BIN/$name"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'echo "ARGS: $*" >> "%s/%s.log"\n' "$TEST_DIR" "$name"
    printf 'if [ ! -t 0 ]; then cat >> "%s/%s.stdin"; fi\n' "$TEST_DIR" "$name"
    [ -n "$stdout" ] && printf 'printf %q\n' "$stdout"
    printf 'exit %s\n' "$exit_code"
  } > "$path"
  chmod +x "$path"
}

# Create a uname stub that returns a specific kernel name.
mock_uname() {
  local kernel="$1"
  cat > "$MOCK_BIN/uname" <<SCRIPT
#!/bin/bash
case "\$1" in
  -s) printf '%s\n' '$kernel' ;;
  *)  printf '%s\n' '$kernel' ;;
esac
SCRIPT
  chmod +x "$MOCK_BIN/uname"
}

# Prepend mock bin to PATH (callers must invoke before running the script).
with_mocks() {
  export PATH="$MOCK_BIN:$PATH"
}

# Returns the contents of a mock's args log, newline-joined.
mock_args() {
  local name="$1"
  if [ -f "$TEST_DIR/$name.log" ]; then
    cat "$TEST_DIR/$name.log"
  fi
}

mock_stdin() {
  local name="$1"
  if [ -f "$TEST_DIR/$name.stdin" ]; then
    cat "$TEST_DIR/$name.stdin"
  fi
}

mock_called() {
  local name="$1"
  [ -f "$TEST_DIR/$name.log" ]
}

# ============================================================
# Script existence + syntax
# ============================================================

@test "tts-native.sh: file exists and is executable" {
  [ -f "$TTS_SCRIPT" ]
  [ -x "$TTS_SCRIPT" ]
}

@test "tts-native.sh: passes bash -n syntax check" {
  bash -n "$TTS_SCRIPT"
}

# ============================================================
# Platform branching via uname
# ============================================================

@test "macOS: Darwin uname invokes say with -r 200 (rate=1.0)" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  echo "hello" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  [ $? -eq 0 ]
  mock_called "say"
  local args; args=$(mock_args "say")
  [[ "$args" == *"-r 200"* ]]
}

@test "macOS: voice != default adds -v <voice>" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "Alex" "1.0" "0.5"
  local args; args=$(mock_args "say")
  [[ "$args" == *"-v Alex"* ]]
  [[ "$args" == *"-r 200"* ]]
}

@test "macOS: voice=default omits -v flag" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  local args; args=$(mock_args "say")
  [[ "$args" != *"-v default"* ]]
  [[ "$args" != *"-v "* ]]
}

@test "Linux: piper preferred when binary + model both available" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mock_cmd "espeak-ng"
  mkdir -p "$TEST_DIR/piper-models"
  touch "$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  mock_called "piper"
  mock_called "aplay"
  ! mock_called "espeak-ng"
  local args; args=$(mock_args "piper")
  [[ "$args" == *"--length-scale 1.00"* ]]
}

@test "Linux: falls back to espeak-ng when piper binary missing" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  # No piper mock → command -v piper returns nonzero
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  mock_called "espeak-ng"
  local args; args=$(mock_args "espeak-ng")
  [[ "$args" == *"-s 175"* ]]
  [[ "$args" == *"-a 50"* ]]
}

@test "Linux: falls back to espeak-ng when piper binary exists but model absent" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "espeak-ng"
  # No model file on disk → piper probe fails the -f check
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  mock_called "espeak-ng"
  ! mock_called "piper"
}

@test "Linux: no engines installed → exits 0 silently" {
  mock_uname "Linux"
  # Neither piper nor espeak-ng on PATH
  with_mocks
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5' 2>&1"
  [ "$status" -eq 0 ]
  # No stderr output without PEON_DEBUG
  [ -z "$output" ] || [ "$output" = "" ]
}

@test "Linux: no engines + PEON_DEBUG=1 → stderr contains diagnostic" {
  mock_uname "Linux"
  with_mocks
  run bash -c "PEON_DEBUG=1 bash -c \"echo 'hi' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5'\" 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no TTS engine found"* ]]
}

@test "MSYS2: MINGW64_NT uname routes to powershell.exe with -File tts-native.ps1" {
  mock_uname "MINGW64_NT-10.0"
  mock_cmd "powershell.exe"
  # Create a dummy tts-native.ps1 so the [ -f ] guard passes
  mkdir -p "$PEON_DIR/scripts"
  echo "# dummy" > "$PEON_DIR/scripts/tts-native.ps1"
  with_mocks
  echo "hello" | bash "$TTS_SCRIPT" "Zira" "1.0" "0.5"
  mock_called "powershell.exe"
  local args; args=$(mock_args "powershell.exe")
  [[ "$args" == *"-NoProfile"* ]]
  [[ "$args" == *"-File"* ]]
  [[ "$args" == *"tts-native.ps1"* ]]
  [[ "$args" == *"-Voice Zira"* ]]
  [[ "$args" == *"-Rate 1.0"* ]]
  [[ "$args" == *"-Vol 0.5"* ]]
}

@test "MSYS2: missing tts-native.ps1 → exits 0 silently (no ps invocation)" {
  mock_uname "MSYS_NT-10.0"
  mock_cmd "powershell.exe"
  # Do NOT create tts-native.ps1
  with_mocks
  run bash -c "echo 'hello' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5' 2>&1"
  [ "$status" -eq 0 ]
  ! mock_called "powershell.exe"
}

@test "MSYS2: missing tts-native.ps1 + PEON_DEBUG=1 logs diagnostic" {
  mock_uname "MINGW32_NT-10.0"
  with_mocks
  run bash -c "PEON_DEBUG=1 bash -c \"echo 'hello' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5'\" 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"tts-native.ps1"* ]]
}

@test "Unknown platform: exits 0, no engines invoked" {
  mock_uname "SunOS"
  mock_cmd "say"
  mock_cmd "espeak-ng"
  with_mocks
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5' 2>&1"
  [ "$status" -eq 0 ]
  ! mock_called "say"
  ! mock_called "espeak-ng"
}

@test "Unknown platform + PEON_DEBUG=1 logs 'unsupported platform'" {
  mock_uname "Plan9"
  with_mocks
  run bash -c "PEON_DEBUG=1 bash -c \"echo 'hi' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5'\" 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsupported platform"* ]]
}

# ============================================================
# Unit conversion correctness
# ============================================================

@test "Rate 2.0: macOS wpm = 400" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "2.0" "0.5"
  [[ "$(mock_args say)" == *"-r 400"* ]]
}

@test "Rate 0.5: macOS wpm = 100" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "0.5" "0.5"
  [[ "$(mock_args say)" == *"-r 100"* ]]
}

@test "Rate 2.0: espeak-ng wpm = 350" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "2.0" "0.5"
  [[ "$(mock_args espeak-ng)" == *"-s 350"* ]]
}

@test "Rate 0.5: espeak-ng wpm is an integer near 87-88" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "0.5" "0.5"
  local args; args=$(mock_args espeak-ng)
  # awk truncates 87.5 to 87 with "%d" format
  [[ "$args" == *"-s 87"* ]] || [[ "$args" == *"-s 88"* ]]
}

@test "Rate 2.0: piper length-scale = 0.50" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/piper-models"
  touch "$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "2.0" "0.5"
  [[ "$(mock_args piper)" == *"--length-scale 0.50"* ]]
}

@test "Rate 0.5: piper length-scale = 2.00" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/piper-models"
  touch "$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "0.5" "0.5"
  [[ "$(mock_args piper)" == *"--length-scale 2.00"* ]]
}

@test "Volume 1.0: espeak-ng amplitude = 100" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "1.0"
  [[ "$(mock_args espeak-ng)" == *"-a 100"* ]]
}

@test "Volume 0.0: espeak-ng amplitude = 0" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.0"
  [[ "$(mock_args espeak-ng)" == *"-a 0"* ]]
}

# ============================================================
# Contract behavior
# ============================================================

@test "Empty stdin: exits 0 without invoking any engine" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  run bash -c ": | bash '$TTS_SCRIPT' 'default' '1.0' '0.5'"
  [ "$status" -eq 0 ]
  ! mock_called "say"
}

@test "Whitespace-only stdin: exits 0 without invoking any engine" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  run bash -c "printf '   \\n' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5'"
  [ "$status" -eq 0 ]
  ! mock_called "say"
}

@test "Missing positional args use defaults (voice=default, rate=1.0, vol=0.5)" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT"
  local args; args=$(mock_args espeak-ng)
  [[ "$args" == *"-s 175"* ]]
  [[ "$args" == *"-a 50"* ]]
  # voice=default → no -v flag
  [[ "$args" != *"-v default"* ]]
}

@test "Shell metacharacters in stdin reach engine uncorrupted" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  # Use single quotes so no interpolation occurs at caller side
  local dangerous='$USER `whoami` "quoted" '"'"'apostrophe'"'"' & semicolon;'
  printf '%s\n' "$dangerous" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  local args; args=$(mock_args say)
  # Literal dollar-USER must survive, not an expansion
  [[ "$args" == *'$USER'* ]]
  [[ "$args" == *'`whoami`'* ]]
  [[ "$args" == *'& semicolon;'* ]]
}

@test "Engine failure (non-zero exit) does NOT cause script to fail" {
  mock_uname "Darwin"
  mock_cmd "say" 42
  with_mocks
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '1.0' '0.5'"
  [ "$status" -eq 0 ]
  mock_called "say"
}

# ============================================================
# --list-voices mode
# ============================================================

@test "--list-voices on macOS: emits one voice name per line" {
  mock_uname "Darwin"
  # Mock `say -v '?'` with whitespace-separated voice table
  cat > "$MOCK_BIN/say" <<'SCRIPT'
#!/bin/bash
if [ "$1" = "-v" ] && [ "$2" = "?" ]; then
  cat <<'OUT'
Alex                en_US    # Most people recognize me by my voice.
Samantha            en_US    # Hello, my name is Samantha.
Fred                en_US    # I sure like being inside this fancy computer
OUT
  exit 0
fi
echo "ARGS: $*" >> "${TEST_DIR}/say.log"
SCRIPT
  chmod +x "$MOCK_BIN/say"
  with_mocks
  run bash "$TTS_SCRIPT" --list-voices
  [ "$status" -eq 0 ]
  # First token of each line is the voice name
  [[ "$output" == *"Alex"* ]]
  [[ "$output" == *"Samantha"* ]]
  [[ "$output" == *"Fred"* ]]
}

@test "--list-voices on Linux with espeak-ng only: prints voice column" {
  mock_uname "Linux"
  cat > "$MOCK_BIN/espeak-ng" <<'SCRIPT'
#!/bin/bash
if [ "$1" = "--voices" ]; then
  cat <<'OUT'
Pty Language Age/Gender VoiceName          File                 Other Languages
 5  en-us       M       english-us         gmw/en-US
 5  en-gb       M       english            gmw/en
 5  fr-fr       M       french             roa/fr
OUT
  exit 0
fi
echo "ARGS: $*" >> "${TEST_DIR}/espeak-ng.log"
SCRIPT
  chmod +x "$MOCK_BIN/espeak-ng"
  with_mocks
  run bash "$TTS_SCRIPT" --list-voices
  [ "$status" -eq 0 ]
  [[ "$output" == *"english-us"* ]]
}

@test "--list-voices on Linux with piper model dir: prints model basenames first" {
  mock_uname "Linux"
  mock_cmd "piper"
  mkdir -p "$TEST_DIR/piper-models"
  touch "$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  touch "$TEST_DIR/piper-models/en_GB-alba-medium.onnx"
  with_mocks
  run bash "$TTS_SCRIPT" --list-voices
  [ "$status" -eq 0 ]
  [[ "$output" == *"en_US-lessac-medium"* ]]
  [[ "$output" == *"en_GB-alba-medium"* ]]
  # Must not include .onnx extension
  [[ "$output" != *".onnx"* ]]
}

@test "--list-voices on MSYS2: delegates to powershell.exe -ListVoices" {
  mock_uname "MINGW64_NT-10.0"
  cat > "$MOCK_BIN/powershell.exe" <<SCRIPT
#!/bin/bash
echo "ARGS: \$*" >> "$TEST_DIR/powershell.exe.log"
# Fake voice output for list mode
if [[ "\$*" == *"-ListVoices"* ]]; then
  echo "Microsoft David"
  echo "Microsoft Zira"
fi
SCRIPT
  chmod +x "$MOCK_BIN/powershell.exe"
  mkdir -p "$PEON_DIR/scripts"
  echo "# dummy" > "$PEON_DIR/scripts/tts-native.ps1"
  with_mocks
  run bash "$TTS_SCRIPT" --list-voices
  [ "$status" -eq 0 ]
  mock_called "powershell.exe"
  [[ "$(mock_args powershell.exe)" == *"-ListVoices"* ]]
}

# ============================================================
# Piper sample-rate sidecar handling
# ============================================================

@test "Piper: sidecar with audio.sample_rate=16000 → aplay called with -r 16000" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/piper-models"
  local model="$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  touch "$model"
  cat > "$model.json" <<'JSON'
{"audio": {"sample_rate": 16000}}
JSON
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  [[ "$(mock_args aplay)" == *"-r 16000"* ]]
}

@test "Piper: missing sidecar → aplay called with -r 22050 (default)" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/piper-models"
  touch "$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  # No .json sidecar
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  [[ "$(mock_args aplay)" == *"-r 22050"* ]]
}

@test "Piper: malformed sidecar → aplay called with -r 22050 (default)" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/piper-models"
  local model="$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  touch "$model"
  echo "{not valid json" > "$model.json"
  with_mocks
  echo "hi" | bash "$TTS_SCRIPT" "default" "1.0" "0.5"
  [[ "$(mock_args aplay)" == *"-r 22050"* ]]
}

@test "Piper: PEON_PIPER_MODEL env var overrides default model path" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/custom"
  touch "$TEST_DIR/custom/my-model.onnx"
  with_mocks
  PEON_PIPER_MODEL="$TEST_DIR/custom/my-model.onnx" \
    bash -c "echo hi | bash '$TTS_SCRIPT' default 1.0 0.5"
  mock_called "piper"
  [[ "$(mock_args piper)" == *"--model $TEST_DIR/custom/my-model.onnx"* ]]
}

# ============================================================
# awk injection hardening (card w3ciyq)
#
# rate/volume values originate in config.json and therefore must be treated
# as untrusted input. The script passes them to awk via `-v` so awk sees
# them as data, not program text. These tests assert that a rate string
# carrying awk syntax cannot execute arbitrary code through the script and
# that the invocation still exits 0 (contract: TTS never fails the caller).
# ============================================================

@test "awk hardening: hostile rate on macOS cannot inject awk code" {
  mock_uname "Darwin"
  mock_cmd "say"
  with_mocks
  local canary="$TEST_DIR/awk-injected.flag"
  # A rate string that, if awk built the program via string interpolation,
  # would use awk's system() to touch the canary file.
  local hostile='system("touch '"$canary"'")'
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '$hostile' '0.5' 2>&1"
  [ "$status" -eq 0 ]
  # Canary must NOT exist — injection blocked by awk -v.
  [ ! -f "$canary" ]
}

@test "awk hardening: hostile rate on Linux/espeak-ng cannot inject awk code" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  local canary="$TEST_DIR/awk-injected.flag"
  local hostile='system("touch '"$canary"'")'
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '$hostile' '0.5' 2>&1"
  [ "$status" -eq 0 ]
  [ ! -f "$canary" ]
}

@test "awk hardening: hostile volume on Linux/espeak-ng cannot inject awk code" {
  mock_uname "Linux"
  mock_cmd "espeak-ng"
  with_mocks
  local canary="$TEST_DIR/awk-injected-vol.flag"
  local hostile='system("touch '"$canary"'")'
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '1.0' '$hostile' 2>&1"
  [ "$status" -eq 0 ]
  [ ! -f "$canary" ]
}

@test "awk hardening: hostile rate on Linux/piper cannot inject awk code" {
  mock_uname "Linux"
  mock_cmd "piper"
  mock_cmd "aplay"
  mkdir -p "$TEST_DIR/piper-models"
  touch "$TEST_DIR/piper-models/en_US-lessac-medium.onnx"
  with_mocks
  local canary="$TEST_DIR/awk-injected-piper.flag"
  local hostile='system("touch '"$canary"'")'
  run bash -c "echo 'hi' | bash '$TTS_SCRIPT' 'default' '$hostile' '0.5' 2>&1"
  [ "$status" -eq 0 ]
  [ ! -f "$canary" ]
}

@test "awk hardening: tts-native.sh uses 'awk -v' for rate/volume (source scan)" {
  # Guards against regressing to `awk "BEGIN { printf ... $rate ... }"` style,
  # which is the interpolation pattern that allowed injection in the first
  # place.  If this test fires, check _speak_macos / _speak_piper /
  # _speak_espeak_ng in scripts/tts-native.sh.
  local bad
  bad=$(grep -nE 'awk[[:space:]]+"[^"]*\$(rate|volume)' "$TTS_SCRIPT" || true)
  [ -z "$bad" ]
}

# ============================================================
# tests/setup.bash python3 portability guard (card w3ciyq)
#
# Pre-existing bug: hardcoded `/usr/bin/python3` in setup.bash prevented the
# harness from running on Git Bash for Windows (18 tts.bats failures traced
# to this).  The fix resolves python3 via PATH. This test codifies the fix
# so it does not regress.
# ============================================================

@test "setup.bash: run_peon_tts resolves python3 via PATH (no hardcoded /usr/bin/python3)" {
  local setup_bash="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/setup.bash"
  [ -f "$setup_bash" ]
  # run_peon_tts / enable_debug_logging must use $PEON_PY (PATH-resolved
  # python3) rather than the Linux-only /usr/bin/python3 absolute path.
  # Accept the whole file being free of that absolute path inside the
  # run_peon_tts and enable_debug_logging function bodies.
  local offenders
  offenders=$(awk '
    /^run_peon_tts\(\)/            { in_tgt = 1 }
    /^enable_debug_logging\(\)/    { in_tgt = 1 }
    in_tgt && /\/usr\/bin\/python3/ { print NR": "$0 }
    in_tgt && /^\}/                { in_tgt = 0 }
  ' "$setup_bash")
  [ -z "$offenders" ]
}
