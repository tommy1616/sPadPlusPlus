#!/usr/bin/env python3
# App Icon 三方案（macOS Big Sur 風格）
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))

S, C, R = 1024, 824, 185
OFF = (S - C) // 2
CJK = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.point((0, y), lerp(top, bottom, y / max(1, size - 1)))
    return img.resize((size, size))

def squircle_mask(size=C, radius=R, ss=4):
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * ss - 1, size * ss - 1],
                                        radius=radius * ss, fill=255)
    return m.resize((size, size), Image.LANCZOS)

def base_icon(top, bottom, border=(255, 255, 255, 34)):
    icon = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    icon.paste(gradient(C, top, bottom), (0, 0), squircle_mask())

    # 上方柔光
    hi = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(hi).ellipse([-C * 0.35, -C * 0.9, C * 1.35, C * 0.32],
                               fill=(255, 255, 255, 30))
    a = hi.split()[3]
    hi.putalpha(Image.composite(a, Image.new("L", (C, C), 0), squircle_mask()))
    icon = Image.alpha_composite(icon, hi)

    d = ImageDraw.Draw(icon)
    d.rounded_rectangle([1.5, 1.5, C - 2.5, C - 2.5], radius=R, outline=border, width=3)
    return icon


def overlay(icon, fn):
    """在透明圖層上畫，再 alpha 合成（PIL 直接畫半透明會覆蓋而不是混合）"""
    layer = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    fn(ImageDraw.Draw(layer))
    return Image.alpha_composite(icon, layer)

def shadowed(icon):
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    a = icon.split()[3].point(lambda v: int(v * 0.32))
    blk = Image.new("RGBA", icon.size, (0, 0, 0, 255))
    blk.putalpha(a)
    sh.paste(blk, (OFF, OFF + 16), blk)
    sh = sh.filter(ImageFilter.GaussianBlur(20))
    out = Image.alpha_composite(Image.new("RGBA", (S, S), (0, 0, 0, 0)), sh)
    out.paste(icon, (OFF, OFF), icon)
    return out

# ------------------------------------------------------------------ A 經典綠皮書
def icon_a():
    ic = base_icon((78, 178, 96), (22, 110, 54))
    d = ImageDraw.Draw(ic)

    pw, ph = 356, 440
    px, py = (C - pw) // 2, (C - ph) // 2

    sh = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([px + 4, py + 12, px + pw + 4, py + ph + 12],
                                         radius=42, fill=(0, 0, 0, 80))
    ic = Image.alpha_composite(ic, sh.filter(ImageFilter.GaussianBlur(18)))
    d = ImageDraw.Draw(ic)

    d.rounded_rectangle([px, py, px + pw, py + ph], radius=42, fill=(255, 255, 255, 255))

    # 文字行
    rows = [(0.26, 0.60), (0.36, 0.74), (0.46, 0.48), (0.56, 0.68)]
    for t, w in rows:
        y = py + int(ph * t)
        d.rounded_rectangle([px + 52, y, px + 52 + int(pw * w), y + 20], radius=10,
                            fill=(203, 211, 205, 255))

    # 綠色游標 + 目前行
    cy = py + int(ph * 0.56)
    ic = overlay(ic, lambda dl: dl.rounded_rectangle(
        [px + 52, cy - 10, px + 52 + int(pw * 0.68), cy + 30], radius=10, fill=(34, 160, 84, 40)))
    d = ImageDraw.Draw(ic)
    d.rounded_rectangle([px + 52, cy - 8, px + 61, cy + 30], radius=4, fill=(28, 132, 66, 255))

    # 再一行在游標下方（營造「正在編輯」）
    y2 = py + int(ph * 0.73)
    d.rounded_rectangle([px + 52, y2, px + 52 + int(pw * 0.36), y2 + 20], radius=10,
                        fill=(216, 222, 217, 255))
    return shadowed(ic)

