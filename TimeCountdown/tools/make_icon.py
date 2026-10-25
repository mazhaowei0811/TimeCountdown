#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 TimeCountdown 的 App 图标（纯 Pillow 绘制，无外部资源）。

图案：深色渐变底 + 青绿渐变秒表环 + 指针，右下角一个小悬浮窗示意。
"""
import os
from PIL import Image, ImageDraw, ImageFilter

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "layout", "Applications", "TimeCountdown.app")
SIZE = 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def radial_bg(size):
    """深色径向渐变底。"""
    img = Image.new("RGB", (size, size), (14, 18, 24))
    px = img.load()
    cx = cy = size / 2.0
    inner = (30, 42, 52)
    outer = (10, 13, 18)
    maxd = (cx ** 2 + cy ** 2) ** 0.5
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / maxd
            px[x, y] = lerp(inner, outer, min(1.0, d ** 0.8))
    return img


def ring(draw, box, width, color):
    draw.arc(box, start=0, end=360, fill=color, width=width)


def main():
    S = SIZE * 4  # 先画大图再缩，边缘更干净
    img = radial_bg(S).convert("RGBA")
    d = ImageDraw.Draw(img)

    cx = cy = S / 2.0
    c = S * 0.30          # 主环半径
    lw = int(S * 0.052)   # 环宽

    # 外圈淡光圈
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([cx - c - lw, cy - c - lw, cx + c + lw, cy + c + lw],
               outline=(45, 212, 191, 90), width=int(lw * 2.2))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.02))
    img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)

    # 主环：用渐变色分段画，做出青绿渐变
    steps = 180
    for i in range(steps):
        t = i / float(steps)
        col = lerp((94, 234, 212), (13, 148, 136), t)
        d.arc([cx - c, cy - c, cx + c, cy + c],
              start=-90 + i * (360.0 / steps),
              end=-90 + (i + 1) * (360.0 / steps) + 1.2,
              fill=col, width=lw)

    # 刻度（12 点方向的小缺口，暗示计时器）
    tick_len = lw * 0.55
    d.rectangle([cx - lw * 0.16, cy - c - lw * 0.5,
                 cx + lw * 0.16, cy - c - lw * 0.5 + tick_len],
                fill=(14, 18, 24, 255))

    # 指针：时针指向 2 点方向，分针指向 6 点方向
    import math
    def hand(angle_deg, length, width, color):
        a = math.radians(angle_deg - 90)
        x2 = cx + length * math.cos(a)
        y2 = cy + length * math.sin(a)
        d.line([cx, cy, x2, y2], fill=color, width=width)
        r = width / 2.0
        d.ellipse([x2 - r, y2 - r, x2 + r, y2 + r], fill=color)

    white = (238, 243, 248, 255)
    hand(60, c * 0.52, int(lw * 0.34), white)     # 指向 2 点
    hand(180, c * 0.72, int(lw * 0.28), white)    # 指向 6 点

    # 中心轴
    r = lw * 0.46
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(94, 234, 212, 255))

    # 右下角小悬浮窗（半透明深色圆角块 + 一道高亮数字条）
    bw, bh = S * 0.34, S * 0.155
    bx = S * 0.60
    by = S * 0.735
    chip = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cd = ImageDraw.Draw(chip)
    cd.rounded_rectangle([bx, by, bx + bw, by + bh],
                         radius=int(bh * 0.34), fill=(8, 12, 16, 205),
                         outline=(45, 212, 191, 190), width=int(S * 0.006))
    # 三道数字条，模拟倒计时数字
    bar_h = bh * 0.20
    bar_y = by + bh * 0.40
    xoff = bx + bw * 0.13
    for i in range(3):
        w = bw * (0.17 if i != 1 else 0.235)
        cd.rounded_rectangle([xoff, bar_y, xoff + w, bar_y + bar_h],
                             radius=int(bar_h * 0.45),
                             fill=(94, 234, 212, 235))
        xoff += w + bw * 0.075
    img = Image.alpha_composite(img, chip)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    os.makedirs(OUT_DIR, exist_ok=True)
    full = os.path.join(OUT_DIR, "icon.png")
    img.save(full, "PNG")
    print("wrote", full, img.size)


if __name__ == "__main__":
    main()
