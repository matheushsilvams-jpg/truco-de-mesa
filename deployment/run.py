"""HTTP público e proxy WebSocket; a autoridade Godot escuta só no loopback."""
import asyncio
import contextlib
import html
import json
import os
from pathlib import Path
import signal
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
BUILD = '0.4.0-beta1'

class Gateway:
    def __init__(self, backend_port, process=None):
        self.backend_port = backend_port
        self.process = process
        self.active = 0
        self.draining = False

    async def ready(self):
        if self.draining or (self.process and self.process.returncode is not None):
            return False
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', self.backend_port), 1)
            writer.close()
            await writer.wait_closed()
            return True
        except (OSError, TimeoutError):
            return False

    async def reply(self, writer, status, body=b'', mime='text/plain; charset=utf-8', extra=''):
        reason = {200:'OK',302:'Found',400:'Bad Request',404:'Not Found',405:'Method Not Allowed',431:'Request Header Fields Too Large',503:'Service Unavailable'}[status]
        head = f'HTTP/1.1 {status} {reason}\r\nContent-Type: {mime}\r\nContent-Length: {len(body)}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src \'none\'; style-src \'unsafe-inline\'\r\n{extra}\r\n'
        writer.write(head.encode('ascii')+body)
        await writer.drain()

    async def pipe(self, reader, writer):
        while data := await reader.read(32768):
            writer.write(data)
            await writer.drain()

    async def handle(self, reader, writer):
        backend_writer = None
        self.active += 1
        try:
            if self.active > 64 or self.draining:
                await self.reply(writer,503,b'Servidor ocupado. Tente novamente.');return
            try:
                head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            except asyncio.LimitOverrunError:
                await self.reply(writer,431);return
            if len(head)>16384:
                await self.reply(writer,431);return
            request = head.decode('iso-8859-1').split('\r\n')
            first = request[0].split(' ')
            if len(first)!=3 or not first[2].startswith('HTTP/1.'):
                await self.reply(writer,400);return
            method,target,_=first
            if method!='GET':
                await self.reply(writer,405,extra='Allow: GET\r\n');return
            headers={}
            for line in request[1:]:
                if not line:continue
                if ':' not in line:
                    await self.reply(writer,400);return
                k,v=line.split(':',1)
                headers[k.strip().lower()]=v.strip()
            path=urlsplit(target).path
            if path=='/v1/ws' and headers.get('upgrade','').lower()=='websocket':
                if not await self.ready():
                    await self.reply(writer,503);return
                backend_reader,backend_writer=await asyncio.wait_for(asyncio.open_connection('127.0.0.1',self.backend_port),3)
                backend_writer.write(head);await backend_writer.drain()
                jobs=[asyncio.create_task(self.pipe(reader,backend_writer)),asyncio.create_task(self.pipe(backend_reader,writer))]
                try:
                    await asyncio.wait(jobs,return_when=asyncio.FIRST_COMPLETED)
                finally:
                    for task in jobs:task.cancel()
                    await asyncio.gather(*jobs,return_exceptions=True)
                return
            if path=='/healthz':
                ok=await self.ready()
                await self.reply(writer,200 if ok else 503,json.dumps({'ready':ok,'build':BUILD}).encode(),'application/json');return
            if path=='/version':
                await self.reply(writer,200,json.dumps({'build':BUILD,'protocol':1,'storage':'ephemeral'}).encode(),'application/json');return
            download=os.environ.get('DOWNLOAD_URL','')
            parsed=urlsplit(download)
            valid_download=parsed.scheme=='https' and bool(parsed.netloc) and not parsed.username and not parsed.password and '\r' not in download and '\n' not in download
            if path=='/baixar':
                if valid_download:
                    await self.reply(writer,302,extra='Location: '+download+'\r\n')
                else:await self.reply(writer,503,'O APK está sendo preparado. Volte em breve.'.encode())
                return
            if path=='/':
                action='<a href="/baixar">Baixar APK Android gratuito</a>' if valid_download else '<p>O instalador será disponibilizado nesta página após a validação.</p>'
                page=f'''<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Truco de Mesa</title><style>body{{margin:0;background:#102b23;color:#f8f1e6;font:18px system-ui;line-height:1.6}}main{{max-width:680px;margin:12vh auto;padding:28px}}h1{{color:#e8ba77;font-size:44px;line-height:1.1}}a{{display:inline-block;background:#e8ba77;color:#102b23;padding:16px 24px;border-radius:14px;font-weight:700;text-decoration:none}}small{{color:#b3c3bb}}li{{margin:12px 0}}</style><main><small>BETA PRIVADA · {BUILD}</small><h1>Truco de Mesa</h1><p>A mesma mesa, mesmo longe. Convide seus amigos para jogar de graça.</p>{action}<ol><li>Instalem o APK nos celulares Android.</li><li>Abram <b>Com amigos</b>. Uma pessoa cria a sala.</li><li>Compartilhem o código, confirmem as equipes e toquem em <b>Estou pronto</b>.</li></ol><p>1×1, 2×2 e 3×3 · Paulista, Mineiro e Maluco · treino offline</p><small>Servidor gratuito: a primeira conexão pode levar cerca de um minuto. Uma reinicialização pode encerrar a mesa, sem atribuir vencedor.</small></main></html>'''
                await self.reply(writer,200,page.encode(),'text/html; charset=utf-8');return
            await self.reply(writer,404,b'Pagina nao encontrada.')
        except (OSError,TimeoutError,asyncio.IncompleteReadError,UnicodeError,ValueError):
            pass
        finally:
            self.active-=1
            for stream in [backend_writer,writer]:
                if stream:
                    stream.close()
                    with contextlib.suppress(OSError,TimeoutError):
                        await asyncio.wait_for(stream.wait_closed(),2)

async def main():
    port=int(os.environ.get('PORT','10000'))
    backend_port=int(os.environ.get('GODOT_PORT','10001'))
    if port==backend_port:raise RuntimeError('As portas pública e interna precisam ser distintas.')
    executable=os.environ.get('GODOT_BIN',str(ROOT/'.toolchain/godot'))
    env=dict(os.environ,PORT=str(backend_port),GODOT_SILENCE_ROOT_WARNING='1')
    process=await asyncio.create_subprocess_exec(executable,'--headless','--path',str(ROOT),'--script','server/main.gd',cwd=ROOT,env=env)
    gateway=Gateway(backend_port,process)
    stop=asyncio.Event()
    loop=asyncio.get_running_loop()
    for sig in [signal.SIGINT,signal.SIGTERM]:loop.add_signal_handler(sig,stop.set)
    server=await asyncio.start_server(gateway.handle,'0.0.0.0',port,limit=16384)
    print(json.dumps({'service':'truco-gateway','build':BUILD,'port':port}),flush=True)
    waits=[asyncio.create_task(stop.wait()),asyncio.create_task(process.wait())]
    try:
        await asyncio.wait(waits,return_when=asyncio.FIRST_COMPLETED)
    finally:
        gateway.draining=True
        server.close();await server.wait_closed()
        if process.returncode is None:
            process.terminate()
            try:await asyncio.wait_for(process.wait(),10)
            except TimeoutError:process.kill();await process.wait()
        for task in waits:task.cancel()
        await asyncio.gather(*waits,return_exceptions=True)
    if process.returncode not in [0,-signal.SIGTERM]:raise SystemExit(1)

if __name__=='__main__':asyncio.run(main())
