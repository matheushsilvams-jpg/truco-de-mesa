extends RefCounted
const VERSION = 1
const BUILD = "0.4.0-beta1"
const MAX_CLIENT_BYTES = 16384
const MAX_SERVER_BYTES = 131072
const ACTIONS = ["play","raise","accept","counter","fold","concede","eleven_yes","eleven_no"]
const SIGNALS = ["zap","copas","espadas","ouros","fraca","segura"]
const CODES = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

static func integer(value, minimum=0, maximum=2147483647) -> bool:
	return (value is int or (value is float and is_finite(value) and floor(value)==value)) and value>=minimum and value<=maximum

static func text(value, minimum=1, maximum=80) -> bool:
	return value is String and value.length()>=minimum and value.length()<=maximum

static func identifier(value) -> bool:
	if not text(value,16,64):return false
	for c in value:
		if not (c.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789-_"):return false
	return true

static func hex_token(value, length=64) -> bool:
	if not text(value,length,length):return false
	for c in value:
		if not c in "0123456789abcdef":return false
	return true

static func keys(value, required: Array, allowed: Array=[]) -> bool:
	if not value is Dictionary:return false
	if allowed.is_empty():allowed=required
	for key in required:
		if not value.has(key):return false
	for key in value:
		if not key in allowed:return false
	return true

static func clean_name(value: String) -> String:
	var result=""
	for c in value.strip_edges():
		if c.unicode_at(0)>=32 and c.unicode_at(0)!=127:result+=c
	return result.left(20) if result!="" else "Truqueiro"

static func profile(value) -> bool:
	return keys(value,["nickname","avatar"]) and text(value.nickname,1,20) and integer(value.avatar,0,5)

static func options(value) -> bool:
	return keys(value,["players","variant","deck_mode","bots"]) and integer(value.players,2,6) and int(value.players) in [2,4,6] and value.variant in ["paulista","mineiro","maluco"] and value.deck_mode in ["limpo","sujo"] and (value.variant=="paulista" or value.deck_mode=="sujo") and value.bots is bool

static func validate(packet) -> String:
	if not keys(packet,["protocol","kind","request_id","body"]):return "BAD_PACKET"
	if not integer(packet.protocol,1,1):return "VERSION_MISMATCH"
	if not identifier(packet.request_id) or not packet.kind is String or not packet.body is Dictionary:return "BAD_PACKET"
	var b=packet.body
	match packet.kind:
		"hello":
			if not keys(b,["client_build","profile"],["client_build","profile","resume_token"]) or not text(b.client_build,1,40) or not profile(b.profile):return "BAD_PACKET"
			if b.has("resume_token") and not hex_token(b.resume_token):return "BAD_PACKET"
		"create_room":
			if not options(b):return "BAD_PACKET"
		"join_room":
			if not keys(b,["code"]) or not text(b.code,6,6):return "BAD_PACKET"
			for c in b.code:
				if not c in CODES:return "BAD_PACKET"
		"join_decision":
			if not keys(b,["lobby_revision","applicant_id","accept"]) or not integer(b.lobby_revision) or not identifier(b.applicant_id) or not b.accept is bool:return "BAD_PACKET"
		"configure_room":
			if not keys(b,["lobby_revision","options"]) or not integer(b.lobby_revision) or not options(b.options):return "BAD_PACKET"
		"ready":
			if not keys(b,["lobby_revision","ready"]) or not integer(b.lobby_revision) or not b.ready is bool:return "BAD_PACKET"
		"seat_request","seat_assign":
			var fields=["lobby_revision","seat"] if packet.kind=="seat_request" else ["lobby_revision","seat","subject_id"]
			if not keys(b,fields) or not integer(b.lobby_revision) or not integer(b.seat,0,5):return "BAD_PACKET"
			if b.has("subject_id") and not identifier(b.subject_id):return "BAD_PACKET"
		"start_match":
			if not keys(b,["lobby_revision"]) or not integer(b.lobby_revision):return "BAD_PACKET"
		"action":
			if not keys(b,["command_id","match_id","expected_revision","action"]) or not identifier(b.command_id) or not hex_token(b.match_id,16) or not integer(b.expected_revision):return "BAD_PACKET"
			if not keys(b.action,["type","payload"]) or not b.action.type in ACTIONS:return "BAD_PACKET"
			if b.action.type=="play":
				if not keys(b.action.payload,["token"],["token","covered"]) or not text(b.action.payload.token,1,80):return "BAD_PACKET"
				if b.action.payload.has("covered") and not b.action.payload.covered is bool:return "BAD_PACKET"
			elif not keys(b.action.payload,[]):return "BAD_PACKET"
		"signal_begin":
			if not keys(b,["match_id","expected_revision","signal"]) or not hex_token(b.match_id,16) or not integer(b.expected_revision) or not b.signal in SIGNALS:return "BAD_PACKET"
		"signal_end":
			if not keys(b,["match_id","challenge_id"]) or not hex_token(b.match_id,16) or not identifier(b.challenge_id):return "BAD_PACKET"
		"barrier_ack":
			if not keys(b,["match_id","revision","barrier_id"]) or not hex_token(b.match_id,16) or not integer(b.revision) or not identifier(b.barrier_id):return "BAD_PACKET"
		"opinion":
			if not keys(b,["match_id","revision","decision"]) or not hex_token(b.match_id,16) or not integer(b.revision) or not b.decision in ["accept","fold","counter"]:return "BAD_PACKET"
		"rematch":
			if not keys(b,["match_id"]) or not hex_token(b.match_id,16):return "BAD_PACKET"
		"pong","ping":
			if not keys(b,["nonce"]) or not identifier(b.nonce):return "BAD_PACKET"
		"emote":
			if not keys(b,["gesture"]) or not b.gesture in ["knock","smile"]:return "BAD_PACKET"
		"sync","leave","signal_cancel":
			if not b.is_empty():return "BAD_PACKET"
		_:return "BAD_PACKET"
	return ""

static func endpoint(value: String, allow_lan: bool=false) -> bool:
	if value.length()>300 or value.contains("@") or value.contains("?") or value.contains("#") or value.contains(" "):return false
	if not value.ends_with("/v1/ws"):return false
	if value.begins_with("wss://"):
		return value.trim_prefix("wss://").split("/")[0]!=""
	if not allow_lan or not value.begins_with("ws://"):return false
	var host=value.trim_prefix("ws://").split("/")[0].split(":")[0]
	if host=="localhost" or host=="127.0.0.1":return true
	if not host.is_valid_ip_address():return false
	var parts=host.split(".")
	return parts.size()==4 and (parts[0]=="10" or (parts[0]=="192" and parts[1]=="168") or (parts[0]=="172" and int(parts[1])>=16 and int(parts[1])<=31))

static func packet(kind: String, body: Dictionary, request_id: String="") -> Dictionary:
	return {"protocol":VERSION,"kind":kind,"request_id":request_id,"body":body}

static func error_text(code: String) -> String:
	return {"BAD_PACKET":"Mensagem inválida.","VERSION_MISMATCH":"Atualize o jogo para entrar neste servidor.","ROOM_NOT_FOUND":"Essa sala não existe ou já encerrou.","ROOM_FULL":"A sala está cheia.","JOIN_PENDING":"Aguarde a aprovação do organizador.","NOT_AUTHORIZED":"Essa ação não está disponível para você.","STALE_REVISION":"A mesa mudou. Confira e tente novamente.","ILLEGAL_ACTION":"A jogada não é permitida agora.","ID_REUSED":"A tentativa de jogada já foi usada.","RATE_LIMITED":"Muitas mensagens seguidas. Aguarde um instante.","MATCH_INTERRUPTED":"A sala foi interrompida, sem vencedor.","NOT_READY":"Todos precisam estar prontos.","BARRIER_PENDING":"Aguarde todos acompanharem a distribuição ou o resultado.","SIGNAL_EXPIRED":"Comece o sinal novamente.","RESUME_EXPIRED":"Sua sessão expirou. Entre em uma nova sala.","SERVICE_FULL":"O servidor está cheio. Tente mais tarde.","STORAGE_FAILED":"O servidor não conseguiu preservar a partida."}.get(code,"Não foi possível concluir agora.")
