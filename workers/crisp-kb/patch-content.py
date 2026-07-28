#!/usr/bin/env python3
"""Patch content onto existing Crisp articles and create any missing ones.

By default an article that already has content on Crisp is left alone, so a
re-run never clobbers hand-edits made in the Crisp UI. To push a CORRECTION to
an already-published article (the usual reason to touch this file), name it:

    python3 patch-content.py --update "What Data Is Collected"

Repeat --update per article, or pass --update-all to force every local article
over its remote copy. Titles must match the local JSON exactly.
"""

import json
import sys
import time
import urllib.request
import urllib.error
import base64
import os
import subprocess

GET_KEY = os.path.expanduser("~/.claude/bin/get-key")

def credential(env_var, key_name):
    """Read a Crisp credential from the environment, else from get-key.

    get-key refuses to print a value inside a Claude Code session, so an agent
    must bridge the values in as environment variables instead:

        ~/.claude/bin/get-key launch crisp-plugin-identifier CRISP_ID -- \\
        ~/.claude/bin/get-key launch crisp-plugin-key CRISP_KEY -- \\
        python3 patch-content.py --update "Some Article Title"

    A human running this outside Claude needs neither wrapper.
    """
    value = os.environ.get(env_var, "").strip()
    if value:
        return value
    return subprocess.check_output([GET_KEY, key_name], text=True).strip()

CRISP_ID = credential("CRISP_ID", "crisp-plugin-identifier")
CRISP_KEY = credential("CRISP_KEY", "crisp-plugin-key")
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

def parse_args(argv):
    """Return (update_titles, update_all). Unknown flags are a hard error."""
    titles = set()
    update_all = False
    i = 0
    while i < len(argv):
        if argv[i] == "--update-all":
            update_all = True
            i += 1
        elif argv[i] == "--update":
            if i + 1 >= len(argv):
                print("ERROR: --update needs an article title")
                sys.exit(2)
            titles.add(argv[i + 1])
            i += 2
        else:
            print(f"ERROR: unknown argument {argv[i]!r}")
            print(__doc__)
            sys.exit(2)
    return titles, update_all

def main():
    print("=== Crisp KB: Patch Content ===\n")

    update_titles, update_all = parse_args(sys.argv[1:])
    if update_all:
        print("Mode: --update-all (every local article overwrites its remote copy)\n")
    elif update_titles:
        print(f"Mode: --update {sorted(update_titles)}\n")

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

    # Fail closed on a typo: a --update title that matches nothing locally would
    # otherwise print a clean "0 patched" and look like a successful no-op run.
    unknown = update_titles - set(local_articles)
    if unknown:
        print(f"\nERROR: --update title not found in local JSON: {sorted(unknown)}")
        return 2

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
            forced = update_all or title in update_titles
            if has_content and not forced:
                print(f"  SKIP (has content): {title[:60]}")
                continue

            print(f"  {'UPDATE' if has_content else 'PATCH'}: {title[:60]}")
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
