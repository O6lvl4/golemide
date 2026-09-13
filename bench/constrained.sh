#!/usr/bin/env bash
# Does a harness change buy pass rate, or only tokens?
#
# `bench/almide.sh` at its default 6 attempts solves 23 of 23 exercises
# (bench/results-almide.tsv). A saturated benchmark cannot show an improvement: every
# arm scores 23/23 and the only thing left to move is cost. The first A/B of the
# prompt-deduplication fix ran that way and both arms scored 6/6, so it measured -56.6%
# cost per attempt and said nothing about solving.
#
# This constrains the budget instead of the model. With `--attempts 2` a run either
# lands quickly or not at all, so a prompt with less filler has somewhere to show it,
# and the six exercises are the ones with the most implementation to put back --
# ranked over all 23 by non-test lines and function count:
#
#   grade-report 415 lines / 9 fns   config-merger 318/9   todo-app 84/9
#   affine-cipher 87/6               pipeline 55/5         named-things 52/3
#
# Multiple seeds, because one run cannot tell a difference from the model's own
# sampling: within a single arm here, affine-cipher goes F,P and grade-report P,F.
#
#   ARMS="/tmp/a:before /tmp/b:after" SEEDS=4 bench/constrained.sh
#
# Each arm is a prebuilt golemide binary, so the comparison is between binaries and
# not between working trees. Seeds are run blocked -- every arm at seed 1, then every
# arm at seed 2 -- so drift in API conditions hits all arms equally instead of
# penalising whichever ran last.
#
# Result, 2026-09-13, almide 0.62.0, 3 arms x 4 seeds x 6 exercises = 72 runs:
#
#   arm                        solved   attempts   cost   $/attempt   vs before
#   before (neither fix)       18/24    39         0.3919 0.01005     --
#   after  (dedup only)        13/24    40         0.3235 0.00809     -19.5%
#   both   (dedup + stale)     18/24    37         0.2174 0.00588     -41.5%
#
# Read it honestly:
#
# **The pass rate did not move.** `both` is 18/24, identical to the baseline, with 4
# exercise-seeds better and 4 worse (paired sign test p=1.000). Two prompt fixes worth
# 42% and 5-7% of the prompt bought no additional solve.
#
# **Cost per attempt did move, by -41.5%, and it reproduces.** That matches what
# bench/budget.almd predicts statically from the two fixes, which is the strongest
# evidence that both instruments are measuring the same thing.
#
# **The `after` arm's 13/24 is noise, not a regression.** It trends worse in every
# seed (2 better / 7 worse, p=0.180), which is suggestive, but `both` contains the
# same deduplication and shows no dip -- a fix cannot be harmful in one arm and
# neutral in another that contains it. The mechanism that would have explained it was
# checked and ruled out: the reference tier clips at MAX_CHARS=48000 and the cheatsheet
# is 41,369 chars, so it was never clipped and the two copies were byte-identical.
#
# So: for a pass-rate claim this benchmark is the wrong instrument in both directions.
# Unconstrained it is saturated at 23/23; constrained to 2 attempts it has 24 paired
# trials per arm, which cannot resolve anything smaller than a very large effect.
#
# ## The same question on a benchmark we did not write
#
# `bench/exercism.sh` runs Aider's polyglot benchmark -- 225 Exercism problems chosen
# by someone else, with a public leaderboard. Rust and C++, all 3 attempts, one arm
# with none of the prompt fixes and one with all three (results-polyglot-*.tsv):
#
#   arm            solved     $/attempt
#   before         49/54      0.00354
#   all three      49/54      0.00362   (+2.3%)
#
#   better 2  worse 2  p=1.000
#   (+ cpp/crypto-square, + rust/alphametics, - cpp/gigasecond, - rust/xorcism)
#
# Identical, on 54 paired trials of a corpus with real headroom. Cost is unchanged too,
# and that part was predicted rather than discovered: `reference_for` resolves through a
# project CHEATSHEET.md or an Almide-specific toolchain command, so a Rust or C++
# exercise has no reference and there is nothing to deduplicate. **The -41.5% above is
# specific to projects that carry their own reference file.**
#
# ## What that means, stated against the claim it refutes
#
# The thesis these fixes were built on is that a generic harness throws away a large
# share of an open-weight model's measured ability, and that prompt overhead is where it
# goes. Two of these fixes removed 42% and 5-7% of the prompt, and the effect on solve
# rate was measured twice, on two corpora, at 24 and 54 paired trials: zero both times.
#
# Prompt bloat is not what this harness loses points to. It costs money, and the money
# is worth recovering, but a token saved is not a problem solved. Whatever the harness
# gap is made of, these three defects were not it -- and that is worth more than the
# cost number, because it rules out the explanation that was easiest to believe.
#
# Checks run before trusting the 90.7%, since it would otherwise be suspiciously near
# the top of a public leaderboard: the Rust verify command is
# `cargo test -q -- --include-ignored`, so the #[ignore] on every test after the first
# is overridden (exercism.sh:132 documents that trap); golemide's own gaming_warnings
# fired on nothing; and the harness check confirms the stub fails where the reference
# solution passes. The score is high because 3 attempts with test feedback is an easier
# protocol than the leaderboard's, not because the tests were weakened.

