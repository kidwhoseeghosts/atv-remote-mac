#!/usr/bin/env python3
"""Генератор иконки ATV Remote (macOS 26-стиль) и значка для строки меню.

Рисует всё программно (Pillow + numpy), без внешних ресурсов:
  * Resources/Assets.xcassets/AppIcon.appiconset — все размеры + Contents.json;
  * Resources/Assets.xcassets/MenuBarRemote(.Filled).imageset — монохромные template-значки;
  * icon-preview.png (по желанию, --preview PATH).

Запуск:  python3 scripts/make_icon.py [--preview ../icon-preview.png]
Зависимости: pip install pillow numpy
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources" / "Assets.xcassets"

U = 1024          # логический размер холста (как в шаблоне macOS)
K = 2             # суперсэмплинг: рисуем в 2048, отдаём 1024
W = U * K


def k(v: float) -> int:
    return int(round(v * K))


# ───────────────────────── вспомогательные примитивы ─────────────────────────

def superellipse_mask(cx, cy, half_w, half_h, n=5.0, size=W, ss=1) -> Image.Image:
    """Маска «сквиркла» (суперэллипс, n≈5 похож на macOS-иконку) с антиалиасингом."""
    scale = 2  # локальный суперсэмплинг для гладкого края
    s = size * scale
    ys, xs = np.mgrid[0:s, 0:s].astype(np.float32)
    x = (xs / scale - cx) / half_w
    y = (ys / scale - cy) / half_h
    inside = (np.abs(x) ** n + np.abs(y) ** n) <= 1.0
    img = Image.fromarray((inside * 255).astype(np.uint8), "L")
    return img.resize((size, size), Image.LANCZOS)


def rrect_mask(box, radius, size=W) -> Image.Image:
    m = Image.new("L", (size * 2, size * 2), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([c * 2 for c in box], radius=radius * 2, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def circle_mask(cx, cy, r, size=W) -> Image.Image:
    m = Image.new("L", (size * 2, size * 2), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([(cx - r) * 2, (cy - r) * 2, (cx + r) * 2, (cy + r) * 2], fill=255)
    return m.resize((size, size), Image.LANCZOS)


def hex_rgb(h: str):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def linear_gradient(stops, angle_deg=90.0, size=W) -> Image.Image:
    """Линейный градиент RGBA. angle 90 = сверху вниз. stops: [(pos, '#rrggbb', alpha)]."""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    t = ((xs - size / 2) * dx + (ys - size / 2) * dy) / size + 0.5
    t = np.clip(t, 0, 1)
    pos = [s[0] for s in stops]
    out = np.zeros((size, size, 4), np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(t, pos, [hex_rgb(s[1])[ch] for s in stops])
    out[..., 3] = np.interp(t, pos, [s[2] * 255 for s in stops])
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def radial_gradient(cx, cy, r, stops, size=W, ry=None) -> Image.Image:
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    ry = ry or r
    t = np.sqrt(((xs - cx) / r) ** 2 + ((ys - cy) / ry) ** 2)
    t = np.clip(t, 0, 1)
    pos = [s[0] for s in stops]
    out = np.zeros((size, size, 4), np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(t, pos, [hex_rgb(s[1])[ch] for s in stops])
    out[..., 3] = np.interp(t, pos, [s[2] * 255 for s in stops])
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def paste_masked(base: Image.Image, layer: Image.Image, mask: Image.Image, opacity=1.0):
    """Накладывает layer на base через mask (и альфу layer)."""
    a = ImageChops.multiply(layer.getchannel("A"), mask)
    if opacity < 1:
        a = a.point(lambda v: int(v * opacity))
    layer = layer.copy()
    layer.putalpha(a)
    base.alpha_composite(layer)


def solid(color, alpha=1.0, size=W) -> Image.Image:
    return Image.new("RGBA", (size, size), (*hex_rgb(color), int(alpha * 255)))


def drop_shadow(base: Image.Image, mask: Image.Image, dx, dy, blur, alpha, color="#000000"):
    sh = Image.new("L", (W, W), 0)
    sh.paste(mask, (k(dx), k(dy)))
    sh = sh.filter(ImageFilter.GaussianBlur(k(blur)))
    layer = solid(color)
    layer.putalpha(sh.point(lambda v: int(v * alpha)))
    base.alpha_composite(layer)


def inner_stroke(mask: Image.Image, width_px: int) -> Image.Image:
    """Кольцо шириной width_px по внутреннему краю маски."""
    eroded = mask.filter(ImageFilter.MinFilter(width_px * 2 + 1))
    return ImageChops.subtract(mask, eroded)


# ───────────────────────────── основная иконка ──────────────────────────────

def vgrad(stops, y0, y1) -> Image.Image:
    """Вертикальный градиент RGB, привязанный к пикселям y0..y1 холста (а не ко всему холсту)."""
    ys = np.arange(W, dtype=np.float32)
    t = np.clip((ys - y0) / max(1.0, (y1 - y0)), 0, 1)
    pos = [s[0] for s in stops]
    col = np.zeros((W, 4), np.float32)
    for ch in range(3):
        col[:, ch] = np.interp(t, pos, [hex_rgb(s[1])[ch] for s in stops])
    col[:, 3] = np.interp(t, pos, [s[2] * 255 for s in stops])
    arr = np.repeat(col[:, None, :], W, axis=1)
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def draw_remote(layer: Image.Image, ox: float, oy: float, s: float, simple: bool = False):
    """Apple TV Remote (Siri Remote 2-го/3-го поколения, 2021+), анфас.

    Пропорции сняты с официальной картинки Apple Support (support.apple.com/102337,
    siri-remote-gen-2-*.png): корпус 216×847 (≈1:3.9, 35×136 мм), клик-пад Ø195 (≈0.9 ширины),
    кнопки Ø76 в две колонки (x=±47), ряды через 92.5, справа высокая «таблетка» громкости
    (+/−) на 2 нижних ряда, сверху справа — кнопка питания. (ox, oy) — центр корпуса, s — масштаб.
    В simple-режиме (16/32 px) корпус шире, детали крупнее, глифы опущены.
    """
    X = lambda x: ox + x * s          # noqa: E731
    Y = lambda y: oy + y * s          # noqa: E731
    kk = lambda v: k(v * s)           # noqa: E731
    thin = lambda v: max(1, kk(v))    # noqa: E731

    if simple:
        BW, BH, BR = 138, 423.5, 54
        pcy, pr = -288, 122
        brr, bx, rows = 47, 62, (-108, -8, 92)
        pill_top, pill_bot = -58, 92 + brr
    else:
        BW, BH, BR = 108, 423.5, 42
        pcy, pr = -248, 97.5
        brr, bx, rows = 38, 47, (-104, -11.5, 81)
        pill_top, pill_bot = -42, 119
    top, bot = Y(-BH), Y(BH)

    # корпус
    remote = rrect_mask((k(X(-BW)), k(top), k(X(BW)), k(bot)), kk(BR))
    drop_shadow(layer, remote, 0, 14 * s, 14 * s, 0.55)
    drop_shadow(layer, remote, 0, 5 * s, 3.5 * s, 0.40)
    metal = vgrad([(0.0, "#f1f2f4", 1), (0.30, "#dcdee1", 1), (0.55, "#bcbec2", 1), (0.80, "#a0a2a6", 1), (1.0, "#8c8e92", 1)], k(top), k(bot))
    paste_masked(layer, metal, remote)
    # боковое затемнение/объём
    side = Image.new("L", (W, W), 0)
    sd = ImageDraw.Draw(side)
    sd.rectangle([0, 0, W, W], fill=0)
    side_img = np.zeros((W,), np.float32)
    xs = np.arange(W, dtype=np.float32)
    u = np.clip((xs - k(X(-BW))) / (k(X(BW)) - k(X(-BW))), 0, 1) * 2 - 1
    side_img = (np.abs(u) ** 6) * 90
    side = Image.fromarray(np.repeat(side_img[None, :], W, 0).astype(np.uint8), "L")
    paste_masked(layer, solid("#3a3c42"), ImageChops.multiply(side, remote), 0.55)
    if not simple:
        paste_masked(layer, vgrad([(0, "#ffffff", 0.95), (0.35, "#ffffff", 0.30), (1, "#ffffff", 0.04)], k(top), k(bot)), inner_stroke(remote, thin(2.2)))
        paste_masked(layer, vgrad([(0, "#000000", 0.0), (0.7, "#000000", 0.0), (1, "#000000", 0.35)], k(top), k(bot)), inner_stroke(remote, thin(1.1)))

    # боковая кнопка Siri (правый край, чуть выступает)
    if not simple:
        siri = rrect_mask((k(X(BW - 2)), k(Y(-318)), k(X(BW + 5)), k(Y(-252))), kk(3))
        paste_masked(layer, linear_gradient([(0, "#f2f3f5", 1), (1, "#9a9ca1", 1)], 0), siri)

    # кнопка питания и микрофон
    if not simple:
        pw_c = (66.5, -384.5)
        pm = circle_mask(k(X(pw_c[0])), k(Y(pw_c[1])), kk(19.5))
        paste_masked(layer, vgrad([(0, "#9c9ea3", 0.9), (1, "#ffffff", 0.9)], k(Y(pw_c[1] - 20)), k(Y(pw_c[1] + 20))), pm)
        pm2 = circle_mask(k(X(pw_c[0])), k(Y(pw_c[1])), kk(17.2))
        paste_masked(layer, vgrad([(0, "#e4e5e8", 1), (1, "#cfd1d4", 1)], k(Y(pw_c[1] - 18)), k(Y(pw_c[1] + 18))), pm2)
        mic = rrect_mask((k(X(-6)), k(Y(-388)), k(X(6)), k(Y(-381))), kk(3))
        paste_masked(layer, solid("#17181a"), mic)

    # клик-пад: чёрное кольцо + сенсорный центр
    pcx = 0
    ring = circle_mask(k(X(pcx)), k(Y(pcy)), kk(pr))
    drop_shadow(layer, ring, 0, 3 * s, 3 * s, 0.35)
    paste_masked(layer, radial_gradient(k(X(pcx)), k(Y(pcy - pr * 0.25)), kk(pr * 1.05),
                                        [(0, "#2b2c30", 1), (0.6, "#17181a", 1), (1, "#0b0b0c", 1)]), ring)
    if not simple:
        paste_masked(layer, vgrad([(0, "#ffffff", 0.45), (0.5, "#ffffff", 0.05), (1, "#ffffff", 0.18)], k(Y(pcy - pr)), k(Y(pcy + pr))), inner_stroke(ring, thin(1.5)))
        for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
            dr = 3.6
            paste_masked(layer, solid("#c9ccd2"), circle_mask(k(X(pcx + dx * pr * 0.90)), k(Y(pcy + dy * pr * 0.90)), kk(dr)), 0.9)
    tr = pr * (0.58 if not simple else 0.55)
    touch = circle_mask(k(X(pcx)), k(Y(pcy)), kk(tr))
    paste_masked(layer, radial_gradient(k(X(pcx)), k(Y(pcy + tr * 0.2)), kk(tr * 1.1),
                                        [(0, "#050506", 1), (0.8, "#070708", 1), (1, "#0c0c0e", 1)]), touch)
    if not simple:
        paste_masked(layer, vgrad([(0, "#000000", 0.7), (1, "#ffffff", 0.22)], k(Y(pcy - tr)), k(Y(pcy + tr))), inner_stroke(touch, thin(1.6)))
        paste_masked(layer, radial_gradient(k(X(-pr * 0.25)), k(Y(pcy - pr * 0.55)), kk(pr * 0.9), [(0, "#ffffff", 0.16), (1, "#ffffff", 0)], ry=kk(pr * 0.4)), ring)

    # кнопки: Back / TV, Play-Pause, Mute + таблетка громкости
    def black_button(mask, y0, y1):
        paste_masked(layer, vgrad([(0, "#2d2e32", 1), (0.45, "#161719", 1), (1, "#0b0b0c", 1)], y0, y1), mask)
        if not simple:
            paste_masked(layer, vgrad([(0, "#ffffff", 0.40), (0.5, "#ffffff", 0.04), (1, "#ffffff", 0.12)], y0, y1), inner_stroke(mask, thin(1.4)))

    centres = {}
    for name, (cx_, cy_) in {"back": (-bx, rows[0]), "tv": (bx, rows[0]), "play": (-bx, rows[1]), "mute": (-bx, rows[2])}.items():
        m = circle_mask(k(X(cx_)), k(Y(cy_)), kk(brr))
        drop_shadow(layer, m, 0, 2.5 * s, 2.5 * s, 0.28)
        black_button(m, k(Y(cy_ - brr)), k(Y(cy_ + brr)))
        centres[name] = (cx_, cy_)
    pill = rrect_mask((k(X(bx - brr)), k(Y(pill_top)), k(X(bx + brr)), k(Y(pill_bot))), kk(brr))
    drop_shadow(layer, pill, 0, 2.5 * s, 2.5 * s, 0.28)
    black_button(pill, k(Y(pill_top)), k(Y(pill_bot)))
    if simple:
        return

    # глифы (рисуются с 8-кратным суперсэмплом в локальных патчах)
    def glyph(cx_, cy_, fn, half=30):
        px = max(2, int(math.ceil(2 * half * s * K)))
        SS = 8
        big = Image.new("L", (px * SS, px * SS), 0)
        d = ImageDraw.Draw(big)
        f = px * SS / (2 * half)                    # пикселей big на локальную единицу
        T = lambda x, y: ((x + half) * f, (y + half) * f)   # noqa: E731
        lw = max(1, int(round(3.6 * f)))
        fn(d, T, lw, f)
        patch = big.resize((px, px), Image.LANCZOS)
        full = Image.new("L", (W, W), 0)
        full.paste(patch, (k(X(cx_)) - px // 2, k(Y(cy_)) - px // 2))
        paste_masked(layer, solid("#e6e7ea"), full, 0.95)

    def seg_line(d, T, pts, lw):
        d.line([T(*p) for p in pts], fill=255, width=lw, joint="curve")
        for p in pts:
            x_, y_ = T(*p)
            d.ellipse([x_ - lw / 2, y_ - lw / 2, x_ + lw / 2, y_ + lw / 2], fill=255)

    def g_back(d, T, lw, f):
        seg_line(d, T, [(4, -13), (-5, 0), (4, 13)], lw)

    def g_tv(d, T, lw, f):
        d.rounded_rectangle([*T(-14, -11), *T(14, 8)], radius=3.5 * f, outline=255, width=max(1, int(round(3.0 * f))))
        seg_line(d, T, [(-6, 14), (6, 14)], max(1, int(round(3.0 * f))))

    def g_play(d, T, lw, f):
        d.polygon([T(-15, -11), T(-15, 11), T(-2, 0)], fill=255)
        d.rounded_rectangle([*T(4, -11), *T(7.5, 11)], radius=1.5 * f, fill=255)
        d.rounded_rectangle([*T(11, -11), *T(14.5, 11)], radius=1.5 * f, fill=255)

    def g_mute(d, T, lw, f):
        w2 = max(1, int(round(3.0 * f)))
        d.polygon([T(-14, -5), T(-8, -5), T(1, -13), T(1, 13), T(-8, 5), T(-14, 5)], outline=255, width=w2)
        d.arc([*T(2, -9), *T(14, 9)], -55, 55, fill=255, width=w2)
        seg_line(d, T, [(-15, 14), (13, -14)], w2)

    def g_plus(d, T, lw, f):
        seg_line(d, T, [(-9, 0), (9, 0)], lw)
        seg_line(d, T, [(0, -9), (0, 9)], lw)

    def g_minus(d, T, lw, f):
        seg_line(d, T, [(-9, 0), (9, 0)], lw)

    glyph(*centres["back"], g_back)
    glyph(*centres["tv"], g_tv)
    glyph(*centres["play"], g_play)
    glyph(*centres["mute"], g_mute)
    pill_c = (pill_top + pill_bot) / 2
    glyph(bx, pill_c - 38, g_plus)
    glyph(bx, pill_c + 38, g_minus)
    # значок питания
    pw = (66.5, -384.5)

    def g_power(d, T, lw, f):
        w2 = max(1, int(round(2.4 * f)))
        d.arc([*T(-7, -6.5), *T(7, 7.5)], -60, 240, fill=255, width=w2)
        seg_line(d, T, [(0, -9), (0, -1)], w2)
    # тёмный значок на светлой кнопке
    px = int(math.ceil(2 * 30 * s * K)); SS = 8
    big = Image.new("L", (px * SS, px * SS), 0)
    f = px * SS / 60
    T = lambda x, y: ((x + 30) * f, (y + 30) * f)   # noqa: E731
    g_power(ImageDraw.Draw(big), T, 0, f)
    full = Image.new("L", (W, W), 0)
    full.paste(big.resize((px, px), Image.LANCZOS), (k(X(pw[0])) - px // 2, k(Y(pw[1])) - px // 2))
    paste_masked(layer, solid("#2a2b2e"), full, 0.95)


def render_app_icon(simple: bool = False) -> Image.Image:
    """Иконка: MacBook анфас, на экране — пульт Apple TV. simple=True — упрощённая версия для 16/32 px."""
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    c = U / 2
    half = 824 / 2

    body = superellipse_mask(k(c), k(c), k(half), k(half), n=5.0)

    # 1. фон «стеклянного» сквиркла (как раньше)
    drop_shadow(img, body, 0, 22, 26, 0.50)
    drop_shadow(img, body, 0, 8, 7, 0.45)
    paste_masked(img, linear_gradient([(0.0, "#3b4160", 1), (0.45, "#1b1f33", 1), (1.0, "#07080f", 1)], 90), body)
    paste_masked(img, radial_gradient(k(c - 120), k(c - 190), k(520), [(0, "#5b6bff", 0.55), (0.55, "#3a2fd0", 0.18), (1, "#1a1a60", 0)]), body)
    paste_masked(img, radial_gradient(k(c + 230), k(c + 360), k(420), [(0, "#00c2ff", 0.35), (0.6, "#0a5cff", 0.10), (1, "#0a1a60", 0)]), body)
    paste_masked(img, linear_gradient([(0.0, "#ffffff", 0.10), (0.5, "#ffffff", 0.0), (1.0, "#ffffff", 0.0)], 35), body)

    # 2. геометрия MacBook (16:10, анфас)
    lx0, lx1, ly0, ly1 = c - 325, c + 325, 296, 702
    bz = 7 if simple else 5           # алюминиевая рамка
    bezel = 18 if simple else 15      # чёрная рамка экрана
    base_y0, base_y1 = ly1, ly1 + (34 if simple else 30)
    bx0, bx1 = c - 372, c + 372

    lid = rrect_mask((k(lx0), k(ly0), k(lx1), k(ly1)), k(30))
    base = rrect_mask((k(bx0), k(base_y0 - 14), k(bx1), k(base_y1)), k(16))
    base_vis = ImageChops.subtract(base, rrect_mask((k(bx0 - 5), k(base_y0 - 40), k(bx1 + 5), k(base_y0 - 0.5)), 0))
    union = ImageChops.lighter(lid, base)
    screen = rrect_mask((k(lx0 + bz + bezel), k(ly0 + bz + bezel), k(lx1 - bz - bezel), k(ly1 - bz - bezel - 2)), k(10))
    bezel_m = rrect_mask((k(lx0 + bz), k(ly0 + bz), k(lx1 - bz), k(ly1 - bz)), k(26))

    # 3. свечение экрана вокруг ноутбука
    glow = Image.new("L", (W, W), 0)
    glow.paste(screen, (0, 0))
    glow = glow.filter(ImageFilter.GaussianBlur(k(46)))
    layer = solid("#6f86ff")
    layer.putalpha(glow.point(lambda v: int(v * 0.55)))
    paste_masked(img, layer, body)

    drop_shadow(img, union, 0, 30, 26, 0.65)
    drop_shadow(img, union, 0, 8, 6, 0.45)

    # 4. основание (клавиатурная палуба анфас)
    base_g = linear_gradient([(0.0, "#e9ecf3", 1), (0.5, "#bfc5d3", 1), (1.0, "#80879a", 1)], 90)
    paste_masked(img, base_g, base_vis)
    if not simple:
        paste_masked(img, linear_gradient([(0, "#ffffff", 0.9), (0.25, "#ffffff", 0.0), (1, "#000000", 0.0)], 90), inner_stroke(base_vis, k(2)))
        paste_masked(img, linear_gradient([(0, "#000000", 0.0), (0.6, "#000000", 0.0), (1, "#000000", 0.35)], 90), inner_stroke(base_vis, k(2.5)))
    # выемка под палец
    groove = rrect_mask((k(c - 66), k(base_y0), k(c + 66), k(base_y0 + 13)), k(7))
    paste_masked(img, linear_gradient([(0, "#2a2e3b", 0.55), (1, "#2a2e3b", 0.05)], 90), ImageChops.multiply(groove, base_vis))

    # 5. крышка: алюминий → чёрная рамка → экран
    lid_g = linear_gradient([(0.0, "#f3f5fa", 1), (0.4, "#c6cbd8", 1), (1.0, "#8b92a5", 1)], 100)
    paste_masked(img, lid_g, lid)
    if not simple:
        paste_masked(img, linear_gradient([(0, "#ffffff", 1.0), (0.3, "#ffffff", 0.25), (1, "#ffffff", 0.05)], 90), inner_stroke(lid, k(2.5)))
    paste_masked(img, linear_gradient([(0, "#171a22", 1), (1, "#06070b", 1)], 90), bezel_m)

    # 6. экран: градиент, свечение, пульт
    sc_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sc_layer.alpha_composite(linear_gradient([(0.0, "#2a3f9e", 1), (0.55, "#14205c", 1), (1.0, "#080c24", 1)], 90))
    scx, scy = c, (ly0 + ly1) / 2 + (0 if simple else 4)
    sc_layer.alpha_composite(radial_gradient(k(scx), k(scy - 10), k(300), [(0, "#8aa0ff", 0.60), (0.5, "#4a63ff", 0.25), (1, "#2a3fd0", 0)]))
    s_rem = 0.43 if simple else 0.395
    rl = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw_remote(rl, scx, scy + (3 if not simple else 0), s_rem, simple)
    sc_layer.alpha_composite(rl)
    # стеклянный блик экрана
    sc_layer.alpha_composite(linear_gradient([(0.0, "#ffffff", 0.14), (0.45, "#ffffff", 0.0), (1.0, "#ffffff", 0.0)], 30))
    paste_masked(img, sc_layer, screen)

    # вырез (notch)
    if not simple:
        notch = rrect_mask((k(c - 48), k(ly0 - 20), k(c + 48), k(ly0 + bz + bezel + 10)), k(10))
        paste_masked(img, solid("#05060a"), ImageChops.multiply(notch, bezel_m))
    # шарнир
    hinge = Image.new("L", (W, W), 0)
    ImageDraw.Draw(hinge).rectangle([k(lx0 + 14), k(ly1 - 3), k(lx1 - 14), k(ly1 + 1)], fill=255)
    paste_masked(img, solid("#1b1e29", 0.55), ImageChops.multiply(hinge, union))

    # 7. стеклянные эффекты всей иконки
    gloss_mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(gloss_mask).ellipse([k(c - 700), k(c - 1010), k(c + 700), k(c - 205)], fill=255)
    gloss_mask = gloss_mask.filter(ImageFilter.GaussianBlur(k(16)))
    paste_masked(img, linear_gradient([(0.0, "#ffffff", 0.16), (0.5, "#ffffff", 0.06), (1.0, "#ffffff", 0.0)], 90),
                 ImageChops.multiply(gloss_mask, body))
    edge_g = linear_gradient([(0.0, "#ffffff", 0.75), (0.35, "#ffffff", 0.18), (0.75, "#9fb0ff", 0.10), (1.0, "#ffffff", 0.30)], 90)
    paste_masked(img, edge_g, inner_stroke(body, k(3.5)))
    outer = ImageChops.subtract(superellipse_mask(k(c), k(c), k(half + 1.2), k(half + 1.2), n=5.0), body)
    paste_masked(img, solid("#000000", 0.5), outer)

    return img.resize((U, U), Image.LANCZOS)


# ───────────────────────────── значок строки меню ───────────────────────────

def render_menubar(filled: bool, px: int) -> Image.Image:
    """Монохромный (чёрный + альфа) template-значок: пульт с клик-падом. Логический размер 18×18."""
    s = px * 8
    sc = s / 18.0
    img = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(img)
    bx0, bx1, by0, by1 = 4.9, 13.1, 0.9, 17.1
    rad = 3.4
    pcx, pcy, pr = 9.0, 5.7, 2.35
    if filled:
        d.rounded_rectangle([bx0 * sc, by0 * sc, bx1 * sc, by1 * sc], radius=rad * sc, fill=255)
        # вырезы: клик-пад, кнопки
        d.ellipse([(pcx - pr) * sc, (pcy - pr) * sc, (pcx + pr) * sc, (pcy + pr) * sc], fill=0)
        for (x, y) in [(7.6, 11.0), (10.4, 11.0), (7.6, 13.9), (10.4, 13.9)]:
            d.ellipse([(x - 0.8) * sc, (y - 0.8) * sc, (x + 0.8) * sc, (y + 0.8) * sc], fill=0)
        d.ellipse([(pcx - 0.7) * sc, (pcy - 0.7) * sc, (pcx + 0.7) * sc, (pcy + 0.7) * sc], fill=255)
    else:
        lw = 1.3 * sc
        d.rounded_rectangle([bx0 * sc, by0 * sc, bx1 * sc, by1 * sc], radius=rad * sc, outline=255, width=int(lw))
        d.ellipse([(pcx - pr) * sc, (pcy - pr) * sc, (pcx + pr) * sc, (pcy + pr) * sc], outline=255, width=int(1.1 * sc))
        for (x, y) in [(7.6, 11.0), (10.4, 11.0), (7.6, 13.9), (10.4, 13.9)]:
            d.ellipse([(x - 0.75) * sc, (y - 0.75) * sc, (x + 0.75) * sc, (y + 0.75) * sc], fill=255)
    img = img.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.putalpha(img)
    return out


# ───────────────────────────── экспорт в xcassets ───────────────────────────

ICON_SLOTS = [  # (pt, scale)
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]


def write_json(path: Path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def export(master: Image.Image, simple: Image.Image):
    ASSETS.mkdir(parents=True, exist_ok=True)
    write_json(ASSETS / "Contents.json", {"info": {"author": "xcode", "version": 1}})

    iconset = ASSETS / "AppIcon.appiconset"
    iconset.mkdir(exist_ok=True)
    images = []
    for pt, scale in ICON_SLOTS:
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        src = simple if px <= 32 else master
        src.resize((px, px), Image.LANCZOS).save(iconset / name, optimize=True)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    write_json(iconset / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})

    for name, filled in [("MenuBarRemote", False), ("MenuBarRemoteFilled", True)]:
        d = ASSETS / f"{name}.imageset"
        d.mkdir(exist_ok=True)
        render_menubar(filled, 18).save(d / f"{name}.png")
        render_menubar(filled, 36).save(d / f"{name}@2x.png")
        render_menubar(filled, 54).save(d / f"{name}@3x.png")
        write_json(d / "Contents.json", {
            "images": [
                {"filename": f"{name}.png", "idiom": "universal", "scale": "1x"},
                {"filename": f"{name}@2x.png", "idiom": "universal", "scale": "2x"},
                {"filename": f"{name}@3x.png", "idiom": "universal", "scale": "3x"},
            ],
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "template"},
        })


def make_preview(master: Image.Image, simple: Image.Image, path: Path):
    """Превью: большая иконка, ряд уменьшенных размеров и значки меню на светлом/тёмном фоне."""
    canvas = Image.new("RGBA", (1600, 1000), (28, 29, 36, 255))
    grad = linear_gradient([(0, "#2b2d3a", 1), (1, "#14151c", 1)], 90, size=1600).crop((0, 0, 1600, 1000))
    canvas.alpha_composite(grad)
    big = master.resize((760, 760), Image.LANCZOS)
    canvas.alpha_composite(big, (40, 120))
    x = 850
    for px in (256, 128, 64, 32, 16):
        sm = (simple if px <= 32 else master).resize((px, px), Image.LANCZOS)
        y = 120 + (256 - px) // 2 if px != 256 else 120
        canvas.alpha_composite(sm, (x, y))
        x += px + 36
    # строка меню (светлая и тёмная)
    for i, (bg, fg) in enumerate([((236, 236, 240, 255), (0, 0, 0)), ((40, 40, 46, 255), (255, 255, 255))]):
        bar = Image.new("RGBA", (700, 44), bg)
        canvas.alpha_composite(bar, (850, 470 + i * 70))
        px = 36
        for j, filled in enumerate([False, True]):
            glyph = render_menubar(filled, px)
            tint = Image.new("RGBA", (px, px), (*fg, 255))
            tint.putalpha(glyph.getchannel("A"))
            canvas.alpha_composite(tint, (1480 - j * 60, 470 + i * 70 + 4))
    d = ImageDraw.Draw(canvas)
    d.text((850, 440), "Menu bar template (outline / filled = connected)", fill=(190, 192, 205, 255))
    d.text((850, 92), "AppIcon sizes: 256 / 128 / 64 / 32 / 16", fill=(190, 192, 205, 255))
    canvas.convert("RGB").save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="сохранить превью PNG")
    ap.add_argument("--master", help="сохранить мастер 1024×1024 PNG")
    args = ap.parse_args()
    master = render_app_icon()
    simple = render_app_icon(simple=True)
    export(master, simple)
    if args.master:
        master.save(args.master)
    if args.preview:
        make_preview(master, simple, Path(args.preview))
    print("Иконка сгенерирована:", ASSETS)


if __name__ == "__main__":
    main()
