#!/bin/sh
# Compatibility suite: runs mask and xc files (taken or derived from the
# upstream projects, see THIRD_PARTY_NOTICES.md) through `kevin --from` and
# checks the migrated result.
#
# Usage: tests/compat/run.sh [path/to/kevin]   (default: zig-out/bin/kevin)
#
# Layout: tests/compat/<suite>/inputs/*.md are the mask/xc files and
# tests/compat/<suite>/cases/*.case describe one expectation each. A case is
# a list of `key: value` lines (`#` starts a comment):
#
#   input: FILE               file in ../inputs, migrated with --from <suite>
#   args: WORDS               run `kevin -f <migrated> WORDS` (shell words);
#                             without `args` only the migration is checked
#   env: NAME=VALUE           extra environment for the run (repeatable)
#   run-in: DIR               run from a subdirectory of the migrated file's dir
#   requires: PROGRAM         skip the case when PROGRAM is not in PATH
#   os: windows | unix        skip the case on the other OS family
#   migrate-exit: N           expected exit code of the migration (default 0)
#   exit: N                   expected exit code of the run (default 0)
#   stdout-contains: TEXT     / stdout-not-contains: / stderr-contains:
#   stdout-equals: TEXT       exact stdout; `\n` is a newline
#   output-contains: TEXT     / output-not-contains: (the migrated Markdown)
#   output-equals-file: FILE  migrated Markdown equals FILE (relative to suite)
#   notes-contains: TEXT      a `kevin: note:` printed by the migration
#   lists: NAME               `kevin --help` lists command NAME
#   not-lists: NAME           ... does not list it
#   xfail: REASON             known gap: the case is expected to fail
#
# Every kevin process runs with a clean environment (PATH, HOME, LANG only).
# The summary counts pass / xfail / xpass / fail / skip; the exit code is 1
# when any case fails unexpectedly or passes while marked xfail.

set -u

here=$(cd "$(dirname "$0")" && pwd)
kevin_bin=${1:-zig-out/bin/kevin}
case $kevin_bin in
/*) ;;
*) kevin_bin="$(pwd)/$kevin_bin" ;;
esac
[ -x "$kevin_bin" ] || {
	echo "compat: kevin binary not found: $kevin_bin" >&2
	exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/kevin-compat.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

case $(uname -s 2>/dev/null) in
MINGW* | MSYS* | CYGWIN* | Windows_NT) os_family=windows ;;
*) os_family=unix ;;
esac

n_pass=0 n_xfail=0 n_xpass=0 n_fail=0 n_skip=0
xfail_list=""
problems=""

clean_env() {
	env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-C}" "$@"
}

value_of() { printf '%s' "${1#*:}" | sed 's/^[[:space:]]*//'; }

