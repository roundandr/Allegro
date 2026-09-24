#!/usr/bin/env python3
"""Check the relocated source tree without invoking RTL tools."""

from __future__ import annotations

from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
FILELISTS = sorted((ROOT / "filelists").glob("*.f"))
SOURCE_REF = re.compile(
    r"(?<![\w/])(?:rtl|verification|scripts|filelists)/"
    r"[\w./-]+\.(?:sv|f|py|sh|cu|json|md)\b"
)
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)|!\[[^\]]*\]\(([^)]+)\)")
# Existing DotProduct figures were absent before the directory migration.
LEGACY_MISSING_IMAGES = {"dp_mid.drawio.png", "dp_low.drawio.png"}
ERRORS: list[str] = []


def error(where: Path, detail: str) -> None:
    ERRORS.append(f"{where.relative_to(ROOT)}: {detail}")


def check_filelist(path: Path, visiting: set[Path]) -> int:
    if path in visiting:
        error(path, "cyclic -f include")
        return 0
    visiting.add(path)
    sources = 0
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("-f "):
            item = line[3:].strip()
        else:
            item = line
            sources += 1
        target = ROOT / item
        if Path(item).is_absolute() or ".." in Path(item).parts:
            error(path, f"line {lineno}: not a root-relative path: {item}")
        elif not target.is_file():
            error(path, f"line {lineno}: missing {item}")
        elif line.startswith("-f "):
            sources += check_filelist(target, visiting)
    visiting.remove(path)
    return sources


def check_references(path: Path) -> None:
    content = path.read_text(errors="replace")
    if "src/main" in content or "src/test" in content:
        error(path, "old src/main or src/test reference")
    for match in SOURCE_REF.finditer(content):
        item = match.group()
        if not (ROOT / item).is_file():
            error(path, f"missing source reference {item}")
    if path == ROOT / "verification/cocotb/Makefile":
        for item in re.findall(r"\$\(CURDIR\)/(\.\./\.\./[\w./-]+\.sv)", content):
            if not (path.parent / item).is_file():
                error(path, f"missing arithmetic source {item}")


def check_markdown(path: Path) -> None:
    for match in MARKDOWN_LINK.finditer(path.read_text()):
        link = (match.group(1) or match.group(2)).split(" ", 1)[0]
        parts = urlsplit(link)
        if parts.scheme or link.startswith("#") or not parts.path:
            continue
        if path.name == "DotProduct.md" and parts.path in LEGACY_MISSING_IMAGES:
            continue
        target = path.parent / unquote(parts.path)
        # Generated evidence is optional in a source-only checkout.
        if target.resolve().is_relative_to(ROOT / "build"):
            continue
        if not target.exists():
            error(path, f"broken local link {link}")


def main() -> int:
    if (ROOT / "src").exists():
        error(ROOT / "src", "obsolete src/ directory remains")
    if len(FILELISTS) != 4:
        error(ROOT / "filelists", f"expected 4 filelists, found {len(FILELISTS)}")
    source_count = sum(check_filelist(path, set()) for path in FILELISTS)
    checked = [ROOT / "Makefile", ROOT / "AGENTS.md", ROOT / "README.md"]
    checked += list((ROOT / "scripts/blackwell").glob("*.sh"))
    checked += list((ROOT / "verification/cocotb").glob("Makefile"))
    checked += list((ROOT / "verification/benchmarks/dot_efficiency").glob("*.py"))
    checked += list((ROOT / "verification/benchmarks/dot_efficiency").glob("*.f"))
    checked += list((ROOT / "doc").glob("*.md"))
    checked += list((ROOT / "verification/cocotb").glob("*.md"))
    checked += FILELISTS
    for path in checked:
        check_references(path)
        if path.suffix == ".md":
            check_markdown(path)
    for detail in ERRORS:
        print(detail, file=sys.stderr)
    if ERRORS:
        print(f"layout check failed: {len(ERRORS)} error(s)", file=sys.stderr)
        return 1
    print(f"layout check passed: {len(FILELISTS)} filelists, {source_count} source entries, {len(checked)} reference files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
