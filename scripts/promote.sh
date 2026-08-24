#!/bin/sh
# Stage-gated promotion of a built kernel artifact: dev -> staging -> canary
# -> prod.  Each stage writes a manifest pinning the exact artifact (sha256),
# its resolved .config, the git commit, and -- from staging on -- a golden
# measurement, SIGNED WITH THAT STAGE'S OWN KEY.  Promoting to stage S verifies
# the ENTIRE chain dev..prev(S): each manifest must exist, be signed by its
# own stage key, carry stage=<that stage>, pin the identical artifact, and its
# prev_manifest_sha256 must match the actual prior manifest.  So a stage cannot
# be skipped (a staging manifest is not a valid canary manifest -- different
# key AND stage field), a stage cannot be reused under another name, and the
# binary is identical end to end.  Keys are generated per stage on first use of
# THAT stage (so the dev runner never mints the prod key); in production each
# stage's key is held by that stage's authority / an HSM.  See docs/ROLLOUT.md.
#
#   scripts/promote.sh <dev|staging|canary|prod> <artifact-basename>
set -eu
cd "$(dirname "$0")/.."
OUT=out
ORDER="dev staging canary prod"

stage=${1:?usage: promote.sh <dev|staging|canary|prod> <artifact-basename>}
art=${2:?usage: promote.sh <dev|staging|canary|prod> <artifact-basename>}
case " $ORDER " in *" $stage "*) ;; *) echo "unknown stage: $stage" >&2; exit 2 ;; esac
[ -f "$OUT/$art" ] || { echo "no artifact $OUT/$art -- build it first" >&2; exit 2; }

MDIR=$OUT/manifests; PKI=$OUT/pki/promote
mkdir -p "$MDIR" "$PKI"
sha() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }
# each stage owns a distinct key; generate on first use of THAT stage only.
keygen() {
	[ -f "$PKI/$1.key" ] || openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$PKI/$1.key" -out "$PKI/$1.crt" -days 3650 \
		-subj "/CN=kvmhost-promote-$1" >/dev/null 2>&1
}
verify_sig() { # $1 manifest  $2 stage-whose-key
	[ -f "$PKI/$2.crt" ] || return 1
	pub=$(mktemp); openssl x509 -in "$PKI/$2.crt" -pubkey -noout > "$pub"
	openssl dgst -sha256 -verify "$pub" -signature "$1.sig" "$1" >/dev/null 2>&1
	rc=$?; rm -f "$pub"; return $rc
}

art_sha=$(sha "$OUT/$art")

# stage immediately before $stage, and the full chain up to it
prev=""; acc=""; chain=""
for s in $ORDER; do
	[ "$s" = "$stage" ] && { prev=$acc; break; }
	acc=$s; chain="$chain $s"
done

# --- the gate: verify the WHOLE chain dev..prev -------------------------------
prev_msha="-"
if [ -n "$prev" ]; then
	link_prev=""            # file of the manifest one stage lower (for link check)
	for s in $chain; do
		m=$MDIR/$art.$s.manifest
		[ -f "$m" ]                                   || { echo "GATE FAIL: missing '$s' manifest -- cannot enter '$stage' (no skipping)" >&2; exit 1; }
		verify_sig "$m" "$s"                          || { echo "GATE FAIL: '$s' manifest not signed by the '$s' key" >&2; exit 1; }
		[ "$(sed -n 's/^stage=//p' "$m")" = "$s" ]    || { echo "GATE FAIL: '$s' manifest carries a different stage= field (reused manifest?)" >&2; exit 1; }
		[ "$(sed -n 's/^artifact_sha256=//p' "$m")" = "$art_sha" ] || { echo "GATE FAIL: '$s' cleared a different binary than the one presented" >&2; exit 1; }
		if [ -n "$link_prev" ]; then
			[ "$(sed -n 's/^prev_manifest_sha256=//p' "$m")" = "$(sha "$link_prev")" ] || { echo "GATE FAIL: broken chain link at '$s'" >&2; exit 1; }
		fi
		link_prev=$m
	done
	prev_msha=$(sha "$MDIR/$art.$prev.manifest")
fi

keygen "$stage"

# derive the profile config exactly as build.sh names it (do NOT strip -arch:
# build.sh writes <profile>-<arch>.config for non-x86 and <profile>-dst for the
# destination track).
prof=$(echo "$art" | sed -E 's/^(bzImage|Image)-//')
cfg_sha="-"; [ -f "$OUT/$prof.config" ] && cfg_sha=$(sha "$OUT/$prof.config")
gitsha=$(git rev-parse --short HEAD 2>/dev/null || echo -)
tree=clean; [ -n "$(git status --porcelain 2>/dev/null)" ] && tree=dirty
golden="-"; [ "$stage" != dev ] && golden="measure-sha256:$art_sha"

man=$MDIR/$art.$stage.manifest
cat > "$man" <<MEOF
artifact=$art
artifact_sha256=$art_sha
config=$prof.config
config_sha256=$cfg_sha
git=$gitsha
git_tree=$tree
stage=$stage
prev_stage=${prev:--}
prev_manifest_sha256=$prev_msha
signed_by=$stage
golden_attestation=$golden
promoted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MEOF
openssl dgst -sha256 -sign "$PKI/$stage.key" -out "$man.sig" "$man"

echo "==> $art promoted to '$stage' (signed by the '$stage' key)"
[ -n "$prev" ] && echo "    gate OK: identical artifact cleared the full chain dev..'$prev'"
echo "    $man"
