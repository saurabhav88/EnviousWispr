#!/bin/bash
# upload.sh -- Upload all KB articles to Crisp Helpdesk via REST API.
# Reads JSON article files, creates categories/sections/articles, publishes them.
# Usage: cd workers/crisp-kb && bash upload.sh

set -uo pipefail

CRISP_ID=$("$HOME/.claude/bin/get-key" crisp-plugin-identifier)
CRISP_KEY=$("$HOME/.claude/bin/get-key" crisp-plugin-key)
WEBSITE_ID="6cfca684-ab92-4927-a1a3-6bf97eac13f9"
LOCALE="en"
BASE="https://api.crisp.chat/v1"

api() {
  local method=$1 path=$2
  shift 2
  curl -s -X "$method" "$BASE$path" \
    --user "$CRISP_ID:$CRISP_KEY" \
    --header "X-Crisp-Tier: plugin" \
    --header "Content-Type: application/json" \
    "$@"
}

echo "=== Crisp KB Upload ==="

# Check if helpdesk exists, initialize if not
echo "Checking helpdesk..."
hd=$(api GET "/website/$WEBSITE_ID/helpdesk")
if echo "$hd" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('data') else 1)" 2>/dev/null; then
  echo "Helpdesk exists."
else
  echo "Initializing helpdesk..."
  api POST "/website/$WEBSITE_ID/helpdesk" -d '{"name":"EnviousWispr Help","domain_basic":"help-enviouswispr"}'
  echo ""
fi

# Check/create locale
echo "Checking locale '$LOCALE'..."
locale_check=$(api HEAD "/website/$WEBSITE_ID/helpdesk/locale/$LOCALE" -o /dev/null -w "%{http_code}")
if [ "$locale_check" != "200" ]; then
  echo "Creating locale '$LOCALE'..."
  api POST "/website/$WEBSITE_ID/helpdesk/locale" -d "{\"locale\":\"$LOCALE\"}"
  echo ""
fi

TOTAL=0
ERRORS=0

# Process each JSON file
for jsonfile in articles/*.json; do
  echo ""
  echo "--- Processing: $jsonfile ---"

  python3 -c "
import json, subprocess, sys, time

def api(method, path, data=None):
    cmd = [
        'curl', '-s', '-X', method,
        '$BASE' + path,
        '--user', '$CRISP_ID:$CRISP_KEY',
        '--header', 'X-Crisp-Tier: plugin',
        '--header', 'Content-Type: application/json',
    ]
    if data:
        cmd.extend(['-d', json.dumps(data)])
    result = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except:
        return {'error': True, 'raw': result.stdout}

website = '$WEBSITE_ID'
locale = '$LOCALE'
total = 0
errors = 0

data = json.load(open('$jsonfile'))

for cat in data.get('categories', []):
    cat_name = cat['name']
    print(f'  Category: {cat_name}')

    # Create category
    cat_res = api('POST', f'/website/{website}/helpdesk/locale/{locale}/category', {'name': cat_name})
    cat_id = cat_res.get('data', {}).get('category_id')
    if not cat_id:
        print(f'    ERROR creating category: {cat_res}')
        errors += 1
        continue
    time.sleep(0.3)

    for sec in cat.get('sections', []):
        sec_name = sec['name']
        print(f'    Section: {sec_name}')

        # Create section
        sec_res = api('POST', f'/website/{website}/helpdesk/locale/{locale}/category/{cat_id}/section', {'name': sec_name})
        sec_id = sec_res.get('data', {}).get('section_id')
        if not sec_id:
            print(f'      ERROR creating section: {sec_res}')
            errors += 1
            continue
        time.sleep(0.3)

        for art in sec.get('articles', []):
            title = art['title']
            print(f'      Article: {title}')

            # Create article (title only)
            art_res = api('POST', f'/website/{website}/helpdesk/locale/{locale}/article', {'title': title})
            art_id = art_res.get('data', {}).get('article_id')
            if not art_id:
                print(f'        ERROR creating article: {art_res}')
                errors += 1
                continue
            time.sleep(0.3)

            # Update article content
            update_data = {
                'title': title,
                'description': art.get('description', ''),
                'content': art.get('content', ''),
            }
            api('PATCH', f'/website/{website}/helpdesk/locale/{locale}/article/{art_id}', update_data)
            time.sleep(0.3)

            # Assign to category + section
            api('PATCH', f'/website/{website}/helpdesk/locale/{locale}/article/{art_id}/category', {
                'category_id': cat_id,
                'section_id': sec_id,
            })
            time.sleep(0.3)

            # Publish
            pub_res = api('POST', f'/website/{website}/helpdesk/locale/{locale}/article/{art_id}/publish')
            if pub_res.get('error'):
                print(f'        ERROR publishing: {pub_res}')
                errors += 1
            else:
                print(f'        Published.')
                total += 1
            time.sleep(0.3)

print(f'')
print(f'  Uploaded: {total}, Errors: {errors}')
" 2>&1

done

echo ""
echo "=== Upload Complete ==="
