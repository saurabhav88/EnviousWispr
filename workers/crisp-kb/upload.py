#!/usr/bin/env python3
"""Upload KB articles to Crisp Helpdesk. Re-runnable: deletes all existing articles first."""

import json
import sys
import time
import urllib.request
import urllib.error
import base64
import os

CRISP_ID = open(os.path.expanduser("~/.enviouswispr-keys/crisp-plugin-identifier")).read().strip()
CRISP_KEY = open(os.path.expanduser("~/.enviouswispr-keys/crisp-plugin-key")).read().strip()
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
        body = e.read().decode()
        try:
            return json.loads(body)
        except:
            return {"error": True, "status": e.code, "raw": body}

def delete_all_articles():
    """Delete all existing articles to allow clean re-upload."""
    print("Cleaning existing articles...")
    deleted = 0
    while True:
        res = api("GET", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/articles/1")
        articles = res.get("data", [])
        if not articles:
            break
        for art in articles:
            aid = art["article_id"]
            api("DELETE", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{aid}")
            deleted += 1
            time.sleep(0.2)
    print(f"  Deleted {deleted} existing articles.")

def delete_all_categories():
    """Delete all existing categories."""
    print("Cleaning existing categories...")
    deleted = 0
    while True:
        res = api("GET", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/categories/1")
        cats = res.get("data", [])
        if not cats:
            break
        for cat in cats:
            cid = cat["category_id"]
            api("DELETE", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/category/{cid}")
            deleted += 1
            time.sleep(0.2)
    print(f"  Deleted {deleted} existing categories.")

def main():
    print("=== Crisp KB Upload (Python) ===\n")

    # Clean slate
    delete_all_articles()
    delete_all_categories()
    print()

    # Ensure locale exists
    api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale", {"locale": LOCALE})

    article_files = sorted([
        f for f in os.listdir("articles")
        if f.endswith(".json")
    ])

    total = 0
    errors = 0

    for jsonfile in article_files:
        path = os.path.join("articles", jsonfile)
        print(f"--- {jsonfile} ---")
        data = json.load(open(path))

        for cat in data.get("categories", []):
            cat_name = cat["name"]
            print(f"  Category: {cat_name}")

            cat_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/category", {"name": cat_name})
            cat_id = cat_res.get("data", {}).get("category_id")
            if not cat_id:
                print(f"    ERROR creating category: {cat_res}")
                errors += 1
                continue
            time.sleep(0.3)

            for sec in cat.get("sections", []):
                sec_name = sec["name"]
                print(f"    Section: {sec_name}")

                sec_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/category/{cat_id}/section", {"name": sec_name})
                sec_id = sec_res.get("data", {}).get("section_id")
                if not sec_id:
                    print(f"      ERROR creating section: {sec_res}")
                    errors += 1
                    continue
                time.sleep(0.3)

                for art in sec.get("articles", []):
                    title = art["title"]
                    print(f"      Article: {title}")

                    # Step 1: Create article (title only)
                    art_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article", {"title": title})
                    art_id = art_res.get("data", {}).get("article_id")
                    if not art_id:
                        print(f"        ERROR creating: {art_res}")
                        errors += 1
                        continue
                    time.sleep(0.3)

                    # Step 2: Update content
                    update_res = api("PATCH", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}", {
                        "title": title,
                        "description": art.get("description", ""),
                        "content": art.get("content", ""),
                    })
                    if update_res.get("error"):
                        print(f"        ERROR updating content: {update_res}")
                        errors += 1
                        continue
                    time.sleep(0.3)

                    # Step 3: Assign to category + section
                    api("PATCH", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}/category", {
                        "category_id": cat_id,
                        "section_id": sec_id,
                    })
                    time.sleep(0.3)

                    # Step 4: Publish
                    pub_res = api("POST", f"/website/{WEBSITE_ID}/helpdesk/locale/{LOCALE}/article/{art_id}/publish")
                    if pub_res.get("error"):
                        print(f"        ERROR publishing: {pub_res}")
                        errors += 1
                    else:
                        print(f"        OK")
                        total += 1
                    time.sleep(0.3)

        print()

    print(f"=== Done: {total} published, {errors} errors ===")
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main())
