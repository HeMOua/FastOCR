"""Explicit, one-time online provisioning. The translation worker never downloads."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import subprocess
import zipfile

PACKAGES = {"en_zh": "1_9", "zh_en": "1_9", "en_ja": "1_1", "ja_en": "1_1"}


def install(root):
    models = root / "models"
    models.mkdir(parents=True, exist_ok=True)
    for pair, version in PACKAGES.items():
        destination = models / pair
        if (destination / "model/model.bin").is_file() and (destination / "sentencepiece.model").is_file():
            print(f"已就绪：{pair}", flush=True)
            continue
        print(f"下载离线语言包：{pair}（首次准备需要联网）", flush=True)
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            temp = Path(temporary)
            archive = temp / "package.zip"
            url = f"https://argos-net.com/v1/translate-{pair}-{version}.argosmodel"
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                            "--max-time", "900", "--silent", "--show-error", url, "--output", str(archive)], check=True)
            with zipfile.ZipFile(archive) as package:
                for member in package.infolist():
                    path = (temp / "unpacked" / member.filename).resolve()
                    if not path.is_relative_to((temp / "unpacked").resolve()):
                        raise ValueError("语言包包含不合法路径")
                package.extractall(temp / "unpacked")
            metadata_files = list((temp / "unpacked").glob("*/metadata.json"))
            if len(metadata_files) != 1:
                raise ValueError("无法识别语言包")
            source = metadata_files[0].parent
            metadata = json.loads(metadata_files[0].read_text())
            if f"{metadata['from_code']}_{metadata['to_code']}" != pair:
                raise ValueError("语言包方向不匹配")
            if not (source / "model/model.bin").is_file() or not (source / "sentencepiece.model").is_file():
                raise ValueError("语言包不完整")
            if destination.exists():
                shutil.rmtree(destination)
            # Keep package metadata and licenses alongside the model.
            os.replace(source, destination)
        print(f"安装完成：{pair}", flush=True)
    print("离线模型准备完成。之后翻译无需联网。", flush=True)


if __name__ == "__main__":
    install(Path(sys.argv[1]))
