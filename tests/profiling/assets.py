import hashlib
import json
import math
import random
from pathlib import Path

from PIL import Image
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

VERSION = 1


def _integer(value, maximum=1_000_000):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise ValueError("asset count must be a bounded nonnegative integer")
    return value


def _dimension(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 < value <= 16384:
        raise ValueError("asset dimension must be finite and between 0 and 16384")
    return value


def generate_pdf(destination, recipe, font_files):
    """Write a one-page PDF with the requested geometry and drawing counts."""
    width = _dimension(recipe["width_pt"])
    height = _dimension(recipe["height_pt"])
    rng = random.Random(_integer(recipe["seed"], 2**32 - 1))
    fonts = _integer(recipe.get("fonts", 1), 32)
    if not font_files or fonts == 0:
        raise ValueError("at least one embeddable TrueType font is required")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    document = canvas.Canvas(str(destination), pagesize=(width, height), invariant=1, pageCompression=1)
    document.setCreator("ss synthetic profiling assets v1")
    document.setTitle("Synthetic figure")
    # Separate font resources preserve resource-management work even when their
    # glyph outlines come from the same small, public font family.
    font_names = []
    for index in range(fonts):
        filename = str(font_files[index % len(font_files)])
        name = "Synthetic" + hashlib.sha256(Path(filename).read_bytes() + str(index).encode()).hexdigest()[:16]
        if name not in pdfmetrics.getRegisteredFontNames():
            font = TTFont(name, filename)
            # ReportLab otherwise aliases registrations with the same face and
            # collapses the requested independent PDF font resources.
            font.face.name = name.encode("ascii")
            pdfmetrics.registerFont(font)
        font_names.append(name)
    for index in range(_integer(recipe.get("rectangles", 0))):
        document.setStrokeColorRGB(.18, .28, .38)
        document.setFillColorRGB(.92, .95, .98)
        document.rect(rng.random() * width * .8, rng.random() * height * .8,
                      width * (.03 + rng.random() * .15), height * (.03 + rng.random() * .15), stroke=1, fill=index % 3 == 0)
    paths = max(1, _integer(recipe.get("paths", 1)))
    lines = _integer(recipe.get("line_segments", 0))
    curves = _integer(recipe.get("curve_segments", 0))
    states = _integer(recipe.get("graphics_states", 0))
    for index in range(paths):
        document.saveState()
        if index < states:
            document.setStrokeAlpha(.35 + .6 * rng.random())
        document.setStrokeColorRGB(.15 + .5 * rng.random(), .25, .45)
        document.setLineWidth(.4 + rng.random())
        shape = document.beginPath()
        shape.moveTo(rng.random() * width, rng.random() * height)
        for _ in range(lines // paths + (index < lines % paths)):
            shape.lineTo(rng.random() * width, rng.random() * height)
        for _ in range(curves // paths + (index < curves % paths)):
            shape.curveTo(*(rng.random() * (width if j % 2 == 0 else height) for j in range(6)))
        document.drawPath(shape)
        document.restoreState()
    runs = _integer(recipe.get("text_runs", 0))
    characters = _integer(recipe.get("characters", runs * 12))
    alphabet = "abcdefghijklmnpqrstuvwxyz0123456789"
    for index in range(runs):
        document.setFont(font_names[index % fonts], min(11, max(4, height / 20)))
        count = characters // runs + (index < characters % runs)
        text = "".join(rng.choice(alphabet) for _ in range(count))
        document.drawString(rng.random() * width * .8, rng.random() * height * .95, text)
    document.showPage()
    document.save()


def generate_image(destination, recipe):
    """Generate a patterned raster with bounded, reproducible local noise."""
    width, height = (_integer(recipe[key], 16384) for key in ("width", "height"))
    if not width or not height or width * height > 32_000_000:
        raise ValueError("raster dimensions exceed the generation budget")
    rng = random.Random(_integer(recipe["seed"], 2**32 - 1))
    alpha = bool(recipe.get("alpha", False))
    pixels = bytearray(width * height * (4 if alpha else 3))
    noise = recipe.get("noise", .08)
    if not isinstance(noise, (int, float)) or not 0 <= noise <= 1:
        raise ValueError("noise must be between zero and one")
    amplitude = round(noise * 255)
    offset = 0
    for y in range(height):
        for x in range(width):
            variation = rng.randrange(-amplitude, amplitude + 1)
            for value in (80 + 140 * x // width, 70 + 150 * y // height, 130 + 50 * ((x // 48 + y // 48) % 2)):
                pixels[offset] = min(255, max(0, value + variation))
                offset += 1
            if alpha:
                pixels[offset] = 210 if (x // 80 + y // 80) % 3 == 0 else 255
                offset += 1
    image = Image.frombytes("RGBA" if alpha else "RGB", (width, height), bytes(pixels))
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if recipe["format"] == "jpeg":
        image.convert("RGB").save(destination, "JPEG", quality=90, optimize=False)
    elif recipe["format"] == "png":
        image.save(destination, "PNG", compress_level=6)
    else:
        raise ValueError("unsupported synthetic raster format")


def generate_assets(destination, specification, font_files):
    """Generate assets into an owned directory and return their fingerprints."""
    if specification.get("schema") != 1 or specification.get("generator_version") != VERSION:
        raise ValueError("unsupported synthetic asset specification")
    destination = Path(destination).resolve()
    seen = set()
    result = {}
    for kind in ("pdfs", "images"):
        for recipe in specification.get(kind, []):
            relative = Path(recipe["path"])
            target = (destination / relative).resolve()
            if relative.is_absolute() or not target.is_relative_to(destination) or relative in seen:
                raise ValueError("asset paths must be unique and inside the owned output directory")
            seen.add(relative)
            if target.exists():
                raise FileExistsError(target)
            if kind == "pdfs":
                generate_pdf(target, recipe, font_files)
            else:
                generate_image(target, recipe)
            data = target.read_bytes()
            result[relative.as_posix()] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    import reportlab
    import PIL
    return {"generator_version": VERSION, "reportlab": reportlab.Version,
            "pillow": PIL.__version__, "assets": result}


if __name__ == "__main__":
    import sys
    request = json.load(sys.stdin)
    json.dump(generate_assets(request["destination"], request["specification"], request["font_files"]), sys.stdout)
