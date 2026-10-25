"""OKFlow's link preview (1200 x 630): the wordmark, and dating-app profile cards for cells.

    uv run --no-project --with resvg-py --with pillow python logo/make_logo.py   # first: draws the wordmark
    uv run --no-project --with pillow python logo/make_share.py

Writes share.png (the page's og:image).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent

F = "C:/Windows/Fonts/"
bold = lambda n: ImageFont.truetype(F + "segoeuib.ttf", n)
reg = lambda n: ImageFont.truetype(F + "segoeui.ttf", n)
sym = lambda n: ImageFont.truetype(F + "seguisym.ttf", n)
BG, CARD, INK, MUTED = (16, 21, 28), (25, 33, 43), (232, 237, 243), (154, 166, 181)
KEEP, TOSS = (60, 199, 159), (255, 122, 107)
g = Image.open(ROOT / "sheets" / "guide.png").convert("RGB")
tile = lambda k, size: g.crop((0, k * 80, 80, (k + 1) * 80)).resize((size, size), Image.NEAREST)


def stamp(text, color, font, angle):
    w = int(font.getlength(text)) + 36
    im = Image.new("RGBA", (w, 74), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((3, 3, w - 3, 71), 12, outline=color + (255,), width=6, fill=(0, 0, 0, 150))
    d.text((18, 6), text, font=font, fill=color + (255,))
    return im.rotate(angle, expand=True, resample=Image.BICUBIC)


def card(k, line1, line2, tag, color, angle, at):
    W, H, S = 300, 392, 264
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, W - 1, H - 1), 22, fill=CARD + (255,), outline=(44, 55, 68, 255), width=2)
    mask = Image.new("L", (S, S), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, S - 1, S - 1), 14, fill=255)
    im.paste(tile(k, S), (18, 18), mask)
    d.text((22, 292), line1, font=bold(26), fill=INK)
    d.text((22, 330), line2, font=reg(21), fill=MUTED)
    st = stamp(tag, color, bold(30), 12 if color == TOSS else -12)
    im.alpha_composite(st, at(W, st))
    return im.rotate(angle, expand=True, resample=Image.BICUBIC)


img = Image.new("RGBA", (1200, 630), BG + (255,))
# two blurry suitors behind, the sharp match in front
left = lambda W, st: (8, 22)
right = lambda W, st: (W - st.width - 8, 22)
for c, xy in [(card(2, "Soft focus", "Says the haze is a vibe", "REJECT", TOSS, 11, right), (880, 70)),
              (card(3, "Always moving", "Can't stay still", "REJECT", TOSS, -11, left), (575, 85)),
              (card(0, "Sharp, single", "Whole, crisp, here to analyse", "A KEEPER", KEEP, 3, left), (720, 105))]:
    img.alpha_composite(c, xy)
d = ImageDraw.Draw(img)
d.rectangle((0, 0, 572, 630), fill=BG + (255,))
wm = Image.open(ROOT / "logo" / "wordmark-dark-preview.png").convert("RGBA")
wm = wm.resize((470, round(470 * wm.height / wm.width)), Image.LANCZOS)
img.alpha_composite(wm, (40, 118))
for i, (text, f, col) in enumerate([("Swipe right on cells", bold(44), INK), ("that are in focus.", bold(44), INK)]):
    d.text((58, 262 + i * 56), text, font=f, fill=col)
d.text((58, 400), "Swipe left on the blurry ones.", font=reg(30), fill=MUTED)
d.text((58, 442), "No sign-up. Just good-looking cells.", font=reg(30), fill=MUTED)
heart = "\u2665"
d.text((58, 520), heart, font=sym(34), fill=TOSS)
d.text((100, 522), "for the Weiss Lab, Polytechnique Montréal", font=reg(24), fill=MUTED)
img.convert("RGB").save(ROOT / "share.png", optimize=True)
print("saved")
