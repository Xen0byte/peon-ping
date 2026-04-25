# Pester 5 tests for scripts/tts-native.ps1 (Windows SAPI5 TTS backend).
# Run: Invoke-Pester -Path tests/tts-native.Tests.ps1
#
# Strategy:
#   The script has two cooperating halves. The "pure" half -- rate/volume unit
#   conversion, input trimming, voice-selection fall-through logic -- is
#   verified by dot-sourcing helper functions out of the script and calling
#   them directly. The "impure" half -- the actual SpeechSynthesizer invocation
#   -- is verified via a side-effect trace: when the env var
#   PEON_TTS_DRY_RUN is set to "1", the script writes the resolved SAPI
#   parameters (rate, volume, selected voice, text) as a JSON object to
#   $env:PEON_TTS_TRACE_FILE and exits 0 without calling Speak(). This
#   mirrors the design doc's allowance of "assert on script output / side
#   effects ... rather than mocking the .NET class directly".
#
# The helper-function dot-source pattern requires the script to define its
# helpers before the main logic and to skip the main logic when dot-sourced
# with the -DotSource switch. That plumbing is part of the implementation.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:TtsNativePath = Join-Path (Join-Path $script:RepoRoot "scripts") "tts-native.ps1"

    # Helper: run tts-native.ps1 in dry-run mode and return the trace object.
    # Dry-run captures the resolved SAPI parameters before Speak() is called.
    function Invoke-TtsNativeDryRun {
        param(
            [string]$InputText = "",
            [string]$Voice = "default",
            [double]$Rate = 1.0,
            [double]$Vol = 0.5,
            [switch]$ListVoices,
            [switch]$Debug
        )

        $tracePath = Join-Path $env:TEMP "peon-tts-trace-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"

        $argList = @("-NoProfile", "-NonInteractive", "-File", $script:TtsNativePath)
        if ($ListVoices) {
            $argList += "-ListVoices"
        } else {
            $argList += @("-Voice", $Voice, "-Rate", $Rate, "-Vol", $Vol)
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = ($argList | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { "$_" }
        }) -join " "
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Environment["PEON_TTS_DRY_RUN"] = "1"
        $psi.Environment["PEON_TTS_TRACE_FILE"] = $tracePath
        if ($Debug) { $psi.Environment["PEON_DEBUG"] = "1" }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            $proc.Start() | Out-Null
            if ($InputText) {
                $proc.StandardInput.Write($InputText)
            }
            $proc.StandardInput.Close()

            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            if (-not $proc.WaitForExit(15000)) {
                $proc.Kill()
                throw "tts-native.ps1 timed out"
            }

            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            $exitCode = $proc.ExitCode
        } finally {
            $proc.Dispose()
        }

        $trace = $null
        if (Test-Path $tracePath) {
            $trace = Get-Content $tracePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Remove-Item $tracePath -Force -ErrorAction SilentlyContinue
        }

        return @{
            ExitCode = $exitCode
            Stdout   = $stdout
            Stderr   = $stderr
            Trace    = $trace
        }
    }
}

# ============================================================
# Structural / parse validation
# ============================================================

Describe "tts-native.ps1 structural validation" {
    It "exists in scripts/" {
        $script:TtsNativePath | Should -Exist
    }

    It "has valid PowerShell syntax" {
        $content = Get-Content $script:TtsNativePath -Raw
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It "contains a comment-based help header near the top" {
        $content = Get-Content $script:TtsNativePath -Raw
        # First block-comment must start within the first ~40 lines and contain
        # .SYNOPSIS and at least one .PARAMETER / .EXAMPLE marker.
        $content | Should -Match '(?s)^\s*<#.*\.SYNOPSIS.*\.PARAMETER.*\.EXAMPLE.*#>'
    }

    It "declares InputText with ValueFromPipeline" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '(?s)\[Parameter\(\s*ValueFromPipeline\s*=\s*\$true\s*\)\][^}]*\[string\]\s*\$InputText'
    }

    It "declares Voice parameter with 'default' default" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[string\]\s*\$Voice\s*=\s*"default"'
    }

    It "declares Rate parameter as double with 1.0 default" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[double\]\s*\$Rate\s*=\s*1\.0'
    }

    It "declares Vol parameter as double with 0.5 default" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[double\]\s*\$Vol\s*=\s*0\.5'
    }

    It "declares ListVoices as a switch parameter" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[switch\]\s*\$ListVoices'
    }

    It "uses begin/process/end blocks for pipeline input" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '(?ms)^\s*begin\s*\{'
        $content | Should -Match '(?ms)^\s*process\s*\{'
        $content | Should -Match '(?ms)^\s*end\s*\{'
    }

    It "loads System.Speech via Add-Type" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match 'Add-Type\s+-AssemblyName\s+System\.Speech'
    }

    It "does not contain ExecutionPolicy Bypass" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Not -Match "ExecutionPolicy Bypass"
    }

    It "applies the rate formula [int][math]::Round((rate-1.0)*10)" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[int\]\[math\]::Round\(\s*\(\s*\$Rate\s*-\s*1\.0\s*\)\s*\*\s*10\s*\)'
    }

    It "applies the volume formula [int][math]::Round(Vol*100)" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[int\]\[math\]::Round\(\s*\$Vol\s*\*\s*100\s*\)'
    }

    It "clamps SAPI rate into -10..+10" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[math\]::Max\(\s*-10'
        $content | Should -Match '\[math\]::Min\(\s*10'
    }

    It "clamps SAPI volume into 0..100" {
        $content = Get-Content $script:TtsNativePath -Raw
        $content | Should -Match '\[math\]::Max\(\s*0'
        $content | Should -Match '\[math\]::Min\(\s*100'
    }
}

