#!/bin/sh
# Verify that the resolved .config actually honours every fragment line.
#
# This is the load-bearing script in the repo.  Kconfig silently drops a
# `CONFIG_FOO=y` whose dependencies are unmet -- allnoconfig-based trees hit
# this constantly -- so "the kernel built" proves nothing about whether KVM,
# the IOMMU, or a mitigation is actually in the image.  Here we diff intent
# against outcome, symbol by symbol.
#
# Fragments are applied in order and later ones override earlier ones (that is
# how kver-*.config and opt-*.config work), so intent is resolved the same way
# before comparing: last fragment to mention a symbol wins.
#
# usage: check-config.sh <.config> <fragment>...
set -eu

config=$1
shift

want_dir=$(mktemp -d)
trap 'rm -rf "$want_dir"' EXIT

# Collect intent: one file per symbol holding "<value>\t<fragment>".
for frag in "$@"; do
	name=$(basename "$frag")
	while IFS= read -r line; do
		case $line in
		CONFIG_*=*)
			printf '%s\t%s\n' "${line#*=}" "$name" >"$want_dir/${line%%=*}"
			;;
		"# CONFIG_"*" is not set")
			sym=${line#\# }
			sym=${sym%% *}
			printf '%s\t%s\n' "__unset__" "$name" >"$want_dir/$sym"
			;;
		esac
	done <"$frag"
done

fail=0
overrides=0

for path in "$want_dir"/CONFIG_*; do
	[ -e "$path" ] || continue
	sym=$(basename "$path")
	want=$(cut -f1 "$path")
	from=$(cut -f2 "$path")
	got=$(sed -n "s/^$sym=//p" "$config" | head -1)

	if [ "$want" = "__unset__" ]; then
		if [ -n "$got" ]; then
			printf 'RESURRECTED %-42s want=n got=%s (something selects it) [%s]\n' \
				"$sym" "$got" "$from"
			fail=$((fail + 1))
		fi
	elif [ -z "$got" ]; then
		printf 'MISSING  %-45s want=%s (dependency unmet or symbol renamed) [%s]\n' \
			"$sym" "$want" "$from"
		fail=$((fail + 1))
	elif [ "$got" != "$want" ]; then
		printf 'MISMATCH %-45s want=%s got=%s [%s]\n' "$sym" "$want" "$got" "$from"
		fail=$((fail + 1))
	fi
done

count=$(find "$want_dir" -name 'CONFIG_*' | wc -l | tr -d ' ')

if [ "$fail" -ne 0 ]; then
	echo
	echo "check-config: $fail of $count requested symbol(s) did not survive resolution." >&2
	echo "Fix the fragment (or add the missing dependency) -- do not ship this." >&2
	exit 1
fi

echo "check-config: all $count requested symbols honoured in $(basename "$config")"
