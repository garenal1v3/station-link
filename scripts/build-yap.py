#!/usr/bin/env python3
"""Собрать YAM-пакет .yap (zip) из package/ и положить рядом .sha256."""
import argparse
import hashlib
from pathlib import Path
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "package"
# Явный список: в пакет попадает только это.
PAYLOAD = ("plugin.toml", "control.sh", "station-link.conf.example")
LIMIT = 32 * 1024 * 1024  # предел распакованного размера в yamd


def build(output=None):
    manifest = tomllib.loads((PACKAGE / "plugin.toml").read_text())
    for name in (manifest["entry"], manifest["launch"]["path"]):
        if name not in PAYLOAD:
            raise ValueError(f"{name} из plugin.toml нет в составе пакета")
    output = Path(output or ROOT / f"dist/{manifest['id']}-{manifest['version']}.yap").resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    files = [(name, PACKAGE / name) for name in PAYLOAD]
    if sum(path.stat().st_size for _, path in files) > LIMIT:
        raise ValueError("распакованный размер больше 32 МиБ")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path in files:
            # Фиксированные дата и права — сборка воспроизводима.
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100755 if name.endswith(".sh") else 0o100644) << 16
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n")
    print(output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="путь .yap (по умолчанию dist/<id>-<version>.yap)")
    build(parser.parse_args().output)
