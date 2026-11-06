"""Download do executável oficial, validado antes de iniciar o serviço."""
import hashlib
import io
import os
from pathlib import Path
import urllib.request
import zipfile

VERSION = '4.7.2'
BINARY = f'Godot_v{VERSION}-stable_linux.x86_64'
SHA256 = '8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e'
URL = f'https://github.com/godotengine/godot-builds/releases/download/{VERSION}-stable/{BINARY}.zip'

def install():
    target = Path('.toolchain/godot')
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == SHA256:
        return
    with urllib.request.urlopen(URL, timeout=120) as response:
        archive = response.read()
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        binary = z.read(BINARY)
    if hashlib.sha256(binary).hexdigest() != SHA256:
        raise RuntimeError('Checksum do executável oficial divergente; implantação cancelada.')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(binary)
    target.chmod(0o755)
    print('Godot oficial instalado e validado: '+VERSION, flush=True)

if __name__ == '__main__':
    install()
