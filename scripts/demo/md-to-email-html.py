#!/usr/bin/env python3
"""Convert the demo guide to HTML that survives being pasted into an email.

    ./md-to-email-html.py <input.md> <output.html>

Email clients are not browsers. Three constraints drive everything here:

* **No <style> block.** Gmail strips it, Outlook mangles it. Every rule is
  inlined on the element that needs it, which is verbose but is the only thing
  that reliably survives a paste.
* **No relative image paths.** A relative src resolves against the mail client,
  not the repo, so every image is rewritten to an absolute raw.githubusercontent
  URL. Embedding them as data: URIs was the alternative and is worse — 3.2 MB of
  PNGs, and Gmail and Outlook both block data: images.
* **Tables carry border/cellpadding attributes as well as CSS**, because Outlook's
  renderer honours the attributes and ignores parts of the CSS.

Written by hand rather than with a markdown library: the output needs per-element
inline styling, which means post-processing a library's output anyway.
"""
import html
import re
import sys

RAW = ("https://raw.githubusercontent.com/jgruberf5/"
       "roksbnkctl-bnk-forge/main/scripts/demo/")

FONT = ("-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,"
        "'Helvetica Neue',Arial,sans-serif")
MONO = "'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace"
INK, MUTED, RULE, ACCENT = "#1f2328", "#57606a", "#d0d7de", "#0969da"
WASH = "#f6f8fa"

S = {
    "h1": f"margin:0 0 16px;font:600 28px/1.3 {FONT};color:{INK};"
          f"border-bottom:1px solid {RULE};padding-bottom:10px",
    "h2": f"margin:32px 0 12px;font:600 22px/1.3 {FONT};color:{INK};"
          f"border-bottom:1px solid {RULE};padding-bottom:8px",
    "h3": f"margin:24px 0 10px;font:600 17px/1.3 {FONT};color:{INK}",
    "p":  f"margin:0 0 14px;font:400 15px/1.6 {FONT};color:{INK}",
    "li": f"margin:0 0 7px;font:400 15px/1.6 {FONT};color:{INK}",
    "table": "border-collapse:collapse;margin:0 0 16px;width:100%;"
             f"font:400 14px/1.5 {FONT}",
    "th": f"border:1px solid {RULE};padding:8px 12px;background:{WASH};"
          f"text-align:left;font-weight:600;color:{INK}",
    "td": f"border:1px solid {RULE};padding:8px 12px;color:{INK};"
          "vertical-align:top",
    "pre": f"margin:0 0 16px;padding:14px;background:{WASH};"
           f"border:1px solid {RULE};border-radius:6px;overflow-x:auto;"
           f"font:400 13px/1.5 {MONO};color:{INK};white-space:pre",
    "code": f"padding:2px 5px;background:{WASH};border:1px solid {RULE};"
            f"border-radius:4px;font:400 13px/1.4 {MONO};color:{INK}",
    "quote": f"margin:0 0 16px;padding:12px 16px;background:{WASH};"
             f"border-left:4px solid {ACCENT};border-radius:0 6px 6px 0",
    "img": f"max-width:100%;height:auto;border:1px solid {RULE};"
           "border-radius:6px;margin:0 0 6px;display:block",
    "cap": f"margin:0 0 18px;font:400 13px/1.4 {FONT};color:{MUTED};"
           "font-style:italic",
    "hr": f"border:0;border-top:1px solid {RULE};margin:28px 0",
    "a": f"color:{ACCENT};text-decoration:underline",
}


def inline(t):
    """Inline markdown -> HTML. Code first, so its contents are not re-parsed."""
    out, stash = [], []

    def keep(frag):
        stash.append(frag)
        return f"\x00{len(stash)-1}\x00"

    t = re.sub(r"`([^`]+)`",
               lambda m: keep(f'<code style="{S["code"]}">'
                              f'{html.escape(m.group(1))}</code>'), t)
    t = html.escape(t)
    # images before links: the syntax differs only by a leading '!'
    t = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)",
               lambda m: keep(_img(m.group(1), m.group(2))), t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
               lambda m: keep(f'<a href="{m.group(2)}" '
                              f'style="{S["a"]}">{m.group(1)}</a>'), t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![*\w])\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", t)
    for i, frag in enumerate(stash):
        t = t.replace(f"\x00{i}\x00", frag)
    return t


def _img(alt, src):
    if not src.startswith(("http://", "https://")):
        src = RAW + src.lstrip("./")
    return (f'<img src="{src}" alt="{html.escape(alt)}" '
            f'style="{S["img"]}">'
            + (f'<div style="{S["cap"]}">{html.escape(alt)}</div>' if alt else ""))


