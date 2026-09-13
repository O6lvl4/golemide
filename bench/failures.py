#!/usr/bin/env python3
"""Why the failures failed — a census over run directories already on disk.

No model is called and nothing is re-run. This reads the logs a benchmark already
wrote, so it costs nothing and can be pointed at any past run.

    bench/failures.py /tmp/golemide-exercism /tmp/golemide-constrained-*

Written because three A/Bs in a row moved cost and not pass rate, and an A/B cannot
explain that: it only sees what differs BETWEEN arms, and the thing that mattered was
in both. The question "where does this harness actually lose?" needs the failures
themselves.

## What it found, over 280 exercise-runs and 43 failures (2026-09-13)

    syntax gate — the code the model wrote is not valid in the language   41%
    ran out of attempts still failing tests — real capability             20%
    fragment — the whole-file protocol was violated                       13%
    edit refused on a path                                                13%
    stuck on the same failure                                              9%
    verify timed out                                                       9%

**The dominant failure is the model writing code the language rejects**, caught by the
syntax gate before any test runs. The two big categories are disjoint — 18 failures show
the syntax gate and no fragment, 6 show a fragment and no syntax gate, 0 show both — so
they are separate populations and not two views of one thing.

## The first version of this file got that backwards

It reported "55% edits rejected for shape" and named the whole-file edit protocol as the
harness's gap. That was a measurement error in this script, not a finding. The signature
included golemide's note `every edit was rejected for its shape`, which it emits when ALL
edits were refused **for any reason** — including a syntax-gate refusal, which is the
model writing bad code and has nothing to do with shape. Separating the two moves the
protocol from 55% to 13% and promotes the syntax gate from invisible to 41%.

The lesson is about the instrument, not the harness: a signature that matches a summary
line instead of the specific cause will attribute every failure to whichever cause the
summary was written for.

## And the size correlation was mostly a language correlation

    target file    runs   fragment   syntax gate   failed
    < 2 KB          155      2%          5%          9%
    2-6 KB           81     14%         11%          9%
    > 6 KB           44     18%         54%         47%

    language       runs   fragment   syntax gate   failed
    almide           79     12%         44%         29%
    rust             60     16%          6%         15%
    cpp             131      2%          1%          7%
    python           10     10%          0%         10%

The syntax gate tracks the failure rate across the size buckets (5/11/54 against 9/9/47);
fragment rejection does not (2/14/18). But the >6 KB bucket is mostly Almide exercises --
`grade-report` and `config-merger` are the two largest files in that corpus -- so size and
language are confounded here, and language is the stronger signal by a wide margin: 44%
syntax-gate on Almide against 0-6% everywhere else.

## What that means for the harness

On languages the model knows, this harness is already at 90%+ and its remaining failures
are mostly genuine capability: cpp fails 7% of runs with a 1% syntax-gate rate. The large
Almide gap is the model not knowing Almide -- it writes `||`, misuses `guard`, reaches for
`..` -- and that is a fluency problem the reference is meant to solve. The reference IS
being delivered whole (41,369 chars, under the 48,000 budget, verified unclipped), so
"send the reference" is already done and is not enough.

So the honest state: the whole-file protocol is worth fixing at 13% (and 18% above 6 KB),
and a replacement edit format is now implemented for it. But it is not the gap, and the
gap that remains on this corpus is not obviously the harness's to close.
"""

import collections
import glob
import os
import re
import sys

# Each signature names a SPECIFIC cause, never a summary line.
#
# `every edit was rejected for its shape` and `produced nothing usable` are both summaries
# — golemide prints them when every edit was refused for ANY reason — and matching them is
# what made the first version of this script blame the edit protocol for failures that
# were really the model writing invalid code. They are deliberately absent below.
SIGNATURES = [
    ("syntax gate — the code it wrote is invalid", r"apply rejected .*edit\.write:"),
    ("fragment — whole-file protocol violated", r"is a \d+-byte fragment"),
    ("edit refused on a path", r"does not exist \(creation not enabled\)|not among the files it was shown"),
    ("replacement did not apply", r"could not find this text in the file|appears more than once, so it does not say"),
    ("malformed edit JSON", r"malformed edit"),
    ("stuck on the same failure", r"same failure as attempt"),
    ("verify timed out", r"TIMED OUT|the command timed out"),
]


def rows_of(run_dir):
    """(exercise, result, log path) from a results.tsv, either benchmark's layout."""
    results = os.path.join(run_dir, "results.tsv")
    if not os.path.isfile(results):
        return
    for line in open(results, errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 4:
            continue
        # bench/almide.sh writes exercise first; bench/exercism.sh writes language first.
        if f[1] in ("PASS", "FAIL"):
            yield f[0], f[1], os.path.join(run_dir, f[0] + ".log")
        else:
            yield f[1], f[2], os.path.join(run_dir, f[0], f[1] + ".log")


def main(dirs):
    runs = []
    for d in dirs:
        for ex, res, log in rows_of(d):
            text = open(log, errors="replace").read() if os.path.isfile(log) else ""
            hits = {name for name, pat in SIGNATURES if re.search(pat, text)}
            runs.append((ex, res, hits, bool(text)))
    if not runs:
        print("no results.tsv found under: " + ", ".join(dirs), file=sys.stderr)
        return 2

    fails = [r for r in runs if r[1] == "FAIL"]
    print(f"exercise-runs {len(runs)}   failures {len(fails)}")
    if not fails:
        return 0

    print("\nfailure signatures (one run can show several):")
    counts = collections.Counter()
    for _, _, hits, had_log in fails:
        for h in hits:
            counts[h] += 1
        if not hits:
            counts["ran out of attempts still failing tests" if had_log else "(no log)"] += 1
    for name, n in counts.most_common():
        print(f"  {n:>3}/{len(fails)}  {100 * n // len(fails):>3}%  {name}")

    # The two causes worth separating, per exercise. Reported side by side because the
    # whole point of the correction above is that they are different problems.
    per = collections.defaultdict(lambda: [0, 0, 0])
    for ex, res, hits, _ in runs:
        a = per[ex]
        a[0] += 1
        a[1] += "fragment — whole-file protocol violated" in hits
        a[2] += "syntax gate — the code it wrote is invalid" in hits
    worst = sorted(per.items(), key=lambda kv: -(kv[1][1] + kv[1][2]))[:8]
    if any(f + s for _, (_, f, s) in worst):
        print(f"\n{'exercise':20}{'runs':>5}{'fragment':>10}{'syntax gate':>13}")
        for ex, (n, f, s) in worst:
            if f or s:
                print(f"  {ex:18}{n:>5}{f:>10}{s:>13}")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:] or sorted(glob.glob(os.path.expanduser("~/../../tmp/golemide-*")))
    sys.exit(main([a for a in args if os.path.isdir(a)]))
