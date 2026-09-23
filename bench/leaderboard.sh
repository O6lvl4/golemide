#!/usr/bin/env bash
# The full polyglot benchmark, in the shape the public leaderboard reports it.
#
# Aider's leaderboard number is pass_rate_2: the share of the 225 exercises solved
# within two tries, the second one after seeing the test output. This script runs
# golemide under that protocol — every language, two attempts — for one or more
# models, one or more times, and writes a table that can be set next to the board.
#
#   bench/leaderboard.sh                          one run, cf:glm-5.3-flash
#   MODELS="cf:glm-5.3-flash cf:glm-5.3" RUNS=3 bench/leaderboard.sh
#
#   MODELS      models to run, space-separated       (default: cf:glm-5.3-flash)
#   RUNS        runs per model; the spread matters   (default: 1)
#   LANGS       languages                            (default: all six)
#   JOBS        exercises in parallel                (default: 4)
#   ATTEMPTS    attempts per exercise                (default: 2, the board's protocol)
#   OUT         where everything goes                (default: /tmp/golemide-leaderboard)
#   POLYGLOT    the benchmark checkout              (default: ../polyglot-benchmark)
#   DRY_RUN=1   preflight and harness check only; no model is asked
#   ESCALATE=1  let golemide's ladder escalate to its strong model (default: stay on MODEL)
#
# What it will not do for you: the numbers are self-reported until someone else
# reproduces them, and one run of anything is one sample. RUNS=3 is the smallest
# number that shows the spread; quality-plan.md records why that matters here.
#
# Time and money, from the 60-exercise Python/Rust runs on 2026-09-22: about
# $0.003 and 40 s per exercise at JOBS=3, so a full run is a few dollars and a
# few hours. Java and C++ build slower; JOBS above 4 made cargo builds hit the
# verify deadline, which counts as a failure that is not the model's.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS="${MODELS:-cf:glm-5.3-flash}"
RUNS="${RUNS:-1}"
LANGS="${LANGS:-cpp go java javascript python rust}"
JOBS="${JOBS:-4}"
ATTEMPTS="${ATTEMPTS:-2}"
OUT="${OUT:-${TMPDIR:-/tmp}/golemide-leaderboard}"
export POLYGLOT="${POLYGLOT:-$ROOT/../polyglot-benchmark}"
# The agent's own verify deadline, and the harness's re-check. Generous, because a
# Rust build that outlives a tight one is reported as a failed repair.
export BENCH_TIMEOUT="${BENCH_TIMEOUT:-300}"
export VERIFY_DEADLINE="${VERIFY_DEADLINE:-600}"

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }

# ---- preflight: nothing below is worth starting if any of this is off --------------
echo "== preflight =="
[ -d "$POLYGLOT" ] || { echo "polyglot-benchmark not found at $POLYGLOT (git clone https://github.com/Aider-AI/polyglot-benchmark)" >&2; exit 2; }
( cd "$ROOT" && almide build >/dev/null 2>&1 ) || { echo "almide build failed" >&2; exit 2; }
# A copy baked into a container has no .git; bench/container.sh leaves the commit beside it.
if [ -f "$ROOT/.bench-version" ]; then version="$(cat "$ROOT/.bench-version")"
else version="$(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet || echo '+dirty')"; fi
echo "  built: $ROOT/golemide ($version)"
if [[ "$LANGS" == *java* ]] && [ -z "${JAVA_HOME:-}" ]; then
  j21="$(mise where java@21 2>/dev/null || true)"
  [ -n "$j21" ] && export JAVA_HOME="$j21"
  [ -n "${JAVA_HOME:-}" ] || echo "  warning: no JAVA_HOME and no java@21 via mise; Gradle 8.7 refuses JDK 22+" >&2
fi
for m in $MODELS; do
  out="$(cd "$ROOT" && ./golemide llm-test --model "$m" 2>&1 | tail -1)"
  case "$out" in text=*) echo "  $m: $out" ;; *) echo "  $m: model call failed: $out" >&2; exit 2 ;; esac
done
mkdir -p "$OUT"
# Prove the harness on every language before paying for anything.
BENCH_CHECK_ONLY=1 BENCH_WORK="$OUT/_check" bash "$ROOT/bench/exercism.sh" $LANGS || exit 3
[ -n "${DRY_RUN:-}" ] && { echo "(DRY_RUN set; stopping before any model is asked)"; exit 0; }