set -uo pipefail

ALMIDE="${ALMIDE:-$HOME/workspace/github.com/almide/almide}"
EXERCISES="${EXERCISES:-grade-report config-merger todo-app affine-cipher pipeline named-things}"
ATTEMPTS="${ATTEMPTS:-2}"
SEEDS="${SEEDS:-4}"
JOBS="${JOBS:-3}"
WORK="${WORK:-${TMPDIR:-/tmp}/golemide-constrained}"
ARMS="${ARMS:-}"

here=$(cd "$(dirname "$0")" && pwd)
[ -n "$ARMS" ] || { echo "set ARMS=\"<binary>:<label> [<binary>:<label> ...]\"" >&2; exit 2; }

rm -rf "$WORK"; mkdir -p "$WORK"
out="$WORK/results.tsv"; : > "$out"

# `bench/almide.sh` invokes ./golemide from the repo root, so each arm's binary has to
# stand in there. Snapshot the real one ONCE, before any arm overwrites it, and put it
# back on the way out however we leave -- including a Ctrl-C, which would otherwise
# leave the tree holding whichever arm ran last.
restore="$WORK/golemide.original"
[ -f "$here/../golemide" ] && cp "$here/../golemide" "$restore"
put_back() { [ -f "$restore" ] && cp "$restore" "$here/../golemide"; }
trap put_back EXIT INT TERM

# Blocked by seed, not by arm: see the header.
for s in $(seq 1 "$SEEDS"); do
  for spec in $ARMS; do
    bin="${spec%%:*}"; label="${spec##*:}"
    [ -x "$bin" ] || { echo "not executable: $bin" >&2; exit 2; }
    d="$WORK/$label-$s"
    echo "== $label seed $s =="
    cp "$bin" "$here/../golemide"
    # $EXERCISES must word-split into one argument per exercise. This script runs under
    # bash, where it does; the same line typed into zsh passes all six as ONE argument
    # and every exercise is then "not found", which is how the first run of this
    # comparison silently produced no rows at all.
    BENCH_WORK="$d" BENCH_ATTEMPTS="$ATTEMPTS" BENCH_JOBS="$JOBS" ALMIDE="$ALMIDE" \
      bash "$here/almide.sh" $EXERCISES > "$WORK/$label-$s.log" 2>&1
    while IFS=$'\t' read -r ex res att cost _; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$s" "$ex" "$res" "$att" "$cost" >> "$out"
    done < "$d/results.tsv"
    awk -F'\t' '{if($2=="PASS")p++; t++} END{printf "   solved %d/%d\n", p, t}' "$d/results.tsv"
  done
done

echo
python3 - "$out" <<'PY'
import sys, collections, math
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
# label, seed, exercise, result, attempts, cost
by=collections.defaultdict(lambda:[0,0,0,0.0])
res={}
for r in rows:
    lab,seed,ex,result,att,cost=r[0],r[1],r[2],r[3],int(r[4]),float(r[5])
    b=by[lab]; b[1]+=1; b[2]+=att; b[3]+=cost
    if result=="PASS": b[0]+=1
    res[(lab,seed,ex)]=result
labels=list(dict.fromkeys(r[0] for r in rows))
base=labels[0]
bpa=by[base][3]/by[base][2] if by[base][2] else 0
print(f"{'arm':24}{'solved':>9}{'attempts':>10}{'cost':>9}{'$/attempt':>11}{'vs '+base:>12}")
for lab in labels:
    p,t,at,c=by[lab]; pa=c/at if at else 0
    delta="--" if lab==base else f"{100*(pa/bpa-1):+.1f}%"
    print(f"{lab:24}{p:>4}/{t:<4}{at:>10}{c:>9.4f}{pa:>11.5f}{delta:>12}")

def sign_p(k,n):
    if n==0: return 1.0
    return min(1.0, sum(math.comb(n,i) for i in range(min(k,n-k)+1))/2**n*2)
print(f"\npaired sign test vs {base} (one pair per exercise-seed):")
for lab in labels[1:]:
    w=l=0
    for (b_lab,seed,ex),r in res.items():
        if b_lab!=base: continue
        o=res.get((lab,seed,ex))
        if o and o!=r:
            if o=="PASS": w+=1
            else: l+=1
    print(f"  {lab:20} better {w:>2}  worse {l:>2}  p={sign_p(w,w+l):.3f}")
PY
