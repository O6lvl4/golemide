# Measuring golemide, gramide and hew together

The objective is better repairs per unit of time and money. Faster parsing and
smaller reads matter only if they preserve the information needed to make a
correct edit. None of the results below establishes a world ranking.

## First checkpoint: correctness and repeatability (2026-09-10)

All three repositories now have a pinned-compiler CI command (`bash ci/check.sh`).
Local validation covered golemide's 7 test files, gramide's 9 and hew's 4, plus builds
and CLI smoke checks. These are file counts, not individual assertion counts.

Hew's comment/literal range regression made a six-line Rust function end at line
2 and invented a function inside its comment. The fix masks lexical contents
before declaration/range detection. Rust nested comments, raw delimiters and
lifetime-versus-character handling were checked against rustc_lexer at
`0d31508599a7814a7044e9a7a871e3dc5f037753`. Hew remains a heuristic reader, not a
full parser. The separate hew-lang compiler is not this project's hew tool.

Golemide's Almide benchmark previously passed unsupported `--agent`/`--steps`
options: those did not select another implementation. The harness now rejects
those legacy settings and supports `BENCH_CHECK_ONLY=1` to validate its original
and stripped exercise without a model call. Historical mode comparisons must be
re-established with actually distinct implementations.

## Comparison protocol

| Component | Primary outcome | Cost and performance | Correctness control |
|---|---|---|---|
| golemide | Independently verified repairs / all selected tasks | API cost including failures, wall time, attempts | Original tests retained; reference solutions hidden; setup failures reported separately |
| gramide | False rejection and false acceptance against reference parsers | Whole-corpus time, bytes/s, peak RSS | Pin language edition and corpus commit; include malformed input and recovery output |
| hew | Symbol names and exact source ranges; required code retained in selected reads | Returned bytes, latency, peak RSS | Annotated cases plus independent parser ranges; report unsupported constructs |
| combined | Repairs with gramide + hew versus the same agent without each | Total cost/time at equal model and attempt budget | One tool removed at a time; fixed task set and repeated runs |

Before comparing numbers, record tool/compiler commits, model identifier, prompt,
limits, corpus hashes, machine, process-startup policy and warmup policy. Report
all selected tasks, not only successful runs. Development fixtures and held-out
cases must have separate results. Unknown training exposure stays unknown.

Next checkpoints are an independent symbol-range corpus for hew, positive and
negative syntax corpus automation for gramide, and an externally defined repair
benchmark for golemide under a fixed model/budget. Run the harness-only checks before
spending model budget. Existing self-reported exercise scores and historical
speed measurements are leads to reproduce, not substitutes for these comparisons.

## Structured reading checkpoint

gramide's `symbols` contract now provides
versioned declaration names, owners and physical line/UTF-8 byte ranges. Hew uses
it for Almide, Go and Rust and labels heuristic fallbacks. The independent Go AST
comparison covers 38 reference source files and 551 concrete functions/methods;
its script and input hashes live in gramide's `docs/symbols.md` evidence.

Golemide consumes `hew read-json` when available, with built-in reads as the fallback.
Unlike display output, this preserves source, line endings and long lines. The
initial 24,000-character read expands to at most 96,000 characters when incomplete.
Files still truncated are context only: the complete-file edit path rejects them.
This does not yet implement model-selected symbol requests or targeted patch edits
for files larger than that budget. No repair-success or world-ranking claim follows
from these integration tests; paid model evaluations were not run.

## Language reference, and three things that did not work (2026-09-10)

One task, repeated: a JSON path picker implemented against 30 pre-written tests
in a language the model has not seen, `almide test` as the verify command,
`cf:glm-5.3-flash`, six attempts. Every number below is from that one task, so
none of it is a repair-success rate. The variance is reported because it is
larger than most of the effects.

**The reference works.** Without one, the run spent six attempts and produced
six hand-rolled functions that unwrap a `Result` by hand, plus a loop counting
a list the standard library already measures. With the toolchain's own
`almide ide stdlib-snapshot` — 14 KB of signatures, no syntax, no
configuration — the same task solved in two attempts for $0.012206 and none of
those helpers appeared. Repeated three more times: 3/3 solved, zero hand-rolled
unwrappers in all three. Every observed failure across every run was a compile
error; not one was a wrong answer. The gap the reference closes is knowing what
the API returns, not knowing how the language is written.

