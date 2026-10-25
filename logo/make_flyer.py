"""OKFlow as PDFs: the share card with a clickable link, and a printable poster with a QR code.

    uv run --no-project --with reportlab --with svglib --with pillow python logo/make_flyer.py

Run make_logo.py and make_share.py first. Writes flyer/okflow-card.pdf (the link preview as
a page; the whole page links to the site) and flyer/okflow-poster.pdf (US Letter, vector:
the wordmark, three cell profiles, a QR code and the address as a link).
"""
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageFont
from reportlab.graphics import renderPDF
from reportlab.graphics.barcode import qr
from reportlab.graphics.shapes import Drawing
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from svglib.svglib import svg2rlg

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "flyer"
OUT.mkdir(exist_ok=True)
URL, SHOWN = "https://okflow.weisslab.ca", "okflow.weisslab.ca"
F = "C:/Windows/Fonts/"
pdfmetrics.registerFont(TTFont("Body", F + "segoeui.ttf"))
pdfmetrics.registerFont(TTFont("Bold", F + "segoeuib.ttf"))
pdfmetrics.registerFont(TTFont("Sym", F + "seguisym.ttf"))
INK, MUTED, CARD, LINE = HexColor("#18202a"), HexColor("#5d6877"), HexColor("#19212b"), HexColor("#d3d9e1")
GREEN, CORAL, PAPER = HexColor("#0e8a6a"), HexColor("#d2483a"), HexColor("#ffffff")
CARD_INK, CARD_MUTED = HexColor("#e8edf3"), HexColor("#9aa6b5")

# ---- 1. the share card as a page ----
share = Image.open(ROOT / "share.png")
w, h = share.size[0] / 2, share.size[1] / 2               # 2 px per point: crisp on screens
c = canvas.Canvas(str(OUT / "okflow-card.pdf"), pagesize=(w, h))
c.setTitle("OKFlow: swipe right on cells that are in focus"); c.setAuthor("Weiss Lab, Polytechnique Montréal")
c.drawImage(ImageReader(share), 0, 0, w, h)
c.linkURL(URL, (0, 0, w, h), relative=0)
c.save()

# ---- 2. the poster ----
guide = Image.open(ROOT / "sheets" / "guide.png").convert("RGB")


def tile(k):
    """Example k's brightfield, enlarged with square pixels so nothing is smoothed."""
    im = guide.crop((0, k * 80, 80, (k + 1) * 80)).resize((640, 640), Image.NEAREST)
    buf = BytesIO(); im.save(buf, "PNG"); buf.seek(0)
    return ImageReader(buf)


def card(c, cx, cy, angle, k, title, sub, stamp, colour, stamp_left):
    W, H, S = 150, 196, 132
    c.saveState(); c.translate(cx, cy); c.rotate(angle)
    c.setFillColor(HexColor("#000000")); c.setFillAlpha(0.12); c.roundRect(-W / 2 + 3, -H / 2 - 4, W, H, 12, stroke=0, fill=1)
    c.setFillAlpha(1); c.setFillColor(CARD); c.roundRect(-W / 2, -H / 2, W, H, 12, stroke=0, fill=1)
    c.drawImage(tile(k), -S / 2, H / 2 - 9 - S, S, S)
    c.setFillColor(CARD_INK); c.setFont("Bold", 12.5); c.drawString(-W / 2 + 11, -H / 2 + 34, title)
    c.setFillColor(CARD_MUTED); c.setFont("Body", 9.5); c.drawString(-W / 2 + 11, -H / 2 + 18, sub)
    c.setFont("Bold", 14)
    sw = pdfmetrics.stringWidth(stamp, "Bold", 14) + 16
    sx = -W / 2 + 12 if stamp_left else W / 2 - 12 - sw
    c.translate(sx + sw / 2, H / 2 - 30); c.rotate(-10 if stamp_left else 10)
    c.setFillColor(HexColor("#000000")); c.setFillAlpha(0.55); c.setStrokeColor(colour); c.setLineWidth(2.4)
    c.roundRect(-sw / 2, -11, sw, 24, 5, stroke=1, fill=1)
    c.setFillAlpha(1); c.setFillColor(colour); c.drawCentredString(0, -4, stamp)
    c.restoreState()


