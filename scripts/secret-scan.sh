#!/bin/sh
# Fail if anything that must not be public lands in the tracked tree: private
# keys, cloud/API tokens, or inline credentials.  Scans git-tracked files only
# (out/ is gitignored -- the promotion keys live there and never enter git).
# Run in CI on every push and locally before sharing the repo.
set -eu
cd "$(dirname "$0")/.."
bad=0

echo "== tracked key / cert / credential FILES =="
if git ls-files | grep -iE '\.(key|pem|p12|pfx)$|(^|/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)$|\.env$|secrets?\.(ya?ml|json|txt)$'; then
	echo "  ^^ a key/secret file is tracked -- must not be committed" >&2; bad=1
else echo "  none"; fi

echo "== secret-like STRINGS in tracked content =="
if git grep -InE 'BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|(password|passwd|secret|api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*.?[A-Za-z0-9/+_-]{12,}' \
	-- . ':!*.md' ':!scripts/secret-scan.sh'; then
	echo "  ^^ secret-like string in tracked content" >&2; bad=1
else echo "  none"; fi

if [ "$bad" -eq 0 ]; then echo "secret-scan: clean"; else echo "secret-scan: FINDINGS -- do not push" >&2; exit 1; fi
