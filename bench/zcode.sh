#!/usr/bin/env bash
# ZCode on the same benchmark, same model, same harness — the second control arm.
#
# ZCode (zai-org/ZCode) is a tool-calling agent: given a task and a directory it reads,
# edits and runs commands in a loop until it decides it is done. There is no "two
# tries" in that shape, so the protocol here is the one golemide is given — the task
# text and the verify command — with a wall-clock cap in place of an attempt count.
# The harness is bench/exercism.sh with BENCH_AGENT pointing at the adapter below:
# same stripped exercise, same verify command, same independent re-check.
#
#   bench/zcode.sh                       cf:glm-5.3-flash, all six languages, one run
#   MODEL=cf:glm-5.3 RUNS=3 bench/zcode.sh
#
#   ZCODE        the ZCode checkout, built (`pnpm --filter '@zcode/cli...' build`)
#                (default: $TMPDIR/golemide-zcode/ZCode, cloned and built if absent)
#   MODEL        golemide's model name; mapped to Cloudflare's id   (default: cf:glm-5.3-flash)
#   REASONING    ZCode's reasoningLevel for the model: low, high, max (default: low)
#   WALL         seconds one exercise may take before ZCode is stopped (default: 900)
#   RUNS / LANGS / JOBS / OUT / POLYGLOT   as in leaderboard.sh
#   ZCODE_NODE   the node binary to run ZCode with     (default: `mise exec -- node`)
#   ZCODE_HOME_DIR  where the provider file with the key goes (default: $OUT/home)
#   DRY_RUN=1    build and probe the model, run no exercise
#
# Needs Node 24 and pnpm (mise installs ZCode's pinned versions from its mise.toml),
# the polyglot checkout, and Cloudflare credentials as for bench/aider.sh.
#
# Run it in a container, not on your machine. ZCode headless is `yolo`: its Bash tool
# runs anything, and on 2026-09-22 it met a C++ exercise whose CMake build needed
# Boost, found Boost missing, and ran `brew install boost` on the host. That is a
# change to the machine outside the exercise, and it also changes the benchmark under
# every other arm: golemide had run on that host earlier and failed both Boost
# exercises at CMake configure, while Aider ran in its Docker image, which ships Boost.
# The fair setup is all three agents in one image with every toolchain installed.
#
# What to know before reading the number: every ZCode request carries its system
# prompt and tool schemas, about 30,000 input tokens, and this endpoint reported no
# cache reads — so the cost is real and an order of magnitude above golemide's for
# the same model. The API key is written as a literal into a 0600 file under OUT,
# because ZCode's provider config has no environment-variable expansion.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${MODEL:-cf:glm-5.3-flash}"
REASONING="${REASONING:-low}"
WALL="${WALL:-900}"
RUNS="${RUNS:-1}"
LANGS="${LANGS:-cpp go java javascript python rust}"
JOBS="${JOBS:-4}"
OUT="${OUT:-${TMPDIR:-/tmp}/golemide-zcode}"
ZCODE="${ZCODE:-$OUT/ZCode}"
export POLYGLOT="${POLYGLOT:-$ROOT/../polyglot-benchmark}"
export VERIFY_DEADLINE="${VERIFY_DEADLINE:-600}"

