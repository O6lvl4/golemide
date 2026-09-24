#!/usr/bin/env bash
# A headless coding agent on the polyglot benchmark: comide or the Cursor CLI.
#
# Both are tool-calling agents that read, edit and run commands until they decide they
# are done, so they get the protocol ZCode got (bench/zcode.sh): the task text and the
# verify command, one session per exercise, a wall-clock cap in place of an attempt
# count. The harness is bench/exercism.sh with BENCH_AGENT pointing at the adapter
# below: same stripped exercise, same verify command, same independent re-check.
#
#   AGENT=comide bench/headless.sh
#   AGENT=cursor bench/headless.sh
#   AGENT=cursor CURSOR_MODEL=sonnet-4 RUNS=3 LANGS="rust python" bench/headless.sh
#
#   AGENT         comide or cursor                              (required)
#   CURSOR_MODEL  passed to cursor-agent --model; empty = Cursor's default (auto)
#   WALL          seconds one exercise may take before the agent is stopped (default: 900)
#   HIDE_VERIFY   1 = the prompt does not name the verify command: the agent has to find
#                 out for itself how to check its work, as it would from a person's request
#   RUNS / LANGS / JOBS / OUT / POLYGLOT   as in leaderboard.sh
#
# comide runs on its own defaults (cf:glm-5.3 for the conversation, golemide's
# cf:glm-5.3-flash behind `solve`) with --yes, and needs the Cloudflare credentials.
# Cursor needs CURSOR_API_KEY; it runs --force, so, as with ZCode, run it in the
# container (bench/container.sh), not on your machine.
#
# Cost: comide prints the session's cost, golemide's solve included, and that is what
# the row records. Cursor bills to the account behind the key; the row records the cost
# only if the CLI's JSON reports one, and $0 otherwise — read Cursor's dashboard for it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="${AGENT:-}"
CURSOR_MODEL="${CURSOR_MODEL:-}"
WALL="${WALL:-900}"
HIDE_VERIFY="${HIDE_VERIFY:-0}"
RUNS="${RUNS:-1}"
LANGS="${LANGS:-cpp go java javascript python rust}"
JOBS="${JOBS:-4}"
OUT="${OUT:-${TMPDIR:-/tmp}/golemide-$AGENT}"
export POLYGLOT="${POLYGLOT:-$ROOT/../polyglot-benchmark}"
export VERIFY_DEADLINE="${VERIFY_DEADLINE:-600}"

# ---- the adapter: what bench/exercism.sh calls per exercise -------------------------------
# Invoked as `headless.sh --agent <task> <dir> <verify-command> <attempts>`.
if [ "${1:-}" = "--agent" ]; then
  task="$2"; dir="$3"; verify="$4"
  started=$(date +%s)
  if [ "$HIDE_VERIFY" = 1 ]; then
    # The harness still re-checks with $verify afterwards; the agent is not told it.
    prompt="$task

The code to change is in the current directory. Do not modify the test files."
  else
    prompt="$task

