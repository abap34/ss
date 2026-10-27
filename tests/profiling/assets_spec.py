import copy
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from assets import generate_assets, generate_pdf
from PIL import Image


class SyntheticAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ss-assets-spec-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        if not shutil.which("fc-match"):
            self.skipTest("fontconfig is unavailable")
        self.fonts = [subprocess.check_output(["fc-match", "-f", "%{file}", name], timeout=10).decode() for name in ("DejaVu Sans", "DejaVu Sans Mono")]
        self.specification = {"schema": 1, "generator_version": 1, "pdfs": [{
            "path": "figures/example.pdf", "seed": 17, "width_pt": 321.25, "height_pt": 87.5,
            "rectangles": 3, "paths": 4, "line_segments": 7, "curve_segments": 5,
            "text_runs": 6, "characters": 48, "fonts": 3,
        }], "images": [{"path": "images/example.png", "seed": 23, "width": 64, "height": 32, "format": "png", "alpha": True}]}

    def test_generation_is_identical_across_directories_and_preserves_dimensions(self):
        first = generate_assets(self.root / "first", self.specification, self.fonts)
        second = generate_assets(self.root / "second", self.specification, self.fonts)
        self.assertEqual(first, second)
        with Image.open(self.root / "first/images/example.png") as image:
            self.assertEqual(image.size, (64, 32))
            self.assertEqual(image.mode, "RGBA")
        pdf = (self.root / "first/figures/example.pdf").read_bytes()
        self.assertRegex(pdf, rb"/MediaBox\s*\[\s*0 0 321\.25 87\.5\s*\]")
        # Embedded TrueType streams and a compressed page content stream.
        self.assertGreaterEqual(pdf.count(b"/FontFile2"), 3)
        changed = copy.deepcopy(self.specification)
        changed["pdfs"][0]["seed"] += 1
        third = generate_assets(self.root / "third", changed, self.fonts)
        self.assertNotEqual(first["assets"]["figures/example.pdf"]["sha256"], third["assets"]["figures/example.pdf"]["sha256"])

    def test_owned_paths_and_existing_files_are_protected(self):
        for unsafe in ("../escape.pdf", "/tmp/ss-escape.pdf"):
            broken = copy.deepcopy(self.specification)
            broken["pdfs"][0]["path"] = unsafe
            with self.assertRaises(ValueError):
                generate_assets(self.root / "unsafe", broken, self.fonts)
        generate_assets(self.root / "owned", self.specification, self.fonts)
        with self.assertRaises(FileExistsError):
            generate_assets(self.root / "owned", self.specification, self.fonts)

    def test_invalid_dimensions_and_counts_are_rejected(self):
        for key, value in (("width_pt", float("nan")), ("height_pt", -1), ("paths", -1), ("fonts", 0)):
            recipe = dict(self.specification["pdfs"][0], **{key: value})
            with self.assertRaises(ValueError):
                generate_pdf(self.root / "invalid.pdf", recipe, self.fonts)


if __name__ == "__main__":
    unittest.main()
