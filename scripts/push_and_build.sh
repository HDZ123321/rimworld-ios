#!/usr/bin/env bash
# Push the prepared payload repo to GitHub and trigger the macOS build.
#
#   GH_TOKEN=ghp_xxx GH_USER=yourname ./scripts/push_and_build.sh
#
# Optional:
#   REPO=rimworld-ios   (default)
#   PRIVATE=1           (default: public — Actions minutes are free & unlimited
#                        for public repos; private gets 2000 min/month on Free)
set -euo pipefail

: "${GH_TOKEN:?set GH_TOKEN to a PAT with repo + workflow scopes}"
: "${GH_USER:?set GH_USER to your GitHub username}"
REPO="${REPO:-rimworld-ios}"
PRIVATE="${PRIVATE:-0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

API="https://api.github.com"
AUTH=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")

echo "==> who am I"
curl -sf "${AUTH[@]}" "$API/user" | grep -E '"login"|"public_repos"' || {
  echo "token rejected by api.github.com"; exit 1; }

echo "==> create repo $GH_USER/$REPO (private=$PRIVATE)"
if [ "$PRIVATE" = "1" ]; then VIS=false; else VIS=true; fi
curl -s "${AUTH[@]}" -X POST "$API/user/repos" \
  -d "{\"name\":\"$REPO\",\"private\":$VIS,\"description\":\"RimWorld 1.6 iOS port - unsigned ipa via GitHub Actions\"}" \
  | grep -E '"full_name"|"message"' || true

echo "==> push"
git remote remove origin 2>/dev/null || true
git remote add origin "https://${GH_USER}:${GH_TOKEN}@github.com/${GH_USER}/${REPO}.git"
git push -u origin main --force

echo "==> workflow present?"
curl -s "${AUTH[@]}" "$API/repos/$GH_USER/$REPO/actions/workflows" \
  | grep -E '"name"|"path"|"state"'

echo "==> dispatch build"
curl -s "${AUTH[@]}" -X POST \
  "$API/repos/$GH_USER/$REPO/actions/workflows/build-ios.yml/dispatches" \
  -d '{"ref":"main"}' -w "dispatch http=%{http_code}\n"

echo
echo "watch: https://github.com/$GH_USER/$REPO/actions"
echo "ipa artifact appears as: RimWorld-unsigned-ipa"
