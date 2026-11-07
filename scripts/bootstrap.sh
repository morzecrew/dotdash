#!/usr/bin/env bash
# Prepares a fresh Debian or Ubuntu server for dotdash: Docker and Compose from
# Docker's own repository, sops, age, zstd, minisign and qrencode, morzer, SSH
# that takes keys only, and unattended security updates. Run again, it redoes
# nothing that is already done.
#
#   curl -fsSLO https://raw.githubusercontent.com/morzecrew/dotdash/main/scripts/bootstrap.sh
#   less bootstrap.sh && sudo bash bootstrap.sh
#
# It leaves the firewall alone: Docker's published ports bypass ufw and
# firewalld anyway, and an SSH port guessed wrong would lock you out.
set -euo pipefail

MORZER_VERSION=0.12.0
SOPS_VERSION=3.13.3
declare -A SOPS_SHA256=(
	[amd64]=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
	[arm64]=53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77
)

say() { printf 'bootstrap: %s\n' "$*"; }
die() {
	printf 'bootstrap: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || die "run it as root: sudo bash $0"
# shellcheck source=/dev/null
. /etc/os-release
case ${ID} in debian | ubuntu) ;; *) die "Debian or Ubuntu only, not ${ID}" ;; esac
arch=$(dpkg --print-architecture)
[ -n "${SOPS_SHA256[${arch}]:-}" ] || die "amd64 or arm64 only, not ${arch}"

export DEBIAN_FRONTEND=noninteractive
say "packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl zstd age minisign qrencode unattended-upgrades >/dev/null

# The distribution's docker.io is older than the Docker 28 and Compose 2.35
# dotdash requires.
if ! docker compose version >/dev/null 2>&1; then
	say "Docker, from download.docker.com"
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
		>/etc/apt/sources.list.d/docker.list
	apt-get update -qq
	apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null

if ! sops --version 2>/dev/null | grep -q "^sops ${SOPS_VERSION}"; then
	say "sops ${SOPS_VERSION}"
	tmp=$(mktemp)
	trap 'rm -f "${tmp}"' EXIT
	curl -fsSL -o "${tmp}" "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}"
	echo "${SOPS_SHA256[${arch}]}  ${tmp}" | sha256sum -c --quiet
	install -m 0755 "${tmp}" /usr/local/bin/sops
fi

if ! morzer --version 2>/dev/null | grep -q " ${MORZER_VERSION}\$"; then
	say "morzer ${MORZER_VERSION}"
	# The installer of that release checks the archive's minisign signature.
	curl -fsSL "https://raw.githubusercontent.com/morzecrew/morzer/v${MORZER_VERSION}/install.sh" |
		sh -s -- --version "${MORZER_VERSION}" --dir /usr/local/bin --require-signature \
			--no-modify-path --no-completions >/dev/null
fi

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Keys only, but never on a machine nobody could then log in to. sshd keeps the
# first value it reads, and this file sorts before cloud-init's 50-.
if command -v sshd >/dev/null; then
	keys=$(cat /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null | grep -c -E '^(ssh-|ecdsa-|sk-)' || true)
	if [ "${keys}" -gt 0 ]; then
		say "SSH: keys only"
		install -d /etc/ssh/sshd_config.d
		cat >/etc/ssh/sshd_config.d/10-dotdash.conf <<'EOF'
# bootstrap.sh: keys only.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
		install -d -m 0755 /run/sshd # sshd -t wants it; ssh.service makes it when it starts
		sshd -t
		# A no-op while sshd is not running, as under Ubuntu's socket activation.
		systemctl try-reload-or-restart ssh.service 2>/dev/null || systemctl try-reload-or-restart sshd.service
	else
		say "SSH: no authorized key on this machine, so password login stays on; add one and run this again"
	fi
fi

say "done: $(docker --version | cut -d, -f1), compose $(docker compose version --short), $(sops --version | head -1), $(morzer --version)"
say "next: DNS, then step 3 of the README's Install"
