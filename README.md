# Truco de Mesa — servidor da beta

Repositório privado. Não contém chaves de assinatura, credenciais, fotos ou partidas de usuários.

Godot 4.7.2 oficial verificado por SHA-256. Servidor autoritativo com salas privadas por código, prontos, equipes, visões privadas e reconexão. Mesas 1×1, 2×2 e 3×3; Paulista, Mineiro e Maluco.

Render Free: runtime Python, build `python3 deployment/bootstrap.py`, start `python3 deployment/run.py`. Escuta `0.0.0.0:$PORT`; autoridade interna no loopback. Health `/healthz`; WebSocket `/v1/ws`. Variável opcional `DOWNLOAD_URL` aponta apenas para o APK público.

Serviço efêmero, máximo de três salas simultâneas. Reiniciar interrompe partidas sem atribuir vencedor.
