#!/usr/bin/env python3
"""Sinh toàn bộ logo/icon Yui từ MỘT bộ thông số (chạy: python tools/make_brand.py). Cần Pillow. Xuất:
  assets/brand/   yui_icon.svg, yui_mark.svg, yui_icon_1024.png, play_store_512.png, logo_horizontal_{dark,light}.png, yui.ico
  assets/android_res/   mipmap-*/ic_launcher{,_round,_foreground,_background,_monochrome}.png + mipmap-anydpi-v26/ic_launcher{,_round}.xml  (workflow chép vào android/app/src/main/res)
Ý tưởng: chữ Y = ba nhánh nối vào một nút giữa (結 "yui" = thắt/kết nối) và ba nút đầu nhánh gợi mạng chuyên gia (MoE); nút hổ phách là chuyên gia đang được chọn."""
import math, os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
BRAND, RES = os.path.join(ROOT, "assets", "brand"), os.path.join(ROOT, "assets", "android_res")
S = 4096                                   # vẽ lớn rồi thu nhỏ để mép mịn
C0, C1, C2 = (38, 31, 140), (104, 70, 238), (196, 92, 255)   # chàm đậm -> tím -> tím hồng
AMBER, WHITE, INK = (255, 200, 87), (255, 255, 255), (38, 31, 140)
# hình học của dấu Y trên khung 1024
JOINT, LEFT, RIGHT, STEM = (512, 566), (318, 300), (706, 300), (512, 790)
W_STROKE, R_NODE, R_JOINT = 84, 62, 46
FONT = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"


def gradient(size):
    g = Image.new("RGB", (size, size)); px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x * 0.55 + y * 0.45) / size
            a, b, u = (C0, C1, t / 0.55) if t < 0.55 else (C1, C2, (t - 0.55) / 0.45)
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * min(1, u)) for i in range(3))
    return g


def grad_fast(size):
    small = gradient(256)
    return small.resize((size, size), Image.BICUBIC)


def mark_layer(size, color=WHITE, node_color=AMBER, scale=1.0, glow=True):
    """Dấu Y trên nền trong suốt, canh giữa theo `scale` quanh tâm khung."""
    k = size / 1024.0
    def P(p): return ((512 + (p[0] - 512) * scale) * k, (512 + (p[1] - 548) * scale) * k)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    w = W_STROKE * scale * k
    def stroke(a, b):
        a, b = P(a), P(b); d.line([a, b], fill=color + (255,), width=int(w))
        for q in (a, b): d.ellipse([q[0] - w / 2, q[1] - w / 2, q[0] + w / 2, q[1] + w / 2], fill=color + (255,))
    for end in (LEFT, RIGHT, STEM): stroke(JOINT, end)
    j = P(JOINT); rj = R_JOINT * scale * k
    d.ellipse([j[0] - rj * 1.9, j[1] - rj * 1.9, j[0] + rj * 1.9, j[1] + rj * 1.9], fill=color + (255,))      # nút giữa (thắt)
    return img, d, P, k


def draw_mark(size, color=WHITE, node_color=AMBER, scale=1.0, hole=None):
    img, d, P, k = mark_layer(size, color, node_color, scale)
    rn = R_NODE * scale * k
    for pt, col in ((LEFT, color), (RIGHT, node_color), (STEM, color)):
        c = P(pt); r = rn * (1.0 if pt != STEM else 0.8)
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=col + (255,))
    j = P(JOINT); rj = R_JOINT * scale * k
    d.ellipse([j[0] - rj, j[1] - rj, j[0] + rj, j[1] + rj], fill=(0, 0, 0, 0) if hole == "clear" else (hole or C1) + (255,))   # lỗ giữa nút: "con mắt/lõi" (clear = xuyên thấu cho icon đơn sắc)
    return img


def rounded(size, radius_frac=0.2237):
    m = Image.new("L", (size, size), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * radius_frac), fill=255); return m


