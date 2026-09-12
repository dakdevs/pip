#!/usr/bin/env python3
"""Calculate the next date-based release version from git tags."""

from __future__ import annotations

import argparse
from datetime import date, datetime, timezone
import re
import sys
from typing import Iterable


_TAG_RE = re.compile(r"^v?(?P<date>[0-9]{8})\.(?P<number>[1-9][0-9]*)$")
_DATE_RE = re.compile(r"^[0-9]{8}$")


def parse_tag(tag: str) -> tuple[date, int] | None:
    """Return a tag's date and sequence, or ``None`` for an unrelated tag."""
    match = _TAG_RE.fullmatch(tag.strip())
    if match is None:
        return None
    try:
        tag_date = datetime.strptime(match.group("date"), "%Y%m%d").date()
    except ValueError:
        return None
    return tag_date, int(match.group("number"))


def next_version(tags: Iterable[str], release_date: date | str | None = None) -> str:
    """Compute the next version, rejecting tags that would cause a rollback."""
    if release_date is None:
        release_date = datetime.now(timezone.utc).date()
    elif isinstance(release_date, str):
        if not _DATE_RE.fullmatch(release_date):
            raise ValueError("date must be a valid calendar date in YYYYMMDD format")
        try:
            release_date = datetime.strptime(release_date, "%Y%m%d").date()
        except ValueError as exc:
            raise ValueError("date must be a valid calendar date in YYYYMMDD format") from exc

    valid_tags = [parsed for tag in tags if (parsed := parse_tag(tag)) is not None]
    future_dates = sorted({tag_date for tag_date, _ in valid_tags if tag_date > release_date})
    if future_dates:
        newest = future_dates[-1].strftime("%Y%m%d")
        requested = release_date.strftime("%Y%m%d")
        raise ValueError(f"cannot release for {requested}: existing tag date {newest} is later")

    highest = max((number for tag_date, number in valid_tags if tag_date == release_date), default=0)
    return f"{release_date:%Y%m%d}.{highest + 1}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Print the next date-based release version")
    parser.add_argument("--date", metavar="YYYYMMDD", help="release date (defaults to UTC today)")
    args = parser.parse_args(argv)
    try:
        print(next_version(sys.stdin, args.date))
    except ValueError as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
