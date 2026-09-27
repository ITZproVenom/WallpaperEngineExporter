from pathlib import Path
import re

root = Path("/src/linux-wallpaperengine/src/WallpaperEngine")

media = root / "Media/MediaSource.h"
s = media.read_text()
if "#include <optional>" not in s:
    s = s.replace("#include <map>", "#include <map>\n#include <memory>\n#include <optional>", 1)
media.write_text(s)

p = root / "Data/Builders/ColorBuilder.cpp"
s = p.read_text()
s = s.replace("#include <format>", "#include <iomanip>\n#include <sstream>", 1)

three = re.compile(
    r'number\s*=\s*std::format\s*\(\s*"\{\}\{\}\{\}\{\}\{\}\{:\s*02x\}"\s*,'
    r'\s*number\.at\s*\(\s*0\s*\)\s*,\s*number\.at\s*\(\s*0\s*\)\s*,'
    r'\s*number\.at\s*\(\s*1\s*\)\s*,\s*number\.at\s*\(\s*1\s*\)\s*,'
    r'\s*number\.at\s*\(\s*2\s*\)\s*,\s*number\.at\s*\(\s*2\s*\)\s*,'
    r'\s*static_cast<int>\s*\(\s*alpha\s*\*\s*255\s*\)\s*\)\s*;',
    re.S,
)
three_replacement = """std::ostringstream expanded;
            expanded << number.at (0) << number.at (0)
                     << number.at (1) << number.at (1)
                     << number.at (2) << number.at (2)
                     << std::hex << std::setw (2) << std::setfill ('0')
                     << static_cast<int> (alpha * 255);
            number = expanded.str ();"""
s, n3 = three.subn(three_replacement, s, count=1)

four = re.compile(
    r'number\s*=\s*std::format\s*\(\s*"\{\}\{\}\{\}\{\}\{\}\{\}"\s*,'
    r'\s*number\.at\s*\(\s*0\s*\)\s*,\s*number\.at\s*\(\s*0\s*\)\s*,'
    r'\s*number\.at\s*\(\s*1\s*\)\s*,\s*number\.at\s*\(\s*1\s*\)\s*,'
    r'\s*number\.at\s*\(\s*2\s*\)\s*,\s*number\.at\s*\(\s*2\s*\)\s*,'
    r'\s*number\.at\s*\(\s*3\s*\)\s*,\s*number\.at\s*\(\s*3\s*\)\s*\)\s*;',
    re.S,
)
four_replacement = """number = std::string {
                number.at (0), number.at (0), number.at (1), number.at (1),
                number.at (2), number.at (2), number.at (3), number.at (3)
            };"""
s, n4 = four.subn(four_replacement, s, count=1)

if n3 != 1 or n4 != 1 or "std::format" in s:
    raise SystemExit(f"ColorBuilder compatibility patch failed: three={n3} four={n4} remaining_format={'std::format' in s}")

p.write_text(s)
