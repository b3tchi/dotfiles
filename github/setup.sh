#!/bin/sh
# github/setup.sh - ssh access to GitHub for this machine, so dots can clone
# the private repos (the phone's nothing-pmos and kwi3 clones). Idempotent:
#
#   - ~/.ssh/id_ed25519, created without a passphrase if missing, so rotz can
#     fetch unattended. It is an ACCOUNT key: whoever reads it can push to
#     every repo. Keep the machine's disk encrypted and its screen locked.
#   - GitHub's ed25519 host key, pinned in ~/.ssh/known_hosts from the value
#     GitHub publishes (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU),
#     never learned on first use. A different github.com key already there
#     stops the run and is left for a human to look at.
#   - gh logged in over ssh, once: `gh auth login --web` prints a code to
#     approve at https://github.com/login/device on any other device.
#   - the key added to the account, once (checked against `gh api user/keys`).
#
# Runs from github/dot.yaml after gh and openssh are installed.
set -u

KEY="$HOME/.ssh/id_ed25519"
KH="$HOME/.ssh/known_hosts"
PIN="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "$(id -un)@$(hostname)" -f "$KEY" || exit 1
  echo "github: created $KEY"
fi

if ! grep -qxF "$PIN" "$KH" 2>/dev/null; then
  if [ -f "$KH" ] && ssh-keygen -F github.com -f "$KH" 2>/dev/null | grep -q 'ssh-ed25519'; then
    echo "github: $KH has a github.com ed25519 key that is not GitHub's published one -- refusing; check it by hand." >&2
    exit 1
  fi
  printf '%s\n' "$PIN" >>"$KH"
  chmod 600 "$KH"
  echo "github: pinned GitHub's host key in $KH"
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "github: one-time login - approve the code at https://github.com/login/device on another device"
  gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web \
    --scopes admin:public_key || { echo "github: gh login failed" >&2; exit 1; }
fi

pub=$(cut -d' ' -f1,2 "$KEY.pub")
if ! gh api user/keys --jq '.[].key' 2>/dev/null | grep -qxF "$pub"; then
  gh ssh-key add "$KEY.pub" --title "$(hostname)" || { echo "github: adding $KEY.pub failed" >&2; exit 1; }
  echo "github: added $KEY.pub to the GitHub account"
fi
echo "github: ssh access ready"
