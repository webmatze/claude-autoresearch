#!/usr/bin/env bash
set -euo pipefail

# autoresearch-finalize — creates independent branches from an autoresearch session
# Ported from pi-autoresearch, adapted for Claude Code (jq instead of node)
#
# Usage: finalize.sh <groups.json>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

DATA_DIR=""
ORIG_BRANCH=""
TRUNK=""
BASE=""
FINAL_TREE=""
GOAL=""
GROUP_COUNT=""
STASHED=false
CREATED_BRANCHES=()
declare -a GROUP_BRANCH

warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${GREEN}$1${NC}"; }
cleanup_data() { if [ -d "${DATA_DIR:-}" ]; then rm -rf "$DATA_DIR"; fi; }
fail() { cleanup_data; echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }

is_session_file() {
  local base
  base=$(basename "$1")
  case "$base" in autoresearch.*) return 0;; *) return 1;; esac
}

# --- Parse (jq with python3 fallback) ---

parse_groups() {
  local groups_file="$1"
  [ -f "$groups_file" ] || fail "$groups_file not found"

  DATA_DIR=$(mktemp -d)

  if command -v jq &>/dev/null; then
    jq -r '.base' "$groups_file" > "$DATA_DIR/base"
    jq -r '.trunk // "main"' "$groups_file" > "$DATA_DIR/trunk"
    jq -r '.final_tree' "$groups_file" > "$DATA_DIR/final_tree"
    jq -r '.goal' "$groups_file" > "$DATA_DIR/goal"
    jq -r '.groups | length' "$groups_file" > "$DATA_DIR/count"
    local count
    count=$(cat "$DATA_DIR/count")
    for ((i=0; i<count; i++)); do
      jq -r ".groups[$i].title" "$groups_file" > "$DATA_DIR/$i.title"
      jq -r ".groups[$i].body" "$groups_file" > "$DATA_DIR/$i.body"
      jq -r ".groups[$i].last_commit" "$groups_file" > "$DATA_DIR/$i.last_commit"
      jq -r ".groups[$i].slug" "$groups_file" > "$DATA_DIR/$i.slug"
    done
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, os
config = json.load(open('$groups_file'))
out = '$DATA_DIR'
open(f'{out}/base','w').write(config['base'])
open(f'{out}/trunk','w').write(config.get('trunk','main'))
open(f'{out}/final_tree','w').write(config['final_tree'])
open(f'{out}/goal','w').write(config['goal'])
open(f'{out}/count','w').write(str(len(config['groups'])))
for i, g in enumerate(config['groups']):
    open(f'{out}/{i}.title','w').write(g['title'])
    open(f'{out}/{i}.body','w').write(g['body'])
    open(f'{out}/{i}.last_commit','w').write(g['last_commit'])
    open(f'{out}/{i}.slug','w').write(g['slug'])
" || fail "Failed to parse $groups_file"
  else
    fail "Neither jq nor python3 found. Install one of them."
  fi

  BASE=$(cat "$DATA_DIR/base")
  TRUNK=$(cat "$DATA_DIR/trunk")
  FINAL_TREE=$(cat "$DATA_DIR/final_tree")
  GOAL=$(cat "$DATA_DIR/goal")
  GROUP_COUNT=$(cat "$DATA_DIR/count")
}

# --- Preflight ---

assert_on_feature_branch() {
  ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  [ -n "$ORIG_BRANCH" ] || fail "Detached HEAD — switch to the autoresearch branch first."
  [ "$ORIG_BRANCH" != "$TRUNK" ] || fail "On trunk ($TRUNK) — switch to the autoresearch branch first."
}

assert_commits_exist() {
  git rev-parse "$BASE" >/dev/null 2>&1 || fail "Base commit $BASE not found."
  git rev-parse "$FINAL_TREE" >/dev/null 2>&1 || fail "Final tree commit $FINAL_TREE not found."
}

collect_group_files() {
  local group_index="$1" prev_commit="$2"
  local last_commit
  last_commit=$(cat "$DATA_DIR/$group_index.last_commit")
  git cat-file -t "$last_commit" 2>/dev/null | grep -q "commit" \
    || fail "Group $((group_index+1)) last_commit $last_commit not found. Use full hashes."

  : > "$DATA_DIR/$group_index.files"
  local changed_file
  while IFS= read -r -d '' changed_file; do
    [ -n "$changed_file" ] || continue
    is_session_file "$changed_file" || echo "$changed_file" >> "$DATA_DIR/$group_index.files"
  done < <(git diff --name-only -z "$prev_commit" "$last_commit")
}

