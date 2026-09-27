from pathlib import Path

root = Path("/src/linux-wallpaperengine/src/WallpaperEngine")

media = root / "Media/MediaSource.h"
s = media.read_text()
if "#include <optional>" not in s:
    s = s.replace("#include <map>", "#include <map>\n#include <memory>\n#include <optional>", 1)
media.write_text(s)

p = root / "Data/Builders/ColorBuilder.cpp"
lines = p.read_text().splitlines(True)
out = []
i = 0
replacements = 0

while i < len(lines):
    line = lines[i]
    if "number = std::format" not in line:
        out.append(line)
        i += 1
        continue

    block = []
    depth = 0
    started = False
    while i < len(lines):
        part = lines[i]
        block.append(part)
        depth += part.count("(") - part.count(")")
        started = True
        i += 1
        if started and depth <= 0 and ");" in part:
            break

    joined = "".join(block)
    if "alpha * 255" in joined:
        replacement = """            std::ostringstream expanded;
            expanded << number.at (0) << number.at (0)
                     << number.at (1) << number.at (1)
                     << number.at (2) << number.at (2)
                     << std::hex << std::setw (2) << std::setfill ('0')
                     << static_cast<int> (alpha * 255);
            number = expanded.str ();
"""
    elif "number.at (3)" in joined:
        replacement = """            number = std::string {
                number.at (0), number.at (0), number.at (1), number.at (1),
                number.at (2), number.at (2), number.at (3), number.at (3)
            };
"""
    else:
        raise SystemExit("Unsupported ColorBuilder std::format block")
    out.append(replacement)
    replacements += 1

s = "".join(out).replace("#include <format>", "#include <iomanip>\n#include <sstream>", 1)
if replacements != 2 or "std::format" in s:
    raise SystemExit(f"ColorBuilder compatibility patch failed: replacements={replacements} remaining_format={'std::format' in s}")
p.write_text(s)
