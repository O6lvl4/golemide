#!/usr/bin/env bash
# golemide, comide, ZCode, the Cursor CLI and Aider on the polyglot benchmark, in one environment.
#
# The first comparison ran golemide on the host, Aider in Aider's Docker image and
# ZCode on the host again, and the environments differed in a way that decided
# exercises: the host had no Boost, so the two C++ exercises that link it failed at
# CMake configure under golemide, while Aider's image ships it — and ZCode, finding it
# missing, installed it on the host with Homebrew. This runs every agent inside the
# same image (Aider's benchmark image plus the agents, bench/container/Dockerfile), so
# the only thing that differs between arms is the agent, and no agent's shell can
# reach the machine it runs on.
#
#   bench/container.sh
#   ARMS="golemide@2 zcode" RUNS=3 bench/container.sh
#
#   ARMS      what to run, in order                (default: golemide@2 zcode golemide@8 aider)
#               golemide@N  golemide with N attempts, pinned to MODEL (no strong-model rung)
#               zcode       ZCode headless, 900 s per exercise, reasoning low
#               aider       Aider's own harness, two tries, diff format, reasoning low
#               comide      comide headless on its own defaults, 900 s per exercise
#               cursor      the Cursor CLI headless, CURSOR_MODEL or Cursor's default, 900 s per exercise
#   CURSOR_MODEL  for the cursor arm; empty = Cursor's default (auto)
#   MODEL     one model for every arm              (default: cf:glm-5.3-flash)
#   RUNS      runs per arm                         (default: 1)
#   JOBS      exercises in parallel                (default: 4)
#   LANGS     space-separated                      (default: all six)
#   OUT       results, logs and the build context  (default: $TMPDIR/golemide-container)
#   POLYGLOT  the benchmark checkout               (default: ../polyglot-benchmark)
#   ZCODE_SHA the ZCode commit to build            (default: the one first measured)
#   COMPANIONS_DIR  local clones of gramide-cli, hew, ctxgate and comide (default: ~/workspace/github.com/O6lvl4)
#   DRY_RUN=1 build the image and prove it, run no arm
#
# Time and money at the defaults, from the separate runs on 2026-09-22: golemide@2 about
# an hour and $0.50; ZCode about four hours and $5-10; golemide@8 and Aider about an
# hour and under $1 each.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARMS="${ARMS:-golemide@2 zcode golemide@8 aider}"
MODEL="${MODEL:-cf:glm-5.3-flash}"
RUNS="${RUNS:-1}"
JOBS="${JOBS:-4}"
LANGS="${LANGS:-cpp go java javascript python rust}"
OUT="${OUT:-${TMPDIR:-/tmp}/golemide-container}"
POLYGLOT="$(cd "${POLYGLOT:-$ROOT/../polyglot-benchmark}" 2>/dev/null && pwd)"
ZCODE_SHA="${ZCODE_SHA:-872ad960de7ec172591f7e1952f7849229f94521}"
COMPANIONS_DIR="${COMPANIONS_DIR:-$HOME/workspace/github.com/O6lvl4}"
IMAGE=golemide-bench
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }

# ---- preflight ----------------------------------------------------------------------------
echo "== preflight =="
docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 2; }
[ -n "$POLYGLOT" ] && [ -d "$POLYGLOT" ] || { echo "polyglot-benchmark not found" >&2; exit 2; }
# The same places golemide and comide read credentials from (src/envfile.almd).
for d in "$ROOT" "$PWD" "${XDG_CONFIG_HOME:-$HOME/.config}/golemide"; do
  [ -f "$d/.env" ] || continue
  [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ] && CLOUDFLARE_ACCOUNT_ID="$(sed -n 's/^CLOUDFLARE_ACCOUNT_ID=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
  [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && CLOUDFLARE_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
  [ -z "${CURSOR_API_KEY:-}" ] && CURSOR_API_KEY="$(sed -n 's/^CURSOR_API_KEY=//p' "$d/.env" | head -1 | tr -d '"'"'"' ')"
done
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "no CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN" >&2; exit 2; }
case " $ARMS " in *" cursor "*) [ -n "${CURSOR_API_KEY:-}" ] || { echo "the cursor arm needs CURSOR_API_KEY (environment, or a .env above)" >&2; exit 2; } ;; esac
export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN CURSOR_API_KEY="${CURSOR_API_KEY:-}"
mkdir -p "$OUT"
if ! docker image inspect aider-benchmark >/dev/null 2>&1; then
  echo "  building Aider's benchmark image first (bench/aider.sh, DRY_RUN)"
  DRY_RUN=1 bash "$ROOT/bench/aider.sh" || exit 2
