"""Rich terminal UI for progress reporting."""

from __future__ import annotations

from rich.console import Console
from rich.progress import (
    BarColumn,
    DownloadColumn,
    Progress,
    SpinnerColumn,
    TaskID,
    TextColumn,
    TimeRemainingColumn,
    TransferSpeedColumn,
)

console = Console()


def create_transcode_progress() -> Progress:
    """Create a progress bar for transcoding."""
    return Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TimeRemainingColumn(),
        console=console,
    )


def create_transfer_progress() -> Progress:
    """Create a progress bar for file transfer."""
    return Progress(
        SpinnerColumn(),
        TextColumn("[bold green]{task.description}"),
        BarColumn(),
        DownloadColumn(),
        TransferSpeedColumn(),
        TimeRemainingColumn(),
        console=console,
    )


def print_file_info(filename: str, action: str) -> None:
    """Print file processing info."""
    console.print(f"\n[bold]{'─' * 60}[/bold]")
    console.print(f"  [bold]{filename}[/bold] → {action}")
    console.print(f"[bold]{'─' * 60}[/bold]")


def print_success(message: str) -> None:
    console.print(f"  [green]✓[/green] {message}")


def print_warning(message: str) -> None:
    console.print(f"  [yellow]⚠[/yellow] {message}")


def print_error(message: str) -> None:
    console.print(f"  [red]✗[/red] {message}")


def print_dry_run(lines: list[str]) -> None:
    """Print dry-run summary."""
    console.print("\n[bold yellow]DRY RUN — no changes will be made[/bold yellow]\n")
    for line in lines:
        console.print(f"  {line}")
    console.print()
