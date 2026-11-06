"""Publica somente o export compilado Web; não usa o processo do servidor de salas."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import tempfile
import shutil
import urllib.request
import zipfile

URL = 'https://github.com/matheushsilvams-jpg/truco-de-mesa-apk/releases/download/v0.4.0-web1/truco-de-mesa-0.4.0-web1.zip'
SHA256 = 'ebb5bfe7b8cc27a80d490094a006ec11942c4018c45ec7af204a2d7538051b89'
ROOT = Path(__file__).resolve().parents[1]
WEB_REVISION = '0.4.0-web1.3'

def apply_frontend(destination):
    launcher=Path(__file__).with_name('web_launcher.html')
    if launcher.exists():(destination/'treino.html').write_bytes(launcher.read_bytes())
    public=Path(__file__).with_name('web_public')
    if public.exists():shutil.copytree(public,destination,dirs_exist_ok=True)
    manifest=destination/'manifest.webmanifest'
    data=json.loads(manifest.read_text());data['start_url']='./online/'
    manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
    files=['./'+p.relative_to(destination).as_posix() for p in sorted(destination.rglob('*')) if p.is_file() and p.name not in ('sw.js','build.json')]
    shell=['./','./index.html','./online/','./online/index.html','./online/online.js','./online/online.css','./pwa.js','./logo.png','./manifest.webmanifest','./icons/apple-touch-icon.png','./icons/icon-192.png','./icons/icon-512.png']
    worker=destination/'sw.js';script=worker.read_text()
    import re
    script=re.sub(r'const CACHE=.*?;', 'const CACHE='+json.dumps('truco-web-'+WEB_REVISION)+';',script)
    script=re.sub(r'const FILES=.*?;', 'const FILES='+json.dumps(files)+';',script)
    script=re.sub(r'const SHELL=.*?;', 'const SHELL='+json.dumps(shell)+';',script)
    script=script.replace("caches.open(CACHE).then(cache=>cache.addAll(SHELL))","caches.open(CACHE).then(cache=>cache.addAll(SHELL)).then(()=>self.skipWaiting())")
    worker.write_text(script)
    report=destination/'build.json';data=json.loads(report.read_text());data['launcher_revision']=WEB_REVISION;data['online_client']='DOM/WebSocket';data['online_requires_webgl']=False
    data['files']={p.relative_to(destination).as_posix():{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(destination.rglob('*')) if p.is_file() and p.name!='build.json'}
    report.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')

def main():
    destination = ROOT / 'web-dist'
    with tempfile.TemporaryDirectory(prefix='truco-web-') as temp:
        path = Path(temp) / 'web.zip'
        digest = hashlib.sha256()
        request = urllib.request.Request(URL,headers={'User-Agent':'TrucoMesa-Web-Deploy/1'})
        with urllib.request.urlopen(request,timeout=120) as response,path.open('wb') as file:
            size=0
            while chunk:=response.read(1024*1024):
                size+=len(chunk)
                if size>150*1024*1024:raise RuntimeError('Export Web muito grande.')
                file.write(chunk);digest.update(chunk)
        if digest.hexdigest()!=SHA256:raise RuntimeError('Checksum do export Web não confere.')
        with zipfile.ZipFile(path) as archive:
            entries=archive.infolist()
            if len(entries)>100 or sum(e.file_size for e in entries)>300*1024*1024:
                raise RuntimeError('Export Web fora do limite.')
            required={'index.html','index.wasm','index.pck','index.js','sw.js','manifest.webmanifest'}
            for entry in entries:
                name=PurePosixPath(entry.filename)
                if name.is_absolute() or '..' in name.parts or '\\' in entry.filename or (entry.external_attr>>16)&0o170000==0o120000:
                    raise RuntimeError('Caminho inválido no export Web.')
            if not required.issubset(set(archive.namelist())):raise RuntimeError('Export Web incompleto.')
            destination.mkdir(exist_ok=True)
            archive.extractall(destination)
    apply_frontend(destination)
    print('Truco de Mesa: export Web validado e pronto para publicação.')

if __name__=='__main__':main()