assert_no_overlapping_files() {
  local new_files_path="$1" seen_files_path="$2"
  [ -s "$new_files_path" ] || return 0
  [ -s "$seen_files_path" ] || return 0
  local candidate
  while IFS= read -r candidate; do
    if grep -qxF "$candidate" "$seen_files_path"; then
      fail "File '$candidate' appears in multiple groups. Merge the overlapping groups and retry."
    fi
  done < "$new_files_path"
}

assert_branch_available() {
  local branch_name="$1"
  if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    fail "Branch '$branch_name' already exists. Delete it first or use a different goal slug."
  fi
}

preflight() {
  echo ""
  info "═══ Preflight ═══"
  echo ""

  assert_on_feature_branch
  assert_commits_exist

  local prev_commit="$BASE"
  local all_seen_path="$DATA_DIR/all_seen_files"
  : > "$all_seen_path"

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    collect_group_files "$i" "$prev_commit"
    assert_no_overlapping_files "$DATA_DIR/$i.files" "$all_seen_path"
    cat "$DATA_DIR/$i.files" >> "$all_seen_path"

    local group_number branch_name
    group_number=$(printf "%02d" $((i + 1)))
    branch_name="autoresearch/${GOAL}/${group_number}-$(cat "$DATA_DIR/$i.slug")"
    assert_branch_available "$branch_name"
    GROUP_BRANCH[$i]=""

    prev_commit=$(cat "$DATA_DIR/$i.last_commit")
  done

  assert_branch_available "autoresearch/${GOAL}/verify-tmp"

  info "Preflight passed."
  echo "  Branch:     $ORIG_BRANCH"
  echo "  Base:       ${BASE:0:12}"
  echo "  Groups:     $GROUP_COUNT"
}

# --- Create branches ---

rollback_on_failure() {
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then return; fi

  echo ""
  echo -e "${RED}FAILED — rolling back...${NC}"
  git reset --quiet HEAD -- . 2>/dev/null || true
  for branch in "${CREATED_BRANCHES[@]}"; do
    git branch -D "$branch" 2>/dev/null || true
  done
  if [ -n "${ORIG_BRANCH:-}" ]; then
    git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  fi
  if [ "$STASHED" = true ]; then
    git stash pop --quiet 2>/dev/null \
      || echo -e "${YELLOW}⚠ Could not restore stashed changes. Run 'git stash list' to recover.${NC}"
  fi
  cleanup_data
  echo -e "${RED}Rolled back to '$ORIG_BRANCH'. No branches left behind.${NC}"
}

stash_if_dirty() {
  if ! git diff --quiet 2>/dev/null \
    || ! git diff --cached --quiet 2>/dev/null \
    || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    warn "Stashing uncommitted changes..."
    git stash -u
    STASHED=true
  fi
}

create_group_branch() {
  local i="$1"
  local title last_commit slug group_number branch_name

  title=$(cat "$DATA_DIR/$i.title")
  local body
  body=$(cat "$DATA_DIR/$i.body")
  last_commit=$(cat "$DATA_DIR/$i.last_commit")
  slug=$(cat "$DATA_DIR/$i.slug")
  local files_path="$DATA_DIR/$i.files"

  group_number=$(printf "%02d" $((i + 1)))
  branch_name="autoresearch/${GOAL}/${group_number}-${slug}"

  info "[$group_number/$GROUP_COUNT] $title"

  if [ ! -s "$files_path" ]; then
    warn "No files changed — skipping this group"
    GROUP_BRANCH[$i]="skipped"
    return
  fi

  git checkout "$BASE" --quiet --detach 2>/dev/null || git checkout "$BASE" --quiet
  git checkout -b "$branch_name"

  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    git checkout "$last_commit" -- "$changed_file"
  done < "$files_path"
  git commit -m "$title" -m "$body"

  CREATED_BRANCHES+=("$branch_name")
  GROUP_BRANCH[$i]="$branch_name"
  echo "  Branch: $branch_name"
  echo "  Files: $(tr '\n' ' ' < "$files_path")"
  echo ""
}

create_branches() {
  echo ""
  info "═══ Creating branches ═══"
  echo ""

  trap rollback_on_failure EXIT
  stash_if_dirty

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    create_group_branch "$i"
  done

  info "Created ${#CREATED_BRANCHES[@]} branches (all from merge-base, independent):"
  for branch in "${CREATED_BRANCHES[@]}"; do echo "  $branch"; done

  trap - EXIT
}

# --- Verify ---

