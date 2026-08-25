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
# Surviving is necessary but not sufficient.  A symbol can be =y and still do
# nothing, because whatever gave it something to do was stripped by a LATER
# fragment: CONFIG_PSTORE with every backend removed passes the symbol-by-symbol
# check above and then never records an oops.  The loop cannot see that -- the
# coupling is knowledge the fragment author has and Kconfig does not -- so the
# fragment states it, in a comment so merge_config.sh ignores it:
#
#   # ASSERT-ANY: CONFIG_PSTORE => CONFIG_PSTORE_RAM CONFIG_PSTORE_BLK
#   # ASSERT-ALL: CONFIG_OPENVSWITCH => CONFIG_NET_CLS_FLOWER CONFIG_NF_NAT
#
# ANY: if the left symbol resolved to y/m, at least one on the right must have
# too.  ALL: every one on the right must have.  Assertions are read from every
# fragment on the command line and evaluated against the RESOLVED config, which
# is the whole point: a later fragment that strips the subject makes them
# vacuous (an absent feature cannot be inert), one that strips the backends
# fails.
#
# usage: check-config.sh <.config> <fragment>...
set -eu

config=$1
shift

want_dir=$(mktemp -d)
trap 'rm -rf "$want_dir"' EXIT

# Assertions accumulate here as "<kind>\t<symbol>\t<targets>\t<fragment>".
# Dot-prefixed so it stays out of the CONFIG_* glob and find below.
assert_file="$want_dir/.assertions"
: >"$assert_file"

# A malformed assertion stops the build rather than silently never firing: a
# check nobody notices is worse than no check.  It also guarantees the sed
# patterns further down are only ever fed symbol names.
check_sym() {
	bad=""
	case $1 in
	CONFIG_?*) ;;
	*) bad="must start with CONFIG_" ;;
	esac
	if [ -z "$bad" ]; then
		case ${1#CONFIG_} in
		*[!A-Z0-9_]*) bad="is not a symbol name" ;;
		esac
	fi
	[ -z "$bad" ] || {
		echo "check-config: ASSERT line names '$1' -- it $bad [$2]" >&2
		exit 1
	}
}

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
		"# ASSERT-ANY:"* | "# ASSERT-ALL:"*)
			kind=${line#\# ASSERT-}
			kind=${kind%%:*}
			body=${line#*:}
			case $body in
			*"=>"*) ;;
			*)
				echo "check-config: ASSERT line has no '=>' [$name]: $line" >&2
				exit 1
				;;
			esac
			# Unquoted expansion on purpose: word splitting is what trims the
			# spaces around "=>" and normalises the target list.
			sym=""
			for t in ${body%%=>*}; do
				[ -z "$sym" ] || {
					echo "check-config: ASSERT line has more than one symbol left of '=>' [$name]: $line" >&2
					exit 1
				}
				sym=$t
			done
			check_sym "$sym" "$name"
			targets=""
			for t in ${body#*=>}; do
				check_sym "$t" "$name"
				targets="$targets $t"
			done
			[ -n "$targets" ] || {
				echo "check-config: ASSERT line has no symbols right of '=>' [$name]: $line" >&2
				exit 1
			}
			printf '%s\t%s\t%s\t%s\n' "$kind" "$sym" "${targets# }" "$name" \
				>>"$assert_file"
			;;
		esac
	done <"$frag"
done

fail=0
inert=0
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

# --- inertness assertions ---------------------------------------------------
# Everything above asks "did the symbol survive?".  This asks the question that
# survival does not answer: is it still wired to anything?  Evaluated against
# the resolved config, so a strip in a later fragment is visible here exactly
# as the kernel will see it.
asserts=0
while IFS='	' read -r kind sym targets from; do
	[ -n "$kind" ] || continue
	asserts=$((asserts + 1))
	got=$(sed -n "s/^$sym=//p" "$config" | head -1)
	# Not enabled -> nothing to be inert about.  This is what lets a profile
	# strip the whole feature without tripping its own assertion.
	case $got in
	y | m) ;;
	*) continue ;;
	esac

	have=""
	miss=""
	for t in $targets; do
		case $(sed -n "s/^$t=//p" "$config" | head -1) in
		y | m) have="$have $t" ;;
		*) miss="$miss $t" ;;
		esac
	done

	violated=""
	case $kind in
	ANY) [ -n "$have" ] || violated="none of these are" ;;
	ALL) [ -z "$miss" ] || violated="these are not" ;;
	esac
	if [ -n "$violated" ]; then
		printf 'INERT    %-45s =%s but %s enabled: %s [%s]\n' \
			"$sym" "$got" "$violated" "${miss# }" "$from"
		fail=$((fail + 1))
		inert=$((inert + 1))
	fi
done <"$assert_file"

count=$(find "$want_dir" -name 'CONFIG_*' | wc -l | tr -d ' ')

if [ "$fail" -ne 0 ]; then
	echo
	if [ "$((fail - inert))" -ne 0 ]; then
		echo "check-config: $((fail - inert)) of $count requested symbol(s) did not survive resolution." >&2
	fi
	if [ "$inert" -ne 0 ]; then
		echo "check-config: $inert of $asserts assertion(s) violated -- the symbol survived," >&2
		echo "but what makes it do anything did not.  A later fragment stripped it." >&2
	fi
	echo "Fix the fragment (or add the missing dependency) -- do not ship this." >&2
	exit 1
fi

echo "check-config: all $count requested symbols honoured in $(basename "$config")"
if [ "$asserts" -ne 0 ]; then
	echo "check-config: $asserts inertness assertion(s) hold"
fi