def render(lines):
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]

        if not line.strip():
            i += 1
            continue

        if re.match(r"^---+\s*$", line):
            out.append(f'<hr style="{S["hr"]}">')
            i += 1
            continue

        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            tag = f"h{len(m.group(1))}"
            out.append(f'<{tag} style="{S[tag]}">{inline(m.group(2))}</{tag}>')
            i += 1
            continue

        if line.startswith("```"):
            i += 1
            buf = []
            while i < n and not lines[i].startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            out.append(f'<pre style="{S["pre"]}">'
                       f'{html.escape(chr(10).join(buf))}</pre>')
            continue

        if line.startswith(">"):
            buf = []
            while i < n and (lines[i].startswith(">") or
                             (lines[i].strip() and buf and
                              not lines[i].startswith(("#", "---", "|")))):
                buf.append(re.sub(r"^>\s?", "", lines[i]))
                i += 1
            out.append(f'<div style="{S["quote"]}">{render(buf)}</div>')
            continue

        if line.lstrip().startswith("|"):
            buf = []
            while i < n and lines[i].lstrip().startswith("|"):
                buf.append(lines[i])
                i += 1
            out.append(table(buf))
            continue

        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if m:
            ordered = not m.group(2) in ("-", "*")
            items, i = collect_list(lines, i)
            tag = "ol" if ordered else "ul"
            body = "".join(f'<li style="{S["li"]}">{inline(x)}</li>'
                           for x in items)
            out.append(f'<{tag} style="margin:0 0 14px;padding-left:26px">'
                       f'{body}</{tag}>')
            continue

        # paragraph: consume until a blank line or a block-level marker
        buf = []
        while i < n and lines[i].strip() and not re.match(
                r"^(#{1,3}\s|```|>|\||---+\s*$|\s*([-*]|\d+\.)\s)", lines[i]):
            buf.append(lines[i].strip())
            i += 1
        if buf:
            txt = inline(" ".join(buf))
            # a bare image is its own block, not a paragraph
            if txt.startswith("<img"):
                out.append(txt)
            else:
                out.append(f'<p style="{S["p"]}">{txt}</p>')
    return "".join(out)


def collect_list(lines, i):
    items, n = [], len(lines)
    while i < n:
        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", lines[i])
        if m:
            items.append(m.group(3))
            i += 1
            # fold continuation lines into the item
            while (i < n and lines[i].strip()
                   and not re.match(r"^\s*([-*]|\d+\.)\s", lines[i])
                   and lines[i].startswith(("  ", "\t"))):
                items[-1] += " " + lines[i].strip()
                i += 1
        elif not lines[i].strip():
            if i + 1 < n and re.match(r"^\s*([-*]|\d+\.)\s", lines[i + 1]):
                i += 1
            else:
                break
        else:
            break
    return items, i


def cells(row):
    return [c.strip() for c in row.strip().strip("|").split("|")]


def table(rows):
    if len(rows) >= 2 and re.match(r"^[\s|:-]+$", rows[1]):
        head, body = cells(rows[0]), rows[2:]
        # `| | |` is the headerless-table idiom and is used throughout the guide
        # for two-column key/value blocks. Emitting a <thead> for it puts an empty
        # grey bar above the table, which looks like a rendering fault.
        if not any(c.strip() for c in head):
            head = None
    else:
        head, body = None, rows
    # border/cellpadding as attributes too: Outlook honours those and drops CSS
    out = [f'<table role="presentation" cellpadding="0" cellspacing="0" '
           f'border="1" style="{S["table"]}">']
    if head:
        out.append("<thead><tr>"
                   + "".join(f'<th style="{S["th"]}">{inline(c)}</th>'
                             for c in head)
                   + "</tr></thead>")
    out.append("<tbody>")
    for r in body:
        out.append("<tr>" + "".join(f'<td style="{S["td"]}">{inline(c)}</td>'
                                    for c in cells(r)) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    md = open(src, encoding="utf-8").read().replace("\r\n", "\n")
    body = render(md.split("\n"))
    title = re.search(r"^#\s+(.*)$", md, re.M)
    title = title.group(1) if title else "Guide"
    doc = (
        "<!doctype html>\n"
        '<html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>{html.escape(title)}</title></head>"
        f'<body style="margin:0;padding:24px;background:#ffffff">'
        f'<div style="max-width:860px;margin:0 auto;background:#ffffff;'
        f'font:400 15px/1.6 {FONT};color:{INK}">{body}</div>'
        "</body></html>\n"
    )
    open(dst, "w", encoding="utf-8").write(doc)
    print(f"wrote {dst} ({len(doc):,} bytes)")


if __name__ == "__main__":
    main()