verify_union_matches_original() {
  local verify_branch="autoresearch/${GOAL}/verify-tmp"

  git checkout "$BASE" --quiet --detach 2>/dev/null || git checkout "$BASE" --quiet
  git checkout -b "$verify_branch"

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    local last_commit
    last_commit=$(cat "$DATA_DIR/$i.last_commit")
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] || continue
      git checkout "$last_commit" -- "$changed_file"
    done < "$DATA_DIR/$i.files"
  done
  git commit --allow-empty -m "verify: union of all groups" --quiet

  local non_session_diff=""
  for changed_file in $(git diff --name-only HEAD "$FINAL_TREE" 2>/dev/null); do
    is_session_file "$changed_file" || non_session_diff="$non_session_diff $changed_file"
  done

  git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  git branch -D "$verify_branch" 2>/dev/null || true

  if [ -n "$non_session_diff" ]; then
    echo -e "${RED}✗ Union of groups differs from autoresearch branch!${NC}"
    echo "  Files:$non_session_diff"
    return 1
  fi

  echo -e "${GREEN}✓ Union of all groups matches original autoresearch branch.${NC}"
  return 0
}

verify_no_session_artifacts() {
  local clean=true
  for branch in "${CREATED_BRANCHES[@]}"; do
    for changed_file in $(git diff-tree --no-commit-id --name-only -r "$(git rev-parse "$branch")" 2>/dev/null); do
      if is_session_file "$changed_file"; then
        echo -e "${RED}✗ Session artifact '$changed_file' in branch $branch!${NC}"
        clean=false
      fi
    done
  done

  if [ "$clean" = true ]; then
    echo -e "${GREEN}✓ No session artifacts in any branch.${NC}"
    return 0
  fi
  return 1
}

verify_no_empty_commits() {
  local errors=0
  for branch in "${CREATED_BRANCHES[@]}"; do
    local commit diff_output
    commit=$(git rev-parse "$branch" 2>/dev/null)
    diff_output=$(git diff-tree --no-commit-id --name-only -r "$commit" 2>/dev/null || echo "")
    if [ -z "$diff_output" ]; then
      echo -e "${RED}✗ Empty commit in $branch${NC}"
      errors=$((errors + 1))
    fi
  done
  return $errors
}

verify_branches() {
  echo ""
  info "═══ Verifying ═══"
  echo ""

  local errors=0

  verify_union_matches_original || errors=$((errors + 1))
  verify_no_session_artifacts || errors=$((errors + 1))
  verify_no_empty_commits || errors=$((errors + $?))

  echo ""
  if [ $errors -gt 0 ]; then
    echo -e "${RED}Verification failed with $errors error(s).${NC}"
    echo -e "${RED}Branches are intact — inspect and fix manually, or delete and retry.${NC}"
    echo "  Branches: ${CREATED_BRANCHES[*]}"
    echo "  You are on: $(git branch --show-current 2>/dev/null || echo 'detached')"
    cleanup_data
    exit 1
  fi
  info "✓ All checks passed."
}

# --- Summary ---

print_summary() {
  echo ""
  info "═══ Summary ═══"
  echo ""

  echo "Goal: $GOAL"
  echo "Base: ${BASE:0:12}"
  echo "Source branch: $ORIG_BRANCH"
  echo ""

  echo "Branches:"
  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    local title body branch group_number
    title=$(cat "$DATA_DIR/$i.title")
    body=$(cat "$DATA_DIR/$i.body")
    branch="${GROUP_BRANCH[$i]:-skipped}"
    group_number=$(printf "%02d" $((i + 1)))
    echo ""
    echo "  $group_number. $title"
    echo "     Branch: $branch"
    echo "     Files: $(tr '\n' ' ' < "$DATA_DIR/$i.files")"
    echo ""
    echo "$body" | sed 's/^/     /'
  done

  echo ""
  echo "Cleanup — after merging, delete the autoresearch branch and session files:"
  echo ""
  echo "  git branch -D $ORIG_BRANCH"
  echo "  rm -f autoresearch.jsonl autoresearch.sh autoresearch.md autoresearch.ideas.md"

  if [ -f "autoresearch.ideas.md" ]; then
    echo ""
    echo "Ideas backlog (from autoresearch.ideas.md):"
    echo ""
    sed 's/^/  /' autoresearch.ideas.md
  fi

  echo ""
  if [ "$STASHED" = true ]; then
    warn "Changes were stashed. Run 'git stash pop' to restore or 'git stash drop' to discard."
  fi
}

# --- Main ---

main() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 <groups.json>"
    exit 1
  fi

  parse_groups "$1"
  preflight
  create_branches
  verify_branches
  print_summary
  cleanup_data
}

main "$@"
