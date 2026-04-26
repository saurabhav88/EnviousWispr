#!/usr/bin/env python3
"""Patch content onto existing Crisp articles and create any missing ones."""

import json
import sys
import time
import urllib.request
import urllib.error
import base64
import os
import subprocess

GET_KEY = os.path.expanduser("~/.claude/bin/get-key")
CRISP_ID = subprocess.check_output([GET_KEY, "crisp-plugin-identifier"], text=True).strip()
CRISP_KEY = subprocess.check_output([GET_KEY, "crisp-plugin-key"], text=True).strip()
WEBSITE_ID = "6cfca684-ab92-4927-a1a3-6bf97eac13f9"
LOCALE = "en"
BASE = "https://api.crisp.chat/v1"
AUTH = base64.b64encode(f"{CRISP_ID}:{CRISP_KEY}".encode()).decode()

def api(method, path, data=None):
    url = f"{BASE}{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Basic {AUTH}")
    req.add_header("X-Crisp-Tier", "plugin")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        try:
            return json.loads(body_text)
        except:
            return {"error": True, "status": e.code, "raw": body_text}

def get_all_articles():
    """Fetch all existing articles from Crisp, keyed by title."""
    articles = {}
    page = 1
    while True:
        res = api("GET", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/articles/{page}")
        data = res.get("data", [])
        if not data or not isinstance(data, list):
            break
        for a in data:
            articles[a["title"]] = a
        page += 1
        time.sleep(0.3)
    return articles

def get_all_categories():
    """Fetch existing categories."""
    cats = {}
    page = 1
    while True:
        res = api("GET", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/categories/{page}")
        data = res.get("data", [])
        if not data or not isinstance(data, list):
            break
        for c in data:
            cats[c["name"]] = c
        page += 1
        time.sleep(0.3)
    return cats

def main():
    print("=== Crisp KB: Patch Content ===\n")

    # Load all local articles
    local_articles = {}  # title -> {title, description, content, category, section}
    article_files = sorted(f for f in os.listdir("articles") if f.endswith(".json"))

    for jsonfile in article_files:
        data = json.load(open(os.path.join("articles", jsonfile)))
        for cat in data.get("categories", []):
            for sec in cat.get("sections", []):
                for art in sec.get("articles", []):
                    local_articles[art["title"]] = {
                        **art,
                        "category": cat["name"],
                        "section": sec["name"],
                    }

    print(f"Local articles: {len(local_articles)}")

    # Fetch remote state
    remote = get_all_articles()
    print(f"Remote articles: {len(remote)}")
    remote_cats = get_all_categories()
    print(f"Remote categories: {len(remote_cats)}\n")

    patched = 0
    created = 0
    errors = 0

    for title, local in local_articles.items():
        if title in remote:
            # Article exists, patch content
            art_id = remote[title]["article_id"]
            has_content = bool(remote[title].get("content"))
            if has_content:
                print(f"  SKIP (has content): {title[:60]}")
                continue

            print(f"  PATCH: {title[:60]}")
            res = api("PATCH", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}", {
                "title": title,
                "description": local.get("description", ""),
                "content": local.get("content", ""),
            })
            if res.get("error"):
                print(f"    ERROR: {res}")
                errors += 1
            else:
                patched += 1
            time.sleep(0.4)
        else:
            # Article missing, need to create
            print(f"  CREATE: {title[:60]}")

            # Ensure category exists
            cat_name = local["category"]
            if cat_name not in remote_cats:
                cat_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/category", {"name": cat_name})
                cat_id = cat_res.get("data", {}).get("category_id")
                if cat_id:
                    remote_cats[cat_name] = {"category_id": cat_id, "name": cat_name}
                    time.sleep(0.3)
                else:
                    print(f"    ERROR creating category: {cat_res}")
                    errors += 1
                    continue
            else:
                cat_id = remote_cats[cat_name]["category_id"]

            # Create section (sections can duplicate, which is fine)
            sec_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/category/{cat_id}/section", {"name": local["section"]})
            sec_id = sec_res.get("data", {}).get("section_id")
            if not sec_id:
                print(f"    ERROR creating section: {sec_res}")
                errors += 1
                continue
            time.sleep(0.3)

            # Create article
            art_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article", {"title": title})
            art_id = art_res.get("data", {}).get("article_id")
            if not art_id:
                print(f"    ERROR creating article: {art_res}")
                errors += 1
                continue
            time.sleep(0.3)

            # Patch content
            api("PATCH", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}", {
                "title": title,
                "description": local.get("description", ""),
                "content": local.get("content", ""),
            })
            time.sleep(0.3)

            # Assign category
            api("PATCH", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}/category", {
                "category_id": cat_id,
                "section_id": sec_id,
            })
            time.sleep(0.3)

            # Publish
            api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}/publish")
            created += 1
            time.sleep(0.3)

    print(f"\n=== Done: {patched} patched, {created} created, {errors} errors ===")
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main())
