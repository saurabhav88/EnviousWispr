#!/usr/bin/env python3
"""IndexNow submission for enviouswispr.com.

Pings Bing/Yahoo/DuckDuckGo (and indirectly influences Google) to crawl URLs.
Run after each significant content update or once per week if no updates.

The key file at https://enviouswispr.com/<KEY>.txt must exist (Cloudflare-deployed
from website/public/<KEY>.txt) before this script will succeed.
"""
import json
import re
import sys
import urllib.request

KEY = "3e345cfbde2a56c127b50a9204258f4fde05f2c40fa3bc79ac94ab9305d07d59"
SITEMAP = "https://enviouswispr.com/sitemap-0.xml"
INDEXNOW_ENDPOINT = "https://api.indexnow.org/indexnow"
UA = "Mozilla/5.0 (compatible; EnviousWispr-IndexNow/1.0)"


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=15).read().decode()


def main() -> int:
    sitemap = fetch(SITEMAP)
    urls = re.findall(r"<loc>([^<]+)</loc>", sitemap)
    if not urls:
        print("No URLs found in sitemap.", file=sys.stderr)
        return 1

    body = {
        "host": "enviouswispr.com",
        "key": KEY,
        "keyLocation": f"https://enviouswispr.com/{KEY}.txt",
        "urlList": urls,
    }
    req = urllib.request.Request(
        INDEXNOW_ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": UA,
        },
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        print(f"IndexNow {resp.status} {resp.reason} — submitted {len(urls)} URLs")
        return 0
    except urllib.error.HTTPError as e:
        print(f"IndexNow HTTP {e.code}: {e.reason}", file=sys.stderr)
        print(f"Body: {e.read().decode()}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
