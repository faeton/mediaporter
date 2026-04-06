"""AFC file transfer to iOS device iTunes_Control directory."""

from __future__ import annotations

import hashlib
import random
import string
from pathlib import Path
from typing import Callable

from mediaporter.device import afc_list_dir, afc_mkdir, afc_push_file
from mediaporter.exceptions import TransferError


# iTunes uses F00-F49 directory distribution
MUSIC_DIR = "iTunes_Control/Music"
NUM_SUBDIRS = 50


def _generate_filename(original_name: str) -> str:
    """Generate a 4-character hash filename like iTunes does.

    iTunes uses short hash filenames (e.g., AHZD.m4v). We replicate this
    by generating a random 4-char uppercase string + original extension.
    """
    ext = Path(original_name).suffix  # .m4v
    chars = string.ascii_uppercase + string.digits
    name = "".join(random.choices(chars, k=4))
    return f"{name}{ext}"


def _pick_subdir(filename: str) -> str:
    """Pick an F-subdirectory for the file (F00-F49 distribution)."""
    # Use hash of filename for deterministic distribution
    h = hashlib.md5(filename.encode()).hexdigest()
    idx = int(h[:8], 16) % NUM_SUBDIRS
    return f"F{idx:02d}"


def ensure_music_dirs(lockdown) -> None:
    """Ensure the iTunes_Control/Music/Fxx directories exist on device."""
    try:
        existing = afc_list_dir(lockdown, MUSIC_DIR)
    except Exception:
        # Directory might not exist; try creating it
        try:
            afc_mkdir(lockdown, MUSIC_DIR)
            existing = []
        except Exception as e:
            raise TransferError(f"Cannot access {MUSIC_DIR} on device: {e}")

    for i in range(NUM_SUBDIRS):
        subdir = f"F{i:02d}"
        if subdir not in existing:
            try:
                afc_mkdir(lockdown, f"{MUSIC_DIR}/{subdir}")
            except Exception:
                pass  # May already exist


def push_to_device(
    lockdown,
    local_path: Path,
    progress_callback: Callable[[int, int], None] | None = None,
) -> tuple[str, str]:
    """Push an M4V file to the device's iTunes_Control/Music/Fxx/ directory.

    Returns (remote_filename, fxx_dir_path) e.g. ("AHZD.m4v", "iTunes_Control/Music/F05")
    """
    # Generate filename and pick subdirectory
    remote_name = _generate_filename(local_path.name)
    subdir = _pick_subdir(remote_name)
    fxx_dir = f"{MUSIC_DIR}/{subdir}"
    remote_path = f"{fxx_dir}/{remote_name}"

    # Ensure directory structure exists
    ensure_music_dirs(lockdown)

    # Push the file
    try:
        afc_push_file(lockdown, local_path, remote_path, progress_callback)
    except Exception as e:
        raise TransferError(f"Failed to push {local_path.name} to device: {e}")

    return remote_name, fxx_dir
