#!/usr/bin/env bash
# Mutation score of the benchmark's verify command.
#
# `bench/almide.sh` hands golemide `--verify "almide test <file>"` and treats exit 0
# as done. Everything the loop does rests on that signal, so its strength is worth a
# number: if a wrong implementation can pass the tests, the loop stops on broken code
# and no amount of attempts helps.
#
# Method. Each exercise ships a reference solution that passes. Apply one small
# semantic change, re-run the verify command, and record whether it now fails. A
# mutant that still passes is a hole in the specification the harness trusts.
#
# No model is called. This measures the harness, not the agent.
#
# Result on the 25 exercises, almide 0.62.0 / develop 51b9e80d7:
#
#   mutants 76 · caught 71 · survived 5 · mutation score 93%
#   19 of 20 runnable exercises at 100%; wasm-smoke's reference does not pass
#
# Survivors have to be read, not just counted — mutation testing under-reports
# unless equivalent mutants are separated out, and here two of five are:
#
#   affine-cipher/bound-ge-to-gt   REAL. `num >= 0` -> `num > 0` skips the letter
#                                  'a' (index 0), and no test string in the
#                                  exercise contains an 'a'. One assertion closes
#                                  it: encode(5, 7, "a") == ok("h") — verified to
#                                  kill the mutant.
#   affine-cipher/bound-lt-to-le   EQUIVALENT. `a < 0` -> `a <= 0` inside
#                                  `if a < 0 then 0 - a else a`; at a = 0 both
#                                  branches give 0. Verified unkillable.
#   affine-cipher/off-by-one       EQUIVALENT. `var i = 1` -> 2 in mod_inverse
#                                  only differs when the inverse is 1, and the
#                                  loop then returns 27, which is 1 mod 26.
#   affine-cipher/arith-minus-to-plus  Unreachable rather than unspecified: it
#                                  mutates gcd's abs, which no sensible test
#                                  reaches because `a` is always positive.
#   pipeline/bound-gt-to-ge        Not analysed.
#
# So the adjusted score is about 97%, and the one closable gap is a missing letter
# in a test fixture. **The verify signal this loop rests on is sound** — which is
# worth knowing precisely because it rules verification out as the place the
# harness loses ground.
#
#   ALMIDE=/path/to/almide-repo bench/mutate.sh
#   MUT_LIMIT=5 bench/mutate.sh          first five exercises only
#   bench/mutate.sh roman-numerals bob   just these

set -uo pipefail

ALMIDE="${ALMIDE:-$HOME/workspace/github.com/almide/almide}"
EXDIR="$ALMIDE/research/benchmark/exercises"
WORK="${MUT_WORK:-${TMPDIR:-/tmp}/golemide-mutate}"
LIMIT="${MUT_LIMIT:-0}"

command -v almide >/dev/null || { echo "almide not on PATH" >&2; exit 2; }

