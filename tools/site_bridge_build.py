"""Build the public Ashley Bridge pages: ashley/bridge/{index,privacy,terms}.html in the site repository.

index.html is copied from docs/site/bridge/index.html (hand-written). privacy.html is PRIVACY.md rendered
with pandoc; terms.html is LICENSE.txt (plain text) turned into headings and paragraphs and rendered with
pandoc. Both use docs/site/bridge/template.html, which carries the CSS block of Ashley's site pages
(ashley/tools/site_build.py) plus a few rules for phones, the back link and the "Save a copy" note.

After writing, the script checks its own output against things outside the rendering: every word of each
source text appears in its page, in order (so nothing was dropped or reordered by the conversion); each
page parses with html.parser and its tags balance; the banned word is nowhere; the CSS block is present
and still identical to Ashley's copy; the document versions the landing page names are the ones in the
texts. A failed check exits non-zero and says which page and why.

    python -X utf8 tools/site_bridge_build.py [--site <path to openspineconsortium.github.io>] [--check-only]

Nothing is staged or committed: the maintainer reviews `git status` in the site repository and pushes.
The kill-list beside these pages (ashley/bridge-killlist.json) is signed by a different tool; see
docs/PUBLISHING_SITE.md.
"""
import argparse
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TEMPLATE_DIR = os.path.join(REPO, "docs", "site", "bridge")
TEMPLATE = os.path.join(TEMPLATE_DIR, "template.html")
LANDING = os.path.join(TEMPLATE_DIR, "index.html")
DEFAULT_SITE = os.path.normpath(os.path.join(REPO, "..", "openspineconsortium.github.io"))
ASHLEY_SITE_BUILD = os.path.normpath(os.path.join(REPO, "..", "ashley", "tools", "site_build.py"))
PANDOC = shutil.which("pandoc") or r"C:\Program Files\Pandoc\pandoc.exe"
BANNED = re.compile(r"prov[a-z]*enance", re.I)
# the CSS of Ashley's pages, byte for byte (ashley/tools/site_build.py CSS); drift is reported
CSS = """<style>
:root{--ink:#1c1c1c;--muted:#555;--line:#ddd;--accent:#1f3b2e;--bg:#fff}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--ink:#e8e8e8;--muted:#b0b0b0;--line:#333;--accent:#8fd3b0;--bg:#121212}}
:root[data-theme="dark"]{--ink:#e8e8e8;--muted:#b0b0b0;--line:#333;--accent:#8fd3b0;--bg:#121212}
body{margin:0;padding:0 16px 48px;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,"Segoe UI",Helvetica,Arial,sans-serif;max-width:760px;margin-inline:auto}
h1{font-size:1.8em;margin:32px 0 4px}h2{font-size:1.2em;margin:28px 0 8px;color:var(--accent)}a{color:var(--accent)}
table{border-collapse:collapse;width:100%;font-size:.95em}td,th{border:1px solid var(--line);padding:6px 8px;vertical-align:top;text-align:left}
pre{white-space:pre-wrap;border:1px solid var(--line);padding:8px;font-size:.9em}
</style>"""