# ------------------------------------------------------------------ B 語法高亮
def icon_b():
    ic = base_icon((42, 46, 66), (16, 18, 30), border=(255, 255, 255, 26))
    d = ImageDraw.Draw(ic)

    cw, ch = 528, 456
    cx, cy = (C - cw) // 2, (C - ch) // 2
    d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=46, fill=(28, 31, 46, 255))
    d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=46, outline=(255, 255, 255, 26), width=2)

    rows = [
        [((108, 132, 214), 0.16), ((150, 205, 225), 0.24)],
        [((205, 150, 205), 0.12), ((150, 212, 165), 0.30), ((150, 212, 165), 0.12)],
        [((214, 184, 118), 0.10), ((104, 168, 226), 0.26), ((214, 184, 118), 0.10)],
        [((190, 128, 128), 0.14), ((205, 150, 205), 0.20)],
        [((150, 212, 165), 0.12), ((108, 132, 214), 0.22)],
        [((108, 132, 214), 0.10), ((150, 205, 225), 0.16)],
    ]

    top = cy + 54
    for i, row in enumerate(rows):
        y = top + i * 54
        x = cx + 88
        for color, wfrac in row:
            w = int(cw * wfrac)
            d.rounded_rectangle([x, y, x + w, y + 20], radius=10, fill=color + (255,))
            x += w + 14

    # 行號
    for i in range(len(rows)):
        y = top + i * 54
        d.rounded_rectangle([cx + 46, y + 4, cx + 60, y + 16], radius=6, fill=(92, 98, 122, 255))

    # 目前行 highlight（柔和）+ 游標
    ay = top + 3 * 54
    ic = overlay(ic, lambda dl: dl.rounded_rectangle(
        [cx + 30, ay - 14, cx + cw - 30, ay + 34], radius=12, fill=(255, 255, 255, 16)))
    d = ImageDraw.Draw(ic)
    d.rounded_rectangle([cx + 88, ay, cx + 96, ay + 20], radius=3, fill=(236, 240, 248, 235))

    return shadowed(ic)

# ------------------------------------------------------------------ C 字母 S
def icon_c():
    ic = base_icon((252, 252, 255), (211, 218, 232), border=(0, 0, 0, 18))
    d = ImageDraw.Draw(ic)

    # 底部柔和內陰影（增加厚度）
    inner = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(inner).ellipse([-C * 0.2, C * 0.82, C * 1.2, C * 1.5],
                                  fill=(0, 0, 0, 12))
    a = inner.split()[3]
    inner.putalpha(Image.composite(a, Image.new("L", (C, C), 0), squircle_mask()))
    inner = inner.filter(ImageFilter.GaussianBlur(30))
    ic = Image.alpha_composite(ic, inner)
    d = ImageDraw.Draw(ic)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 430, index=1)
    except Exception:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 430)

    bbox = d.textbbox((0, 0), "S", font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx = (C - tw) / 2 - bbox[0] - 40
    ty = (C - th) / 2 - bbox[1] + 6
    d.text((tx, ty), "S", font=font, fill=(32, 37, 50, 255))

    cx = tx + tw + 52
    d.rounded_rectangle([cx, ty + bbox[1] + 10, cx + 30, ty + bbox[3] - 10],
                        radius=9, fill=(0, 174, 122, 255))
    return shadowed(ic)

icons = [("A   經典綠皮書", icon_a()),
         ("B   語法高亮", icon_b()),
         ("C   字母 S", icon_c())]

for i, (_, im) in enumerate(icons, 1):
    im.save(os.path.join(HERE, f"icon_{chr(64+i)}.png"))
    im.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, f"icon_{chr(64+i)}_256.png"))

W, H = 1760, 780
sheet = Image.new("RGB", (W, H), (246, 246, 248))
sd = ImageDraw.Draw(sheet)
lf = ImageFont.truetype(CJK, 28)
sf = ImageFont.truetype(CJK, 19)

for i, (label, im) in enumerate(icons):
    big = im.resize((480, 480), Image.LANCZOS)
    small = im.resize((100, 100), Image.LANCZOS)
    x = 60 + i * 565
    sheet.paste(big, (x, 70), big)
    sheet.paste(small, (x + 380, 560), small)
    sd.text((x, 578), label, font=lf, fill=(28, 30, 36))
    sd.text((x + 384, 668), "100 px", font=sf, fill=(130, 132, 140))

sheet.save(os.path.join(HERE, "icons_compare.png"))
print("done")