PW, PH = letter
c = canvas.Canvas(str(OUT / "okflow-poster.pdf"), pagesize=letter)
c.setTitle("OKFlow: swipe right on cells that are in focus"); c.setAuthor("Weiss Lab, Polytechnique Montréal")
c.setFillColor(PAPER); c.rect(0, 0, PW, PH, stroke=0, fill=1)
wm = svg2rlg(str(ROOT / "logo" / "okflow-wordmark-light.svg"))
scale = 400 / wm.width
wm.scale(scale, scale); wm.width *= scale; wm.height *= scale
renderPDF.draw(wm, c, (PW - wm.width) / 2, PH - 60 - wm.height)
c.linkURL(URL, ((PW - wm.width) / 2, PH - 60 - wm.height, (PW + wm.width) / 2, PH - 60), relative=0)
c.setFillColor(INK); c.setFont("Bold", 31)
c.drawCentredString(PW / 2, PH - 228, "Swipe right on cells"); c.drawCentredString(PW / 2, PH - 266, "that are in focus.")
c.setFillColor(MUTED); c.setFont("Body", 15)
c.drawCentredString(PW / 2, PH - 298, "Swipe left on the blurry ones. No sign-up. Just good-looking cells.")
# the three profiles
y = PH - 445
card(c, PW / 2 - 150, y + 6, 9, 3, "Always moving", "Can't stay still", "REJECT", CORAL, True)
card(c, PW / 2 + 150, y + 6, -9, 2, "Soft focus", "Says the haze is a vibe", "REJECT", CORAL, False)
card(c, PW / 2, y + 14, 0, 0, "Sharp, single", "Whole, crisp, here to analyse", "A KEEPER", GREEN, True)
# QR code and the address
q = qr.QrCodeWidget(URL, barLevel="M"); b = q.getBounds()
size = 132
d = Drawing(size, size, transform=[size / (b[2] - b[0]), 0, 0, size / (b[3] - b[1]), 0, 0]); d.add(q)
qx, qy = 92, 98
renderPDF.draw(d, c, qx, qy)
c.linkURL(URL, (qx, qy, qx + size, qy + size), relative=0)
c.setFillColor(MUTED); c.setFont("Body", 10.5); c.drawCentredString(qx + size / 2, qy - 14, "Scan with your phone camera")
tx = qx + size + 36
c.setFillColor(INK); c.setFont("Bold", 15); c.drawString(tx, qy + 102, "Start on your phone or computer:")
c.setFillColor(GREEN); c.setFont("Bold", 30); c.drawString(tx, qy + 62, SHOWN)
uw = pdfmetrics.stringWidth(SHOWN, "Bold", 30)
c.setStrokeColor(GREEN); c.setLineWidth(1.6); c.line(tx, qy + 56, tx + uw, qy + 56)
c.linkURL(URL, (tx, qy + 52, tx + uw, qy + 92), relative=0)
c.setFillColor(MUTED); c.setFont("Body", 12.5)
c.drawString(tx, qy + 30, "Each card is one cell from an imaging flow cytometer.")
c.drawString(tx, qy + 13, "Keep the sharp ones, reject the rest.")
# credit
c.setStrokeColor(LINE); c.setLineWidth(0.8); c.line(54, 62, PW - 54, 62)
credit = "from the Weiss Lab, Polytechnique Montréal"
cw = pdfmetrics.stringWidth(credit, "Body", 12) + 18
c.setFillColor(CORAL); c.setFont("Sym", 13); c.drawString(PW / 2 - cw / 2, 38, "\u2665")
c.setFillColor(MUTED); c.setFont("Body", 12); c.drawString(PW / 2 - cw / 2 + 18, 38, credit)
c.save()
print("wrote", OUT / "okflow-card.pdf", "and", OUT / "okflow-poster.pdf")
