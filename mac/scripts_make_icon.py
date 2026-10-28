"""Resources/AppIcon.png · AppIcon.icns 만들기 (StemMixer · AutoTuner와 같은 타일, 안에는 섹터 + 끌어 그리는 음 높이 선).
사용: python mac/scripts_make_icon.py  (Pillow 필요)"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 4  # 크게 그려서 줄이기 (매끈하게)
W = 1024 * S
out = Path(__file__).parent / "Resources"


def squircle_mask(box, n=5.0):
    x0, y0, x1, y1 = box
    a, b = (x1 - x0) / 2, (y1 - y0) / 2
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    yy, xx = np.mgrid[0:W, 0:W]
    v = np.abs((xx - cx) / a) ** n + np.abs((yy - cy) / b) ** n
    return Image.fromarray(((v <= 1) * 255).astype(np.uint8))


def gradient(c0, c1, angle_box):
    yy, xx = np.mgrid[0:W, 0:W] / W
    t = np.clip((xx * 0.35 + yy * 0.65 - angle_box[0]) / (angle_box[1] - angle_box[0]), 0, 1)[..., None]
    rgb = np.array(c0) * (1 - t) + np.array(c1) * t
    return Image.fromarray(rgb.astype(np.uint8), "RGB")


img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
tile = (100 * S, 100 * S, 924 * S, 924 * S)
mask = squircle_mask(tile)
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
shadow.paste((30, 10, 70, 120), mask=mask.filter(ImageFilter.GaussianBlur(18 * S)).point(lambda v: v * 0.6))
img.alpha_composite(shadow, (0, 12 * S))
img.paste(gradient((164, 140, 255), (92, 56, 214), (0.1, 0.95)), mask=mask)

# 안쪽 흰 카드 (악보)
card = Image.new("RGBA", (W, W), (0, 0, 0, 0))
cbox = (232 * S, 250 * S, 792 * S, 774 * S)
ImageDraw.Draw(card).rounded_rectangle(cbox, radius=96 * S, fill=(255, 255, 255, 255))
cs = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(cs).rounded_rectangle(cbox, radius=96 * S, fill=(40, 10, 90, 110))
img.alpha_composite(cs.filter(ImageFilter.GaussianBlur(22 * S)), (0, 14 * S))
img.alpha_composite(card)

d = ImageDraw.Draw(img)
# 왼쪽 음 이름 표 (건반)
for i, y in enumerate(range(318, 700, 62)):
    fill = (223, 216, 250, 255) if i % 2 else (242, 239, 253, 255)
    d.rounded_rectangle((268 * S, y * S, 346 * S, (y + 50) * S), radius=12 * S, fill=fill)

# 섹터 (가사 한 글자씩)
xs = [(370, 482), (482, 584), (584, 686), (686, 764)]
ys = [630, 564, 498, 564]
for (x0, x1), y in zip(xs, ys):
    d.rounded_rectangle(((x0 + 5) * S, (y - 27) * S, (x1 - 5) * S, (y + 27) * S), radius=20 * S,
                        fill=(150, 124, 246, 255))

# 끌어 그린 음 높이 선 (미끄러짐 + 끝에 떨림)
pts = []
for x in np.linspace(370, 764, 420):
    k = min(3, int(np.searchsorted([x1 for _, x1 in xs], x, side="right")))
    base = ys[k]
    nxt = ys[min(3, k + 1)]
    frac = (x - xs[k][0]) / (xs[k][1] - xs[k][0])
    u = max(0.0, (frac - 0.6) / 0.4)
    y = base + (nxt - base) * (3 * u ** 2 - 2 * u ** 3)
    if k == 3 and x > 700:
        y += 11 * np.sin((x - 700) / 9) * min(1, (x - 700) / 35)
    pts.append((x * S, y * S))
d.line(pts, fill=(255, 150, 42, 255), width=15 * S, joint="curve")

# 끌고 있는 손 (동그란 점 + 꼬리)
px, py = pts[-1]
r = 17 * S
d.ellipse((px - r, py - r, px + r, py + r), fill=(255, 150, 42, 255))
d.ellipse((px - r * 0.45, py - r * 0.45, px + r * 0.45, py + r * 0.45), fill=(255, 255, 255, 235))

img = img.resize((1024, 1024), Image.LANCZOS)
out.mkdir(exist_ok=True)
img.save(out / "AppIcon.png")
img.save(out / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("ok")
