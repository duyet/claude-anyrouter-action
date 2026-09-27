#!/usr/bin/env bash
#
# Shared test helpers: assertion counters and a parser for the $GITHUB_ENV
# environment-file format (both `NAME=value` and `NAME<<EOF ... EOF`).

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  ok   %s\n' "$1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2-}" ]; then
    printf '       %s\n' "$2"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$name"
  else
    _fail "$name" "expected '${expected}', got '${actual}'"
  fi
}

assert_ne() {
  local unexpected="$1" actual="$2" name="$3"
  if [ "$unexpected" != "$actual" ]; then
    _pass "$name"
  else
    _fail "$name" "expected value other than '${unexpected}'"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) _pass "$name" ;;
    *) _fail "$name" "expected to contain '${needle}'" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) _fail "$name" "expected NOT to contain '${needle}'" ;;
    *) _pass "$name" ;;
  esac
}

assert_status() {
  local expected="$1" actual="$2" name="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$name"
  else
    _fail "$name" "expected exit ${expected}, got ${actual}"
  fi
}

# print_env_var <env-file> <name>
# Prints the value of <name>, or nothing when it is absent.
print_env_var() {
  python3 - "$1" "$2" <<'PY'
import sys

path, wanted = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")

value = None
i = 0
while i < len(lines):
    line = lines[i]
    if "<<" in line and line.split("<<", 1)[0] == wanted:
        delim = line.split("<<", 1)[1]
        buf = []
        i += 1
        while i < len(lines) and lines[i] != delim:
            buf.append(lines[i])
            i += 1
        value = "\n".join(buf)
    elif "=" in line and line.split("=", 1)[0] == wanted:
        value = line.split("=", 1)[1]
    i += 1

print(value if value is not None else "", end="")
PY
}

# env_var_names <env-file>
# Prints every variable name written to the file, one per line.
env_var_names() {
  python3 - "$1" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
names = []
i = 0
while i < len(lines):
    line = lines[i]
    if "<<" in line:
        delim = line.split("<<", 1)[1]
        name = line.split("<<", 1)[0]
        if name:
            names.append(name)
        i += 1
        while i < len(lines) and lines[i] != delim:
            i += 1
    elif "=" in line:
        names.append(line.split("=", 1)[0])
    i += 1

print("\n".join(names))
PY
}

summary() {
  local name="$1"
  printf '\n%s: %d assertions, %d failed\n' "$name" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
