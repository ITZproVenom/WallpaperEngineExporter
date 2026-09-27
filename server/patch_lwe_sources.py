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
s = s.replace("#include <format>", "#include <iomanip>\n#include <sstream>")

s = re.sub(
    r'number = std::format \(\s*"\{\}\{\}\{\}\{\}\{\}\{\}\{\}\{:\\02x\}",\s*number\.at \(0\), number\.at \(0\), number\.at \(1\), number\.at \(1\), number\.at \(2\),\s*number\.at \(2\), static_cast<int> \(alpha \* 255\)\s*\);',
    '''std::ostringstream expanded;
            expanded << number.at (0) << number.at (0)
                     << number.at (1) << number.at (1)
                     << number.at (2) << number.at (2)
                     << std::hex << std::setw (2) << std::setfill ('0')
                     << static_cast<int> (alpha * 255);
            number = expanded.str ();''',
    s,
    count=1,
)
s = re.sub(
    r'number = std::format \(\s*"\{\}\{\}\{\}\{\}\{\}\{\}\{\}",\s*number\.at \(0\), number\.at \(0\), number\.at \(1\), number\.at \(1\), number\.at \(2\),\s*number\.at \(2\), number\.at \(3\), number\.at \(3\)\s*\);',
    '''number = std::string {
                number.at (0), number.at (0), number.at (1), number.at (1),
                number.at (2), number.at (2), number.at (3), number.at (3)
            };''',
    s,
    count=1,
)
if "std::format" in s:
    raise SystemExit("ColorBuilder still contains std::format")
p.write_text(s)
