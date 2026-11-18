#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the published Bash preview as documentation images, without installing."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess

from playwright.sync_api import sync_playwright

SCREENS = {
    'home': 'home', 'vpn': 'vpn', 'seedbox': 'seedbox', 'access': 'ssh',
    'ssh': 'keys', 'sftp': 'sftp', 'policy': 'policy',
    'protection': 'protection', 'maintenance': 'maintenance', 'backup': 'backup',
}
PALETTE = ['#111116', '#ff5c61', '#54d68b', '#e9ce70', '#799cfa', '#ff5fff', '#65d7dc', '#eeeaf2']
SGR = re.compile(r'\x1b\[([0-9;]*)m')


def indexed(n):
    if n < 16:
        return PALETTE[n % 8]
    if n >= 232:
        return '#' + f'{8 + 10 * (n - 232):02x}' * 3
    n -= 16
    values = [0, 95, 135, 175, 215, 255]
    return '#' + ''.join(f'{values[i]:02x}' for i in (n // 36, (n // 6) % 6, n % 6))


def ansi_html(raw):
    state, parts, pos = {}, [], 0
    for match in SGR.finditer(raw):
        style = ';'.join(k + ':' + v for k, v in state.items())
        parts.append('<span style="' + style + '">' + html.escape(raw[pos:match.start()]) + '</span>')
        codes = [int(n or 0) for n in match[1].split(';')]
        i = 0
        while i < len(codes):
            n = codes[i]
            if n == 0:
                state = {}
            elif n == 1:
                state['font-weight'] = '700'
            elif n == 2:
                state['opacity'] = '0.65'
            elif n == 22:
                state.pop('font-weight', None)
                state.pop('opacity', None)
            elif 30 <= n <= 37 or 90 <= n <= 97:
                state['color'] = PALETTE[n % 10]
            elif 40 <= n <= 47 or 100 <= n <= 107:
                state['background-color'] = PALETTE[n % 10]
            elif n in (38, 48) and i + 2 < len(codes) and codes[i + 1] == 5:
                state['color' if n == 38 else 'background-color'] = indexed(codes[i + 2])
                i += 2
            elif n == 39:
                state.pop('color', None)
            elif n == 49:
                state.pop('background-color', None)
            else:
                raise ValueError(f'Unsupported terminal color code: {n}')
            i += 1
        pos = match.end()
    parts.append(html.escape(raw[pos:]))
    return ''.join(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--browser', default='/usr/bin/chromium')
    args = parser.parse_args()
    source = args.source_dir.resolve()
    if not re.fullmatch('[0-9a-f]{40}', args.source_sha):
        parser.error('source-sha must be a complete commit SHA')
    version = re.search(r'^APP_VERSION="([^"]+)"$', (source / 'lib/common.sh').read_text(), re.M)[1]
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {'version': version, 'source_sha': args.source_sha, 'columns': 90,
                'preview_sha256': hashlib.sha256((source / 'tools/preview.sh').read_bytes()).hexdigest(),
                'data': 'fictional, independent preview states', 'images': {}}
    css = '''*{box-sizing:border-box}body{margin:0;padding:24px;background:#171020;color:#e5e1eb;width:max-content}
    .terminal{background:#101016;border:1px solid #39303f;border-radius:12px;overflow:hidden}
    .title{font:14px "DejaVu Sans Mono",monospace;color:#aaa3b5;padding:15px 25px;border-bottom:1px solid #302936}
    pre{font:20px/1.45 "DejaVu Sans Mono",monospace;margin:0;padding:24px;white-space:pre;font-variant-ligatures:none}'''
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=args.browser, headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport={'width': 1400, 'height': 1200}, device_scale_factor=1.5)
        for language in ('en', 'fr'):
            raw = subprocess.check_output(
                ['bash', str(source / 'tools/preview.sh'), '--all', '--color', '--columns', '90', '--' + language],
                env={**os.environ, 'TERM': 'xterm-256color', 'LC_ALL': 'C.UTF-8'}, text=True)
            sections = dict(re.findall(r'^=== ([a-z-]+) ===\n(.*?)(?=^=== |\Z)', raw, re.M | re.S))
            for filename, screen in SCREENS.items():
                text = sections[screen].strip('\n')
                plain = SGR.sub('', text)
                if '\x1b' in plain or 'v' + version not in plain:
                    raise ValueError(f'Unexpected terminal output: {screen}')
                if max(map(len, plain.splitlines())) > 90:
                    raise ValueError(f'Unexpected line width: {screen}')
                title = f'SeedTunnel {version} · Debian 13 · {language.upper()}'
                document = '<!doctype html><meta charset="utf-8"><style>' + css + '</style>'
                document += '<div class="terminal"><div class="title">' + title + '</div><pre>'
                document += ansi_html(text) + '</pre></div>'
                page.set_content(document)
                page.evaluate('document.fonts.ready')
                dimensions = page.locator('body').bounding_box()
                page.set_viewport_size({'width': int(dimensions['width']), 'height': int(dimensions['height'])})
                name = language + '-' + filename + '.png'
                path = args.output / name
                page.screenshot(path=str(path), full_page=True)
                manifest['images'][name] = {
                    'screen': screen, 'text_sha256': hashlib.sha256(plain.encode()).hexdigest(),
                    'png_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                }
        browser.close()
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{len(manifest["images"])} captures rendered from {version}, fictional data only.')


if __name__ == '__main__':
    main()
