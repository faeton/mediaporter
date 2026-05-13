"""Interactive terminal selector with arrow keys."""

from __future__ import annotations

import sys
import tty
import termios


def _read_key() -> str:
    """Read a single keypress."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        ch = sys.stdin.read(1)
        if ch == "\x1b":
            ch2 = sys.stdin.read(1)
            if ch2 == "[":
                ch3 = sys.stdin.read(1)
                if ch3 == "A":
                    return "up"
                if ch3 == "B":
                    return "down"
            return "esc"
        if ch in ("\r", "\n"):
            return "enter"
        if ch == "\x03":
            return "ctrl-c"
        return ch
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def radio_select(title: str, items: list[str], default: int = 0) -> int | None:
    """Arrow-key single-choice selector. Returns index or None if cancelled."""
    n = len(items)
    if n <= 1:
        return 0 if n == 1 else None

    # Fallback for non-TTY (piped input, testing)
    if not sys.stdin.isatty():
        try:
            raw = input().strip()
            return int(raw) - 1 if raw else default
        except (ValueError, EOFError):
            return default

    cursor = default
    total_lines = n + 1  # title + items

    # Initial draw
    _draw_menu(title, items, cursor)

    while True:
        key = _read_key()

        if key == "up":
            cursor = (cursor - 1) % n
        elif key == "down":
            cursor = (cursor + 1) % n
        elif key == "enter":
            # Erase menu
            _erase_lines(total_lines)
            return cursor
        elif key in ("ctrl-c", "esc"):
            _erase_lines(total_lines)
            return None
        else:
            continue

        # Redraw: move up, overwrite
        _move_up(total_lines)
        _draw_menu(title, items, cursor)


def _draw_menu(title: str, items: list[str], cursor: int) -> None:
    """Draw the menu to stdout."""
    sys.stdout.write(f"  \x1b[1m{title}\x1b[0m\n")
    for i, item in enumerate(items):
        if i == cursor:
            sys.stdout.write(f"    \x1b[32m> {item}\x1b[0m\n")
        else:
            sys.stdout.write(f"      {item}\n")
    sys.stdout.flush()


def _move_up(n: int) -> None:
    """Move cursor up n lines."""
    sys.stdout.write(f"\x1b[{n}F")
    sys.stdout.flush()


def _erase_lines(n: int) -> None:
    """Erase n lines starting from current position."""
    for _ in range(n):
        sys.stdout.write("\x1b[2K\n")
    _move_up(n)
    sys.stdout.flush()


def checkbox_select(
    title: str, items: list[str], checked: list[bool] | None = None
) -> list[int] | None:
    """Arrow-key multi-select with space to toggle. Returns selected indices or None."""
    n = len(items)
    if n == 0:
        return []

    # Fallback for non-TTY
    if not sys.stdin.isatty():
        return list(range(n))

    selected = list(checked) if checked else [True] * n
    cursor = 0
    total_lines = n + 1  # title + items

    _draw_checkbox_menu(title, items, cursor, selected)

    while True:
        key = _read_key()

        if key == "up":
            cursor = (cursor - 1) % n
        elif key == "down":
            cursor = (cursor + 1) % n
        elif key == " ":
            selected[cursor] = not selected[cursor]
        elif key == "enter":
            _erase_lines(total_lines)
            return [i for i, s in enumerate(selected) if s]
        elif key in ("ctrl-c", "esc"):
            _erase_lines(total_lines)
            return None
        else:
            continue

        _move_up(total_lines)
        _draw_checkbox_menu(title, items, cursor, selected)


def _draw_checkbox_menu(
    title: str, items: list[str], cursor: int, selected: list[bool]
) -> None:
    """Draw checkbox menu to stdout."""
    sys.stdout.write(f"  \x1b[1m{title}\x1b[0m\n")
    for i, item in enumerate(items):
        check = "\x1b[32m[x]\x1b[0m" if selected[i] else "[ ]"
        if i == cursor:
            sys.stdout.write(f"    \x1b[32m> {check} {item}\x1b[0m\n")
        else:
            sys.stdout.write(f"      {check} {item}\n")
    sys.stdout.flush()
