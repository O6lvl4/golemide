#!/usr/bin/env bash
# Aider on the same benchmark, same model, same protocol — the control arm.
#
# `bench/leaderboard.sh` gives golemide's number. Set next to Aider's public board it
# is agent+model against Aider+other-model, and nobody can say which half moved. This
# runs Aider's own benchmark harness (its Docker image, its edit loop, its pass_rate_2)
# with the model pointed at the same Cloudflare endpoint golemide uses, so the only
# thing that differs between the two numbers is the agent.
#
#   bench/aider.sh                         cf:glm-5.3-flash, diff format, 4 threads
#   MODEL=cf:glm-5.3 bench/aider.sh
#
#   MODEL        golemide's model name; mapped to Cloudflare's id   (default: cf:glm-5.3-flash)
#   EDIT_FORMAT  aider edit format; the board uses diff             (default: diff)
#   THREADS      exercises in parallel                              (default: 4)
#   TRIES        the board's protocol is 2                          (default: 2)
#   LANGS        comma-separated, or empty for all six              (default: all)
#   REASONING    reasoning effort passed to the model, or empty for the model's default
#                (golemide asks for "low" on its first attempts; leaving this empty is
#                what a board entry would do, and costs more tokens)
#   OUT          where the aider checkout and runs live             (default: $TMPDIR/golemide-aider)
#   AIDER_REF    aider git ref to check out                         (default: main; the commit is recorded)
#   DRY_RUN=1    set up and build the image, ask the model nothing
#
# Needs Docker running, the polyglot checkout, and CLOUDFLARE_ACCOUNT_ID /
# CLOUDFLARE_API_TOKEN in the environment or in one of the .env files golemide reads.
#
# Cost is computed here from the token counts Aider records, at the prices in
# src/llm.almd, because Aider does not know these models and would report $0.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${MODEL:-cf:glm-5.3-flash}"
EDIT_FORMAT="${EDIT_FORMAT:-diff}"
THREADS="${THREADS:-4}"
TRIES="${TRIES:-2}"
LANGS="${LANGS:-}"
REASONING="${REASONING:-}"
OUT="${OUT:-${TMPDIR:-/tmp}/golemide-aider}"
AIDER_REF="${AIDER_REF:-main}"
POLYGLOT="${POLYGLOT:-$ROOT/../polyglot-benchmark}"

