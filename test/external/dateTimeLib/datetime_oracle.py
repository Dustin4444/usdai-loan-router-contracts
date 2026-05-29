#!/usr/bin/env python3
"""
DateTimeLib oracle for Foundry FFI differential tests.

Output format: "0x" followed by N concatenated 64-char lowercase hex words (one 32-byte
uint256 per word, no separators). The Solidity side abi.decodes the raw bytes directly.

Modes:
  dim <year> <month>        -- 1 word: days in the given month
  d2t <year> <month> <day>  -- 1 word: unix timestamp (midnight UTC)
  t2d <timestamp>           -- 3 words: (year, month, day) for the day containing timestamp
  batch <year_start> <year_end>
                            -- 2 words per day for every day in [year_start-01-01,
                               year_end-12-31]: word 0 = timestamp, word 1 = daysInMonth

Notes:
  - Python datetime is valid for years 1..9999; this oracle's range is 1970..9999.
  - December is special-cased in dim() to return 31 without constructing date(year+1, 1, 1),
    avoiding the year-10000 overflow in datetime.monthrange for year=9999.
  - Python-only unit tests verify the algorithm; the FFI test verifies deployed bytecode.
"""

import sys
import calendar
from datetime import date, timedelta

EPOCH = date(1970, 1, 1)


def _word(n: int) -> str:
    return format(n, "064x")


def _days_in_month(year: int, month: int) -> int:
    if month == 12:
        return 31
    return calendar.monthrange(year, month)[1]


def cmd_dim(year: int, month: int) -> None:
    print("0x" + _word(_days_in_month(year, month)))


def cmd_d2t(year: int, month: int, day: int) -> None:
    ts = (date(year, month, day) - EPOCH).days * 86400
    print("0x" + _word(ts))


def cmd_t2d(timestamp: int) -> None:
    days = timestamp // 86400
    d = EPOCH + timedelta(days=days)
    print("0x" + _word(d.year) + _word(d.month) + _word(d.day))


def cmd_batch(year_start: int, year_end: int) -> None:
    parts = []
    current = date(year_start, 1, 1)
    end = date(year_end, 12, 31)
    while current <= end:
        ts = (current - EPOCH).days * 86400
        dim = _days_in_month(current.year, current.month)
        parts.append(_word(ts))
        parts.append(_word(dim))
        current += timedelta(days=1)
    print("0x" + "".join(parts))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "dim":
        cmd_dim(int(sys.argv[2]), int(sys.argv[3]))
    elif mode == "d2t":
        cmd_d2t(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    elif mode == "t2d":
        cmd_t2d(int(sys.argv[2]))
    elif mode == "batch":
        cmd_batch(int(sys.argv[2]), int(sys.argv[3]))
    else:
        sys.exit(f"unknown mode: {mode}")
