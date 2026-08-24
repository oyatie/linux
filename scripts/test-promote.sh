#!/bin/sh
# Unit tests for the promotion gate (scripts/promote.sh).  Uses a throwaway
# artifact -- no kernel build -- so it runs in a second while covering the gate
# logic: the happy-path chain, stage-skipping (both entering mid-pipeline and
# skipping to the end), the artifact-hash pin, signature tampering, and bad
# input.
set -u
cd "$(dirname "$0")/.."
OUT=out; MDIR=$OUT/manifests
ART=bzImage-promotest
pass=0; fail=0

setup()   { mkdir -p "$OUT"; head -c 4096 /dev/urandom > "$OUT/$ART"; echo "CONFIG_TEST=y" > "$OUT/promotest.config"; }
reset()   { rm -f "$MDIR/$ART".*.manifest "$MDIR/$ART".*.manifest.sig 2>/dev/null || true; }
cleanup() { reset; rm -f "$OUT/$ART" "$OUT/promotest.config"; }
run()     { ./scripts/promote.sh "$1" "$ART" >/tmp/promotest.$$ 2>&1; return $?; }

ok() { if [ "$1" -eq 0 ]; then pass=$((pass+1)); echo "  PASS  $2"
       else fail=$((fail+1)); echo "  FAIL  $2 (wanted success, got exit $1)"; sed 's/^/        | /' /tmp/promotest.$$; fi; }
no() { if [ "$1" -ne 0 ]; then pass=$((pass+1)); echo "  PASS  $2"
       else fail=$((fail+1)); echo "  FAIL  $2 (wanted failure, it succeeded)"; fi; }

trap cleanup EXIT
setup

echo "happy-path chain:"
reset
run dev;     ok $? "dev stamps the entry manifest"
run staging; ok $? "staging accepts the dev-cleared artifact"
run canary;  ok $? "canary accepts the staging-cleared artifact"
run prod;    ok $? "prod accepts the canary-cleared artifact"

echo "no entering mid-pipeline:"
reset
run staging; no $? "staging refused with no dev manifest"

echo "no skipping to the end:"
reset
run dev;  ok $? "dev stamps"
run prod; no $? "prod refused with only dev (no staging/canary)"

echo "artifact hash is pinned:"
reset
run dev;     ok $? "dev"
run staging; ok $? "staging"
printf 'tamper' >> "$OUT/$ART"
run canary;  no $? "canary refused after the binary changed"

echo "manifest signature tamper is caught:"
reset; setup
run dev; ok $? "dev"
echo "injected=evil" >> "$MDIR/$ART.dev.manifest"
run staging; no $? "staging refused on an altered (unsigned) dev manifest"

echo "bad input:"
reset
run bogus; no $? "unknown stage rejected"
./scripts/promote.sh dev bzImage-nope >/dev/null 2>&1; no $? "missing artifact rejected"

rm -f /tmp/promotest.$$
echo
echo "promote gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
