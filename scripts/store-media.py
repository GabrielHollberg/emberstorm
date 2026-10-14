"""Made-up music for store and website pictures: eight albums by invented
artists, each cover drawn here, each song a short synthesized beat (so the
visualizers have something to move to). Never anybody's real music.

    python scripts/store-media.py LIBRARY_DIR

writes LIBRARY_DIR/music/<Artist>/<Album>/{cover.jpg, NN Title.mp3}. Songs are
made by ffmpeg in Docker (the test server's photo image has it).
"""
import math
import os
import random
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ALBUMS = [
    ("Neon Coast", "Afterglow", ["Afterglow", "Shoreline", "Electric Blue"], 118, ((255, 94, 120), (88, 40, 190)), "sun"),
    ("Velvet Hours", "Midnight Bloom", ["Midnight Bloom", "Satellite Heart", "Gold Dust"], 104, ((20, 16, 60), (232, 70, 140)), "rings"),
    ("Kaleido", "Prism", ["Prism", "Glass Garden", "Overtone"], 124, ((0, 200, 210), (120, 30, 200)), "prism"),
    ("Lumen", "Paper Planes", ["Paper Planes", "Weightless", "Northern Lights"], 96, ((250, 200, 90), (230, 80, 60)), "waves"),
    ("The Tidewater", "Open Water", ["Open Water", "Undertow", "Harbour Lights"], 112, ((10, 60, 110), (60, 210, 200)), "waves2"),
    ("Mira Vale", "Starlight Motel", ["Starlight Motel", "Highway Hearts", "Neon Rain"], 108, ((40, 20, 70), (255, 120, 60)), "grid"),
    ("Echo Park Kids", "Summer Static", ["Summer Static", "Polaroid", "Cruise Control"], 126, ((255, 170, 200), (110, 200, 255)), "blob"),
    ("Nightshift", "City of Glass", ["City of Glass", "Afterhours", "Skyline Drive"], 122, ((5, 10, 30), (0, 160, 255)), "city"),
]

FONT_BOLD = r"C:/Windows/Fonts/segoeuib.ttf"
FONT_BLACK = r"C:/Windows/Fonts/seguibl.ttf"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def cover(path, artist, album, colors, art):
    W = 1000
    im = Image.new("RGB", (W, W))
    d = ImageDraw.Draw(im)
    a, b = colors
    for y in range(W):
        d.line([(0, y), (W, y)], fill=lerp(a, b, y / W))
    rnd = random.Random(album)
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    g = ImageDraw.Draw(layer)
    if art == "sun":
        for i, r in enumerate(range(330, 0, -1)):
            g.ellipse((W / 2 - r, 560 - r, W / 2 + r, 560 + r), fill=(*lerp((255, 220, 120), (255, 80, 140), r / 330), 255))
        for k in range(8):
            y = 600 + k * 34
            g.rectangle((0, y, W, y + 10 + k * 2), fill=(*b, 255))
    elif art == "rings":
        for r in range(420, 40, -36):
            g.ellipse((W / 2 - r, W / 2 - r, W / 2 + r, W / 2 + r), outline=(255, 160, 210, 200), width=6)
    elif art == "prism":
        g.polygon([(500, 170), (820, 760), (180, 760)], outline=(255, 255, 255, 255), width=10)
        for i, c in enumerate([(255, 80, 80), (255, 200, 60), (90, 230, 120), (60, 160, 255), (180, 90, 255)]):
            g.polygon([(560, 470 + i * 8), (W, 520 + i * 60), (W, 560 + i * 60)], fill=(*c, 220))
        g.line([(0, 420), (470, 470)], fill=(255, 255, 255, 255), width=12)
    elif art in ("waves", "waves2"):
        for k in range(9):
            pts = [(x, 520 + k * 48 + 40 * math.sin(x / 90 + k)) for x in range(0, W + 10, 10)]
            g.line(pts, fill=(255, 255, 255, 120 + k * 12), width=8)
    elif art == "grid":
        g.ellipse((300, 180, 700, 580), fill=(255, 120, 80, 255))
        for k in range(14):
            y = 600 + k * k * 4
            g.line([(0, y), (W, y)], fill=(255, 60, 200, 230), width=3)
        for x in range(-1000, 2000, 110):
            g.line([(W / 2, 580), (x, W)], fill=(255, 60, 200, 230), width=3)
    elif art == "blob":
        for _ in range(7):
            x, y, r = rnd.randint(100, 900), rnd.randint(100, 900), rnd.randint(120, 280)
            g.ellipse((x - r, y - r, x + r, y + r), fill=(*rnd.choice([(255, 255, 255), (255, 120, 170), (120, 220, 255)]), 140))
        layer = layer.filter(ImageFilter.GaussianBlur(40))
    elif art == "city":
        x = 0
        while x < W:
            w, h = rnd.randint(50, 130), rnd.randint(200, 620)
            g.rectangle((x, W - h, x + w, W), fill=(10, 20, 45, 255))
            for wy in range(W - h + 20, W - 20, 36):
                for wx in range(x + 12, x + w - 12, 26):
                    if rnd.random() < 0.55:
                        g.rectangle((wx, wy, wx + 12, wy + 16), fill=(120, 220, 255, 230))
            x += w + 6
    im = Image.alpha_composite(im.convert("RGBA"), layer).convert("RGB")
    d = ImageDraw.Draw(im)
    f1, f2 = ImageFont.truetype(FONT_BLACK, 92), ImageFont.truetype(FONT_BOLD, 46)
    d.text((70, 70), album.upper(), font=f1, fill=(255, 255, 255))
    d.text((74, 180), artist, font=f2, fill=(255, 255, 255))
    im.save(path, quality=92)


