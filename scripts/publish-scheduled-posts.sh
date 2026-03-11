#!/bin/bash
# Publish blog posts whose pubDate has arrived (draft: true → false)
# Runs daily via cron. Commits + pushes to trigger Cloudflare deploy.

set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR="$(pwd)/logs"
mkdir -p "$LOG_DIR"

BLOG_DIR="website/src/content/blog"
TODAY=$(date +%Y-%m-%d)
PUBLISHED=()

for file in "$BLOG_DIR"/*.md; do
  # Skip duplicate files
  [[ "$file" == *" 2"* ]] && continue

  # Only process drafts
  grep -q "^draft: true" "$file" || continue

  # Extract pubDate
  PUB_DATE=$(grep "^pubDate:" "$file" | head -1 | sed 's/pubDate: *//' | tr -d '"' | tr -d "'" | xargs)

  # If pubDate <= today, publish it
  if [[ "$PUB_DATE" <= "$TODAY" ]]; then
    sed -i '' 's/^draft: true/draft: false/' "$file"
    PUBLISHED+=("$(basename "$file")")
    echo "[publish] $PUB_DATE <= $TODAY → $(basename "$file")"
  fi
done

if [[ ${#PUBLISHED[@]} -eq 0 ]]; then
  echo "[publish] No posts to publish today ($TODAY)"
  exit 0
fi

echo "[publish] Publishing ${#PUBLISHED[@]} post(s)..."

# Commit and push
git add "$BLOG_DIR"/*.md
git commit -m "blog: publish ${#PUBLISHED[@]} scheduled post(s) for $TODAY

Posts: ${PUBLISHED[*]}

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

git push

echo "[publish] Done. Cloudflare will auto-deploy."
