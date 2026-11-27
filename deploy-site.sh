#!/usr/bin/env sh
# Deploy the static marketing site (site/) to Cloudflare Pages.
#
# Requires these in the environment (a scoped API token is enough):
#   CLOUDFLARE_API_TOKEN   - token with Account · Cloudflare Pages · Edit
#   CLOUDFLARE_ACCOUNT_ID  - your Cloudflare account id
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... ./deploy-site.sh
#
# Set CLOUDFLARE_PAGES_PROJECT to target a Pages project other than cue.
set -e
DIR="$(cd "$(dirname "$0")/site" && pwd)"
exec npx --yes wrangler@latest pages deploy "$DIR" \
  --project-name "${CLOUDFLARE_PAGES_PROJECT:-cue}" --branch main