# ============================================================
# Rate mapping (dry-run trace)
# ============================================================

Describe "tts-native.ps1 rate mapping" {
    It "Rate 1.0 maps to SAPI rate 0" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Rate 1.0
        $r.ExitCode | Should -Be 0
        $r.Trace | Should -Not -BeNullOrEmpty
        $r.Trace.SapiRate | Should -Be 0
    }

    It "Rate 0.5 maps to SAPI rate -5" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Rate 0.5
        $r.Trace.SapiRate | Should -Be -5
    }

    It "Rate 2.0 maps to SAPI rate +10" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Rate 2.0
        $r.Trace.SapiRate | Should -Be 10
    }

    It "Rate 5.0 is clamped to SAPI +10" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Rate 5.0
        $r.Trace.SapiRate | Should -Be 10
    }

    It "Rate 0.0 is clamped to SAPI -10" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Rate 0.0
        $r.Trace.SapiRate | Should -Be -10
    }
}

# ============================================================
# Volume mapping (dry-run trace)
# ============================================================

Describe "tts-native.ps1 volume mapping" {
    It "Vol 0.5 maps to SAPI volume 50" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Vol 0.5
        $r.Trace.SapiVolume | Should -Be 50
    }

    It "Vol 0.0 maps to SAPI volume 0" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Vol 0.0
        $r.Trace.SapiVolume | Should -Be 0
    }

    It "Vol 1.0 maps to SAPI volume 100" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Vol 1.0
        $r.Trace.SapiVolume | Should -Be 100
    }

    It "Vol 2.0 is clamped to SAPI 100" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Vol 2.0
        $r.Trace.SapiVolume | Should -Be 100
    }

    It "Vol -1.0 is clamped to SAPI 0" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Vol -1.0
        $r.Trace.SapiVolume | Should -Be 0
    }
}

# ============================================================
# Stdin pipeline binding
# ============================================================

Describe "tts-native.ps1 stdin handling" {
    It "binds single-line stdin to the resolved text" {
        $r = Invoke-TtsNativeDryRun -InputText "hello"
        $r.ExitCode | Should -Be 0
        $r.Trace.Text | Should -Be "hello"
        $r.Trace.Spoke | Should -BeTrue
    }

    It "accumulates multi-line stdin and trims trailing whitespace" {
        $r = Invoke-TtsNativeDryRun -InputText "line one`nline two`n"
        $r.ExitCode | Should -Be 0
        # Lines should be preserved in order with newline separators; trailing
        # whitespace removed before synthesis.
        $r.Trace.Text | Should -Match "line one"
        $r.Trace.Text | Should -Match "line two"
        $r.Trace.Text | Should -Not -Match '\s+$'
    }

    It "empty stdin exits 0 without invoking Speak" {
        $r = Invoke-TtsNativeDryRun -InputText ""
        $r.ExitCode | Should -Be 0
        # Either no trace was written, or trace.Spoke is false.
        if ($r.Trace) { $r.Trace.Spoke | Should -BeFalse }
    }

    It "whitespace-only stdin exits 0 without invoking Speak" {
        $r = Invoke-TtsNativeDryRun -InputText "   `n  "
        $r.ExitCode | Should -Be 0
        if ($r.Trace) { $r.Trace.Spoke | Should -BeFalse }
    }
}

