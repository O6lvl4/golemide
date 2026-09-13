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

    edits rejected for shape (fragment / whole-file protocol)   55%
    nothing usable produced (the same mechanism, overlapping)   48%
    ran out of attempts still failing tests — real capability   18%
    edit refused on a path                                      13%
    stuck on the same failure                                    9%
    verify timed out                                             9%

**The dominant failure is the harness refusing the model's answer for its shape, not
the model failing to solve the problem.** And it scales with the size of the file the
model has to reproduce:

    target file    runs   shape-rejected   failed
    < 2 KB          155        11%           9%
    2-6 KB           81        25%           9%
    > 6 KB           44        72%          47%

    grade-report   11,511 B   12 runs   12 shape-rejected   9 failed
    config-merger  10,907 B   12 runs   11 shape-rejected   6 failed

`edit_prompt` requires the whole file: "For each file you change, emit its COMPLETE new
contents ... A fragment, a single function, or a diff will be discarded." Above about
6 KB the model stops complying, and nearly half of those runs fail.

## The honest caveat

Large files are also harder, so size is confounded with difficulty and this is not proof
that the protocol causes the failures. Two things still point at the protocol. The
mechanism is visible rather than inferred — the log says the harness discarded the answer
for its shape, before any test ran. And the failure rate is identical (9%) in the two
smaller buckets while shape rejection more than doubles across them, so the jump to 47%
arrives together with shape rejection reaching 72% rather than tracking size smoothly.

## The lever this implies

A partial-edit format — search/replace blocks or a unified diff — instead of demanding
complete file contents. That is what this benchmark's own author uses: aider ships both a
"whole" and a "diff" edit format precisely because the choice moves the score, and the
diff format is the one used for large files. Testing it here means adding a second edit
format and running this census again; it is the measurement the next session should make,
and unlike prompt size it has not yet been ruled out.
"""

import collections
import glob
import os
import re
import sys

# Each signature is something the harness said about the answer, not a guess about it.
SIGNATURES = [
    ("edits rejected for shape", r"is a \d+-byte fragment|malformed edit|every edit was rejected for its shape"),
    ("edit refused on a path", r"does not exist \(creation not enabled\)|not among the files it was shown"),
    ("stuck on the same failure", r"same failure as attempt"),
    ("verify timed out", r"TIMED OUT|the command timed out"),
    ("nothing usable produced", r"produced nothing usable"),
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

    # Shape rejection against the size of what the model had to reproduce.
    per = collections.defaultdict(lambda: [0, 0])
    for ex, res, hits, _ in runs:
        a = per[ex]
        a[0] += 1
        a[1] += "edits rejected for shape" in hits
    worst = sorted(per.items(), key=lambda kv: -kv[1][1])[:8]
    if any(n for _, (_, n) in worst):
        print("\nexercises whose answers were most often refused for their shape:")
        for ex, (n, s) in worst:
            if s:
                print(f"  {s:>2}/{n:<3} {ex}")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:] or sorted(glob.glob(os.path.expanduser("~/../../tmp/golemide-*")))
    sys.exit(main([a for a in args if os.path.isdir(a)]))