**Run-to-run variance is the headline.** Three runs of one identical
configuration: 2, 3 and 4 attempts; 139 s, 174 s and 456 s; $0.0093, $0.0096
and $0.0224; cyclomatic 18, 40 and 18. A single run cannot separate a change
from noise here, and three earlier single-run comparisons in this project were
noise.

**Polish did not work: three attempts, three failures.** Asking, once the verify
command already passes, for the same behaviour written more simply produced a
two-byte diff on the first run and a version that failed the tests on the second
and third. The rollback is sound — the tree came back byte-identical each time —
so the pass ships behind `--polish` at a default of 0, and as `golemide polish` for
a project that is already green. The command exists mostly so the pass can be
measured at all; before it, polish could only happen inside a repair.

**Asking for structure up front did not work either, and was worse.** Adding
"a type that names the cases, over flags and re-scanning a string" and two
similar lines to the edit question moved the model to sum types and recursive
descent — the shape a stronger model reaches for unprompted. It could not then
keep `Option[T]` and `T` apart. Five runs under that instruction had written
nothing by their second attempt, while three control runs had already finished;
their requests were streaming 500-760 KB each, generating without converging on
an answer of about 5 KB. The instruction was removed. Explaining the rejected
diagnostic on the re-ask, added while testing this, did not rescue it and was
kept for its own sake.

Taken together: the harness closes gaps in what the model knows, and prompting
does not close gaps in what it can do. Structural quality did not move under
either intervention.

That is a claim about prompting, not about harnesses, and the same runs argue
against the wider reading. Six runs of one configuration produced cyclomatic
13, 15, 18, 18, 24 and 40 — a threefold spread, every one passing the tests and
scoring 9-10 on the behaviour probes. The model does not write code of a fixed
structure; it writes a distribution, and a single run samples it. Choosing among
k samples on a structural measure would land near 13 rather than near the 18-24
a single sample typically gives, which is roughly two fifths of the distance to
the 6 a stronger model reached — without a better model, at k times the cost of
one attempt, which for this task is still under five cents.

Selecting this way has a trap worth stating before anyone builds it: an
analyzer scores what it can parse, so a candidate it fails to parse looks clean.
Codopsy graded the worst file in this whole comparison an A on 10.2% of its
contents. Any selection needs a parse-coverage floor, or it will reliably pick
the file the analyzer understood least.

**Instrumentation earned more than the features.** Hedged requests looked
plausible until they reported themselves: three hedges fired, three lost, so the
second request was paid for and discarded every time. A rolled-back polish
reported `SOLVED` until the outcome was carried out of the loop. Twenty-eight
per cent of attempts were spending a whole model call on a rejected edit, which
was only visible by counting across saved logs. None of these were features; all
three changed a decision.

### Hedging, measured (2026-09-10)

Three runs of the final configuration solved 3/3 at $0.0078, $0.0111 and
$0.0106, in 168 s, 146 s and 221 s. Their eight model calls took 25, 26, 29,
46, 47, 73, 117 and 168 seconds — a median near 46 s and a tail at 117-168 s.

At a 75-second threshold the hedge fired five times across every run recorded
and won once. The other four were duplicate requests paid for and discarded.
The threshold is now 120000, above the merely-slow and below the tail, so the
second request is spent where the first is genuinely not arriving. This is
tuned on eight calls of one task; it is a starting point, not a constant.

The win rate is only visible because the hedge reports it. Before that, two
earlier runs containing a 231-second and a 565-second attempt could not be
told apart from ones where the hedge had rescued them.

### What a structural selector would need (2026-09-10)

Choosing among k samples needs a measure that ranks them. Two were checked
against each other on the six runs above, whose codopsy cyclomatic values were
13, 15, 18, 18, 24 and 40, with 6 for the stronger model's file.

Cheap textual proxies do not rank them. Maximum indentation is inverted — the
best file of the six indents deeper than the worst. Line count is unrelated:
the shortest golemide file is the second worst. Counting branch keywords gives a
rank correlation near 0.5, which is the middle of the distribution ordered at
random.

Counting decision points in gramide's parse tree — every `if`, every
`match_arm` past the first of its `match`, every loop and guard — is a real
measure rather than a proxy, and does better at 0.56, but its range across the
six files is 29 to 37 where codopsy's is 13 to 40. It does not discriminate.

Both measures agree on exactly two things: which file is best and which is
worst. A selector built on either would reject the outlier reliably and choose
among the rest close to randomly. Rejecting the 40 alone moves the mean of
these six from 21.3 to 17.6, which is worth having and is not the same feature
as choosing the best.