HEADING = re.compile(r"^\d{1,2}\.\s+\S")  # "12. NO WARRANTY"
ITEM = re.compile(r"^\([a-z]\)\s")  # "(b) distribute, ..."


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def write(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def pandoc(src, out, reader, title, docfile):
    subprocess.run(
        [PANDOC, src, "-o", out, "--standalone", "--template", TEMPLATE, "--metadata", f"pagetitle={title}", "--metadata", "lang=en", "-V", f"docfile={docfile}", "-f", reader, "-t", "html5"],
        check=True,
    )
    write(out, read(out))  # LF, utf-8


def license_fragment(text):
    """LICENSE.txt is hard-wrapped plain text. Blocks are separated by blank lines; the first block is the
    title, a one-line all-caps block starting "N." is a section heading, a line starting "(a) " begins a
    sub-item of its own, an indented line continues the line before it. Every word is kept; the check
    below proves it."""
    blocks = re.split(r"\n\s*\n", text.replace("\r\n", "\n").strip("\n"))
    out = []
    for i, block in enumerate(blocks):
        lines = block.split("\n")
        if i == 0 and len(lines) == 1:
            out.append(f"<h1>{html.escape(lines[0].strip())}</h1>")
            continue
        if len(lines) == 1 and HEADING.match(lines[0]) and lines[0] == lines[0].upper():
            out.append(f"<h2>{html.escape(lines[0].strip())}</h2>")
            continue
        paras = []
        for line in lines:
            s = line.strip()
            if not s:
                continue
            if paras and not line[:1].isspace() and ITEM.match(s):
                paras.append(s)
            elif paras:
                paras[-1] += " " + s
            else:
                paras.append(s)
        out.extend(f"<p>{html.escape(p)}</p>" for p in paras)
    return "\n".join(out) + "\n"


class Page(HTMLParser):
    """Text and tag balance of a page; a mismatched non-void tag is a build error, not a browser's problem."""

    VOID = {"meta", "link", "br", "hr", "img", "input", "col", "wbr", "source"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text, self.stack, self.errors, self.in_style = [], [], [], False

    def handle_starttag(self, tag, attrs):
        if tag in self.VOID:
            return
        if tag == "style":
            self.in_style = True
        self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in self.VOID:
            return
        if tag == "style":
            self.in_style = False
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"</{tag}> closes <{self.stack[-1] if self.stack else 'nothing'}> at line {self.getpos()[0]}")
            return
        self.stack.pop()

    def handle_data(self, data):
        if not self.in_style:
            self.text.append(data)


def words(s):
    s = s.replace("\u2019", "'").replace("\u2018", "'")
    return re.findall(r"[A-Za-z0-9']+", s)


def check_page(path, source_text, checks):
    page = read(path)
    p = Page()
    p.feed(page)
    p.close()
    if p.errors or p.stack:
        checks.append(f"{path}: tags do not balance: {p.errors or p.stack}")
    if BANNED.search(page):
        checks.append(f"{path}: the banned word is on the page")
    if 'name="viewport"' not in page or "padding:0 16px 48px" not in page:
        checks.append(f"{path}: no viewport meta or no 16px gutter")
    if CSS not in page:
        checks.append(f"{path}: the Ashley CSS block is missing or altered")
    if source_text is not None:
        want, have = " ".join(words(source_text)), " ".join(words("".join(p.text)))
        if want not in have:
            w, h = want.split(), have.split()
            k = next((i for i in range(min(len(w), len(h))) if w[i] != h[i]), min(len(w), len(h)))
            checks.append(f"{path}: the page does not carry every word of its source in order; first difference near word {k}: source '{' '.join(w[max(0, k - 4):k + 4])}' vs page '{' '.join(h[max(0, k - 4):k + 4])}'")
    return page


def version_of(text, name):
    m = re.search(r"^Version (\d+), (\d{4}-\d{2}-\d{2})", text, re.M)
    if not m:
        raise SystemExit(f"{name}: no 'Version N, YYYY-MM-DD' line")
    return m.group(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--site", default=DEFAULT_SITE, help="the site repository (default: ../openspineconsortium.github.io)")
    ap.add_argument("--check-only", action="store_true", help="check the pages already in the site repository; write nothing")
    a = ap.parse_args()
    out_dir = os.path.join(a.site, "ashley", "bridge")
    if not os.path.isdir(os.path.join(a.site, "ashley")):
        raise SystemExit(f"{a.site} does not look like the site repository (no ashley/ folder)")
    privacy_md, license_txt = read(os.path.join(REPO, "PRIVACY.md")), read(os.path.join(REPO, "LICENSE.txt"))
    for name, text in (("PRIVACY.md", privacy_md), ("LICENSE.txt", license_txt)):
        if BANNED.search(text):
            raise SystemExit(f"{name}: the banned word is in the source text")
    if not a.check_only:
        os.makedirs(out_dir, exist_ok=True)
        shutil.copyfile(LANDING, os.path.join(out_dir, "index.html"))
        pandoc(os.path.join(REPO, "PRIVACY.md"), os.path.join(out_dir, "privacy.html"), "markdown+pipe_tables", "Ashley Bridge privacy statement", "PRIVACY.md")
        with tempfile.TemporaryDirectory() as td:
            frag = os.path.join(td, "license.html")
            write(frag, license_fragment(license_txt))
            pandoc(frag, os.path.join(out_dir, "terms.html"), "html", "Ashley Bridge Trial Edition License Agreement", "LICENSE.txt")
    checks = []
    landing = check_page(os.path.join(out_dir, "index.html"), None, checks)
    check_page(os.path.join(out_dir, "privacy.html"), privacy_md, checks)
    check_page(os.path.join(out_dir, "terms.html"), license_txt, checks)
    pv, lv = version_of(privacy_md, "PRIVACY.md"), version_of(license_txt, "LICENSE.txt")
    if f'href="privacy.html">Privacy statement</a> (version {pv})' not in landing:
        checks.append(f"index.html: does not say the privacy statement is version {pv}")
    if f'href="terms.html">Trial Edition License Agreement</a> (version {lv})' not in landing:
        checks.append(f"index.html: does not say the agreement is version {lv}")
    if os.path.exists(ASHLEY_SITE_BUILD):
        m = re.search(r'CSS = """(.*?)"""', read(ASHLEY_SITE_BUILD), re.S)
        if not m or m.group(1) != CSS:
            checks.append(f"the CSS block differs from {ASHLEY_SITE_BUILD}; copy theirs here and into the template and the landing page")
    for c in checks:
        print("FAIL:", c)
    if checks:
        sys.exit(1)
    for f in ("index.html", "privacy.html", "terms.html"):
        print(f"ok  {os.path.join(out_dir, f)}  {os.path.getsize(os.path.join(out_dir, f))} bytes")
    print(f"privacy statement version {pv}, agreement version {lv}; every source word present in order; tags balance; banned word absent")


if __name__ == "__main__":
    main()
