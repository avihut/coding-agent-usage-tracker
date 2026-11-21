#!/bin/zsh
# Regenerates the zstd decoder's test fixtures in
# Tests/UsageCoreTests/Fixtures/zstd/: SYNTHETIC Codex-shaped rollouts (a
# fixed-seed generator — no real session content, ever) compressed by the
# reference encoder at the settings the decoder must handle. Needs Homebrew
# zstd (`brew install zstd`); the tests themselves never run it.
#
# The generator is deterministic, so a rerun reproduces the plain files byte
# for byte; the compressed ones can differ across zstd versions, and the
# tests only ever compare decoded output with the plain twin.
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/Tests/UsageCoreTests/Fixtures/zstd"
command -v zstd >/dev/null || { echo "zstd not found (brew install zstd)" >&2; exit 1; }
mkdir -p "$OUT"
cd "$OUT"

# One synthetic rollout: `turns` turns starting `day` (YYYY-MM-DD), a turn
# every ~37 minutes so it crosses midnight. Text comes from a small
# vocabulary plus hex noise, so Huffman and FSE tables come out non-trivial.
rollout() {
    awk -v turns="$1" -v day="$2" -v seed="$3" -v words="$4" '
    function rnd(n) { seed = (seed * 69069 + 1) % 4294967296; return int(seed / 4294967296 * n) }
    function text(count,   s, i) {
        s = ""
        for (i = 0; i < count; i++) {
            if (rnd(15) == 0) s = s sprintf("%08x", rnd(4294967296))
            else s = s vocab[rnd(nv)]
            s = s (rnd(11) == 0 ? ". " : " ")
        }
        return s
    }
    function stamp(minute,   d, h, m) {
        d = int(minute / 1440); h = int((minute % 1440) / 60); m = minute % 60
        return sprintf("%s%02dT%02d:%02d:%02d.%03dZ", prefix, base + d, h, m, rnd(60), rnd(1000))
    }
    BEGIN {
        nv = split("the scanner reads each rollout line and tallies tokens per day model session " \
            "window cache input output reasoning patch file test build error fix merge review " \
            "function struct enum protocol async await actor main queue lock buffer stream frame " \
            "block literal sequence offset match table huffman entropy decoder", vocab, " ")
        prefix = substr(day, 1, 8); base = substr(day, 9, 2) + 0
        minute = 20 * 60 + 5; total_in = 0; total_out = 0
        printf "{\"timestamp\":\"%s\",\"type\":\"session_meta\",\"payload\":{\"id\":\"00000000-0000-4000-8000-%012d\",\"cwd\":\"/tmp/synthetic/project\",\"originator\":\"codex_cli_rs\",\"cli_version\":\"0.99.0\"}}\n", stamp(minute), seed % 1000000
        for (t = 0; t < turns; t++) {
            model = (t % 5 == 4) ? "gpt-5.2" : "gpt-5.2-codex"
            printf "{\"timestamp\":\"%s\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/tmp/synthetic/project\",\"model\":\"%s\",\"effort\":\"high\"}}\n", stamp(minute), model
            printf "{\"timestamp\":\"%s\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"%s\",\"images\":null}}\n", stamp(minute + 1), text(6 + rnd(10))
            printf "{\"timestamp\":\"%s\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"%s\"}]}}\n", stamp(minute + 2), text(words + rnd(words))
            input = 2000 + rnd(30000); cached = int(input * rnd(90) / 100); output = 50 + rnd(3000)
            total_in += input; total_out += output
            printf "{\"timestamp\":\"%s\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":%d,\"cached_input_tokens\":0,\"output_tokens\":%d,\"reasoning_output_tokens\":0,\"total_tokens\":%d},\"last_token_usage\":{\"input_tokens\":%d,\"cached_input_tokens\":%d,\"output_tokens\":%d,\"reasoning_output_tokens\":0,\"total_tokens\":%d},\"model_context_window\":258400},\"rate_limits\":{\"primary\":{\"used_percent\":%d.0,\"window_minutes\":300,\"resets_at\":1792000000},\"secondary\":{\"used_percent\":%d.0,\"window_minutes\":10080,\"resets_at\":1792500000},\"plan_type\":\"plus\"}}}\n", stamp(minute + 3), total_in, total_out, total_in + total_out, input, cached, output, input + output, t % 100, t / 2
            minute += 30 + rnd(15)
        }
    }'
}

# Pseudo-random bytes from the same LCG (the tests regenerate them, so
# only the compressed form is checked in): incompressible → raw blocks.
noise() {
    awk -v count="$1" -v seed="$2" '
    BEGIN { for (i = 0; i < count; i++) { seed = (seed * 69069 + 1) % 4294967296; printf "%02x", int(seed / 16777216) } }' |
        xxd -r -p
}

rm -f -- *.zst *.jsonl
rollout 3 2026-10-11 7 12 >tiny.jsonl
# Past one 128 KiB block, crossing local midnight.
rollout 45 2026-10-14 42 220 >rollout.jsonl

zstd -q -f -3 --no-check rollout.jsonl -o rollout.jsonl.zst      # Codex's own settings
zstd -q -f -1 rollout.jsonl -o rollout.l1.jsonl.zst
zstd -q -f -19 rollout.jsonl -o rollout.l19.jsonl.zst
zstd -q -f -3 --no-compress-literals rollout.jsonl -o rollout.raw-literals.jsonl.zst
# From a pipe: no content size, a window descriptor at the 2^27 limit.
zstd -q -c -19 --long=27 <rollout.jsonl >rollout.long27.jsonl.zst

zstd -q -f -19 tiny.jsonl -o tiny.jsonl.zst
zstd -q -f -19 --no-check tiny.jsonl -o tiny.no-check.jsonl.zst
# A 1 KiB window: many small blocks, matches reaching back across them.
zstd -q -f -19 --zstd=wlog=10 tiny.jsonl -o tiny.wlog10.jsonl.zst
# One past the window limit: 2^28.
zstd -q -c -3 --long=28 <tiny.jsonl >tiny.long28.jsonl.zst

# Several frames: tiny, a skippable frame, tiny again → tiny twice.
{
    cat tiny.jsonl.zst
    printf '\x50\x2a\x4d\x18\x05\x00\x00\x00skip!'
    cat tiny.no-check.jsonl.zst
} >multi-frame.zst

noise 20000 99 | zstd -q -c -3 >noise.bin.zst
# Patterns the reference encoder codes with RLE literals (every literal a
# "c") and RLE sequence tables (one offset and literal-length code per
# block). The tests regenerate both inputs.
pattern_ab() {
    awk 'BEGIN { seed = 5; for (i = 0; i < 3000; i++) { seed = (seed * 69069 + 1) % 4294967296
        n = 2 + int(seed / 4294967296 * 40); s = ""; for (j = 0; j < n; j++) s = s "ab"; printf "%sc", s } }'
}
pattern_z() {
    awk 'BEGIN { seed = 5; for (i = 0; i < 3000; i++) { seed = (seed * 69069 + 1) % 4294967296
        n = int(seed / 4294967296 * 8); s = ""; for (j = 0; j < 20 + n * 7; j++) s = s "a"; printf "%sZ", s } }'
}
pattern_ab | zstd -q -c -19 >pattern-ab.bin.zst
pattern_z | zstd -q -c -1 >pattern-z.bin.zst
# A run past one block: RLE blocks, with RLE literals around a short break.
{ head -c 300000 /dev/zero | tr '\0' 'a'; printf 'b'; head -c 1000 /dev/zero | tr '\0' 'a'; } |
    zstd -q -c -19 >runs.bin.zst

ls -l "$OUT"