A selector that closes the distance to 6 needs a measure that separates 13 from
18. For Almide that means an analyzer that parses the language properly —
codopsy reads it through tree-sitter and its coverage on these files ranged from
0% to 89.8% unparsed. The route to structural quality runs through that parse,
not through more prompting.

### Correction: the structural numbers above were measured wrong (2026-09-10)

Every cyclomatic figure quoted so far came from codopsy, and codopsy reads
Almide through tree-sitter. Checking its coverage on the same files shows the
two numbers the comparison rested on were computed from incomplete parses: the
file called worst at 40 had 41.8% of it unparsed and three of its functions
seen, and the stronger model's file scoring 6 had 14.3% unparsed. Codopsy's
file-level figure is also the maximum over the functions it parsed, not a total,
so it was never the same measure as a whole-file count.

Gramide parses seven of the eight completely and says so: its `symbols` output
carries a `complete` flag. The eighth — the stronger model's file — trips its
list pattern `[s, ..rest]` and is recovered with one part skipped, so the 7
below is measured on a tree missing a two-armed match. Counting decision points
per function from that parse — every `if`, every `match_arm` past the first of its `match`,
every loop and guard — gives a measure that is both complete and comparable:

| File | max per function | total |
|---|---|---|
| stronger model | 7 | 26 |
| six golemide runs with a reference | 10, 11, 13, 13, 14, 17 | 33-45 |
| golemide without a reference | 22 | 65 |

Three claims made earlier are wrong and are corrected here. The spread across
identical runs is 10 to 17, not 13 to 40, so there is less for a selector to
exploit than the earlier note claimed. The file singled out as the outlier worth
rejecting is the second best of the six; a selector built on the earlier reading
would have discarded it. And the reference did move structural quality — 22 down
to 10-17 — so the finding is not that structure resists every intervention, but
that it resisted the two prompting ones while responding to the one that gave
the model the API it was working against.

The remaining distance is 7 against a median of 13: real, and about half of what
was reported. The measurement to trust for Almide is the one taken from a parse
that covers the file.


### A measure of its own code, and what it found (2026-09-11)

Golemide now has a structural check in `ci/check.sh`. It is codopsy-almd, which
measures Almide through gramide's parse and declines to grade a file that parse
did not cover — the failure that made every earlier structural number in this
document wrong.

Its first run named `solve` at 69 decision points, against 23 for the next worst
function in this repository and 12 for the worst in hew. Seven seams came out of
it: turning an answer into edits, applying them through the gate, wording a
re-ask, explaining diagnostics, widening the read set, recording an attempt, and
building the prompt. That is 69 down to 45, with the 70 tests unchanged and one
task solved end to end afterwards in a single attempt for $0.0034.

One of those seams was a duplicate. Explaining the diagnostics of a rejected
edit had been added to this repository the same day, and the same code already
existed for a failing verify command a hundred lines away. Nobody noticed until
something counted the branches.

The remaining 45 is the attempt loop's own state — ten mutable variables that
would have to become a record — which is a different kind of change from lifting
out a cohesive block, and is not attempted here. The CI number is a ratchet at
45: it may fall, and raising it needs a reason written beside it.

## Loosened replacement matching (2026-09-22)

`replace.almd` finds a replacement's `old` on a fixed ladder when it is not in the
file verbatim: line-number prefixes stripped, escapes undone, a uniform indentation
change ignored, each line trimmed, then first-and-last-line anchors. Ported from
ZCode's `edit-matchers.ts`, with `new` re-indented by the same shift and line endings
restored on write. Measured once, both arms concurrently on one machine, Python and
Rust, the first 30 exercises of each, `cf:glm-5.3-flash`, three attempts
(`bench/results-replace-{before,after}.tsv`):

|                              | before | after |
|---|---|---|
| solved                       | 55/60  | 54/60 |
| cost                         | $0.183 | $0.155 |
| replacement batches applied  | 41     | 36    |
| replacements refused         | 7      | 2     |
| rescued by the ladder        | —      | 4 (3 indentation, 1 trimmed) |

Every rescued replacement was in an exercise that then passed. The two refusals
that remain quote text the file never contained. The solved counts differ by one
exercise in sixty, inside this project's measured run-to-run variance; one of the
six `after` failures is a Rust build that hit the 120 s verify deadline under six
concurrent cargo builds, not an edit. Path refusals were zero in both arms, so the
"did you mean" suggestion added alongside was not exercised by this corpus — the
13% path-refusal rate in `bench/failures.py` came from the C++ and Almide runs.