cf_id() { case "${1#cf:}" in
  glm-5.3-flash) echo "@cf/zai-org/glm-5.3-flash" ;;
  glm-5.3)       echo "@cf/zai-org/glm-5.3" ;;
  deepseek-v4-flash-0731) echo "@cf/deepseek-ai/deepseek-v4-flash-0731" ;;
  gemma-4-26b)   echo "@cf/google/gemma-4-26b-a4b-it" ;;
  @cf/*)         echo "${1#cf:}" ;;
  *)             echo "@cf/${1#cf:}" ;;
esac; }
# $/M input, $/M output, $/M cached input — the same three columns as src/llm.almd.
price() { case "${1#cf:}" in
  glm-5.3-flash) echo "0.15 0.5 0.03" ;;
  glm-5.3)       echo "1.4 4.4 0.26" ;;
  deepseek-v4-flash-0731) echo "0.44 1.32 0.014" ;;
  gemma-4-26b)   echo "0.1 0.3 0.1" ;;
  *)             echo "0 0 0" ;;
esac; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }

# ---- the adapter: what bench/exercism.sh calls per exercise -------------------------------
# Invoked as `zcode.sh --agent <task> <dir> <verify-command> <attempts>` with the
# environment the driver prepared. Prints what the harness's results row expects.
if [ "${1:-}" = "--agent" ]; then
  task="$2"; dir="$3"; verify="$4"
  started=$(date +%s)
  read -r PIN POUT PCACHED <<< "$(price "$MODEL")"
  prompt="$task

The code to change is in the current directory. Run \`$verify\` to check your work, and keep working until it passes. Do not modify the test files. When it passes, stop."
  echo "[edit] attempt 1/1 (zcode, wall cap ${WALL}s)"
  out="$dir.zcode.json"
  # Its own session store per exercise: four ZCode processes sharing one SQLite file
  # is not a thing to find out about mid-run.
  ( cd "$ZCODE" && ZCODE_SESSION_DB_PATH="$dir.zcode.sqlite" ZCODE_STORAGE_DIR="$dir.zcode-storage" \
      ${ZCODE_NODE:-mise exec -- node} "$ZCODE/apps/zcode-cli/packages/cli/dist/zcode.cjs" \
      --cwd "$dir" --mode yolo --output-format json -p "$prompt" > "$out" 2> "$dir.zcode.stderr" ) &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$WALL" ]; then
      kill -TERM "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null
      echo "  note: stopped at the ${WALL}s wall cap"
      break
    fi
    sleep 2; waited=$((waited + 2))
  done
  wait "$pid" 2>/dev/null; rc=$?
  echo "  zcode exit $rc"
  [ -s "$dir.zcode.stderr" ] && { echo "  stderr:"; head -c 2000 "$dir.zcode.stderr" | sed 's/^/    /'; }
  python3 - "$out" "$PIN" "$POUT" "$PCACHED" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  no usable JSON output ({e})"); print("  cost $0.000000"); sys.exit(0)
u = r.get("usage", {})
i, o, c = u.get("inputTokens", 0), u.get("outputTokens", 0), u.get("cacheReadTokens", 0)
# Cached input is billed at the cached rate, as golemide bills its own runs.
cost = max(i - c, 0) * float(sys.argv[2]) / 1e6 + c * float(sys.argv[4]) / 1e6 + o * float(sys.argv[3]) / 1e6
print(f"  requests={u.get('modelRequestCount', 0)} in={i} out={o} cache_read={c} turns={r.get('projection', {}).get('turnCount', 0)}")
print("  response: " + (r.get("response") or "")[:300].replace("\n", " "))
print(f"  cost ${cost:.6f}")
PY
  echo "wall $(( $(date +%s) - started ))s"
  exit 0
fi

# ---- preflight ---------------------------------------------------------------------------
echo "== preflight =="
[ -d "$POLYGLOT" ] || { echo "polyglot-benchmark not found at $POLYGLOT" >&2; exit 2; }
[ -n "${ZCODE_NODE:-}" ] || command -v mise >/dev/null || { echo "mise is needed for ZCode's pinned Node and pnpm (or set ZCODE_NODE)" >&2; exit 2; }
for d in "$ROOT" "$PWD" "$HOME/workspace/github.com/O6lvl4/_agent" "$HOME/workspace/github.com/Aid-On/famulus5" "$HOME/workspace/github.com/Aid-On/famulus4"; do
  [ -f "$d/.env" ] || continue
  [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ] && CLOUDFLARE_ACCOUNT_ID="$(sed -n 's/^CLOUDFLARE_ACCOUNT_ID=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
  [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && CLOUDFLARE_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
done
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "no CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN" >&2; exit 2; }
CF_MODEL="$(cf_id "$MODEL")"
mkdir -p "$OUT"

if [ ! -f "$ZCODE/apps/zcode-cli/packages/cli/dist/zcode.cjs" ]; then
  [ -d "$ZCODE/.git" ] || git clone -q --depth 1 https://github.com/zai-org/ZCode "$ZCODE" || exit 2
  echo "== building the ZCode CLI (once; a few minutes) =="
  ( cd "$ZCODE" && mise install -q && mise exec -- pnpm install --filter '@zcode/cli...' >/dev/null && mise exec -- pnpm --filter '@zcode/cli...' build >/dev/null ) || { echo "ZCode build failed" >&2; exit 2; }
fi
echo "  zcode: $(git -C "$ZCODE" rev-parse --short HEAD) at $ZCODE"

# The provider file: ZCode's own schema, the key as a literal, 0600. Both env vars
# below are set explicitly, which is also what stops ZCode fetching its built-in
# provider list from its vendor at startup.
# In a container this is a path the host never sees: the file holds the API key.
HOME_DIR="${ZCODE_HOME_DIR:-$OUT/home}"; mkdir -p "$HOME_DIR/.zcode/v2"
PROVIDER_FILE="$HOME_DIR/.zcode/v2/provider_config.json"
umask 077
cat > "$PROVIDER_FILE" <<JSON
{
  "schemaVersion": 1,
  "config": {
    "providerOrder": ["cloudflare-ai"],
    "providerConfigRules": { "providerRules": [ {
      "providerId": "cloudflare-ai", "providerName": "Cloudflare Workers AI", "enabled": true,
      "config": {
        "group": "standard-personal",
        "access": { "type": "api-key", "apiKey": "$CLOUDFLARE_API_TOKEN" },
        "api": { "type": "openai-chat-completions", "baseUrl": "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/v1" },
        "personalModelIds": ["$CF_MODEL"], "modelOrder": ["$CF_MODEL"]
      } } ] },
    "modelConfigRules": {
      "providerModelRules": [ { "providerId": "cloudflare-ai", "modelId": "$CF_MODEL",
        "config": { "enabled": true, "properties": { "contextWindow": 131072, "supportsToolCall": true } } } ],
      "manualProviderModelRules": []
    },
    "defaultModelSelection": { "providerId": "cloudflare-ai", "modelId": "$CF_MODEL", "options": { "reasoningLevel": "$REASONING" } }
  }
}
JSON
umask 022
export ZCODE MODEL WALL ZCODE_NODE
export ZCODE_DATA_BASE_DIR="$HOME_DIR"
export ZCODE_BUILTIN_PROVIDER_CONFIG_FILE="$ZCODE/config/provider/zcode-builtin.json"
export ZCODE_PERSONAL_PROVIDER_CONFIG_FILE="$PROVIDER_FILE"
export ZCODE_MODEL_TELEMETRY_ENABLED=0

# One cheap headless prompt through the real path before paying for anything.
probe_dir="$OUT/_probe"; rm -rf "$probe_dir"; mkdir -p "$probe_dir"
probe="$(cd "$ZCODE" && ZCODE_SESSION_DB_PATH="$probe_dir.sqlite" ZCODE_STORAGE_DIR="$probe_dir-storage" ${ZCODE_NODE:-mise exec -- node} "$ZCODE/apps/zcode-cli/packages/cli/dist/zcode.cjs" --cwd "$probe_dir" --mode yolo --output-format json -p "Reply with exactly the word OK." 2>&1)"
printf '%s' "$probe" | grep -q '"response"' || { echo "ZCode probe failed: $(printf '%s' "$probe" | head -c 400)" >&2; exit 2; }
echo "  $MODEL as $CF_MODEL, reasoning $REASONING: $(printf '%s' "$probe" | python3 -c 'import sys,json; r=json.load(sys.stdin); print("response=%r in=%d out=%d" % (r["response"], r["usage"]["inputTokens"], r["usage"]["outputTokens"]))')"
[ -n "${DRY_RUN:-}" ] && { echo "(DRY_RUN set; stopping before any exercise)"; exit 0; }

# ---- the runs, through the shared harness --------------------------------------------------
for run in $(seq 1 "$RUNS"); do
  work="$OUT/$(slug "$MODEL")-$REASONING/run-$run"
  if [ -s "$work/results.tsv" ]; then echo "== run $run: already has results, skipping (rm -r $work to redo)"; continue; fi
  echo "== $MODEL run $run/$RUNS -> $work =="
  mkdir -p "$work"
  # The harness runs BENCH_AGENT with the four arguments and nothing else, so the
  # `--agent` switch has to come from a wrapper. Without it this script re-enters its
  # driver path once per exercise, which is a fork bomb — found the first time.
  agent="$OUT/zcode-agent.sh"
  printf '#!/usr/bin/env bash\nexec bash %q --agent "$@"\n' "$ROOT/bench/zcode.sh" > "$agent"; chmod +x "$agent"
  BENCH_AGENT="$agent" BENCH_ATTEMPTS=1 BENCH_JOBS="$JOBS" BENCH_WORK="$work" \
    bash "$ROOT/bench/exercism.sh" $LANGS 2>&1 | tee "$work.log" | grep -vE '^\s*$'
done

# ---- the table ----------------------------------------------------------------------------
python3 - "$OUT/$(slug "$MODEL")-$REASONING" "$MODEL" "$REASONING" "$(git -C "$ZCODE" rev-parse --short HEAD)" "$WALL" <<'PY' | tee "$OUT/summary-$(slug "$MODEL")-$REASONING.md"
import sys, os, glob, collections, statistics
base, model, reasoning, commit, wall = sys.argv[1:6]
runs = sorted(glob.glob(os.path.join(base, "run-*", "results.tsv")))
print(f"# ZCode {commit} on the polyglot benchmark, one session per exercise with the verify command, {wall}s wall cap, {model} at reasoning {reasoning}\n")
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
print(f"({len(per_run)} run{'s' if len(per_run) > 1 else ''})\n")
print("| language | solved | rate | cost | median wall |"); print("|---|---|---|---|---|")
langs = sorted({l for by in per_run for l in by}); tp = tn = 0; tc = 0.0
for lang in langs:
    p = [by[lang][0] for by in per_run if lang in by]; n = per_run[0][lang][1]
    c = [by[lang][2] for by in per_run if lang in by]; w = [x for by in per_run if lang in by for x in by[lang][3]]
    spread = f" ({min(p)}–{max(p)})" if len(p) > 1 else ""
    print(f"| {lang} | {statistics.mean(p):.1f}/{n}{spread} | {statistics.mean(p) / n * 100:.1f}% | ${statistics.mean(c):.3f} | {statistics.median(w) if w else 0:.0f}s |")
    tp += statistics.mean(p); tn += n; tc += statistics.mean(c)
print(f"| **total** | **{tp:.1f}/{tn}** | **{tp / tn * 100:.1f}%** | **${tc:.3f}** | |")
if len(per_run) > 1:
    print(f"\nper-run totals: {', '.join(str(sum(b[0] for b in by.values())) for by in per_run)} of {tn}")
print("\nCost is ZCode's reported token usage x the prices in src/llm.almd. Self-reported.")
PY
echo "logs: $OUT/<model>-<reasoning>/run-N/<lang>/<exercise>.log (ZCode's JSON beside each as <exercise>.zcode.json)"