fi

# ---- the build context: exactly what is being measured ------------------------------------------
CTX="$OUT/context"; rm -rf "$CTX"; mkdir -p "$CTX/golemide" "$CTX/comide" "$CTX/companions"
# golemide's working tree as it is, uncommitted changes included — that is what was
# measured on the host — minus the host binary and the README images.
( cd "$ROOT" && git ls-files -co --exclude-standard | grep -vx golemide | grep -v '^docs/images/' | tar -cf - -T - ) | tar -xf - -C "$CTX/golemide"
version="$(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- src bench || echo '+dirty')"
printf '%s\n' "$version" > "$CTX/golemide/.bench-version"
versions="golemide $version"
# comide the same way: its working tree as it is, minus the host binary and images.
COMIDE_DIR="${COMIDE_DIR:-$COMPANIONS_DIR/comide}"
( cd "$COMIDE_DIR" && git ls-files -co --exclude-standard | grep -vx comide | grep -v '^docs/images/' | tar -cf - -T - ) | tar -xf - -C "$CTX/comide"
cversion="$(git -C "$COMIDE_DIR" rev-parse --short HEAD)$(git -C "$COMIDE_DIR" diff --quiet HEAD -- src || echo '+dirty')"
printf '%s\n' "$cversion" > "$CTX/comide/.bench-version"
versions="$versions, comide $cversion"
# The gramide command is built from gramide-cli: gramide itself is the library and its
# language packages, and builds no command of its own any more.
for t in gramide hew ctxgate; do
  repo="$t"; [ "$t" = gramide ] && repo=gramide-cli
  mkdir -p "$CTX/companions/$t"
  if [ -d "$COMPANIONS_DIR/$repo/.git" ]; then
    git -C "$COMPANIONS_DIR/$repo" archive HEAD | tar -xf - -C "$CTX/companions/$t"
    versions="$versions, $repo $(git -C "$COMPANIONS_DIR/$repo" rev-parse --short HEAD)"
  else
    git clone -q --depth 1 "https://github.com/O6lvl4/$repo" "$CTX/companions/$t.git" && mv "$CTX/companions/$t.git"/* "$CTX/companions/$t/"
    versions="$versions, $repo $(git -C "$CTX/companions/$t.git" rev-parse --short HEAD) (fresh clone)"
  fi
done
cp "$ROOT/bench/container/Dockerfile" "$CTX/Dockerfile"
echo "  measuring: $versions, ZCode ${ZCODE_SHA:0:7}"

echo "== building $IMAGE (ZCode and the Almide tools compile here; the first build takes a while) =="
docker build --build-arg ZCODE_SHA="$ZCODE_SHA" -t "$IMAGE" "$CTX" > "$OUT/image-build.log" 2>&1 \
  || { tail -40 "$OUT/image-build.log"; exit 2; }
echo "  image $(docker image inspect "$IMAGE" --format '{{.Id}}' | cut -c8-19)"

# The exercise that exposed the difference, proven in the image before anything is paid for:
# its reference solution must configure against Boost, build and pass.
docker run --rm -v "$POLYGLOT":/polyglot:ro "$IMAGE" bash -c '
  cp -r /polyglot/cpp/exercises/practice/gigasecond /tmp/gigasecond && cd /tmp/gigasecond &&
  cp .meta/example.cpp gigasecond.cpp && cp .meta/example.h gigasecond.h &&
  cmake -B build -S . -DEXERCISM_RUN_ALL_TESTS=1 >/dev/null && cmake --build build >/dev/null && ./build/gigasecond' \
  > "$OUT/boost-check.log" 2>&1 || { echo "gigasecond reference does not build in the image:"; tail -20 "$OUT/boost-check.log"; exit 3; }
echo "  cpp/gigasecond reference builds against Boost and passes, in the image"
[ -n "${DRY_RUN:-}" ] && { echo "(DRY_RUN set; stopping before any arm)"; exit 0; }

# ---- the arms -------------------------------------------------------------------------------
for arm in $ARMS; do
  name="$(printf '%s' "$arm" | tr '@' '-')"
  echo "== $arm =="
  case "$arm" in
    aider)
      for run in $(seq 1 "$RUNS"); do
        dest="$OUT/aider/run-$run"
        [ -s "$dest/results.tsv" ] && { echo "  run $run: already has results"; continue; }
        alangs=""; [ "$LANGS" != "cpp go java javascript python rust" ] && alangs="$(printf '%s' "$LANGS" | tr ' ' ',')"
        MODEL="$MODEL" REASONING=low THREADS="$JOBS" LANGS="$alangs" POLYGLOT="$POLYGLOT" \
          bash "$ROOT/bench/aider.sh" 2>&1 | tee "$OUT/aider-run-$run.log" | grep -E '^==|^\| \*\*total'
        latest="$(ls -td "${TMPDIR:-/tmp}"/golemide-aider/aider/tmp.benchmarks/*--"$(slug "$MODEL")"-diff-* 2>/dev/null | head -1)"
        mkdir -p "$dest" && cp "$latest/results.tsv" "$dest/results.tsv" && echo "$latest" > "$dest/source"
      done ;;
    golemide@*|zcode|comide|cursor)
      docker run --rm --name "golemide-bench-$name" \
        -v "$POLYGLOT":/polyglot:ro -v "$OUT":/out \
        -e CLOUDFLARE_ACCOUNT_ID -e CLOUDFLARE_API_TOKEN -e CURSOR_API_KEY -e CURSOR_MODEL \
        -e MODEL="$MODEL" -e RUNS="$RUNS" -e JOBS="$JOBS" -e LANGS="$LANGS" \
        "$IMAGE" bash /opt/golemide/bench/container/run-arm.sh "$arm" 2>&1 \
        | tee "$OUT/$name.log" | grep -E '^==|^\| \*\*total|CHANGED|^  !!' ;;
    *) echo "  unknown arm $arm, skipped" ;;
  esac
done

# ---- one table for every arm ----------------------------------------------------------------------
python3 - "$OUT" "$(slug "$MODEL")" "$MODEL" "$versions" $ARMS <<'PY' | tee "$OUT/summary.md"
import sys, os, glob, collections, statistics
out, mslug, model, versions, arms = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
def results(arm):
    name = arm.replace("@", "-")
    if arm.startswith("golemide@"): pat = f"{out}/{name}/{mslug}/run-*/results.tsv"
    elif arm == "zcode": pat = f"{out}/zcode/{mslug}-low/run-*/results.tsv"
    elif arm in ("comide", "cursor"): pat = f"{out}/{arm}/run-*/results.tsv"
    else: pat = f"{out}/aider/run-*/results.tsv"
    runs = []
    for p in sorted(glob.glob(pat)):
        rows = {}
        for line in open(p):
            f = line.rstrip("\n").split("\t")
            if len(f) >= 6: rows[(f[0], f[1])] = (f[2] == "PASS", float(f[4] or 0))
        runs.append(rows)
    return runs
