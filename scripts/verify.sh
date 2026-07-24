#!/usr/bin/env bash
# One-command verification gate for the notch app: build + unit self-tests +
# every script-level test suite, with an aggregate pass/fail summary. Run before
# pushing to feat/notch-app (or wire it as a pre-push hook — see --install-hook).
#
#   notch/scripts/verify.sh                 # run everything
#   notch/scripts/verify.sh --install-hook  # install a git pre-push hook
#
# Exits non-zero if any check fails. No external effects; all tests are local.
set -uo pipefail
cd "$(dirname "$0")/.."   # → notch/

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# ---- optional: install a pre-push hook that runs this script ----------------
if [ "${1:-}" = "--install-hook" ]; then
  repo_root="$(git rev-parse --show-toplevel)"
  hook="${repo_root}/.git/hooks/pre-push"
  # In a worktree, .git is a file pointing at the real gitdir; resolve it.
  if [ -f "${repo_root}/.git" ]; then
    gitdir="$(git rev-parse --git-common-dir)"
    hook="${gitdir}/hooks/pre-push"
  fi
  cat > "$hook" <<HOOK
#!/usr/bin/env bash
# Auto-installed by notch/scripts/verify.sh — gate pushes on the notch suite.
exec "$(pwd)/scripts/verify.sh"
HOOK
  chmod +x "$hook"
  echo "Installed pre-push hook: $hook"
  exit 0
fi

pass=0; fail=0
declare -a results

run() {
  local name="$1"; shift
  printf '%s==>%s %s\n' "$BOLD" "$RESET" "$name"
  if "$@"; then
    results+=("${GREEN}PASS${RESET}  ${name}"); pass=$((pass+1))
  else
    results+=("${RED}FAIL${RESET}  ${name}"); fail=$((fail+1))
  fi
  echo
}

# 1. Release-mode build (catches what debug sometimes hides).
run "swift build" swift build

# 2. In-process unit self-tests.
BIN="$(swift build --show-bin-path)/NotchApp"
run "self-tests (NOTCH_SELFTEST)" bash -c 'NOTCH_SELFTEST=1 "$0" | grep -q "all passed"' "$BIN"

# 3. Script-level suites (each spins the app up on its own port).
for suite in smoke-test telegram-mock-test telegram-backoff-test settings-merge-test hostapp-test single-instance-test client-drop-test; do
  if [ -x "scripts/${suite}.sh" ]; then
    run "scripts/${suite}.sh" bash "scripts/${suite}.sh"
  fi
done

# ---- summary ----------------------------------------------------------------
echo "${BOLD}── verification summary ──${RESET}"
for r in "${results[@]}"; do printf '  %s\n' "$r"; done
echo
if [ "$fail" -eq 0 ]; then
  echo "${GREEN}${BOLD}all ${pass} checks passed${RESET}"
  exit 0
else
  echo "${RED}${BOLD}${fail} of $((pass+fail)) checks FAILED${RESET} ${DIM}(safe to push only when green)${RESET}"
  exit 1
fi