# The same table as src/llm.almd: short name -> Cloudflare id, $/M input, $/M output.
cf_id() { case "${1#cf:}" in
  glm-5.3-flash) echo "@cf/zai-org/glm-5.3-flash" ;;
  glm-5.3)       echo "@cf/zai-org/glm-5.3" ;;
  deepseek-v4-flash-0731) echo "@cf/deepseek-ai/deepseek-v4-flash-0731" ;;
  gemma-4-26b)   echo "@cf/google/gemma-4-26b-a4b-it" ;;
  @cf/*)         echo "${1#cf:}" ;;
  *)             echo "@cf/${1#cf:}" ;;
esac; }
price() { case "${1#cf:}" in
  glm-5.3-flash) echo "0.15 0.5" ;;
  glm-5.3)       echo "1.4 4.4" ;;
  deepseek-v4-flash-0731) echo "0.44 1.32" ;;
  gemma-4-26b)   echo "0.1 0.3" ;;
  *)             echo "0 0" ;;
esac; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }

# ---- preflight ---------------------------------------------------------------------------
echo "== preflight =="
docker info >/dev/null 2>&1 || { echo "Docker is not running. Start it and try again." >&2; exit 2; }
[ -d "$POLYGLOT" ] || { echo "polyglot-benchmark not found at $POLYGLOT" >&2; exit 2; }
# Credentials, from the same places golemide's load_env looks.
for d in "$ROOT" "$PWD" "$HOME/workspace/github.com/O6lvl4/_agent" "$HOME/workspace/github.com/Aid-On/famulus5" "$HOME/workspace/github.com/Aid-On/famulus4"; do
  [ -f "$d/.env" ] || continue
  [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ] && CLOUDFLARE_ACCOUNT_ID="$(sed -n 's/^CLOUDFLARE_ACCOUNT_ID=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
  [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && CLOUDFLARE_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
done
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "no CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN" >&2; exit 2; }
API_BASE="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/v1"
CF_MODEL="$(cf_id "$MODEL")"
# One cheap call through the OpenAI-compatible path Aider will use, before anything is built.
probe="$(curl -sS -m 60 "$API_BASE/chat/completions" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$CF_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the word OK.\"}],\"max_completion_tokens\":512}")"
# 512, not 16: these models reason before they answer, and a tiny budget is spent
# entirely on the reasoning, which looks like an empty answer from a working endpoint.
printf '%s' "$probe" | grep -q '"choices"' || { echo "model probe failed for $CF_MODEL: $(printf '%s' "$probe" | head -c 300)" >&2; exit 2; }
echo "  $MODEL -> openai/$CF_MODEL via $API_BASE: ok"

# ---- aider checkout, benchmark tree, image ---------------------------------------------------
mkdir -p "$OUT"
AIDER="$OUT/aider"
if [ ! -d "$AIDER/.git" ]; then
  git clone -q https://github.com/Aider-AI/aider.git "$AIDER" || exit 2
fi
git -C "$AIDER" fetch -q origin "$AIDER_REF" && git -C "$AIDER" checkout -q FETCH_HEAD
AIDER_COMMIT="$(git -C "$AIDER" rev-parse --short HEAD)"
echo "  aider: $AIDER_COMMIT ($AIDER_REF)"
mkdir -p "$AIDER/tmp.benchmarks"
if [ ! -d "$AIDER/tmp.benchmarks/polyglot-benchmark" ]; then
  # A copy, not a symlink: the harness copies from it and Docker sees only the mount.
  cp -R "$POLYGLOT" "$AIDER/tmp.benchmarks/polyglot-benchmark"
fi
# Aider does not know this model. The settings file gives it the edit format and repo map
# the board's entries use; the metadata file gives it a context window so it does not guess.
cat > "$AIDER/.aider.model.settings.yml" <<YML
- name: openai/$CF_MODEL
  edit_format: $EDIT_FORMAT
  use_repo_map: true
  streaming: true
YML
cat > "$AIDER/.aider.model.metadata.json" <<JSON
{ "openai/$CF_MODEL": { "max_input_tokens": 128000, "max_output_tokens": 32000, "input_cost_per_token": 0, "output_cost_per_token": 0, "litellm_provider": "openai", "mode": "chat" } }
JSON
if ! docker image inspect aider-benchmark >/dev/null 2>&1; then
  echo "== building the aider-benchmark image (once; several minutes) =="
  ( cd "$AIDER" && ./benchmark/docker_build.sh ) || exit 2
fi
[ -n "${DRY_RUN:-}" ] && { echo "(DRY_RUN set; stopping before any model is asked)"; exit 0; }

# ---- the run ----------------------------------------------------------------------------------
NAME="$(slug "$MODEL")-$EDIT_FORMAT-$(date +%Y%m%d-%H%M)"
echo "== running: $NAME =="
docker run --rm \
  --memory=12g --memory-swap=12g \
  -v "$AIDER":/aider \
  -v "$AIDER/tmp.benchmarks/.":/benchmarks \
  -e OPENAI_API_KEY="$CLOUDFLARE_API_TOKEN" \
  -e OPENAI_API_BASE="$API_BASE" \
  -e AIDER_DOCKER=1 \
  -e AIDER_BENCHMARK_DIR=/benchmarks \
  aider-benchmark \
  bash -c "pip install -q -e '.[dev]' >/dev/null 2>&1; ./benchmark/benchmark.py '$NAME' \
    --model 'openai/$CF_MODEL' --edit-format '$EDIT_FORMAT' --threads '$THREADS' --tries '$TRIES' \
    --read-model-settings .aider.model.settings.yml --exercises-dir polyglot-benchmark --new \
    ${LANGS:+--languages '$LANGS'} ${REASONING:+--reasoning-effort '$REASONING'}" 2>&1 | tee "$OUT/$NAME.log" | grep -vE '^\s*$' | tail -40

RUN_DIR="$(ls -d "$AIDER"/tmp.benchmarks/*--"$NAME" 2>/dev/null | head -1)"
[ -n "$RUN_DIR" ] || { echo "no run directory for $NAME under $AIDER/tmp.benchmarks" >&2; exit 1; }

# ---- the table, in the same shape as leaderboard.sh's ------------------------------------------
read -r PIN POUT <<< "$(price "$MODEL")"
python3 - "$RUN_DIR" "$MODEL" "$AIDER_COMMIT" "$EDIT_FORMAT" "$TRIES" "$PIN" "$POUT" <<'PY' | tee "$RUN_DIR/summary.md"
import sys, json, glob, os, collections, statistics
run, model, commit, fmt, tries, pin, pout = sys.argv[1:8]
pin, pout = float(pin) / 1e6, float(pout) / 1e6
by = collections.defaultdict(lambda: {"n": 0, "pass": [0] * int(tries), "cost": 0.0, "wall": [], "timeouts": 0, "malformed": 0})
for path in glob.glob(os.path.join(run, "*", "exercises", "practice", "*", ".aider.results.json")):
    lang = path.split(os.sep)[-5]
    r = json.load(open(path))
    b = by[lang]; b["n"] += 1
    outcomes = r.get("tests_outcomes", [])
    for i in range(int(tries)):
        if any(outcomes[: i + 1]): b["pass"][i] += 1
    b["cost"] += r.get("prompt_tokens", 0) * pin + r.get("completion_tokens", 0) * pout
    b["wall"].append(r.get("duration", 0)); b["timeouts"] += r.get("test_timeouts", 0); b["malformed"] += r.get("num_malformed_responses", 0)
print(f"# Aider {commit} on the polyglot benchmark, {tries} tries, {fmt} format, {model}\n")
print("| language | solved (pass_rate_2) | rate | pass_rate_1 | cost | median wall | test timeouts | malformed |")
print("|---|---|---|---|---|---|---|---|")
tn = 0; tp = [0] * int(tries); tc = 0.0
for lang in sorted(by):
    b = by[lang]; n = b["n"]; last = b["pass"][-1]
    print(f"| {lang} | {last}/{n} | {last / n * 100:.1f}% | {b['pass'][0] / n * 100:.1f}% | ${b['cost']:.3f} | {statistics.median(b['wall']) if b['wall'] else 0:.0f}s | {b['timeouts']} | {b['malformed']} |")
    tn += n; tc += b["cost"]
    for i in range(int(tries)): tp[i] += b["pass"][i]
if tn:
    print(f"| **total** | **{tp[-1]}/{tn}** | **{tp[-1] / tn * 100:.1f}%** | {tp[0] / tn * 100:.1f}% | **${tc:.3f}** | | | |")
print(f"\nCost is tokens x the prices in src/llm.almd (${float(sys.argv[6])}/M in, ${float(sys.argv[7])}/M out); Aider itself reports $0 for a model it does not know. Self-reported, one run.")
PY
# The same row format as bench/exercism.sh's results.tsv, so every arm reads alike.
python3 - "$RUN_DIR" "$PIN" "$POUT" > "$RUN_DIR/results.tsv" <<'PY'
import sys, glob, json, os
run, pin, pout = sys.argv[1], float(sys.argv[2]) / 1e6, float(sys.argv[3]) / 1e6
for f in sorted(glob.glob(os.path.join(run, "*", "exercises", "practice", "*", ".aider.results.json"))):
    r = json.load(open(f)); parts = f.split(os.sep); o = r.get("tests_outcomes", [])
    cost = r.get("prompt_tokens", 0) * pin + r.get("completion_tokens", 0) * pout
    print("\t".join([parts[-5], parts[-2], "PASS" if any(o) else "FAIL", str(len(o)), f"{cost:.6f}", f"{r.get('duration', 0):.0f}s"]))
PY
echo "aider's own stats: (cd $AIDER && ./benchmark/benchmark.py --stats $(basename "$RUN_DIR"))"
echo "written: $RUN_DIR/summary.md   per-exercise: $RUN_DIR/<lang>/exercises/practice/<exercise>/.aider.results.json"
