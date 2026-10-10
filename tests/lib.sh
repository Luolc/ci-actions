#!/usr/bin/env bash
# Helpers shared by the tests. Each test runs in its own bash process, so
# the state set up here never leaks from one test into another.

export ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "${3:-value}: want [$2], got [$1]"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "want [$2] in: $1"
}
