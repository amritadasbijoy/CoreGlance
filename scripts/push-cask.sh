#!/bin/bash
# Updates the Homebrew cask in the homebrew-tap repo. Used by the GitHub workflows.
#   TAP_DEPLOY_KEY=<private key> scripts/push-cask.sh <version> [zip file]
# TAP_DEPLOY_KEY is an SSH deploy key with write access to the tap repo only.
set -euo pipefail
VERSION="${1:?usage: push-cask.sh <version> [zip file]}"
ZIP="${2:-}"
: "${TAP_DEPLOY_KEY:?TAP_DEPLOY_KEY is not set}"

KEY=$(mktemp)
trap 'rm -f "$KEY"; rm -rf "$TAP"' EXIT
TAP=$(mktemp -d)
printf '%s\n' "$TAP_DEPLOY_KEY" > "$KEY"
chmod 600 "$KEY"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

git clone --quiet --depth 1 git@github.com:amritadasbijoy/homebrew-tap.git "$TAP"
"$(dirname "$0")/make-cask.sh" "$VERSION" $ZIP > "$TAP/Casks/coreglance.rb"

cd "$TAP"
if git diff --quiet; then
    echo "Cask is already at $VERSION, nothing to do."
    exit 0
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit --quiet -am "Update CoreGlance to $VERSION"
git push --quiet
echo "Cask updated to $VERSION."
