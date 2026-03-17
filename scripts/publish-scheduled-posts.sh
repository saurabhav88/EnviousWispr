#!/bin/bash
# Publish blog posts whose pubDate has arrived.
# Moves from content-engine/pipeline/drafts/ -> published/ (archive)
# Copies to website/src/content/blog/ with draft: false
# Max 2 posts per run to avoid Google indexing issues.
# Runs daily via launchd. Commits + pushes to trigger Cloudflare deploy.

set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$(pwd)/logs"
mkdir -p "$LOG_DIR"

DRAFTS_DIR="content-engine/pipeline/drafts"
PUBLISHED_DIR="content-engine/pipeline/published"
BLOG_DIR="website/src/content/blog"
TODAY=$(date +%Y-%m-%d)
MAX_PER_DAY=2
PUBLISHED=()

mkdir -p "$PUBLISHED_DIR"

# Collect eligible posts (pubDate <= today), sorted by pubDate (oldest first)
ELIGIBLE=()
while IFS='|' read -r pub_date filepath; do
  ELIGIBLE+=("$filepath")
done < <(
  for file in "$DRAFTS_DIR"/*.md; do
    [ -f "$file" ] || continue
    PUB_DATE=$(grep "^pubDate:" "$file" | head -1 | sed 's/pubDate: *//' | tr -d '"' | tr -d "'" | xargs)
    [ -z "$PUB_DATE" ] && continue
    if [[ ! "$PUB_DATE" > "$TODAY" ]]; then
      echo "${PUB_DATE}|${file}"
    fi
  done | sort -t'|' -k1
)

for file in "${ELIGIBLE[@]}"; do
  # Enforce daily limit
  if [[ ${#PUBLISHED[@]} -ge $MAX_PER_DAY ]]; then
    echo "[publish] Hit daily limit ($MAX_PER_DAY). Remaining eligible posts deferred to tomorrow."
    break
  fi

  BASENAME=$(basename "$file")

  # Copy to blog dir with draft flag flipped
  sed 's/^draft: true/draft: false/' "$file" > "$BLOG_DIR/$BASENAME"

  # Move original to published archive
  mv "$file" "$PUBLISHED_DIR/$BASENAME"

  PUBLISHED+=("$BASENAME")
  echo "[publish] Published: $BASENAME"
done

if [[ ${#PUBLISHED[@]} -eq 0 ]]; then
  echo "[publish] No posts to publish today ($TODAY)"
  exit 0
fi

echo "[publish] Publishing ${#PUBLISHED[@]} post(s)..."

# Stage drafts removal, published addition, and blog addition
git add "$DRAFTS_DIR" "$PUBLISHED_DIR" "$BLOG_DIR"
git commit -m "$(cat <<'COMMIT_EOF'
blog: publish scheduled post(s)

COMMIT_EOF
)$(echo "Posts: ${PUBLISHED[*]}")

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

git push

echo "[publish] Done. Cloudflare will auto-deploy."
