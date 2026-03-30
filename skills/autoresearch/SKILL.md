---
name: autoresearch
description: Use when asked to optimize something in a loop, run autoresearch, benchmark iteratively, or start autonomous experiments. Sets up and runs an autonomous experiment loop for any optimization target.
---

# Autoresearch

Autonomous experiment loop: try ideas, keep what works, discard what doesn't, never stop.

*Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).*

## Scripts

Helper scripts are located at `<SKILL_DIR>/../scripts/`. Resolve the absolute path before first use:

```bash
SCRIPTS_DIR="$(cd "$(dirname "<SKILL_FILE>")/../scripts" && pwd)"
```

Replace `<SKILL_FILE>` with the actual path to this SKILL.md that was loaded. Then use:

- **`$SCRIPTS_DIR/init_experiment.sh`** — configure session (name, metric, unit, direction)
- **`$SCRIPTS_DIR/run_experiment.sh`** — run command, time it, parse `METRIC name=value` lines from output, run optional checks
- **`$SCRIPTS_DIR/log_experiment.sh`** — record result, compute confidence score, auto-commit (keep) or auto-revert (discard/crash/checks_failed)

## Setup (no existing `autoresearch.md`)

1. Ask (or infer from context): **Goal**, **Command**, **Metric** (name + direction), **Files in scope**, **Constraints**.
2. Create branch: `git checkout -b autoresearch/<goal>-<YYYY-MM-DD>`
3. Read the source files in scope. Understand the workload deeply before writing anything.
4. Write `autoresearch.md` (session document — see template below). Commit.
5. Write `autoresearch.sh` (benchmark script — see template below). Make it executable. Commit.
6. If constraints require correctness checks (tests must pass, types must check), write `autoresearch.checks.sh`. Make it executable. Commit.
7. Initialize: `$SCRIPTS_DIR/init_experiment.sh --name "<goal>" --metric "<metric_name>" --unit "<unit>" --direction "<lower|higher>"`
8. Run baseline: `$SCRIPTS_DIR/run_experiment.sh --command "./autoresearch.sh"`
9. Log baseline: `$SCRIPTS_DIR/log_experiment.sh --commit "$(git rev-parse --short HEAD)" --metric <value> --status keep --description "baseline"`
10. Start looping immediately.

## Resume (existing `autoresearch.md`)

1. Read `autoresearch.md` — full session context.
2. Read last 20 lines of `autoresearch.jsonl` — recent results.
3. Read `autoresearch.ideas.md` if it exists — pending ideas.
4. Continue looping from where the previous session left off.

## `autoresearch.md` Template

```markdown
# Autoresearch: <goal>

## Objective
<Specific description of what we're optimizing and the workload.>

## Metrics
- **Primary**: <name> (<unit>, lower/higher is better) — the optimization target
- **Secondary**: <name>, <name>, ... — independent tradeoff monitors

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
<Every file the agent may modify, with a brief note on what it does.>

## Off Limits
<What must NOT be touched.>

## Constraints
<Hard rules: tests must pass, no new deps, etc.>

## What's Been Tried
<Update this section as experiments accumulate. Note key wins, dead ends,
and architectural insights so the agent doesn't repeat failed approaches.>
```

This is the heart of the session. A fresh agent with no context should be able to read this file and run the loop effectively. Invest time making it excellent.

## `autoresearch.sh` Template

```bash
#!/bin/bash
set -euo pipefail
# Pre-checks (fast, <1s) — catch syntax errors early
# ...

# Run the benchmark
# ...

# Output structured metrics (parsed by run_experiment.sh)
echo "METRIC total_seconds=12.34"
echo "METRIC compile_seconds=3.2"
```

For fast, noisy benchmarks (<5s), run the workload multiple times and report the median. This makes the confidence score reliable from the start. Slow workloads (ML training, large builds) don't need this.

Design the script to output whatever data helps you make better decisions: phase timings, error counts, memory usage, cache hit rates. You can update the script during the loop as you learn what matters.

## `autoresearch.checks.sh` (optional)

Only create this file when the user's constraints require correctness validation (e.g., "tests must pass", "types must check"). When it exists, `run_experiment.sh` runs it automatically after every passing benchmark.

```bash
#!/bin/bash
set -euo pipefail
# Keep output minimal — only errors, not verbose success output
pnpm test --run --reporter=dot 2>&1 | tail -50
pnpm typecheck 2>&1 | grep -i error || true
```

## The Loop

**LOOP FOREVER.** Never ask "should I continue?" — the user expects autonomous work.

Each iteration:
1. Study the code/data. Think about what to try next.
2. Make a code change. Stage it with `git add`.
3. Run: `$SCRIPTS_DIR/run_experiment.sh --command "./autoresearch.sh"`
4. Determine status:
   - Command passed + metric improved → `keep`
   - Command passed + metric worse/equal → `discard`
   - Command crashed or timed out → `crash`
   - Checks failed → `checks_failed`
5. Log: `$SCRIPTS_DIR/log_experiment.sh --commit "$(git rev-parse --short HEAD)" --metric <value> --status <status> --description "<what you tried>" --asi '<json>'`
6. Repeat.

### Rules

- **Primary metric is king.** Improved → keep. Worse or equal → discard. Secondary metrics rarely affect this.
- **Annotate every run with ASI.** Pass `--asi '{"key":"value"}'` to `log_experiment.sh`. Record what you *learned*, not what you *did*. What would help the next iteration or a fresh agent resuming this session?
- **Watch the confidence score.** After 3+ runs, `log_experiment.sh` reports confidence. ≥2.0× = likely real improvement. <1.0× = within noise — consider re-running to confirm.
- **Simpler is better.** Removing code for equal perf = keep. Ugly complexity for tiny gain = probably discard.
- **Don't thrash.** Repeatedly reverting the same idea? Try something structurally different.
- **Crashes:** fix if trivial, otherwise log and move on. Don't over-invest.
- **Think longer when stuck.** Re-read source files, study profiling data, reason about what the CPU is actually doing. The best ideas come from deep understanding, not random variations.
- **Update `autoresearch.md`** periodically — especially the "What's Been Tried" section.
- **Ideas backlog:** append promising but complex ideas to `autoresearch.ideas.md`. On resume, check it — prune stale entries, try promising ones.

### User Messages During Experiments

If the user sends a message while an experiment is running, finish the current run_experiment + log_experiment cycle first, then incorporate their feedback in the next iteration.

**NEVER STOP.** The user may be away for hours. Keep going until interrupted.
