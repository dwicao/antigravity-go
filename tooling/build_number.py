#!/usr/bin/env python3
"""Android versionCode generator for Antigravity Go builds."""

import argparse
import datetime
import sys

EPOCH_YEAR = 2026
UTC_OFFSET = datetime.timezone(datetime.timedelta(hours=8), "UTC+8")
MAX_VERSION_CODE = 2_100_000_000
YEAR_SPAN = 100_000_000


def build_number(at: datetime.datetime | None = None) -> int:
    if at is None:
        at = datetime.datetime.now(datetime.timezone.utc)
    t = at.astimezone(UTC_OFFSET)
    if t.year < EPOCH_YEAR:
        raise ValueError(f"{t:%Y-%m-%d %H:%M} is before {EPOCH_YEAR}")
    code = (t.year - EPOCH_YEAR) * YEAR_SPAN + int(t.strftime("%m%d%H%M"))
    if code > MAX_VERSION_CODE:
        raise ValueError(f"{code} exceeds Android versionCode limit")
    return code


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=int)
    args = parser.parse_args()
    if args.check is not None:
        if not 1 <= args.check <= MAX_VERSION_CODE:
            sys.exit(f"Invalid versionCode: {args.check}")
        return
    print(build_number())


if __name__ == "__main__":
    main()
