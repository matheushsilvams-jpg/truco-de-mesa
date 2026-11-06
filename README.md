# Truco de Mesa — servidor da beta

Servidor autoritativo da beta gratuita. Mesas 1×1, 2×2 e 3×3; Paulista, Mineiro e Maluco. Salas privadas por código, equipes, prontos, projeções privadas e reconexão.

Serviço: https://truco-de-mesa-beta.onrender.com

APK: https://github.com/matheushsilvams-jpg/truco-de-mesa-apk/releases

## Implantar

Godot 4.7.2 oficial, validado por SHA-256. Render Free, runtime Python; build `python3 deployment/bootstrap.py`; start `python3 deployment/run.py`. HTTP em `0.0.0.0:$PORT` e autoridade somente em loopback. `/healthz` valida o handshake da autoridade; `/version` mostra a versão; `/v1/ws` aceita WebSocket.

`DOWNLOAD_URL` aponta para a distribuição do APK. Serviço efêmero: reiniciar interrompe mesas sem atribuir vencedor. Limite inicial: três salas simultâneas. A instância gratuita pode adormecer quando estiver inativa.

O repositório contém apenas os fontes necessários ao servidor. Chave de assinatura, credenciais, fotos e dados de jogadores são mantidos fora dele.
