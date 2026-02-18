#!/usr/bin/env python3
"""CLI tool for screenshot capture and pixel-diff verification.

Subcommands
-----------
capture       — Capture a screenshot (full screen or specific window by PID).
compare       — Capture a screenshot and compare against a saved baseline.
baseline      — Capture a screenshot and save it as the baseline for future comparisons.
compare-files — Compare two arbitrary image files on disk.
"""

import argparse
import json
import os
import subprocess
import sys
import time

from PIL import Image
import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCREENSHOTS_DIR = os.path.join(SCRIPT_DIR, "screenshots")
BASELINES_DIR = os.path.join(SCRIPT_DIR, "baselines")

DEFAULT_TOLERANCE = 0.02  # 2% pixel difference allowed


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _ensure_dir(path):
    """Create *path* if it does not exist."""
    os.makedirs(path, exist_ok=True)


def _log(msg):
    """Print a diagnostic message to stderr."""
    print(msg, file=sys.stderr)


def _timestamp():
    return time.strftime("%Y%m%d_%H%M%S")


# ---------------------------------------------------------------------------
# Screenshot capture — full screen / region
# ---------------------------------------------------------------------------

def capture_screenshot(name, window_name=None, region=None):
    """Capture a screenshot using macOS screencapture.

    Parameters
    ----------
    name : str
        Logical name used in the filename.
    window_name : str | None
        Unused placeholder (kept for API symmetry with PID capture).
    region : tuple | None
        (x, y, w, h) to restrict capture region.

    Returns
    -------
    str
        Absolute path to the saved PNG file.
    """
    _ensure_dir(SCREENSHOTS_DIR)
    filename = f"{name}_{_timestamp()}.png"
    filepath = os.path.join(SCREENSHOTS_DIR, filename)

    cmd = ["screencapture", "-x"]
    if region is not None:
        x, y, w, h = region
        cmd += ["-R", f"{x},{y},{w},{h}"]
    cmd.append(filepath)

    _log(f"Running: {' '.join(cmd)}")
    subprocess.check_call(cmd)
    _log(f"Saved screenshot: {filepath}")
    return filepath


# ---------------------------------------------------------------------------
# Screenshot capture — by PID (Quartz window capture)
# ---------------------------------------------------------------------------

def capture_window_by_pid(name, pid):
    """Capture the window of a specific process by PID using Quartz.

    Parameters
    ----------
    name : str
        Logical name used in the filename.
    pid : int
        Process ID whose window should be captured.

    Returns
    -------
    str
        Absolute path to the saved PNG file.
    """
    import Quartz
    from AppKit import NSBitmapImageRep, NSPNGFileType

    _ensure_dir(SCREENSHOTS_DIR)

    # Find the window belonging to the given PID.
    window_list = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionAll | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )
    target_window_id = None
    for win in window_list:
        if win.get("kCGWindowOwnerPID") == pid:
            # Prefer on-screen, non-zero-sized windows.
            bounds = win.get("kCGWindowBounds", {})
            w = bounds.get("Width", 0)
            h = bounds.get("Height", 0)
            if w > 0 and h > 0:
                target_window_id = win.get("kCGWindowNumber")
                break

    if target_window_id is None:
        raise RuntimeError(f"No visible window found for PID {pid}")

    _log(f"Capturing window ID {target_window_id} for PID {pid}")

    image = Quartz.CGWindowListCreateImage(
        Quartz.CGRectNull,
        Quartz.kCGWindowListOptionIncludingWindow,
        target_window_id,
        Quartz.kCGWindowImageDefault,
    )
    if image is None:
        raise RuntimeError(f"CGWindowListCreateImage returned None for window {target_window_id}")

    rep = NSBitmapImageRep.alloc().initWithCGImage_(image)
    png_data = rep.representationUsingType_properties_(NSPNGFileType, {})
    if png_data is None:
        raise RuntimeError("Failed to convert captured image to PNG data")

    filename = f"{name}_{_timestamp()}.png"
    filepath = os.path.join(SCREENSHOTS_DIR, filename)
    png_data.writeToFile_atomically_(filepath, True)
    _log(f"Saved window screenshot: {filepath}")
    return filepath


# ---------------------------------------------------------------------------
# Image comparison
# ---------------------------------------------------------------------------

def compare_images(path_a, path_b, tolerance=DEFAULT_TOLERANCE):
    """Compare two images and return a diff report.

    Parameters
    ----------
    path_a : str
        Path to the reference (baseline) image.
    path_b : str
        Path to the candidate image.
    tolerance : float
        Maximum allowed fraction of changed pixels (0.0 – 1.0).

    Returns
    -------
    dict
        Keys: passed, diff_percent, diff_pixels, total_pixels,
              tolerance_percent, diff_image, image_a, image_b.
    """
    img_a = Image.open(path_a).convert("RGB")
    img_b = Image.open(path_b).convert("RGB")

    # Resize img_b to match img_a if dimensions differ.
    if img_a.size != img_b.size:
        _log(f"Resizing image_b from {img_b.size} to {img_a.size}")
        img_b = img_b.resize(img_a.size, Image.LANCZOS)

    arr_a = np.array(img_a, dtype=np.int16)
    arr_b = np.array(img_b, dtype=np.int16)

    diff = np.abs(arr_a - arr_b)

    # Sum across RGB channels — gives per-pixel total deviation (0..765).
    pixel_diff = diff.sum(axis=2)

    # A pixel counts as "changed" if summed channel diff > 30 (~12% per-channel).
    changed_mask = pixel_diff > 30
    diff_pixels = int(changed_mask.sum())
    total_pixels = int(arr_a.shape[0] * arr_a.shape[1])
    diff_percent = diff_pixels / total_pixels if total_pixels > 0 else 0.0

    passed = diff_percent <= tolerance

    # Generate diff image: copy of img_b with changed pixels overlaid in red.
    diff_img = img_b.copy()
    diff_arr = np.array(diff_img)
    diff_arr[changed_mask] = [255, 0, 0]
    diff_img = Image.fromarray(diff_arr)

    _ensure_dir(SCREENSHOTS_DIR)
    diff_filename = f"diff_{_timestamp()}.png"
    diff_filepath = os.path.join(SCREENSHOTS_DIR, diff_filename)
    diff_img.save(diff_filepath)
    _log(f"Diff image saved: {diff_filepath}")

    return {
        "passed": passed,
        "diff_percent": round(diff_percent, 6),
        "diff_pixels": diff_pixels,
        "total_pixels": total_pixels,
        "tolerance_percent": tolerance,
        "diff_image": diff_filepath,
        "image_a": path_a,
        "image_b": path_b,
    }


