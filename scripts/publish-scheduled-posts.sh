#!/bin/bash
# Publish blog posts whose pubDate has arrived.
# Moves from content-engine/pipeline/drafts/ -> website/src/content/blog/
# Flips draft: true -> draft: false on move.
# Runs daily via cron. Commits + pushes to trigger Cloudflare deploy.

set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR="$(pwd)/logs"
mkdir -p "$LOG_DIR"

DRAFTS_DIR="content-engine/pipeline/drafts"
BLOG_DIR="website/src/content/blog"
TODAY=$(date +%Y-%m-%d)
PUBLISHED=()

for file in "$DRAFTS_DIR"/*.md; do
  [ -f "$file" ] || continue

  # Extract pubDate
  PUB_DATE=$(grep "^pubDate:" "$file" | head -1 | sed 's/pubDate: *//' | tr -d '"' | tr -d "'" | xargs)
  [ -z "$PUB_DATE" ] && continue

  # If pubDate <= today, publish it
  if [[ ! "$PUB_DATE" > "$TODAY" ]]; then
    BASENAME=$(basename "$file")

    # Flip draft flag and move to blog dir
    sed 's/^draft: true/draft: false/' "$file" > "$BLOG_DIR/$BASENAME"
    rm "$file"

    PUBLISHED+=("$BASENAME")
    echo "[publish] $PUB_DATE <= $TODAY -- $BASENAME"
  fi
done

if [[ ${#PUBLISHED[@]} -eq 0 ]]; then
  echo "[publish] No posts to publish today ($TODAY)"
  exit 0
fi

echo "[publish] Publishing ${#PUBLISHED[@]} post(s)..."

# Stage both the removal from drafts and addition to blog
git add "$DRAFTS_DIR" "$BLOG_DIR"
git commit -m "$(cat <<EOF
blog: publish ${#PUBLISHED[@]} scheduled post(s) for $TODAY

Posts: ${PUBLISHED[*]}

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"

git push

echo "[publish] Done. Cloudflare will auto-deploy."