def glow_spot(size):
    """Vệt sáng mềm (độ sáng giảm dần theo hình tròn) ở góc trên trái cho có chiều sâu, không có mép cứng."""
    r = Image.radial_gradient("L").point(lambda v: max(0, 255 - v * 2) * 40 // 255)      # tâm sáng nhất, tắt dần về 0 ở nửa bán kính
    r = r.resize((int(size * 1.3), int(size * 1.3)), Image.BICUBIC)
    g = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    g.paste((255, 255, 255, 255), (int(-size * 0.25), int(-size * 0.3)), r)
    return g


def full_icon(size, rounded_corners=True, mark_scale=1.0, circle=False):
    big = S
    bg = grad_fast(big).convert("RGBA"); bg.alpha_composite(glow_spot(big))
    # bóng nhẹ dưới dấu Y
    mk = draw_mark(big, scale=mark_scale)
    sh = Image.new("RGBA", (big, big), (0, 0, 0, 0)); sh.putalpha(mk.split()[3].point(lambda v: int(v * 0.28))); sh = sh.filter(ImageFilter.GaussianBlur(big * 0.012))
    bg.alpha_composite(sh, (0, int(big * 0.012))); bg.alpha_composite(mk)
    out = bg.resize((size, size), Image.LANCZOS)
    if circle:
        m = Image.new("L", (size * 4, size * 4), 0); ImageDraw.Draw(m).ellipse([0, 0, size * 4 - 1, size * 4 - 1], fill=255); out.putalpha(m.resize((size, size), Image.LANCZOS))
    elif rounded_corners:
        out.putalpha(rounded(size * 4).resize((size, size), Image.LANCZOS))
    return out


def layer(size, kind):
    """Lớp adaptive 108dp: dấu Y nằm gọn trong vùng an toàn (đường kính 66/108)."""
    big = S
    sc = 0.72   # vùng an toàn của adaptive icon là đường tròn 66/108 ≈ 61% khung: mọi điểm của dấu Y vẫn nằm trong đó
    if kind == "foreground":
        return draw_mark(big, scale=sc).resize((size, size), Image.LANCZOS)
    if kind == "monochrome":
        return draw_mark(big, color=WHITE, node_color=WHITE, scale=sc, hole="clear").resize((size, size), Image.LANCZOS)
    bg = grad_fast(big).convert("RGBA"); bg.alpha_composite(glow_spot(big)); return bg.resize((size, size), Image.LANCZOS)


def wordmark(dark):
    icon = full_icon(512)
    H = 640; f = ImageFont.truetype(FONT, 400); text = "Yui"
    tw = int(ImageDraw.Draw(Image.new("L", (1, 1))).textlength(text, font=f))
    W = 512 + 70 + tw + 40
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0)); img.alpha_composite(icon, (0, (H - 512) // 2))
    d = ImageDraw.Draw(img); d.text((512 + 70, H // 2 + 14), text, font=f, fill=(INK if dark else WHITE) + (255,), anchor="lm")
    return img


def svg():
    def pts(p): return f"{p[0]},{p[1]}"
    marks = f'''<g stroke="#fff" stroke-width="{W_STROKE}" stroke-linecap="round" fill="none"><path d="M{pts(LEFT)} L{pts(JOINT)} M{pts(RIGHT)} L{pts(JOINT)} M{pts(STEM)} L{pts(JOINT)}"/></g>
  <circle cx="{JOINT[0]}" cy="{JOINT[1]}" r="{R_JOINT*1.9:.0f}" fill="#fff"/><circle cx="{JOINT[0]}" cy="{JOINT[1]}" r="{R_JOINT}" fill="#{C1[0]:02x}{C1[1]:02x}{C1[2]:02x}"/>
  <circle cx="{LEFT[0]}" cy="{LEFT[1]}" r="{R_NODE}" fill="#fff"/><circle cx="{RIGHT[0]}" cy="{RIGHT[1]}" r="{R_NODE}" fill="#ffc857"/><circle cx="{STEM[0]}" cy="{STEM[1]}" r="{R_NODE*0.8:.0f}" fill="#fff"/>'''
    defs = f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="rgb{C0}"/><stop offset=".55" stop-color="rgb{C1}"/><stop offset="1" stop-color="rgb{C2}"/></linearGradient></defs>'
    icon = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{defs}\n  <rect width="1024" height="1024" rx="229" fill="url(#g)"/>\n  <g transform="translate(0,-18)">{marks}</g>\n</svg>\n'
    mark = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="150 130 724 760" width="724" height="760">\n  <g style="--c:#fff">{marks.replace("#fff", "#262a8f").replace("#262a8f", "#4a3fd1")}</g>\n</svg>\n'
    return icon, mark


def main():
    os.makedirs(BRAND, exist_ok=True)
    icon_svg, mark_svg = svg()
    open(os.path.join(BRAND, "yui_icon.svg"), "w").write(icon_svg); open(os.path.join(BRAND, "yui_mark.svg"), "w").write(mark_svg)
    full_icon(1024).save(os.path.join(BRAND, "yui_icon_1024.png")); full_icon(512).save(os.path.join(BRAND, "play_store_512.png"))
    wordmark(True).save(os.path.join(BRAND, "logo_horizontal_dark.png")); wordmark(False).save(os.path.join(BRAND, "logo_horizontal_light.png"))
    full_icon(256).save(os.path.join(BRAND, "yui.ico"), sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)])
    for name, legacy, adaptive in (("mdpi", 48, 108), ("hdpi", 72, 162), ("xhdpi", 96, 216), ("xxhdpi", 144, 324), ("xxxhdpi", 192, 432)):
        d = os.path.join(RES, f"mipmap-{name}"); os.makedirs(d, exist_ok=True)
        full_icon(legacy, mark_scale=1.0).save(os.path.join(d, "ic_launcher.png")); full_icon(legacy, circle=True).save(os.path.join(d, "ic_launcher_round.png"))
        for kind in ("foreground", "background", "monochrome"): layer(adaptive, kind).save(os.path.join(d, f"ic_launcher_{kind}.png"))
    xd = os.path.join(RES, "mipmap-anydpi-v26"); os.makedirs(xd, exist_ok=True)
    xml = '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@mipmap/ic_launcher_background"/>\n    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n</adaptive-icon>\n'
    for n in ("ic_launcher.xml", "ic_launcher_round.xml"): open(os.path.join(xd, n), "w").write(xml)
    print("xong:", BRAND, RES)


if __name__ == "__main__":
    main()
