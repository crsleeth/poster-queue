#!/usr/bin/env python3
"""posterfit.py - turn a submitted poster PDF into a print-ready PDF for a roll printer.

Usage: posterfit.py SRC.pdf REQUEST.json OUT.pdf [--roll 36] [--printable 35.6] ...

Reads the Power Automate request JSON (size_mode, width_in, height_in), decides the
final printed size, and writes OUT.pdf: page 1 only, scaled, and rotated so the short
side runs across the roll (page width = across-roll dimension). Content is transformed,
not re-rendered, so vector art and fonts are untouched.

Prints a JSON "plan" to stdout for the bash wrapper. Exits non-zero on hard errors
(unreadable PDF, missing width/height for a specific-size request).
"""
import argparse
import json
import subprocess
import sys

from pypdf import PdfReader, PdfWriter, Transformation
from pypdf.generic import RectangleObject

PT = 72.0  # PDF points per inch


def die(msg):
    print(json.dumps({"error": msg}))
    sys.exit(1)


def size_mode(text):
    t = (text or "").strip().lower()
    if t.startswith("a specific"):
        return "custom"
    if t.startswith("as large"):
        return "fit"
    die(f"unrecognized size option: {text!r} (form wording changed? update size_mode())")


def num(v, name):
    try:
        x = float(v)
    except (TypeError, ValueError):
        die(f"{name} missing or not a number: {v!r}")
    if x <= 0:
        die(f"{name} must be positive: {v!r}")
    return x


def lowest_image_ppi(src, page_w, page_h, scale, min_fraction=0.05):
    """Lowest effective ppi (after scaling) among images covering >= 5% of the page.
    Small logos are ignored so they don't trigger false low-res warnings."""
    try:
        out = subprocess.run(["pdfimages", "-list", "-f", "1", "-l", "1", src],
                             capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    page_area = page_w * page_h
    lowest = None
    for line in out.splitlines()[2:]:          # skip the two header lines
        c = line.split()
        if len(c) < 14 or c[2] != "image":     # skip smask/stencil entries
            continue
        try:
            w_px, h_px, xppi, yppi = int(c[3]), int(c[4]), float(c[12]), float(c[13])
        except ValueError:
            continue
        if xppi <= 0 or yppi <= 0:
            continue
        area = (w_px / xppi) * (h_px / yppi)   # placed size in square inches
        if area / page_area < min_fraction:
            continue
        eff = min(xppi, yppi) / scale
        lowest = eff if lowest is None else min(lowest, eff)
    return lowest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("request")
    ap.add_argument("out")
    ap.add_argument("--roll", type=float, default=36.0, help="loaded roll width, inches")
    ap.add_argument("--printable", type=float, default=35.6, help="max across-roll print width")
    ap.add_argument("--aspect-tol", type=float, default=0.02, help="allowed shape mismatch (0.02 = 2%%)")
    ap.add_argument("--min-ppi", type=float, default=100)
    ap.add_argument("--min-short", type=float, default=18, help="flag prints whose short side is under this")
    a = ap.parse_args()

    with open(a.request) as f:
        req = json.load(f)
    flags = []   # things to check before approving (folder gets _CHECK)
    notes = []   # informational only

    try:
        reader = PdfReader(a.src)
        if reader.is_encrypted:
            reader.decrypt("")
        pages = len(reader.pages)
        # pypdf 7 only allows editing pages that belong to a writer: copy page 1 in first.
        w = PdfWriter()
        page = w.add_page(reader.pages[0])
    except Exception as e:  # noqa: BLE001 - any parse failure is a hard error
        die(f"cannot read PDF: {e}")

    if pages > 1:
        flags.append(f"MULTIPAGE: PDF has {pages} pages; only page 1 will print")

    # Bake any /Rotate into the content so width/height mean what the viewer shows.
    page.transfer_rotation_to_content()
    box = page.cropbox                        # visible area
    pw, ph = float(box.width) / PT, float(box.height) / PT

    mode = size_mode(req.get("size_mode"))

    if mode == "fit":
        s = a.printable / min(pw, ph)
    else:  # custom
        rw, rh = num(req.get("width_in"), "width_in"), num(req.get("height_in"), "height_in")
        # Requester may have swapped width/height relative to how the PDF is laid out.
        if abs(rw - rh) > 0.01 and abs(pw - ph) > 0.01 and (rw > rh) != (pw > ph):
            rw, rh = rh, rw
            notes.append(f"Width/height entered opposite to PDF orientation; using {rw:g}x{rh:g}")
        mismatch = abs((pw / ph) / (rw / rh) - 1)
        if mismatch > a.aspect_tol:
            flags.append(f"ASPECT MISMATCH: PDF {pw:.2f}x{ph:.2f}in vs requested {rw:g}x{rh:g}in "
                         f"({mismatch:.0%} off); scaled to fit within requested size, not stretched")
        s = min(rw / pw, rh / ph)

    short = min(pw, ph) * s
    if short > a.roll + 0.01:
        flags.append(f"TOO LARGE: shortest side {short:.1f}in exceeds {a.roll:g}in roll; "
                     f"shrunk to {a.printable:g}in - confirm with requester")
        s *= a.printable / short
    elif short > a.printable + 0.001:
        notes.append(f"Shrunk {1 - a.printable / short:.1%} to clear printer margins")
        s *= a.printable / short

    fw, fh = pw * s, ph * s                   # final size as the poster hangs
    if min(fw, fh) < a.min_short:
        flags.append(f"SMALL: prints at only {fw:.1f}x{fh:.1f}in (short side under {a.min_short:g}in) - "
                     f"confirm this is intended")
    rotate = fw > fh                          # landscape -> turn so short side is across roll
    across, along = min(fw, fh), max(fw, fh)

    ppi = lowest_image_ppi(a.src, pw, ph, s)
    if ppi is not None and ppi < a.min_ppi:
        flags.append(f"LOW RESOLUTION: a large image prints at ~{ppi:.0f} ppi (< {a.min_ppi:g})")

    # Build transform: move visible box to origin, scale, optionally rotate 90 CCW.
    t = Transformation().translate(-float(box.left), -float(box.bottom)).scale(s, s)
    if rotate:
        t = t.rotate(90).translate(fh * PT, 0)
    page.add_transformation(t)
    new_box = RectangleObject([0, 0, across * PT, along * PT])
    page.mediabox = new_box
    page.cropbox = new_box
    for name in ("/TrimBox", "/BleedBox", "/ArtBox"):
        if name in page:
            del page[name]

    with open(a.out, "wb") as f:
        w.write(f)

    print(json.dumps({
        "mode": mode,
        "orig_w": round(pw, 2), "orig_h": round(ph, 2),
        "final_w": round(fw, 2), "final_h": round(fh, 2),
        "across": round(across, 2), "along": round(along, 2),
        "scale_pct": round(s * 100, 1),
        "rotated": rotate,
        "min_ppi": None if ppi is None else round(ppi),
        "flags": flags,
        "notes": notes,
    }))


if __name__ == "__main__":
    main()
