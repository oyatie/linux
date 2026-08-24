#!/bin/sh
# Stage-gated promotion of a built kernel artifact: dev -> staging -> canary
# -> prod.  Each stage writes a SIGNED manifest pinning the exact artifact
# (sha256), its resolved .config, the git commit, and -- from staging on -- a
# golden measurement.  Promotion REFUSES to advance unless the previous stage's
# manifest verifies AND pins the identical artifact hash: no skipping a stage,
# and no shipping to prod a binary that did not pass canary.  dev signs with a
# throwaway dev CA; staging onward with the prod key -- the trust boundary
# where Secure Boot re-signing happens.  See docs/ROLLOUT.md.
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
for k in dev prod; do
	[ -f "$PKI/$k.key" ] || openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$PKI/$k.key" -out "$PKI/$k.crt" -days 3650 \
		-subj "/CN=kvmhost-promote-$k" >/dev/null 2>&1
done
sha() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }
signer_of() { [ "$1" = dev ] && echo dev || echo prod; }

# the stage immediately before $stage
prev=""; acc=""
for s in $ORDER; do [ "$s" = "$stage" ] && { prev=$acc; break; }; acc=$s; done

art_sha=$(sha "$OUT/$art")

# --- the gate: past dev, the prior manifest must verify AND pin this artifact
prev_ref="-"; prev_msha="-"
if [ -n "$prev" ]; then
	pm=$MDIR/$art.$prev.manifest
	[ -f "$pm" ] || { echo "GATE FAIL: $art has no '$prev' manifest -- cannot enter '$stage' (no skipping)" >&2; exit 1; }
	pub=$(mktemp); openssl x509 -in "$PKI/$(signer_of "$prev").crt" -pubkey -noout > "$pub"
	if ! openssl dgst -sha256 -verify "$pub" -signature "$pm.sig" "$pm" >/dev/null 2>&1; then
		rm -f "$pub"; echo "GATE FAIL: '$prev' manifest signature invalid" >&2; exit 1
	fi
	rm -f "$pub"
	pinned=$(sed -n 's/^artifact_sha256=//p' "$pm")
	if [ "$pinned" != "$art_sha" ]; then
		echo "GATE FAIL: artifact changed since '$prev'" >&2
		echo "  '$prev' cleared  $pinned" >&2
		echo "  now             $art_sha" >&2
		echo "  a binary that did not pass '$prev' cannot enter '$stage'." >&2
		exit 1
	fi
	prev_ref=$prev; prev_msha=$(sha "$pm")
fi

prof=$(echo "$art" | sed -E 's/^(bzImage|Image)-//; s/-arm64$//')
cfg_sha="-"; [ -f "$OUT/$prof.config" ] && cfg_sha=$(sha "$OUT/$prof.config")
gitsha=$(git rev-parse --short HEAD 2>/dev/null || echo -)
tree=clean; [ -n "$(git status --porcelain 2>/dev/null)" ] && tree=dirty
# golden measurement is captured on (real/emulated) silicon from staging on;
# here it stands in as the value a measured boot would extend into a PCR.
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
prev_stage=$prev_ref
prev_manifest_sha256=$prev_msha
signed_by=$(signer_of "$stage")
golden_attestation=$golden
promoted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MEOF
openssl dgst -sha256 -sign "$PKI/$(signer_of "$stage").key" -out "$man.sig" "$man"

echo "==> $art promoted to '$stage' (signed by $(signer_of "$stage"))"
[ "$prev_ref" != - ] && echo "    gate OK: identical artifact cleared '$prev_ref'"
echo "    $man"