data = {a: results(a) for a in arms}
data = {a: r for a, r in data.items() if r}
if not data: print("no results"); sys.exit(0)
langs = sorted({k[0] for runs in data.values() for rows in runs for k in rows})
print(f"# Polyglot benchmark, one environment, {model}\n\n{versions}\n")
print("| language | " + " | ".join(data) + " |"); print("|---|" + "---|" * len(data))
def cell(runs, keep):
    solved = [sum(v[0] for k, v in rows.items() if keep(k)) for rows in runs]
    n = sum(1 for k in runs[0] if keep(k))
    spread = f" ({min(solved)}-{max(solved)})" if len(solved) > 1 else ""
    return f"{statistics.mean(solved):.0f}/{n} {statistics.mean(solved) / n * 100:.1f}%{spread}" if n else "-"
for lang in langs:
    print(f"| {lang} | " + " | ".join(cell(r, lambda k: k[0] == lang) for r in data.values()) + " |")
print("| **total** | " + " | ".join(f"**{cell(r, lambda k: True)}**" for r in data.values()) + " |")
print("| cost | " + " | ".join(f"${statistics.mean(sum(v[1] for v in rows.values()) for rows in r):.2f}" for r in data.values()) + " |")
changed = [a for a in data if a != "aider" and os.path.getsize(f"{out}/{a.replace('@', '-')}.env-changes") > 0] if data else []
print("\nEnvironment changed during the run by: " + (", ".join(changed) if changed else "none of the containerised arms") + ".")
print("Aider runs in its own copy of the same base image. Self-reported; runs per arm as shown.")
print("comide runs on cf:glm-5.3 with golemide's solve on cf:glm-5.3-flash; the cursor arm on Cursor's model (its cost is on Cursor's dashboard, not here).")
PY
echo "written: $OUT/summary.md"
