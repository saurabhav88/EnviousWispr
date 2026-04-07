#!/usr/bin/env python3
"""Convert HTML article content to clean Crisp Markdown."""

from html.parser import HTMLParser
import html
import re


class HTML2Markdown(HTMLParser):
    def __init__(self):
        super().__init__()
        self.output = []
        self.tag_stack = []
        self.list_stack = []  # 'ul' or 'ol'
        self.ol_counter = []
        self.in_pre = False
        self.skip_first_h2 = True  # Remove duplicate title

    def handle_starttag(self, tag, attrs):
        self.tag_stack.append(tag)
        attrs_dict = dict(attrs)

        if tag in ('h2', 'h3', 'h4'):
            if tag == 'h2' and self.skip_first_h2:
                self._skipping_h2 = True
                return
            prefix = {'h2': '\n\n## ', 'h3': '\n\n### ', 'h4': '\n\n#### '}[tag]
            self.output.append(prefix)

        elif tag == 'p':
            self.output.append('\n\n')

        elif tag == 'strong':
            self.output.append('**')

        elif tag == 'em':
            self.output.append('*')

        elif tag == 'code':
            if not self.in_pre:
                self.output.append('`')

        elif tag == 'pre':
            self.in_pre = True
            self.output.append('\n\n```\n')

        elif tag == 'ul':
            self.list_stack.append('ul')
            self.output.append('\n')

        elif tag == 'ol':
            self.list_stack.append('ol')
            self.ol_counter.append(0)
            self.output.append('\n')

        elif tag == 'li':
            if self.list_stack:
                if self.list_stack[-1] == 'ul':
                    self.output.append('\n* ')
                else:
                    self.ol_counter[-1] += 1
                    self.output.append(f'\n{self.ol_counter[-1]}. ')

        elif tag == 'a':
            href = attrs_dict.get('href', '')
            self.output.append('[')
            # Store href for closing tag
            self._pending_href = href

        elif tag == 'br':
            self.output.append('\n')

        elif tag == 'table':
            self.output.append('\n\n')
            self._table_rows = []
            self._current_row = []
            self._in_thead = False

        elif tag == 'thead':
            self._in_thead = True

        elif tag == 'tbody':
            self._in_thead = False

        elif tag in ('th', 'td'):
            self._current_cell = []

        elif tag == 'tr':
            self._current_row = []

    def handle_endtag(self, tag):
        if self.tag_stack and self.tag_stack[-1] == tag:
            self.tag_stack.pop()

        if tag == 'h2' and getattr(self, '_skipping_h2', False):
            self.skip_first_h2 = False
            self._skipping_h2 = False
            return

        if tag in ('h2', 'h3', 'h4'):
            self.output.append('\n')

        elif tag == 'strong':
            self.output.append('**')

        elif tag == 'em':
            self.output.append('*')

        elif tag == 'code':
            if not self.in_pre:
                self.output.append('`')

        elif tag == 'pre':
            self.in_pre = False
            self.output.append('\n```\n')

        elif tag == 'ul':
            if self.list_stack:
                self.list_stack.pop()
            self.output.append('\n')

        elif tag == 'ol':
            if self.list_stack:
                self.list_stack.pop()
            if self.ol_counter:
                self.ol_counter.pop()
            self.output.append('\n')

        elif tag == 'a':
            href = getattr(self, '_pending_href', '')
            self.output.append(f']({href})')

        elif tag in ('th', 'td'):
            cell_text = ''.join(self._current_cell).strip()
            self._current_row.append(cell_text)
            self._current_cell = []

        elif tag == 'tr':
            self._table_rows.append(self._current_row)

        elif tag == 'table':
            if self._table_rows:
                for i, row in enumerate(self._table_rows):
                    self.output.append('| ' + ' | '.join(row) + ' |\n')
                    if i == 0:
                        self.output.append('| ' + ' | '.join(['---'] * len(row)) + ' |\n')
            self.output.append('\n')

    def _in_table(self):
        return any(t == 'table' for t in self.tag_stack)

    def handle_data(self, data):
        # Skip data inside the first H2 (duplicate title)
        if getattr(self, '_skipping_h2', False):
            return

        # If inside a table, only collect into cells, don't add to main output
        if self._in_table() and hasattr(self, '_current_cell'):
            self._current_cell.append(data)
            return

        self.output.append(data)

    def handle_entityref(self, name):
        self.output.append(html.unescape(f'&{name};'))

    def handle_charref(self, name):
        self.output.append(html.unescape(f'&#{name};'))

    def get_markdown(self):
        text = ''.join(self.output)
        # Clean up whitespace
        text = re.sub(r'\n{3,}', '\n\n', text)
        text = re.sub(r'[ \t]+\n', '\n', text)  # trailing spaces
        text = text.strip()
        return text


def convert(html_content, title=""):
    parser = HTML2Markdown()
    parser.feed(html_content)
    return parser.get_markdown()


if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1:
        # Test with a specific article
        html_str = sys.argv[1]
        print(convert(html_str))
    else:
        # Convert all articles and save as markdown files
        import os, json
        os.makedirs('markdown', exist_ok=True)

        idx = 0
        for jsonfile in sorted(os.listdir('articles')):
            if not jsonfile.endswith('.json'):
                continue
            data = json.load(open(os.path.join('articles', jsonfile)))
            for cat in data.get('categories', []):
                for sec in cat.get('sections', []):
                    for art in sec.get('articles', []):
                        idx += 1
                        title = art['title']
                        md = convert(art.get('content', ''), title)
                        safe_name = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
                        fname = f'{idx:02d}-{safe_name[:50]}.md'
                        with open(os.path.join('markdown', fname), 'w') as f:
                            f.write(md)
                        print(f'{fname}: {len(md)} chars')
