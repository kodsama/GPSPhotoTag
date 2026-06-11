"""Filesystem date reading/setting for --fix-dates."""

from __future__ import annotations

import os
import subprocess
from datetime import datetime, timezone

from gpsphototag import dates

UTC = timezone.utc


def test_read_file_created_returns_aware_datetime(tmp_path):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    dt = dates.read_file_created(f)
    assert dt.tzinfo is not None


def test_read_file_created_falls_back_to_mtime(tmp_path, monkeypatch):
    """When st_birthtime is absent, st_mtime is used."""
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    known = datetime(2021, 6, 1, 12, 0, 0, tzinfo=UTC).timestamp()
    os.utime(f, (known, known))

    real_stat = type(f).stat

    class NoBirth:
        st_mtime = known

        def __getattr__(self, name):
            if name == "st_birthtime":
                raise AttributeError(name)
            return getattr(real_stat, name)

    monkeypatch.setattr(type(f), "stat", lambda self, *a, **k: NoBirth())
    dt = dates.read_file_created(f)
    assert abs(dt.timestamp() - known) < 2


def test_set_file_dates_sets_mtime(tmp_path):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    target = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    dates.set_file_dates(f, target)
    assert abs(f.stat().st_mtime - target.timestamp()) < 2


def test_set_file_dates_non_darwin_returns_false(tmp_path, monkeypatch):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    monkeypatch.setattr(dates.platform, "system", lambda: "Linux")
    assert dates.set_file_dates(f, datetime(2024, 8, 15, tzinfo=UTC)) is False


def test_set_file_dates_darwin_without_setfile_warns(tmp_path, monkeypatch, caplog):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    monkeypatch.setattr(dates.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(dates, "setfile_available", lambda: False)
    with caplog.at_level("WARNING"):
        result = dates.set_file_dates(f, datetime(2024, 8, 15, tzinfo=UTC))
    assert result is False
    assert any("SetFile not found" in r.message for r in caplog.records)


def test_set_file_dates_darwin_with_setfile_success(tmp_path, monkeypatch):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    monkeypatch.setattr(dates.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(dates, "setfile_available", lambda: True)
    monkeypatch.setattr(dates.subprocess, "run",
                        lambda *a, **k: subprocess.CompletedProcess([], 0, "", ""))
    assert dates.set_file_dates(f, datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)) is True


def test_set_file_dates_darwin_setfile_failure_warns(tmp_path, monkeypatch, caplog):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"hi")
    monkeypatch.setattr(dates.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(dates, "setfile_available", lambda: True)
    monkeypatch.setattr(dates.subprocess, "run",
                        lambda *a, **k: subprocess.CompletedProcess([], 1, "", "nope"))
    with caplog.at_level("WARNING"):
        assert dates.set_file_dates(f, datetime(2024, 8, 15, tzinfo=UTC)) is False
    assert any("SetFile failed" in r.message for r in caplog.records)


def test_setfile_available_returns_bool():
    assert isinstance(dates.setfile_available(), bool)


def test_parse_exif_offset_variants():
    assert dates.parse_exif_offset("Z") is timezone.utc
    assert dates.parse_exif_offset("+02:00").utcoffset(None).total_seconds() == 2 * 3600
    assert dates.parse_exif_offset("-05:30").utcoffset(None).total_seconds() == -(5.5 * 3600)
    assert dates.parse_exif_offset("garbage") is None


def test_parse_exif_datetime_offset_and_fallback():
    dt = dates.parse_exif_datetime("2024:08:15 10:00:00", "+02:00", timezone.utc)
    assert dt.utcoffset().total_seconds() == 2 * 3600
    dt = dates.parse_exif_datetime("2024:08:15 10:00:00", None, timezone.utc)
    assert dt.tzinfo is timezone.utc
    assert dates.parse_exif_datetime("not a date", None, timezone.utc) is None