run_case() {
	case_file=$1 suite=$2 suite_dir=$3
	name="$suite/$(basename "$case_file" .case)"
	tmp=$(mktemp -d "$work/case.XXXXXX")

	input="" args="" has_args=0 env_words="" run_in="" xfail=""
	migrate_exit=0 want_exit=0 skip=""
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
		'#'* | '') continue ;;
		input:*) input=$(value_of "$line") ;;
		args:*) args=$(value_of "$line") has_args=1 ;;
		env:*) env_words="$env_words $(value_of "$line")" ;;
		run-in:*) run_in=$(value_of "$line") ;;
		migrate-exit:*) migrate_exit=$(value_of "$line") ;;
		exit:*) want_exit=$(value_of "$line") ;;
		xfail:*) xfail=$(value_of "$line") ;;
		requires:*)
			prog=$(value_of "$line")
			command -v "$prog" >/dev/null 2>&1 || skip="$prog not found in PATH"
			;;
		os:*)
			[ "$(value_of "$line")" = "$os_family" ] || skip="only runs on $(value_of "$line")"
			;;
		esac
	done <"$case_file"

	if [ -n "$skip" ]; then
		n_skip=$((n_skip + 1))
		echo "SKIP  $name ($skip)"
		return
	fi

	failures=""
	note_fail() { failures="$failures
      - $1"; }

	src="$suite_dir/inputs/$input"
	mig="$tmp/migrated.md"
	(cd "$tmp" && clean_env "$kevin_bin" --from "$suite" -f "$src" -o "$mig") \
		>"$tmp/mig.out" 2>"$tmp/notes"
	mig_rc=$?
	[ "$mig_rc" = "$migrate_exit" ] ||
		note_fail "migration exited $mig_rc, expected $migrate_exit: $(head -n 3 "$tmp/notes")"

	: >"$tmp/out"
	: >"$tmp/err"
	if [ "$has_args" = 1 ] && [ "$mig_rc" = 0 ]; then
		rundir="$tmp"
		if [ -n "$run_in" ]; then
			rundir="$tmp/$run_in"
			mkdir -p "$rundir"
		fi
		(cd "$rundir" && eval "clean_env $env_words \"\$kevin_bin\" -f \"\$mig\" $args") \
			>"$tmp/out" 2>"$tmp/err" </dev/null
		rc=$?
		[ "$rc" = "$want_exit" ] ||
			note_fail "exit code $rc, expected $want_exit (stderr: $(head -n 2 "$tmp/err" | tr '\n' ' '))"
	fi

	help_ready=0
	while IFS= read -r line || [ -n "$line" ]; do
		v=$(value_of "$line")
		case $line in
		stdout-contains:*) grep -qF -- "$v" "$tmp/out" || note_fail "stdout lacks '$v' (got: $(head -n 3 "$tmp/out" | tr '\n' '|'))" ;;
		stdout-not-contains:*) grep -qF -- "$v" "$tmp/out" && note_fail "stdout contains '$v'" ;;
		stderr-contains:*) grep -qF -- "$v" "$tmp/err" || note_fail "stderr lacks '$v' (got: $(head -n 2 "$tmp/err" | tr '\n' '|'))" ;;
		stdout-equals:*)
			printf '%b\n' "$v" >"$tmp/want"
			cmp -s "$tmp/want" "$tmp/out" || note_fail "stdout is '$(tr '\n' '|' <"$tmp/out")', expected '$(tr '\n' '|' <"$tmp/want")'"
			;;
		output-contains:*) grep -qF -- "$v" "$mig" 2>/dev/null || note_fail "migrated file lacks '$v'" ;;
		output-not-contains:*) grep -qF -- "$v" "$mig" 2>/dev/null && note_fail "migrated file contains '$v'" ;;
		output-equals-file:*) cmp -s "$suite_dir/$v" "$mig" || note_fail "migrated file differs from $v" ;;
		notes-contains:*) grep -qF -- "$v" "$tmp/notes" || note_fail "migration notes lack '$v'" ;;
		lists:* | not-lists:*)
			if [ "$help_ready" = 0 ]; then
				(cd "$tmp" && clean_env "$kevin_bin" -f "$mig" --help) 2>/dev/null |
					sed -n '/^Commands:/,/^$/p' | sed '1d;/^$/d;s/^  //' >"$tmp/listed"
				help_ready=1
			fi
			found=0
			while IFS= read -r row; do
				case $row in "$v" | "$v "*) found=1 ;; esac
			done <"$tmp/listed"
			case $line in
			lists:*) [ "$found" = 1 ] || note_fail "command '$v' is not listed" ;;
			*) [ "$found" = 0 ] || note_fail "command '$v' is listed" ;;
			esac
			;;
		esac
	done <"$case_file"

	if [ -z "$xfail" ]; then
		if [ -z "$failures" ]; then
			n_pass=$((n_pass + 1))
			echo "PASS  $name"
		else
			n_fail=$((n_fail + 1))
			echo "FAIL  $name$failures"
			problems="$problems
  FAIL  $name"
		fi
	else
		if [ -n "$failures" ]; then
			n_xfail=$((n_xfail + 1))
			echo "XFAIL $name"
			xfail_list="$xfail_list
  $name: $xfail"
		else
			n_xpass=$((n_xpass + 1))
			echo "XPASS $name (marked xfail: $xfail; remove the xfail line)"
			problems="$problems
  XPASS $name"
		fi
	fi
}

for suite in mask xc; do
	suite_dir="$here/$suite"
	for case_file in "$suite_dir"/cases/*.case; do
		[ -f "$case_file" ] || continue
		run_case "$case_file" "$suite" "$suite_dir"
	done
done

if [ -n "$xfail_list" ]; then
	echo
	echo "Known gaps (xfail):$xfail_list"
fi
echo
echo "compat: $n_pass passed, $n_xfail xfail, $n_xpass xpass, $n_fail failed, $n_skip skipped"
if [ -n "$problems" ]; then
	echo "compat: unexpected results:$problems"
	exit 1
fi
exit 0
