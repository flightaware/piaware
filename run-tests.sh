#!/bin/sh
#
# Run every tcltest suite (*.test) in the tree.
#
# tcltest exits 0 even when tests fail, so a suite's exit status alone
# can't be trusted. Each suite runs with "-verbose pbe" and counts as
# failed if it exits non-zero, has any failing test, or runs no tests at
# all (e.g. every test skipped).
#
# Set TCLSH to choose the interpreter (default: tclsh).
#

TCLSH=${TCLSH:-tclsh}
top=$(cd "$(dirname "$0")" && pwd)
cd "$top" || exit 1

suites_list=$(mktemp) || exit 1
output=$(mktemp) || exit 1
trap 'rm -f "$suites_list" "$output"' EXIT

find . -name '*.test' -type f -not -path './.git/*' | sort > "$suites_list"

suites=0
failures=0

# read from a file rather than a pipe so the counters survive the loop,
# and line by line so paths with spaces work
while IFS= read -r suite; do
	suites=$((suites + 1))
	dir=$(dirname "$suite")
	name=$(basename "$suite")

	(cd "$dir" && "$TCLSH" "./$name" -verbose pbe) >"$output" 2>&1
	code=$?
	passed=$(grep -c '^++++ .* PASSED' "$output")
	# with "-verbose b", tcltest prints this once for each failing test,
	# whatever the test is called
	failed=$(grep -c '^==== Contents of test case:' "$output")

	if [ "$code" -ne 0 ] || [ "$failed" -ne 0 ] || [ "$passed" -eq 0 ]; then
		failures=$((failures + 1))
		echo "FAIL $suite: $passed passed, $failed failed, exit status $code"
		cat "$output"
	else
		echo "ok   $suite: $passed passed"
	fi
done < "$suites_list"

if [ "$suites" -eq 0 ]; then
	echo "no test suites found"
	exit 1
fi

echo "$suites suites, $failures failed"
[ "$failures" -eq 0 ]