The code to change is in the current directory. Run \`$verify\` to check your work, and keep working until it passes. Do not modify the test files. When it passes, stop."
  fi
  echo "[edit] attempt 1/1 ($AGENT, wall cap ${WALL}s)"
  out="$dir.$AGENT.out"; err="$dir.$AGENT.err"
  # A group of its own, so the wall cap stops the agent and everything it started.
  case "$AGENT" in
    comide)
      # The cost so far, written by comide after every step: a comide stopped at the
      # wall cap prints no footer.
      rm -f "$dir.$AGENT.cost"
      COMIDE_COST_FILE="$dir.$AGENT.cost" setsid bash -c 'cd "$1" && exec comide run "$2" --yes --root "$1"' _ "$dir" "$prompt" > "$out" 2> "$err" & ;;
    cursor)
      model_flag=(); [ -n "$CURSOR_MODEL" ] && model_flag=(--model "$CURSOR_MODEL")
      setsid bash -c 'cd "$1" && shift && exec cursor-agent -p --force --output-format json "$@"' _ "$dir" "${model_flag[@]}" "$prompt" > "$out" 2> "$err" & ;;
    *) echo "unknown AGENT: $AGENT"; exit 2 ;;
  esac
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$WALL" ]; then
      kill -TERM -- "-$pid" 2>/dev/null; sleep 3; kill -KILL -- "-$pid" 2>/dev/null
      echo "  note: stopped at the ${WALL}s wall cap"
      break
    fi
    sleep 2; waited=$((waited + 2))
  done
  wait "$pid" 2>/dev/null; rc=$?
  echo "  $AGENT exit $rc"
  [ -s "$err" ] && { echo "  stderr (tail):"; tail -c 3000 "$err" | sed 's/^/    /'; }
  python3 - "$AGENT" "$out" "$err" <<'PY'
import json, re, sys
agent, out, err = sys.argv[1:4]
text = open(out, errors="replace").read()
cost = 0.0
if agent == "comide":
    # The footer comide prints after the turn: "... · $0.0123 · session $0.0123".
    found = re.findall(r"session \$([0-9]+\.[0-9]+)", open(err, errors="replace").read())
    if found: cost = float(found[-1])
    else:
        try: cost = float(open(out[:-len(".out")] + ".cost").read().strip().lstrip("$"))
        except Exception: pass
    print("  response: " + text.strip()[:300].replace("\n", " "))
else:
    try:
        r = json.loads(text.strip().splitlines()[-1]) if text.strip() else {}
    except Exception as e:
        r = {}; print(f"  no usable JSON output ({e})")
    for key in ("total_cost_usd", "cost_usd", "costUsd"):
        if isinstance(r.get(key), (int, float)): cost = float(r[key])
    usage = r.get("usage") or {}
    if usage: print("  usage: " + json.dumps(usage)[:300])
    print("  response: " + str(r.get("result") or r.get("response") or "")[:300].replace("\n", " "))
print(f"  cost ${cost:.6f}")
PY
  echo "wall $(( $(date +%s) - started ))s"
  exit 0
fi

# ---- preflight ---------------------------------------------------------------------------
echo "== preflight =="
case "$AGENT" in
  comide) command -v comide >/dev/null && command -v golemide >/dev/null || { echo "comide and golemide must be on PATH" >&2; exit 2; }
          [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "no CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN" >&2; exit 2; }
          version="comide $(cat /opt/comide/.bench-version 2>/dev/null || echo '?'), $(golemide --version)" ;;
  cursor) command -v cursor-agent >/dev/null || { echo "cursor-agent is not on PATH" >&2; exit 2; }
          [ -n "${CURSOR_API_KEY:-}" ] || { echo "no CURSOR_API_KEY" >&2; exit 2; }
          version="cursor-agent $(cursor-agent --version 2>&1 | head -1), model ${CURSOR_MODEL:-default}" ;;
  *) echo "AGENT must be comide or cursor" >&2; exit 2 ;;
esac
[ -d "$POLYGLOT" ] || { echo "polyglot-benchmark not found at $POLYGLOT" >&2; exit 2; }
echo "  $version"
mkdir -p "$OUT"; printf '%s\n' "$version" > "$OUT/version"
export AGENT CURSOR_MODEL WALL HIDE_VERIFY

for run in $(seq 1 "$RUNS"); do
  work="$OUT/run-$run"
  if [ -s "$work/results.tsv" ]; then echo "== run $run: already has results, skipping (rm -r $work to redo)"; continue; fi
  echo "== $AGENT run $run/$RUNS -> $work =="
  mkdir -p "$work"
  # The harness runs BENCH_AGENT with the four arguments only, so `--agent` comes from
  # a wrapper; without it this script would re-enter its driver once per exercise.
  agent="$OUT/$AGENT-agent.sh"
  printf '#!/usr/bin/env bash\nexec bash %q --agent "$@"\n' "$ROOT/bench/headless.sh" > "$agent"; chmod +x "$agent"
  BENCH_AGENT="$agent" BENCH_ATTEMPTS=1 BENCH_JOBS="$JOBS" BENCH_WORK="$work" \
    bash "$ROOT/bench/exercism.sh" $LANGS 2>&1 | tee "$work.log" | grep -vE '^\s*$'
done

python3 - "$OUT" "$AGENT" "$(cat "$OUT/version")" "$WALL" <<'PY' | tee "$OUT/summary.md"
import sys, os, glob, collections, statistics
base, agent, version, wall = sys.argv[1:5]
runs = sorted(glob.glob(os.path.join(base, "run-*", "results.tsv")))
print(f"# {agent} on the polyglot benchmark, one session per exercise with the verify command, {wall}s wall cap\n\n{version}\n")
per_run = []
for path in runs:
    by = collections.defaultdict(lambda: [0, 0, 0.0, []])
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if len(f) < 6: continue
        lang, _ex, res, _att, cost, w = f[:6]
        b = by[lang]; b[0] += res == "PASS"; b[1] += 1; b[2] += float(cost or 0)
        if w.rstrip("s").isdigit(): b[3].append(int(w.rstrip("s")))
    per_run.append(by)
if not per_run: print("no results"); sys.exit(0)
print("| language | solved | rate | cost | median wall |"); print("|---|---|---|---|---|")
tp = tn = 0; tc = 0.0
for lang in sorted({l for by in per_run for l in by}):
    p = [by[lang][0] for by in per_run if lang in by]; n = per_run[0][lang][1]
    c = [by[lang][2] for by in per_run if lang in by]; w = [x for by in per_run if lang in by for x in by[lang][3]]
    print(f"| {lang} | {statistics.mean(p):.1f}/{n} | {statistics.mean(p) / n * 100:.1f}% | ${statistics.mean(c):.3f} | {statistics.median(w) if w else 0:.0f}s |")
    tp += statistics.mean(p); tn += n; tc += statistics.mean(c)
print(f"| **total** | **{tp:.1f}/{tn}** | **{tp / tn * 100:.1f}%** | **${tc:.3f}** | |")
PY
