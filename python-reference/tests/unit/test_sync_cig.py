"""Tests for CIG signature computation."""

import plistlib
import datetime

from mediaporter.sync.atc import ATCSession
from mediaporter.sync.device import DeviceInfo
from mediaporter.sync.frameworks import get_grappa_bytes


def test_cig_produces_21_bytes():
    """CIG computation should produce a 21-byte signature."""
    session = ATCSession.__new__(ATCSession)
    grappa = get_grappa_bytes()

    # Build a minimal plist to sign
    plist_data = plistlib.dumps({
        "revision": 1,
        "timestamp": datetime.datetime.now(),
        "operations": [],
    }, fmt=plistlib.FMT_BINARY)

    cig = session.compute_cig(grappa, plist_data)
    assert len(cig) == 21


def test_cig_deterministic():
    """Same input should produce same CIG."""
    session = ATCSession.__new__(ATCSession)
    grappa = get_grappa_bytes()

    # Use fixed datetime for determinism
    fixed_time = datetime.datetime(2026, 4, 6, 12, 0, 0)
    plist_data = plistlib.dumps({
        "revision": 1,
        "timestamp": fixed_time,
        "operations": [],
    }, fmt=plistlib.FMT_BINARY)

    cig1 = session.compute_cig(grappa, plist_data)
    cig2 = session.compute_cig(grappa, plist_data)
    assert cig1 == cig2


def test_cig_changes_with_data():
    """Different input should produce different CIG."""
    session = ATCSession.__new__(ATCSession)
    grappa = get_grappa_bytes()

    fixed_time = datetime.datetime(2026, 4, 6, 12, 0, 0)

    plist1 = plistlib.dumps({
        "revision": 1, "timestamp": fixed_time, "operations": [],
    }, fmt=plistlib.FMT_BINARY)

    plist2 = plistlib.dumps({
        "revision": 2, "timestamp": fixed_time, "operations": [],
    }, fmt=plistlib.FMT_BINARY)

    cig1 = session.compute_cig(grappa, plist1)
    cig2 = session.compute_cig(grappa, plist2)
    assert cig1 != cig2
