"""Draw the OKFlow logo as vector graphics and write the files the site uses.

    uv run --no-project --with resvg-py --with pillow python logo/make_logo.py

The wordmark sits on a 100-unit cap height:
- O: the cell. A green ring of stroke S, lighter green cytoplasm, and a purple nucleus
  filling 72% of the inside, pushed against the ring at the lower left (as in a lymphocyte).
- K: a solid block letter with flat cuts and square corners (in the spirit of Arial Black),
  so "OK" reads as one firm word.
- Flow: one monoline script stroke of the same weight S: a wavy-topped F whose crossbar
  sweeps up into a looped l, joined into o, out over the top into w, ending in a flick.

Writes logo/okflow-wordmark-light.svg, logo/okflow-wordmark-dark.svg, logo/okflow-icon.svg,
logo/okflow-cell.svg, logo/header.svg (colours as CSS variables, pasted into index.html),
apple-touch-icon.png and icon-512.png.
"""
import math
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent
S, h = 17, 8.5
NUC, NUC_ANGLE = 0.72, 135
LIGHT = dict(ring="#0e8a6a", cyto="#7fd6b8", nucleus="#8b45c4", ink="#18202a")
DARK = dict(ring="#3cc79f", cyto="#a9ecd8", nucleus="#c08af0", ink="#e8edf3")
CSSVARS = dict(ring="var(--keep)", cyto="var(--cyto)", nucleus="var(--nucleus)", ink="var(--ink)")
VIEW = (-12, -14, 560, 130)         # the wordmark's box, strokes included, with a little air


def cell(cx, cy, R, c):
    inner = R - S
    n = inner * NUC
    a = math.radians(NUC_ANGLE)
    nx, ny = cx + (inner - n) * math.cos(a), cy + (inner - n) * math.sin(a)
    return (f'<circle cx="{cx}" cy="{cy}" r="{R - h}" fill="{c["cyto"]}" stroke="{c["ring"]}" stroke-width="{S}"/>'
            f'<circle cx="{nx:.2f}" cy="{ny:.2f}" r="{n + 0.6:.2f}" fill="{c["nucleus"]}"/>')


def wordmark(c):
    line = lambda d: (f'<path d="{d}" fill="none" stroke="{c["ink"]}" stroke-width="{S}" '
                      f'stroke-linecap="round" stroke-linejoin="round"/>')
    parts = [cell(52, 50, 52, c)]
    stem, x0 = 30, 118
    K = [(0, 0), (stem, 0), (stem, 40), (stem + 28, 0), (stem + 50, 0), (stem + 16, 46),
         (stem + 52, 100), (stem + 18, 100), (stem, 70), (stem, 100), (0, 100)]
    parts.append(f'<polygon points="{" ".join(f"{x0 + a},{b}" for a, b in K)}" fill="{c["ring"]}"/>')
    shift = x0 + stem + 52 + 22 - 186
    flow = [
        line("M196 14 C204 4 186 6 192 6 C210 11 232 9 252 5 C258 4 263 3 268 2"),                    # F: wavy top bar
        line("M222 8 C220 36 218 66 212 86 C208 96 198 99 191 92"),                                     # F: stem with a hook
        line("M202 52 C236 50 296 42 312 22"                                                            # F crossbar, up into
             " C318 6 300 0 296 14 C292 34 292 68 296 86 C300 98 312 100 324 92 C330 86 334 74 338 62"  # the looped l, into
             " M362 44 C344 40 330 54 332 72 C334 92 360 98 370 82 C378 70 376 50 362 44 C372 44 384 42 396 42"  # o, out to
             " C402 42 404 46 406 52 L418 91.5 L432 56 L446 91.5 L460 52 C462 44 470 38 482 36"),        # w, with a flick
    ]
    parts.append(f'<g transform="translate({shift} 0)">{"".join(flow)}</g>')
    return "".join(parts)


def svg(body, view, w=None, hgt=None, extra=""):
    size = f' width="{w}" height="{hgt}"' if w else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(map(str, view))}"{size}{extra}>{body}</svg>'


def icon(tile=True, c=LIGHT):
    """The cell on its own: on a dark rounded tile for app icons, bare for the browser tab."""
    k = 0.7 * 1024 / 100
    body = f'<g transform="translate(512 512) scale({k}) translate(-52 -50)">{cell(52, 50, 52, c)}</g>'
    if tile:
        body = '<rect width="1024" height="1024" rx="230" fill="#10151c"/>' + body
    return svg(body, (0, 0, 1024, 1024))


if __name__ == "__main__":
    (HERE / "okflow-wordmark-light.svg").write_text(svg(wordmark(LIGHT), VIEW))
    (HERE / "okflow-wordmark-dark.svg").write_text(svg(wordmark(DARK), VIEW))
    (HERE / "okflow-icon.svg").write_text(icon(True, DARK))
    (HERE / "okflow-cell.svg").write_text(icon(False, LIGHT))
    (HERE / "header.svg").write_text(svg(wordmark(CSSVARS), VIEW))
    import resvg_py
    for name, size in (("apple-touch-icon.png", 180), ("icon-512.png", 512)):
        big = icon(True, DARK).replace('viewBox="0 0 1024 1024"', f'viewBox="0 0 1024 1024" width="{size}" height="{size}"')
        (ROOT / name).write_bytes(bytes(resvg_py.svg_to_bytes(svg_string=big)))
    # the dark wordmark as a PNG for the link preview
    wm = svg(wordmark(DARK), VIEW, 560 * 0.8, 130 * 0.8)
    (HERE / "wordmark-dark-preview.png").write_bytes(bytes(resvg_py.svg_to_bytes(svg_string=wm)))
    print("wrote the logo files")