## The polyglot leaderboard protocol, full run (2026-09-22)

`bench/leaderboard.sh`: all 225 exercises, two attempts (the board's pass_rate_2),
`cf:glm-5.3-flash`, four in parallel, one run
(`bench/results-leaderboard-glm-5.3-flash-run1.tsv`):

| language | solved | rate | cost |
|---|---|---|---|
| cpp | 20/26 | 76.9% | $0.073 |
| go | 34/39 | 87.2% | $0.061 |
| java | 33/47 | 70.2% | $0.089 |
| javascript | 37/49 | 75.5% | $0.097 |
| python | 26/34 | 76.5% | $0.054 |
| rust | 20/30 | 66.7% | $0.087 |
| **total** | **170/225** | **75.6%** | **$0.46** |

Failure census: 40 of 55 ran out of attempts still failing tests, 5 stuck on the
same failure, 4 verify timeouts at the 300 s deadline (go/robot-simulator,
cpp/zebra-puzzle, python/forth, java/book-store — not edits), 3 syntax gate, 2
path refusals, 2 replacements that did not apply. No provider errors; every
exercise reached a verdict.

For scale, not for a ranking: Aider's own leaderboard (last updated 2025-11-20)
lists DeepSeek-V3.2-Exp reasoner at 74.2% for $1.30 as its best open-weight
entry, and Gemini 2.5 Pro at 76.5%. Three things stop this being a comparison.
It is one run, and the 60-exercise runs above moved by one exercise between
identical runs. The board is stale: no GLM-5.x, DeepSeek-V4 or Kimi-K3 entry, so
"above every open-weight entry" is against models a year older. And the harness
differs: an attempt here may include a shape-repair re-ask before its verify,
and the syntax gate and diagnostic explanations are golemide's, not the model's —
which is the point of measuring an agent, but it means the number is
agent+model, and the board's numbers are Aider+model. Separating the two needs
Aider run with `cf:glm-5.3-flash` under the same protocol.

`bench/aider.sh` is that control arm: Aider's own harness in its own Docker image,
the model pointed at the same Cloudflare endpoint by name, the board's two tries and
`diff` format, with cost computed from Aider's recorded token counts at the prices in
`src/llm.almd`. The endpoint returns the model's reasoning in a separate
`reasoning_content` field and the answer in `content`, which is the shape Aider's
client already handles. Not yet run: it needs Docker, which was not running when
the script was written.

### Aider, same model, same protocol (2026-09-22)

`bench/aider.sh`, Aider `5dc9490bb`, `diff` format, two tries, `cf:glm-5.3-flash`
at reasoning effort `low`, four threads, one run
(`bench/results-aider-glm-5.3-flash-low-run1.tsv`):

| language | Aider | golemide |
|---|---|---|
| cpp | 20/26 76.9% | 20/26 76.9% |
| go | 27/39 69.2% | 34/39 87.2% |
| java | 27/47 57.4% | 33/47 70.2% |
| javascript | 33/49 67.3% | 37/49 75.5% |
| python | 27/34 79.4% | 26/34 76.5% |
| rust | 17/30 56.7% | 20/30 66.7% |
| **total** | **151/225 67.1%, $0.47** | **170/225 75.6%, $0.46** |

Same model, same 225 exercises, same two attempts, same cost. golemide never
escalated to the stronger model in its run (0 of 225; seven attempts went to
`medium` reasoning). Aider's pass_rate_1 was 20.9%: most of its solves came from the
second try, after seeing test output.

Reasoning effort is the condition to be honest about. Aider was first run at the
model's default effort and stopped: in an hour it finished 9 exercises, and the
four in flight had each hit Cloudflare's 408 request timeout up to five times,
retried identically each time. golemide classifies that 408 as a server timeout
and lowers the effort; Aider retries. So both arms ran at `low`, which is where
golemide's ladder starts. A reader may say Aider was not run at its own default;
the reply is that at its own default it did not run.

One run each. The 60-exercise repeats above moved by one exercise; an eight-point
gap on 225 is well outside that, but `RUNS=3` on both is what would settle it.

### ZCode, stopped after 25 exercises (2026-09-22)

`bench/zcode.sh`: ZCode `872ad96` headless, one session per exercise with the task
and the verify command, `cf:glm-5.3-flash` at reasoning `low`, 900 s wall cap, run on
the host through `bench/exercism.sh`. Stopped after 25 exercises
(`bench/results-zcode-glm-5.3-flash-low-partial.tsv`), 24 of them C++:

| on those 25 | solved | cost |
|---|---|---|
| ZCode | 24/25 | $0.454 |
| golemide (2 attempts) | 20/25 | $0.072 |
| Aider (2 tries) | 20/25 | $0.127 |

No test file was modified in any ZCode directory. ZCode is not under the two-attempt
protocol: it runs the tests itself as often as it likes, and made 4-17 model requests
per exercise.

It was stopped because it changed the machine. On `cpp/gigasecond` it found Boost
missing and ran `brew install boost` (Homebrew `boost` created 22:15:26; nothing else
was installed). That also exposed a flaw in the earlier arms: the two C++ exercises
that need Boost, `gigasecond` and `meetup`, fail at CMake configure on a host without
it — golemide's baselines exited 1 in 0.7 s and 0.4 s — so golemide's run on the host
could not solve them, while Aider's Docker image ships Boost. golemide's final
`gigasecond` passes all five tests once Boost is present. Its C++ score, and so its
total, is understated by up to two exercises; that has not been re-measured.
Excluding those two, the 23 remaining exercises give ZCode 22, golemide 20, Aider 19.

The benchmark needs one environment for every arm: a container with every
toolchain and library the corpus uses, where an agent's shell cannot reach the host.

## One environment for every agent (2026-09-23)

`bench/container.sh` builds one image — Aider's benchmark image (Python 3.11, Go 1.21,
Java 21, Node 20, Rust, CMake, Boost) plus almide v0.63.0-rc3, golemide, gramide, hew,
ctxgate and ZCode `872ad96` — and runs every agent inside it, so no agent's shell
reaches the host and the only thing that differs between arms is the agent. Each arm
snapshots installed packages before and after; no arm changed them. `cf:glm-5.3-flash`
throughout, one run per arm, and golemide pinned to that model with `--strong-model`.