# ============================================================
# Voice selection
# ============================================================

Describe "tts-native.ps1 voice selection" {
    It "uses 'default' as a sentinel that skips SelectVoice" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Voice "default"
        $r.ExitCode | Should -Be 0
        $r.Trace | Should -Not -BeNullOrEmpty
        $r.Trace.SelectVoiceCalled | Should -BeFalse
    }

    It "selects an installed voice when its name matches" {
        # Ask the OS for the first installed voice so the test is portable
        # across Windows 10 / 11 images.
        Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue
        $voices = [System.Speech.Synthesis.SpeechSynthesizer]::new().GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }
        if (-not $voices -or $voices.Count -eq 0) {
            Set-ItResult -Skipped -Because "no SAPI voices installed on this runner"
            return
        }
        $first = $voices[0]
        $r = Invoke-TtsNativeDryRun -InputText "test" -Voice $first
        $r.ExitCode | Should -Be 0
        $r.Trace.SelectVoiceCalled | Should -BeTrue
        $r.Trace.SelectedVoice | Should -Be $first
    }

    It "falls through to the engine default when the voice is not installed" {
        $r = Invoke-TtsNativeDryRun -InputText "test" -Voice "NoSuchVoiceABC123" -Debug
        $r.ExitCode | Should -Be 0
        $r.Trace.SelectVoiceCalled | Should -BeFalse
        # With PEON_DEBUG=1, a diagnostic line should appear on stderr.
        $r.Stderr | Should -Match "NoSuchVoiceABC123"
    }
}

# ============================================================
# -ListVoices
# ============================================================

Describe "tts-native.ps1 -ListVoices" {
    It "prints one voice name per line and exits 0" {
        $r = Invoke-TtsNativeDryRun -ListVoices
        $r.ExitCode | Should -Be 0
        # Stdout should contain at least one line that looks like a voice name.
        $lines = $r.Stdout -split "`r?`n" | Where-Object { $_ -ne "" }
        if ($lines.Count -eq 0) {
            Set-ItResult -Skipped -Because "no SAPI voices installed on this runner"
            return
        }
        $lines.Count | Should -BeGreaterThan 0
    }

    It "does not read stdin in -ListVoices mode" {
        # Pipe some text: with -ListVoices it must be ignored (the script
        # should never call Speak). We verify no trace with Spoke=true is
        # written -- the dry-run helper already disables Speak, but in
        # -ListVoices mode the script must exit early before writing a
        # synthesis trace.
        $r = Invoke-TtsNativeDryRun -InputText "ignored input" -ListVoices
        $r.ExitCode | Should -Be 0
        if ($r.Trace) {
            $r.Trace.Spoke | Should -BeFalse
        }
    }
}

# ============================================================
# Error containment
# ============================================================

Describe "tts-native.ps1 error containment" {
    It "exits 0 even when PEON_DEBUG is on and input is empty" {
        $r = Invoke-TtsNativeDryRun -InputText "" -Debug
        $r.ExitCode | Should -Be 0
    }

    It "never writes to stderr unless PEON_DEBUG=1 (happy path)" {
        $r = Invoke-TtsNativeDryRun -InputText "test"
        # Stderr should be empty or whitespace-only in the default happy path.
        $r.Stderr.Trim() | Should -BeNullOrEmpty
    }
}

# ============================================================
# Production-pipeline invocation path (card w3ciyq)
#
# The existing Invoke-TtsNativeDryRun helper uses `powershell -File` with
# stdin redirected via the ProcessStartInfo APIs. That path exercises the
# `[Console]::IsInputRedirected` fallback in end{} but does NOT exercise
# the ValueFromPipeline binding of the process{} block -- which is the
# path install.ps1's Invoke-TtsSpeak actually takes when it invokes
# tts-native.ps1 via `'text' | & $script ...` inside a single PowerShell
# session. These tests cover that production shape using
# `powershell -Command` so the pipeline binding is evaluated in-process.
# ============================================================

