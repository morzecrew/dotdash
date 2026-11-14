#!/usr/bin/env bash
# What every update starts with: a backup of the registrations, encrypted for
# the installation's recipients. The rig runs init with
# --no-recovery-recipient, so this passes only while the release makes init
# create the encrypted state (secrets.schema.yaml, morzer#363).
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer backup --no-push 2>&1) || die "backup failed: $(tail -3 <<<"${out}")"
echo "20-backup.sh: the registrations back up with the rig's recipients"
