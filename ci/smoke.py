"""Exercise the built CLI without network or model credentials."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

BIN = Path(__file__).resolve().parents[1] / "golemide"

def run(*args, code=0, stdin=None, env=None):
    p = subprocess.run([str(BIN), *map(str, args)], capture_output=True, text=True, timeout=30,
                       input=stdin, env=env)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout

assert "golemide solve" in run("help")
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "main.py").write_text("def real():\n    return 1\n")
    for command, expected in [("exit 0", "baseline: exit 0"), ("exit 1", "baseline: exit 1")]:
        output = run("observe", "--root", root, "--verify", command)
        assert "main.py" in output and expected in output, output
print("CLI smoke passed: observation preserves passing and failing verification results")

# `golemide edit` is the tool form: one edit on stdin, one JSON object on stdout.
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "calc.py").write_text("def total(xs):\n    s = 0\n    return s\n")
    def edit(request, code, *flags):
        return json.loads(run("edit", "--root", root, *flags, code=code, stdin=json.dumps(request)))
    done = edit({"path": str(root / "calc.py"), "replacements": [{"old": "return s", "new": "return s + 1"}]}, 0)
    assert done["ok"] and done["path"] == "calc.py" and "+     return s + 1" in done["diff"], done
    assert (root / "calc.py").read_text().endswith("return s + 1\n")
    gate = edit({"path": "calc.py", "replacements": [{"old": "return s + 1", "new": "return (s"}]}, 1)
    assert "syntax gate" in gate["error"] and (root / "calc.py").read_text().endswith("return s + 1\n"), gate
    assert "outside the project root" in edit({"path": "../x.py", "source": "x = 1\n"}, 1)["error"]
    assert "--create" in edit({"path": "new.py", "source": "x = 1\n"}, 1)["error"]
    assert edit({"path": "new.py", "source": "x = 1\n"}, 0, "--create")["ok"]
    assert json.loads(run("edit", "--root", root, code=2, stdin="not json"))["ok"] is False
print("CLI smoke passed: edit applies, refuses with a reason, and never writes what the gate rejects")

# `--json` owns stdout even when the run stops before the model is asked. The credentials
# are placeholders: nothing here reaches the network.
with tempfile.TemporaryDirectory() as tmp:
    env = dict(os.environ, CLOUDFLARE_ACCOUNT_ID="smoke", CLOUDFLARE_API_TOKEN="smoke")
    (Path(tmp) / "main.py").write_text("def real():\n    return 1\n")
    doc = json.loads(run("solve", "t", "--root", tmp, "--verify", "exit 0", "--json", env=env))
    assert doc["status"] == "already_passes" and doc["exit"] == 0 and doc["attempts"] == 0, doc
    doc = json.loads(run("polish", "--root", tmp, "--verify", "exit 1", "--json", code=3, env=env))
    assert doc["status"] == "not_passing", doc
print("CLI smoke passed: --json prints exactly one object for runs that end early")

# Obsolete benchmark settings must fail before any model invocation.
for flag in ("BENCH_AGENT", "BENCH_STEPS"):
    env = dict(os.environ, **{flag: "1"})
    result = subprocess.run(["bash", str(BIN.parent / "bench/almide.sh")],
                            env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 2 and "unsupported" in result.stderr, result
print("Benchmark smoke passed: obsolete execution modes rejected")
