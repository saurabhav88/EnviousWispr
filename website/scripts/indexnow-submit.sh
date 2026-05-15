#!/usr/bin/env bash
# IndexNow URL submitter for enviouswispr.com.
#
# Usage:
#   scripts/indexnow-submit.sh https://enviouswispr.com/blog/new-post/
#   scripts/indexnow-submit.sh --all          # submits every URL in the live sitemap
#
# Pushes notifications to Bing, Yandex, Naver via the IndexNow protocol. Free.
# Key file lives at https://enviouswispr.com/<KEY>.txt and must remain available.

set -euo pipefail
HOST="enviouswispr.com"
KEY="92397c9600e144958cb267c661aedfab"
KEY_LOCATION="https://${HOST}/${KEY}.txt"
ENDPOINT="https://api.indexnow.org/IndexNow"

submit_one() {
  local url="$1"
  curl -sS -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "{\"host\":\"${HOST}\",\"key\":\"${KEY}\",\"keyLocation\":\"${KEY_LOCATION}\",\"urlList\":[\"${url}\"]}" \
    -o /dev/null -w "  %{http_code}  ${url}\n"
}

submit_batch() {
  local payload="$1"
  curl -sS -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "$payload" \
    -w "\nHTTP %{http_code}\n"
}

if [[ "${1:-}" == "--all" ]]; then
  echo "Fetching live sitemap…"
  urls=$(curl -sS "https://${HOST}/sitemap-index.xml" \
    | grep -oE '<loc>[^<]+</loc>' \
    | sed -E 's,</?loc>,,g' \
    | xargs -n1 curl -sS \
    | grep -oE '<loc>[^<]+</loc>' \
    | sed -E 's,</?loc>,,g')

  list=$(echo "$urls" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  payload=$(python3 -c "import json,sys; key='${KEY}'; host='${HOST}'; kl='${KEY_LOCATION}'; u=json.loads('''$list'''); print(json.dumps({'host':host,'key':key,'keyLocation':kl,'urlList':u}))")
  echo "Submitting $(echo "$list" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') URLs…"
  submit_batch "$payload"
elif [[ $# -ge 1 ]]; then
  for url in "$@"; do
    submit_one "$url"
  done
else
  echo "Usage: $0 <url> [<url>…]   |   $0 --all"
  exit 1
fi
