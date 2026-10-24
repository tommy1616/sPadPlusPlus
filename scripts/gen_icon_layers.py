#!/usr/bin/env python3
"""產生 macOS 26 (Tahoe) 的 .icon 分層素材。

輸出：macapp/AppIcon.icon/{icon.json, Assets/*.png}
畫布 1024×1024 滿版（系統會套上圓角遮罩與液態玻璃）。
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "macapp", "AppIcon.icon")
ASSETS = os.path.join(OUT, "Assets")
S = 1024
SC = 1024 / 824.0          # 由舊的 824 設計放大到滿版


def sc(v):
    return int(round(v * SC))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.point((0, y), lerp(top, bottom, y / (size - 1)))
    return img.resize((size, size))


def layer():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def overlay(base, fn):
    l = layer()
    fn(ImageDraw.Draw(l))
    return Image.alpha_composite(base, l)


# ---------------------------------------------------------------- 01 背景
def background():
    img = vertical_gradient(S, (58, 63, 92), (14, 16, 28)).convert("RGBA")

    # 上方柔光
    glow = layer()
    ImageDraw.Draw(glow).ellipse([-S * 0.35, -S * 0.85, S * 1.35, S * 0.42],
                                 fill=(255, 255, 255, 26))
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    img = Image.alpha_composite(img, glow)

    # 底部微暗（讓玻璃層有厚度）
    shade = layer()
    ImageDraw.Draw(shade).ellipse([-S * 0.2, S * 0.72, S * 1.2, S * 1.5],
                                  fill=(0, 0, 0, 40))
    img = Image.alpha_composite(img, shade.filter(ImageFilter.GaussianBlur(60)))
    return img


# ---------------------------------------------------------------- 02 卡片
def card():
    img = layer()
    d = ImageDraw.Draw(img)
    cx, cy, cw, ch = sc(148), sc(198), sc(528), sc(456)
    d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=sc(46), fill=(10, 12, 22, 255))
    return img


# ---------------------------------------------------------------- 03 程式碼行
def code():
    img = layer()
    d = ImageDraw.Draw(img)
    cx, cy, cw, ch = sc(148), sc(198), sc(528), sc(456)
    top = cy + sc(54)

    rows = [
        [((122, 162, 247), 0.16), ((125, 207, 255), 0.24)],
        [((187, 154, 247), 0.12), ((158, 206, 106), 0.30), ((158, 206, 106), 0.12)],
        [((224, 175, 104), 0.10), ((122, 162, 247), 0.26), ((224, 175, 104), 0.10)],
        [((247, 118, 142), 0.14), ((187, 154, 247), 0.20)],
        [((158, 206, 106), 0.12), ((122, 162, 247), 0.22)],
        [((122, 162, 247), 0.10), ((125, 207, 255), 0.16)],
    ]
    for i, row in enumerate(rows):
        y = top + i * sc(54)
        x = cx + sc(88)
        for color, wfrac in row:
            w = int(cw * wfrac)
            d.rounded_rectangle([x, y, x + w, y + sc(20)], radius=sc(10), fill=color + (255,))
            x += w + sc(14)

    for i in range(len(rows)):
        y = top + i * sc(54)
        d.rounded_rectangle([cx + sc(46), y + sc(4), cx + sc(60), y + sc(16)],
                            radius=sc(6), fill=(70, 76, 100, 255))

    # 目前行高亮
    ay = top + 3 * sc(54)
    img = overlay(img, lambda dl: dl.rounded_rectangle(
        [cx + sc(30), ay - sc(14), cx + cw - sc(30), ay + sc(34)],
        radius=sc(12), fill=(255, 255, 255, 26)))
    return img


# ---------------------------------------------------------------- 04 游標
def cursor():
    img = layer()
    d = ImageDraw.Draw(img)
    cx, cy, cw, ch = sc(148), sc(198), sc(528), sc(456)
    ay = cy + sc(54) + 3 * sc(54)
    d.rounded_rectangle([cx + sc(88), ay, cx + sc(96), ay + sc(20)],
                        radius=sc(3), fill=(240, 243, 250, 255))
    return img


def main():
    os.makedirs(ASSETS, exist_ok=True)
    # 分層素材另外存一份，方便日後在 Icon Composer 裡微調
    layers_dir = os.path.join(HERE, "icon-layers")
    os.makedirs(layers_dir, exist_ok=True)
    for name, im in [("01-background.png", background()),
                     ("02-card.png", card()),
                     ("03-code.png", code()),
                     ("04-cursor.png", cursor())]:
        im.save(os.path.join(layers_dir, name))
        print("寫出", name)

    # 合成單一圖層：macOS 26 會把「第二個 group」當成漂浮玻璃層而整片模糊，
    # 所以主視覺必須壓成一張圖，只用一個 group。
    composited = background()
    for part in (card(), code(), cursor()):
        composited = Image.alpha_composite(composited, part)
    os.makedirs(ASSETS, exist_ok=True)
    composited.save(os.path.join(ASSETS, "00-artwork.png"))
    print("寫出 00-artwork.png")

    doc = {
        "fill": {"solid": "srgb:0.055,0.063,0.110,1.000"},
        "groups": [{"layers": [{"image-name": "00-artwork.png", "name": "主視覺"}]}],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(OUT, "icon.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print("寫出 icon.json")


if __name__ == "__main__":
    main()