golemide@2, all 225 exercises (`bench/results-container-golemide2-glm-5.3-flash.tsv`):
169/225, 75.1%, $0.45 — against 75.6% on the host. The host run had understated C++ by
the two Boost exercises and overstated Go by run-to-run variance; the nine Go
exercises that flipped to failing were re-tested in the image and every one is an
ordinary wrong answer or compile error, none a Go-version error. Aider in the same
image: 67.1%.

Rust and Python, 64 exercises, every arm in the image
(`bench/results-container-{golemide8,zcode}-rust-python-glm-5.3-flash.tsv`):

| | golemide@8 | ZCode | golemide@2 | Aider |
|---|---|---|---|---|
| rust (30) | 30 | 30 | 18 | 17 |
| python (34) | 34 | 33 | 25 | 27 |
| **total (64)** | **64 (100%)** | **63 (98.4%)** | 43 (67.2%) | 44 (68.8%) |
| cost | $0.23 | $1.25 | $0.13 | $0.10 |
| median wall per exercise | 29 s | 78 s | 18 s | 18 s |

ZCode runs the tests itself as often as it likes within 900 s; golemide@8 was allowed
eight attempts and used at most five (25 exercises in one, 22 in two). At two attempts
golemide trailed ZCode by 20 exercises; at eight it matched it, at a fifth of the
cost and under half the wall time. The gap was chances to react, not the agent: three
of golemide@2's misses were solved on the first attempt of the @8 run, so part of it is
also the model's own variance, which cheap attempts let golemide resample.

Why the cost differs: golemide averaged 1.6 model requests per exercise at two
attempts; ZCode made a median of 9, each carrying about 33,000 input tokens of system
prompt, tool schemas and history. On Cloudflare's 20 requests per minute for this
model, ZCode at four in parallel was rate-limited on 32 of its first 33 exercises;
golemide's 225 never were.

Why golemide beats Aider at two attempts, stated with its caveat: golemide solved
45.8% on the first attempt, Aider 20.9%. golemide reads the test files and runs them
before its first request; Aider's benchmark deliberately withholds test files from
the first try (`benchmark.py` adds test files to `ignore_files`). Part of that gap is
the agent choosing to look, which is golemide's design, and part is a protocol Aider
set for itself. ZCode reads the tests too, so the ZCode comparison is not affected.

ZCode was checked for the obvious ways to be wrong: no WebFetch or WebSearch call in
any session, no test file changed. It edited one `Cargo.toml`
(`rust/doubly-linked-list`) to enable the exercise's `advanced` tests, which makes the
check stricter, not weaker.

One run per arm on two languages. Before this becomes a public claim: every language,
`RUNS=3`, and the spread next to each number.
