#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import struct

root = Path('Resources/Help').resolve()
page = root / 'index.html'

class GuideParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = []
        self.images = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if values.get('id'):
            self.ids.add(values['id'])
        if tag == 'script':
            raise AssertionError('Help must remain script-free')
        if tag == 'a':
            self.links.append(values.get('href', ''))
        if tag == 'img':
            assert values.get('alt', '').strip(), 'Screenshot needs alternative text'
            self.images.append(values.get('src', ''))

guide = GuideParser()
guide.feed(page.read_text(encoding='utf-8'))
assert len(guide.images) >= 10, 'Guide needs representative screenshots'
for link in guide.links:
    if link.startswith('#'):
        assert link[1:] in guide.ids, f'Broken section link: {link}'
    else:
        assert link.startswith('https://'), f'Unexpected link scheme: {link}'
for image in guide.images:
    assert image.startswith('images/') and '..' not in image, f'Invalid image path: {image}'
    path = (root / image).resolve()
    assert path.is_relative_to(root) and path.is_file(), f'Missing screenshot: {image}'
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'Invalid PNG: {image}'
    width, height = struct.unpack('>II', data[16:24])
    assert width >= 900 and height >= 500, f'Screenshot too small: {image}'
print(f'PASS: offline Help guide, {len(guide.ids)} sections and {len(guide.images)} screenshots')
PY