# ---------------------------------------------------------------------------
# Subcommand: capture
# ---------------------------------------------------------------------------

def cmd_capture(args):
    """Capture a screenshot and print its path as JSON."""
    if args.pid is not None:
        filepath = capture_window_by_pid(args.name, args.pid)
    else:
        filepath = capture_screenshot(args.name)
    print(json.dumps({"screenshot": filepath}, indent=2))


# ---------------------------------------------------------------------------
# Subcommand: baseline
# ---------------------------------------------------------------------------

def cmd_baseline(args):
    """Capture a screenshot and save it as the baseline for *name*."""
    if args.pid is not None:
        filepath = capture_window_by_pid(args.name, args.pid)
    else:
        filepath = capture_screenshot(args.name)

    _ensure_dir(BASELINES_DIR)
    baseline_path = os.path.join(BASELINES_DIR, f"{args.name}.png")

    # Copy captured image to baseline location.
    img = Image.open(filepath)
    img.save(baseline_path)
    _log(f"Baseline saved: {baseline_path}")

    print(json.dumps({
        "baseline": baseline_path,
        "screenshot": filepath,
    }, indent=2))


# ---------------------------------------------------------------------------
# Subcommand: compare
# ---------------------------------------------------------------------------

def cmd_compare(args):
    """Capture a screenshot and compare against the saved baseline."""
    baseline_path = os.path.join(BASELINES_DIR, f"{args.name}.png")
    if not os.path.isfile(baseline_path):
        _log(f"Error: no baseline found at {baseline_path}")
        _log("Run 'baseline' subcommand first to create one.")
        print(json.dumps({"error": f"baseline not found: {baseline_path}"}))
        sys.exit(1)

    if args.pid is not None:
        filepath = capture_window_by_pid(args.name, args.pid)
    else:
        filepath = capture_screenshot(args.name)

    tolerance = args.tolerance
    result = compare_images(baseline_path, filepath, tolerance=tolerance)
    print(json.dumps(result, indent=2))

    sys.exit(0 if result["passed"] else 1)


# ---------------------------------------------------------------------------
# Subcommand: compare-files
# ---------------------------------------------------------------------------

def cmd_compare_files(args):
    """Compare two arbitrary image files."""
    if not os.path.isfile(args.file_a):
        _log(f"Error: file not found: {args.file_a}")
        print(json.dumps({"error": f"file not found: {args.file_a}"}))
        sys.exit(1)
    if not os.path.isfile(args.file_b):
        _log(f"Error: file not found: {args.file_b}")
        print(json.dumps({"error": f"file not found: {args.file_b}"}))
        sys.exit(1)

    tolerance = args.tolerance
    result = compare_images(args.file_a, args.file_b, tolerance=tolerance)
    print(json.dumps(result, indent=2))

    sys.exit(0 if result["passed"] else 1)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        description="Screenshot capture and pixel-diff verification CLI.",
    )
    sub = parser.add_subparsers(dest="command")

    # capture
    cap_p = sub.add_parser("capture", help="Capture a screenshot")
    cap_p.add_argument("--name", required=True, help="Logical name for the screenshot")
    cap_p.add_argument("--pid", type=int, default=None, help="Capture window of a specific PID")

    # baseline
    base_p = sub.add_parser("baseline", help="Capture and save as baseline")
    base_p.add_argument("--name", required=True, help="Logical name for the baseline")
    base_p.add_argument("--pid", type=int, default=None, help="Capture window of a specific PID")

    # compare
    cmp_p = sub.add_parser("compare", help="Capture and compare against baseline")
    cmp_p.add_argument("--name", required=True, help="Logical name (must match an existing baseline)")
    cmp_p.add_argument("--pid", type=int, default=None, help="Capture window of a specific PID")
    cmp_p.add_argument(
        "--tolerance", type=float, default=DEFAULT_TOLERANCE,
        help=f"Max allowed diff fraction (default: {DEFAULT_TOLERANCE})",
    )

    # compare-files
    cmpf_p = sub.add_parser("compare-files", help="Compare two arbitrary image files")
    cmpf_p.add_argument("file_a", help="Path to first (reference) image")
    cmpf_p.add_argument("file_b", help="Path to second (candidate) image")
    cmpf_p.add_argument(
        "--tolerance", type=float, default=DEFAULT_TOLERANCE,
        help=f"Max allowed diff fraction (default: {DEFAULT_TOLERANCE})",
    )

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(0)

    if args.command == "capture":
        cmd_capture(args)
    elif args.command == "baseline":
        cmd_baseline(args)
    elif args.command == "compare":
        cmd_compare(args)
    elif args.command == "compare-files":
        cmd_compare_files(args)


if __name__ == "__main__":
    main()