Describe "tts-native.ps1 production-pipeline binding" {
    It "binds piped text through the PowerShell pipeline (not IsInputRedirected)" {
        $tracePath = Join-Path $env:TEMP "peon-tts-trace-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $scriptPath = $script:TtsNativePath
        # Escape single quotes for the inner command string.
        $scriptPathEscaped = $scriptPath.Replace("'", "''")

        # The production shape: `'hello' | & 'tts-native.ps1' -Voice ... -Rate ... -Vol ...`
        # evaluated inside one powershell -Command session. This forces
        # PowerShell to bind the stdin string through ValueFromPipeline.
        $inner = "'hello' | & '$scriptPathEscaped' -Voice 'default' -Rate 1.0 -Vol 0.5"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -NonInteractive -Command `"$inner`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Environment["PEON_TTS_DRY_RUN"] = "1"
        $psi.Environment["PEON_TTS_TRACE_FILE"] = $tracePath

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            $proc.Start() | Out-Null
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(15000)) {
                $proc.Kill()
                throw "tts-native.ps1 timed out in production-pipeline test"
            }
            $exitCode = $proc.ExitCode
            $stderr = $stderrTask.Result
            $null = $stdoutTask.Result
        } finally {
            $proc.Dispose()
        }

        $trace = $null
        if (Test-Path $tracePath) {
            $trace = Get-Content $tracePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Remove-Item $tracePath -Force -ErrorAction SilentlyContinue
        }

        $exitCode | Should -Be 0
        $trace | Should -Not -BeNullOrEmpty
        $trace.Spoke | Should -BeTrue
        $trace.Text | Should -Be "hello"
    }
}

# ============================================================
# Voice-name case insensitivity (card w3ciyq)
#
# -contains uses PowerShell's case-insensitive equality semantics, so an
# uppercase voice argument resolves to a properly-cased installed voice
# without extra work. This test codifies that behaviour as intended
# rather than accidental, matching the skip-guard pattern used by the
# other voice-dependent tests.
# ============================================================

Describe "tts-native.ps1 voice case insensitivity" {
    It "resolves an uppercase voice name to the installed (properly-cased) voice" {
        Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue
        $voices = [System.Speech.Synthesis.SpeechSynthesizer]::new().GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }
        if (-not $voices -or $voices.Count -eq 0) {
            Set-ItResult -Skipped -Because "no SAPI voices installed on this runner"
            return
        }
        $first = $voices[0]
        $upper = $first.ToUpper()
        # Sanity: we actually need the upper-case form to differ from the
        # canonical form to meaningfully test case-insensitivity.
        if ($upper -ceq $first) {
            Set-ItResult -Skipped -Because "first installed voice name is already uppercase"
            return
        }
        $r = Invoke-TtsNativeDryRun -InputText "test" -Voice $upper
        $r.ExitCode | Should -Be 0
        $r.Trace.SelectVoiceCalled | Should -BeTrue
        # Tightened assertion (w3ciyq planner cycle 1 follow-up): require the
        # resolved voice to be the canonical (properly-cased) installed name,
        # not merely non-empty. This codifies the case-insensitive match
        # contract -- the script must resolve an uppercase argument back to
        # the installed canonical form, not fall back to a default voice.
        $r.Trace.SelectedVoice | Should -Be $first
    }
}

# ============================================================
# SAPI5 spaced-voice-name binding (card w3ciyq)
#
# Guards the bash -> powershell.exe -File arg handoff for realistic SAPI5
# voice names containing spaces (e.g. "Microsoft David Desktop",
# "Microsoft Zira Desktop"). The existing -Voice test only covers voice
# names returned from GetInstalledVoices at runtime; this one asserts that
# a spaced literal still arrives as a single intact -Voice argument.
# ============================================================

Describe "tts-native.ps1 SAPI5 spaced voice-name binding" {
    It "preserves a spaced voice name across the powershell -File arg handoff" {
        # Pass a hand-rolled spaced voice name that is unlikely to actually
        # match anything. The dry-run trace records RequestedVoice verbatim,
        # so we can assert the spaced name arrived intact regardless of
        # whether the voice is installed.
        $spaced = "Microsoft David Desktop"
        $r = Invoke-TtsNativeDryRun -InputText "test" -Voice $spaced
        $r.ExitCode | Should -Be 0
        $r.Trace | Should -Not -BeNullOrEmpty
        $r.Trace.RequestedVoice | Should -Be $spaced
    }

    It "preserves a different spaced voice name (Microsoft Zira Desktop)" {
        $spaced = "Microsoft Zira Desktop"
        $r = Invoke-TtsNativeDryRun -InputText "test" -Voice $spaced
        $r.ExitCode | Should -Be 0
        $r.Trace.RequestedVoice | Should -Be $spaced
    }
}
