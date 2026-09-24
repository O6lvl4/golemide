#!/usr/bin/env bash
# Runs inside the golemide-bench image: one arm, all of its runs, then what it changed.
#
#   run-arm.sh golemide@2     golemide with two attempts (the leaderboard's protocol)
#   run-arm.sh golemide@8     golemide with eight attempts, still on one model
#   run-arm.sh zcode          ZCode headless, one session per exercise
#   run-arm.sh comide         comide headless (`comide run --yes`), one session per exercise
#   run-arm.sh cursor         the Cursor CLI headless (`cursor-agent -p --force`), likewise
#
# MODEL, RUNS, JOBS, LANGS, CURSOR_MODEL and the credentials come from `docker run -e`.
# Results land under /out, which bench/container.sh mounts from the host.
set -uo pipefail

arm="$1"
name="$(printf '%s' "$arm" | tr '@' '-')"
export POLYGLOT=/polyglot
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"

# What an agent with a shell could have installed. Diffed after the arm, so a run that
# changed its own environment says so instead of quietly benefiting from it.
snapshot() {
  {
    dpkg-query -W -f='dpkg ${Package} ${Version}\n'
    python3 -m pip freeze 2>/dev/null | sed 's/^/pip /'
    npm ls -g --depth 0 --parseable 2>/dev/null | sed 's/^/npm /'
    ls /usr/local/bin /root/.cargo/bin 2>/dev/null | sed 's/^/bin /'
  } | sort
}
snapshot > "/tmp/$name.before"

case "$arm" in
  golemide@*)
    OUT="/out/$name" MODELS="${MODEL:-cf:glm-5.3-flash}" ATTEMPTS="${arm#golemide@}" \
      bash /opt/golemide/bench/leaderboard.sh ;;
  zcode)
    OUT=/out/zcode ZCODE=/opt/ZCode ZCODE_NODE=/opt/node24/bin/node ZCODE_HOME_DIR=/tmp/zcode-home \
      bash /opt/golemide/bench/zcode.sh ;;
  comide|cursor)
    OUT="/out/$arm" AGENT="$arm" bash /opt/golemide/bench/headless.sh ;;
  *) echo "unknown arm: $arm" >&2; exit 2 ;;
esac
status=$?

snapshot > "/tmp/$name.after"
if diff "/tmp/$name.before" "/tmp/$name.after" > "/out/$name.env-changes"; then
  echo "== $arm left the environment as it found it"
else
  echo "== $arm CHANGED the environment (see $name.env-changes):"
  sed 's/^/  /' "/out/$name.env-changes" | head -20
fi
exit "$status"
