# claude-autoresearch

Autonomous experiment loop for [Claude Code](https://claude.ai/code). Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch) and ported from [pi-autoresearch](https://github.com/davebcn87/pi-autoresearch).

*Try an idea, measure it, keep what works, discard what doesn't, repeat forever.*

## What's included

| Component | Description |
|-----------|-------------|
| `/autoresearch` skill | Set up and run an autonomous experiment loop |
| `/autoresearch-finalize` skill | Turn a noisy branch into clean, reviewable branches |
| Helper scripts | `init_experiment.sh`, `run_experiment.sh`, `log_experiment.sh`, `finalize.sh` |

## Install

Clone this repo and add the skills to your Claude Code settings:

```bash
git clone https://github.com/webmatze/claude-autoresearch.git ~/.claude-autoresearch
```

Add to `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project):

```json
{
  "skills": ["~/.claude-autoresearch/skills"]
}
```

### Dependencies

- `bash` 4.0+
- `git`
- `awk`
- `python3` (for JSON escaping in scripts)
- `jq` (for finalize.sh; falls back to python3 if unavailable)

## Usage

### 1. Start autoresearch

```
/autoresearch optimize unit test runtime, monitor correctness
```

Claude will ask about your goal, command, metric, and files in scope — then create a branch, write session files, run a baseline, and start looping.

### 2. The loop

Claude runs autonomously: edit → benchmark → keep or revert → repeat. Every result is logged to `autoresearch.jsonl`. The session document `autoresearch.md` captures what's been tried so a fresh session can resume.

### 3. Finalize into reviewable branches

```
/autoresearch-finalize
```

Claude reads the experiment log, groups kept experiments into logical changesets, and creates independent branches from the merge-base. Each branch can be reviewed and merged independently.

## Session files

| File | Purpose |
|------|---------|
| `autoresearch.md` | Session document — objective, metrics, files, what's been tried |
| `autoresearch.sh` | Benchmark script — outputs `METRIC name=value` lines |
| `autoresearch.jsonl` | Append-only log of every experiment run |
| `autoresearch.checks.sh` | Optional correctness checks (tests, types, lint) |
| `autoresearch.ideas.md` | Ideas backlog for complex optimizations |

## Example domains

| Domain | Metric | Command |
|--------|--------|---------|
| Test speed | seconds ↓ | `pnpm test` |
| Bundle size | KB ↓ | `pnpm build && du -sb dist` |
| ML training | val_bpb ↓ | `uv run train.py` |
| Build speed | seconds ↓ | `pnpm build` |

## How it works

Two skills encode the workflow. Four bash scripts handle the mechanics.

```
┌────────────────────────┐     ┌─────────────────────────┐
│  Skills (prompts)      │     │  Scripts (bash)          │
│                        │     │                          │
│  /autoresearch         │────▶│  init_experiment.sh      │
│  /autoresearch-finalize│────▶│  run_experiment.sh       │
│                        │     │  log_experiment.sh       │
│                        │     │  finalize.sh             │
└────────────────────────┘     └─────────────────────────┘
```

Session state lives in plain files — a fresh Claude session can resume by reading `autoresearch.md` and `autoresearch.jsonl`.

## Confidence scoring

After 3+ experiments, the log script computes a confidence score using [Median Absolute Deviation (MAD)](https://en.wikipedia.org/wiki/Median_absolute_deviation). This distinguishes real gains from benchmark noise.

| Confidence | Meaning |
|-----------|---------|
| ≥ 2.0× | Improvement is likely real |
| 1.0–2.0× | Above noise but marginal |
| < 1.0× | Within noise — consider re-running |

## License

MIT