# ---- the runs -------------------------------------------------------------------------
for m in $MODELS; do
  for run in $(seq 1 "$RUNS"); do
    work="$OUT/$(slug "$m")/run-$run"
    if [ -s "$work/results.tsv" ]; then echo "== $m run $run: already has results, skipping (rm -r $work to redo)"; continue; fi
    echo "== $m run $run/$RUNS -> $work =="
    mkdir -p "$work"
    # One model per run unless ESCALATE=1: with more than two attempts the ladder can
    # reach its strong-model rung, and a comparison on one model would quietly stop being one.
    strong="$m"; [ -n "${ESCALATE:-}" ] && strong=""
    BENCH_MODEL="$m" BENCH_STRONG_MODEL="$strong" \
    BENCH_ATTEMPTS="$ATTEMPTS" BENCH_JOBS="$JOBS" BENCH_WORK="$work" \
      bash "$ROOT/bench/exercism.sh" $LANGS 2>&1 | tee "$work.log" | grep -vE '^\s*$'
    # Rows that ended in the provider failing rather than a verdict are not a
    # measurement of the agent. List them; re-run with BENCH_ONLY if there are any.
    rerun="$work/rerun.tsv"; : > "$rerun"
    while IFS=$'\t' read -r lang ex res _; do
      [ "$res" = FAIL ] || continue
      log="$work/$lang/$ex.log"
      if grep -qE 'the provider timed out|model: .*status (5[0-9][0-9]|429)|no model credentials' "$log" 2>/dev/null \
         && ! grep -q '^\[verify\]' "$log"; then printf '%s\t%s\n' "$lang" "$ex" >> "$rerun"; fi
    done < "$work/results.tsv"
    if [ -s "$rerun" ]; then
      echo "  $(wc -l < "$rerun") exercise(s) never reached a verdict (provider errors). To re-measure them:"
      echo "    BENCH_ONLY=$rerun BENCH_MODEL=$m BENCH_ATTEMPTS=$ATTEMPTS BENCH_WORK=$work bash bench/exercism.sh $LANGS"
    fi
  done
done

# ---- the table --------------------------------------------------------------------------
python3 - "$OUT" "$ATTEMPTS" $MODELS <<'PY' | tee "$OUT/summary.md"
import sys, os, glob, collections, statistics
out, attempts, models = sys.argv[1], sys.argv[2], sys.argv[3:]
def slug(s): return "".join(c if c.isalnum() or c in ".-" else "_" for c in s)
print(f"# golemide on the polyglot benchmark, {attempts} attempts\n")
for m in models:
    runs = sorted(glob.glob(os.path.join(out, slug(m), "run-*", "results.tsv")))
    if not runs: continue
    per_run = []
    for path in runs:
        by = collections.defaultdict(lambda: [0, 0, 0.0, []])
        for line in open(path):
            f = line.rstrip("\n").split("\t")
            if len(f) < 6: continue
            lang, _ex, res, _att, cost, wall = f[:6]
            b = by[lang]; b[0] += res == "PASS"; b[1] += 1; b[2] += float(cost or 0)
            if wall.rstrip("s").isdigit(): b[3].append(int(wall.rstrip("s")))
        per_run.append(by)
    print(f"## {m}  ({len(runs)} run{'s' if len(runs) > 1 else ''})\n")
    print("| language | solved | rate | cost | median wall |")
    print("|---|---|---|---|---|")
    langs = sorted({l for by in per_run for l in by})
    tp = tn = 0; tc = 0.0
    for lang in langs:
        p = [by[lang][0] for by in per_run if lang in by]; n = per_run[0][lang][1]
        c = [by[lang][2] for by in per_run if lang in by]
        w = [x for by in per_run if lang in by for x in by[lang][3]]
        rate = statistics.mean(p) / n * 100
        spread = f" ({min(p)}–{max(p)})" if len(p) > 1 else ""
        print(f"| {lang} | {statistics.mean(p):.1f}/{n}{spread} | {rate:.1f}% | ${statistics.mean(c):.3f} | {statistics.median(w) if w else 0:.0f}s |")
        tp += statistics.mean(p); tn += n; tc += statistics.mean(c)
    print(f"| **total** | **{tp:.1f}/{tn}** | **{tp / tn * 100:.1f}%** | **${tc:.3f}** | |")
    if len(per_run) > 1:
        totals = [sum(b[0] for b in by.values()) for by in per_run]
        print(f"\nper-run totals: {', '.join(str(t) for t in totals)} of {tn} — the spread is the noise floor for any comparison.")
    print()
print("Self-reported. Model, attempts and commit are above; the polyglot checkout is at " + os.environ.get("POLYGLOT", "?") + ".")
PY
echo "written: $OUT/summary.md   results: $OUT/<model>/run-N/results.tsv   logs: $OUT/<model>/run-N/<lang>/<exercise>.log"