def song(path, title, artist, album, n, bpm, seconds=75):
    # A four-on-the-floor kick, a snare on 2 and 4, hats, and a chord pad:
    # enough for the beat tracker and the looks.
    beat = 60.0 / bpm
    f0 = random.Random(title).choice([110, 123.47, 130.81, 146.83])
    expr = (
        f"0.85*sin(2*PI*55*t)*exp(-18*mod(t,{beat}))"
        f"+0.35*(random(0)-0.5)*exp(-30*mod(t+{beat},{2*beat}))"
        f"+0.08*(random(1)-0.5)*exp(-60*mod(t,{beat/2}))"
        f"+0.10*sin(2*PI*{f0}*t)+0.08*sin(2*PI*{f0*1.25}*t)+0.07*sin(2*PI*{f0*1.5}*t)"
    )
    expr = expr.replace(",", r"\,")  # a filter's own commas separate its options
    host = os.path.dirname(os.path.abspath(path))
    name = os.path.basename(path)
    image = subprocess.run(["docker", "inspect", "ss-smoke-immich", "--format", "{{.Config.Image}}"],
                           capture_output=True, text=True).stdout.strip()
    subprocess.run([
        "docker", "run", "--rm", "--entrypoint", "ffmpeg", "-v", f"{host}:/o", image,
        "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"aevalsrc={expr}:s=44100:d={seconds}",
        "-ac", "2", "-c:a", "libmp3lame", "-b:a", "192k",
        "-metadata", f"title={title}", "-metadata", f"artist={artist}", "-metadata", f"album_artist={artist}",
        "-metadata", f"album={album}", "-metadata", f"track={n}", "-metadata", "genre=Pop", f"/o/{name}",
    ], check=True, env={**os.environ, "MSYS_NO_PATHCONV": "1"})


def main():
    lib = sys.argv[1]
    for artist, album, titles, bpm, colors, art in ALBUMS:
        d = os.path.join(lib, "music", artist, album)
        os.makedirs(d, exist_ok=True)
        cover(os.path.join(d, "cover.jpg"), artist, album, colors, art)
        for n, t in enumerate(titles, 1):
            p = os.path.join(d, f"{n:02d} {t}.mp3")
            if not os.path.exists(p):
                song(p, t, artist, album, n, bpm)
        print("made", artist, "-", album)


if __name__ == "__main__":
    main()
