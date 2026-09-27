from pathlib import Path

p = Path("/src/linux-wallpaperengine/src/WallpaperEngine/Data/Builders/ColorBuilder.cpp")
s = p.read_text()
s = s.replace("#include <format>", "#include <iomanip>\n#include <sstream>")
old = '''number = std::format (
        "{}{}{}{}{}{}{:02x}", number.at (0), number.at (0), number.at (1), number.at (1), number.at (2),
        number.at (2), static_cast<int> (alpha * 255)
    );'''
new = '''std::ostringstream expanded;
    expanded << number.at (0) << number.at (0)
             << number.at (1) << number.at (1)
             << number.at (2) << number.at (2)
             << std::hex << std::setw (2) << std::setfill ('0')
             << static_cast<int> (alpha * 255);
    number = expanded.str ();'''
if old not in s:
    raise SystemExit("3-digit std::format block not found")
s = s.replace(old, new)
old = '''number = std::format (
        "{}{}{}{}{}{}{}{}", number.at (0), number.at (0), number.at (1), number.at (1), number.at (2),
        number.at (2), number.at (3), number.at (3)
    );'''
new = '''number = std::string {
        number.at (0), number.at (0), number.at (1), number.at (1),
        number.at (2), number.at (2), number.at (3), number.at (3)
    };'''
if old not in s:
    raise SystemExit("4-digit std::format block not found")
s = s.replace(old, new)
p.write_text(s)