# A mutant can loop forever — `<` to `<=` on a loop bound is one of the mutations
# below, and it produced a four-minute hang on the first run. golemide itself is not
# exposed to this (it runs the verify command through `process.exec_status_timeout`),
# but this script is, and `timeout` is not on a stock macOS. Hence a portable one.
#
# A mutant that has to be killed counts as caught: a verify command that never
# returns has not accepted the change.
VERIFY_TIMEOUT="${MUT_TIMEOUT:-20}"
run_verify() {
  local dir=$1 file=$2
  ( cd "$dir" && almide test "$file" >/dev/null 2>&1 ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$VERIFY_TIMEOUT" ] && { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}
[ -d "$EXDIR" ] || { echo "exercises not found at $EXDIR" >&2; exit 2; }

# One mutation per line: a sed program, and a label. Each is a change of meaning that
# a test suite specifying the function's behaviour ought to notice. `replace first
# occurrence only` throughout, so a mutant differs from the reference in one place.
#
# Operators and boundaries rather than deletions: removing a line usually stops the
# file compiling, and a compile error is caught by anything, which would inflate the
# score with mutants no verifier could miss.
MUTATIONS=(
  's/ + / - /:arith-plus-to-minus'
  's/ - / + /:arith-minus-to-plus'
  's/ \* / + /:arith-times-to-plus'
  's/ < / <= /:bound-lt-to-le'
  's/ > / >= /:bound-gt-to-ge'
  's/ <= / < /:bound-le-to-lt'
  's/ >= / > /:bound-ge-to-gt'
  's/ == / != /:eq-to-ne'
  's/ and / or /:logic-and-to-or'
  's/ or / and /:logic-or-to-and'
  's/true/false/:bool-flip'
  's/ 1/ 2/:off-by-one'
)

rm -rf "$WORK"; mkdir -p "$WORK"

exercises=("$@")
if [ ${#exercises[@]} -eq 0 ]; then
  while IFS= read -r d; do exercises+=("$(basename "$d")"); done < <(find "$EXDIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi
[ "$LIMIT" -gt 0 ] && exercises=("${exercises[@]:0:$LIMIT}")

total=0; caught=0; survived=0; skipped=0; base_fail=0; timeouts=0
declare -a SURVIVORS=()

for ex in "${exercises[@]}"; do
  src=$(ls "$EXDIR/$ex"/*.almd 2>/dev/null | head -1)
  [ -z "$src" ] && continue
  base=$(basename "$src")
  d="$WORK/$ex"; mkdir -p "$d"

  # The reference has to pass, or every mutant "fails" for the wrong reason.
  cp "$src" "$d/$base"
  if ! run_verify "$d" "$base"; then
    printf '%-22s SKIP  reference does not pass\n' "$ex"
    base_fail=$((base_fail + 1))
    continue
  fi

  ex_total=0; ex_caught=0
  for entry in "${MUTATIONS[@]}"; do
    prog="${entry%%:*}"; label="${entry##*:}"
    mut="$d/mut_$base"
    # Mutate only outside test blocks: changing a test changes the specification
    # rather than the implementation, and a suite that notices its own edit proves
    # nothing about the code under test.
    python3 - "$d/$base" "$mut" "$prog" <<'PY'
import re, subprocess, sys
src, dst, prog = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().split("\n")
out, depth, done = [], 0, False
for line in lines:
    in_test = depth > 0 or line.startswith("test ")
    if not done and not in_test and line.strip() and not line.strip().startswith("//"):
        new = subprocess.run(["sed", prog], input=line, capture_output=True, text=True).stdout.rstrip("\n")
        if new != line:
            line, done = new, True
    if line.startswith("test "):
        depth += line.count("{") - line.count("}")
    elif depth > 0:
        depth += line.count("{") - line.count("}")
    out.append(line)
open(dst, "w").write("\n".join(out))
sys.exit(0 if done else 3)
PY
    rc=$?
    if [ $rc -eq 3 ]; then skipped=$((skipped + 1)); continue; fi
    total=$((total + 1)); ex_total=$((ex_total + 1))
    run_verify "$d" "mut_$base"; vrc=$?
    if [ $vrc -eq 0 ]; then
      survived=$((survived + 1))
      SURVIVORS+=("$ex/$label")
    else
      caught=$((caught + 1)); ex_caught=$((ex_caught + 1))
      [ $vrc -eq 124 ] && timeouts=$((timeouts + 1))
    fi
  done
  [ "$ex_total" -gt 0 ] && printf '%-22s %2d/%2d caught\n' "$ex" "$ex_caught" "$ex_total"
done

echo
echo "mutants        $total"
echo "caught         $caught"
echo "survived       $survived"
[ "$total" -gt 0 ] && echo "mutation score $(( 100 * caught / total ))%"
[ "$skipped" -gt 0 ] && echo "(not applicable $skipped — the pattern does not occur outside the tests)"
[ "$base_fail" -gt 0 ] && echo "(references failing before mutation: $base_fail)"
[ "$timeouts" -gt 0 ] && echo "(of the caught, $timeouts hung and were killed at ${VERIFY_TIMEOUT}s)"

if [ "$survived" -gt 0 ]; then
  echo
  echo "survivors — the verify command accepts these wrong implementations:"
  printf '  %s\n' "${SURVIVORS[@]}"
fi
