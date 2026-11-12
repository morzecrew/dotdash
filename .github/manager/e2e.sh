#!/usr/bin/env bash
# dotdash-manager against a real server, in the rig: an authority on a file://
# target, the server following it. The first sync hands the server the
# manager's keys and devices; once it applied them, its facts say so, and the
# second sync has nothing to change.
set -euo pipefail
die() { echo "e2e: $*" >&2; exit 1; }

apk add --no-cache --quiet python3 age
m=/rig/manager t=/rig/state
mkdir -p "${m}" "${t}"
authority=$(morzer state key generate "${m}/authority.key")
age-keygen -o "${m}/authority.age" 2>/dev/null
recipient=$(age-keygen -y "${m}/authority.age")

sudo morzer config set sync.target="file://${t}" sync.authority="${authority}" sync.recipient="${recipient}" >/dev/null ||
  die "could not point the server at the authority"
sudo morzer backup target add "file://${t}" >/dev/null || die "could not add the target"
sudo morzer fleet publish >/dev/null || die "the server could not publish its row"
row=$(sudo morzer fleet publish --dry-run --json)
id=$(jq -r .data.row.installation_id <<<"${row}")
key=$(jq -r .data.row.signing_key <<<"${row}")

cat >"${m}/network.toml" <<EOF
target = "file://${t}"
key = "${m}/authority.key"
identity = "${m}/authority.age"
authority = "${authority}"
subscription = true
devices = ["phone"]

[[server]]
name = "a"
id = "${id}"
key = "${key}"
EOF
mgr() { python3 /rig/dotdash_manager.py --roster "${m}/network.toml" "$@"; }

out=$(mgr sync) || die "the first sync failed: ${out}"
grep -q '^a: published$' <<<"${out}" || die "the first sync published nothing for the server: ${out}"
echo "e2e: the first sync published the server's document"

sudo morzer config set sync.enabled=true >/dev/null
sudo morzer sync now || die "the server did not apply the document: $(sudo morzer sync status 2>&1)"
sudo morzer fleet publish >/dev/null || die "the server could not publish its row and facts"

pbk=$(python3 -c "import json, sys; sys.path.insert(0, '/rig'); import dotdash_manager as d; \
print(d.public_key(json.load(open('${m}/dotdash-state.json'))['keys']['reality_key']))")
links=$(sudo morzer task run client-config --output -- --full)
grep -q '^== phone ==$' <<<"${links}" || die "the server's devices are not the roster's: ${links}"
grep 'security=reality' <<<"${links}" | grep -qF "pbk=${pbk}" || die "the server's links do not carry the manager's key"
echo "e2e: the server applied it: the roster's device, the manager's keys"

out=$(mgr sync) || die "the second sync failed: ${out}"
! grep -q '^waiting: a:' <<<"${out}" || die "the manager does not see the server's facts with its keys: ${out}"
grep -q '^a: unchanged$' <<<"${out}" || die "the second sync changed the server's document: ${out}"
mgr status >/dev/null || die "status failed"
echo "e2e: the server's facts show the keys applied, and the second sync has nothing to change"
