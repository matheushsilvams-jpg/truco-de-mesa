extends RefCounted
const Protocol=preload("res://network/protocol.gd")
const Room=preload("res://server/room.gd")
const Projector=preload("res://server/projector.gd")
var listener=TCPServer.new()
var peers: Dictionary={}
var sessions: Dictionary={}
var token_sessions: Dictionary={}
var rooms: Dictionary={}
var crypto=Crypto.new()
var next_peer=1
var clock=0
var storage_failed=false
var config={"max_rooms":3,"max_peers":48,"msg_rate":10.0,"burst":20.0,"handshake_ms":10000,"presence_ms":45000,"reservation_ms":90000,"heartbeat_ms":15000,"bot_ms":800,"idle_ms":1200000}
var metrics={"commands":0,"rejected":0,"bytes_out":0,"connections":0,"bot_ms_max":0.0}

func start(port: int=10000,bind: String="0.0.0.0",overrides: Dictionary={}) -> int:
	for key in overrides:
		if config.has(key):config[key]=overrides[key]
	clock=Time.get_ticks_msec()
	return listener.listen(port,bind)
func port() -> int:return listener.get_local_port()
func stop():
	for id in peers:peers[id].socket.close(1001,"Servidor encerrando")
	listener.stop();peers.clear()
func tick(now: int=-1):
	clock=Time.get_ticks_msec() if now<0 else now
	while listener.is_connection_available():
		var stream=listener.take_connection()
		if peers.size()>=int(config.max_peers):stream.disconnect_from_host();continue
		var socket=WebSocketPeer.new();socket.inbound_buffer_size=32768;socket.outbound_buffer_size=262144;socket.max_queued_packets=64
		if socket.accept_stream(stream)!=OK:continue
		peers[next_peer]={"socket":socket,"sid":"","created":clock,"last":clock,"open":false,"tokens":float(config.burst),"rate_at":clock,"bad":0,"ping":"","ping_at":clock}
		next_peer+=1;metrics.connections+=1
	for id in peers.keys():
		if not peers.has(id):continue
		var p=peers[id];var socket=p.socket;socket.poll()
		if socket.get_ready_state()==WebSocketPeer.STATE_CLOSED:_disconnect(id);continue
		if socket.get_ready_state()!=WebSocketPeer.STATE_OPEN:
			if clock-int(p.created)>int(config.handshake_ms):_disconnect(id)
			continue
		if not p.open:
			p.open=true;socket.set_no_delay(true)
			var requested=socket.get_requested_url();var path=requested
			if requested.contains("://"):
				var start=requested.find("/",requested.find("://")+3);path=requested.substr(start) if start>=0 else "/"
			if path!="/v1/ws":socket.close(1008,"Caminho inválido");continue
		if p.sid=="" and clock-int(p.created)>int(config.handshake_ms):socket.close(1008,"Identifique sua sessão");continue
		var budget=8
		while budget>0 and socket.get_available_packet_count()>0:
			budget-=1
			var raw=socket.get_packet()
			if not socket.was_string_packet() or raw.size()>Protocol.MAX_CLIENT_BYTES:socket.close(1009,"Mensagem grande ou inválida");break
			p.tokens=minf(float(config.burst),float(p.tokens)+maxi(0,clock-int(p.rate_at))*float(config.msg_rate)/1000.0);p.rate_at=clock
			if p.tokens<1:_error(id,"","RATE_LIMITED");continue
			p.tokens-=1
			var packet=JSON.parse_string(raw.get_string_from_utf8());var error=Protocol.validate(packet)
			if error!="":
				var request=str(packet.get("request_id","")) if packet is Dictionary and Protocol.identifier(packet.get("request_id","")) else ""
				_error(id,request,error);p.bad+=1
				if int(p.bad)>=3:socket.close(1008,"Mensagens inválidas")
				continue
			p.last=clock
			_handle(id,packet)
		if p.sid!="" and sessions.has(p.sid):
			if clock-int(p.last)>int(config.presence_ms):socket.close(1001,"Sem contato");_disconnect(id);continue
			if clock-int(p.ping_at)>=int(config.heartbeat_ms):_ping(id)
	for room in rooms.values():
		_check_presence(room)
		if room.game!=null and not room.suspended and not room.interrupted and room.barrier.is_empty() and room.game.s.phase!="match_over":_bot(room)
		if clock-int(room.last_activity)>int(config.idle_ms) and room.humans().is_empty():rooms.erase(room.code)
	for sid in sessions.keys():
		if int(sessions[sid].peer)<0 and sessions[sid].room=="" and clock-int(sessions[sid].disconnected)>3600000:
			token_sessions.erase(sessions[sid].token_hash);sessions.erase(sid)

func _send(id: int,kind: String,body: Dictionary,request_id: String=""):
	if not peers.has(id):return
	var text=JSON.stringify(Protocol.packet(kind,body,request_id));var p=peers[id]
	if text.to_utf8_buffer().size()>Protocol.MAX_SERVER_BYTES or p.socket.get_current_outbound_buffered_amount()>262144:
		p.socket.close(1009,"Cliente não acompanha a mesa");return
	if p.socket.send_text(text)!=OK:p.socket.close(1011,"Falha de envio")
	metrics.bytes_out+=text.to_utf8_buffer().size()
func _error(id: int,request: String,code: String):
	metrics.rejected+=1;_send(id,"error",{"code":code,"message":Protocol.error_text(code)},request)
func _ack(id: int,request: String,body: Dictionary={}):_send(id,"ack",body,request)
func _ping(id: int):
	var p=peers[id];p.ping=crypto.generate_random_bytes(16).hex_encode();p.ping_at=clock
	_send(id,"server_ping",{"nonce":p.ping})
func _disconnect(id: int):
	if not peers.has(id):return
	var sid=peers[id].sid;peers[id].socket.close();peers.erase(id)
	if sid!="" and sessions.has(sid) and int(sessions[sid].peer)==id:
		var s=sessions[sid];s.peer=-1;s.disconnected=clock;s.challenge={}
		if rooms.has(s.room):
			var room=rooms[s.room]
			if room.seat_of(sid)>=0 and room.game!=null:room.suspended=true
			elif room.game==null:room.reset_ready()
			_publish(room)
func _new_code() -> String:
	while true:
		var code=""
		for b in crypto.generate_random_bytes(6):code+=Protocol.CODES[int(b)&31]
		if not rooms.has(code):return code
	return ""

func _handle(id: int,packet: Dictionary):
	var kind=str(packet.kind);var request=str(packet.request_id);var b=packet.body
	if kind=="hello":_hello(id,request,b);return
	var p=peers[id]
	if p.sid=="" or not sessions.has(p.sid):_error(id,request,"NOT_AUTHORIZED");return
	var s=sessions[p.sid]
	if kind=="pong":
		if b.nonce==p.ping:
			var rtt=clampi(clock-int(p.ping_at),0,300);s.rtt=rtt if int(s.rtt)<0 else mini(int(s.rtt),rtt);p.ping=""
		return
	if kind=="ping":_send(id,"pong",b,request);return
	if kind=="leave":_leave(s);_ack(id,request);_send(id,"room_left",{});return
	if kind=="create_room":_create(id,request,s,b);return
	if kind=="join_room":_join(id,request,s,str(b.code));return
	if s.room=="" or not rooms.has(s.room):_error(id,request,"ROOM_NOT_FOUND");return
	var room=rooms[s.room];room.last_activity=clock
	if kind=="sync":_ack(id,request);_publish(room);return
	if room.game==null:
		_lobby(id,request,s,room,kind,b);return
	var seat=room.seat_of(s.id)
	if seat<0:_error(id,request,"NOT_AUTHORIZED");return
	if kind=="rematch":
		if room.interrupted:_error(id,request,"MATCH_INTERRUPTED");return
		if str(b.match_id)!=str(room.game.s.match_id) or room.game.s.phase!="match_over" or room.suspended:_error(id,request,"NOT_AUTHORIZED");return
		for person in room.players:
			if person.sid=="" and not room.options.bots:_error(id,request,"NOT_READY");return
		room.rematch_votes[s.id]=true
		if room.rematch_votes.size()==room.humans().size():room.begin_match();room.bot_at=clock+int(config.bot_ms)
		_ack(id,request);_publish(room);return
	if kind=="action":_action(id,request,s,room,seat,b);return
	if room.interrupted:_error(id,request,"MATCH_INTERRUPTED");return
	if room.suspended:_error(id,request,"NOT_AUTHORIZED");return
	if kind=="barrier_ack":
		if room.barrier.is_empty() or b.barrier_id!=room.barrier.id or str(b.match_id)!=str(room.game.s.match_id) or int(b.revision)!=int(room.game.s.revision):_error(id,request,"STALE_REVISION");return
		room.barrier_acks[s.id]=true;_advance_barrier(room);_ack(id,request);_publish(room);return
	if kind=="opinion":
		if str(b.match_id)!=str(room.game.s.match_id) or int(b.revision)!=int(room.game.s.revision) or room.game.s.phase!="offer" or seat%2==int(room.game.s.offer_team):_error(id,request,"NOT_AUTHORIZED");return
		room.opinions[str(seat)]=str(b.decision);_ack(id,request);_publish(room);return
	if kind=="signal_cancel":s.challenge={};_ack(id,request);return
	if kind=="signal_begin":_signal_begin(id,request,s,room,seat,b);return
	if kind=="signal_end":_signal_end(id,request,s,room,seat,b);return
	if kind=="emote":
		if clock-int(s.emote_at)<1500:_error(id,request,"RATE_LIMITED");return
		s.emote_at=clock
		for other in room.humans():_send(int(sessions[other].peer),"emote",{"seat":seat,"gesture":b.gesture})
		_ack(id,request);return
	_error(id,request,"NOT_AUTHORIZED")

func _hello(id: int,request: String,b: Dictionary):
	var p=peers[id]
	if p.sid!="":_error(id,request,"NOT_AUTHORIZED");return
	if not str(b.client_build).begins_with("0.4."):_error(id,request,"VERSION_MISMATCH");return
	var token=str(b.get("resume_token",""));var sid="";var resumed=false
	if token!="":
		var hash_value=token.sha256_text()
		if not token_sessions.has(hash_value):_error(id,request,"RESUME_EXPIRED");return
		sid=token_sessions[hash_value];resumed=true
		var old=int(sessions[sid].peer)
		if old>=0 and peers.has(old):peers[old].sid="";peers[old].socket.close(1000,"Sessão retomada em outra conexão");peers.erase(old)
	else:
		if sessions.size()>=96:_error(id,request,"SERVICE_FULL");return
		token=crypto.generate_random_bytes(32).hex_encode();sid=crypto.generate_random_bytes(16).hex_encode()
		sessions[sid]={"id":sid,"token_hash":token.sha256_text(),"peer":id,"room":"","profile":{},"disconnected":clock,"rtt":-1,"challenge":{},"signal_at":-10000,"signals_done":{},"dedup":{},"emote_at":-10000}
		token_sessions[token.sha256_text()]=sid
	var s=sessions[sid];s.peer=id;s.profile={"nickname":Protocol.clean_name(str(b.profile.nickname)),"avatar":int(b.profile.avatar)};p.sid=sid;p.last=clock
	_send(id,"welcome",{"session_id":sid,"resume_token":token,"resumed":resumed,"build":Protocol.BUILD},request);_ping(id)
	if rooms.has(s.room):
		var room=rooms[s.room];var seat=room.seat_of(sid)
		if seat>=0:room.players[seat].profile=s.profile.duplicate()
		_check_presence(room);_publish(room)
	else:s.room=""

func _create(id: int,request: String,s: Dictionary,b: Dictionary):
	if s.room!="":_error(id,request,"NOT_AUTHORIZED");return
	if rooms.size()>=int(config.max_rooms):_error(id,request,"SERVICE_FULL");return
	var room=Room.new(_new_code(),s.id,{"players":int(b.players),"variant":b.variant,"deck_mode":b.deck_mode,"bots":b.bots})
	room.players[0]={"sid":s.id,"profile":s.profile.duplicate(),"ready":false,"bot":false};room.last_activity=clock
	rooms[room.code]=room;s.room=room.code;_ack(id,request);_publish(room)
func _join(id: int,request: String,s: Dictionary,code: String):
	if s.room!="":_error(id,request,"NOT_AUTHORIZED");return
	if not rooms.has(code):_error(id,request,"ROOM_NOT_FOUND");return
	var room=rooms[code]
	if room.game!=null or room.empty_seat()<0 or room.pending.size()>=6:_error(id,request,"ROOM_FULL");return
	room.pending.append(s.id);s.room=code;room.last_activity=clock;_ack(id,request);_publish(room)
func _lobby(id: int,request: String,s: Dictionary,room,kind: String,b: Dictionary):
	if kind=="join_decision":
		if s.id!=room.owner or not room.pending.has(b.applicant_id):_error(id,request,"NOT_AUTHORIZED");return
		if int(b.lobby_revision)!=room.lobby_revision:_error(id,request,"STALE_REVISION");_publish(room);return
		var candidate=sessions.get(b.applicant_id,{})
		if candidate.is_empty():_error(id,request,"NOT_AUTHORIZED");return
		var place=room.empty_seat()
		if b.accept and place<0:_error(id,request,"ROOM_FULL");return
		room.pending.erase(b.applicant_id)
		if b.accept:
			room.players[place]={"sid":candidate.id,"profile":candidate.profile.duplicate(),"ready":false,"bot":false};room.reset_ready()
		else:candidate.room="";_send(int(candidate.peer),"room_left",{});_error(int(candidate.peer),"","NOT_AUTHORIZED")
	elif kind in ["ready","configure_room","seat_request","seat_assign","start_match"]:
		if not b.has("lobby_revision") or int(b.lobby_revision)!=room.lobby_revision:_error(id,request,"STALE_REVISION");_publish(room);return
		var seat=room.seat_of(s.id)
		if seat<0:_error(id,request,"NOT_AUTHORIZED");return
		if kind=="ready":room.players[seat].ready=b.ready
		elif kind=="configure_room":
			if s.id!=room.owner:_error(id,request,"NOT_AUTHORIZED");return
			if int(b.options.players)<room.humans().size():_error(id,request,"ROOM_FULL");return
			var occupied=[]
			for person in room.players:
				if person.sid!="":occupied.append(person)
			while occupied.size()<int(b.options.players):occupied.append({"sid":"","profile":{"nickname":"Lugar livre","avatar":occupied.size()},"ready":false,"bot":false})
			room.players=occupied
			room.options={"players":int(b.options.players),"variant":b.options.variant,"deck_mode":b.options.deck_mode,"bots":b.options.bots};room.reset_ready()
		elif kind in ["seat_request","seat_assign"]:
			var target=int(b.seat);var subject=s.id
			if kind=="seat_assign":
				if s.id!=room.owner:_error(id,request,"NOT_AUTHORIZED");return
				subject=str(b.subject_id)
			var source=room.seat_of(subject)
			if source<0 or target>=room.players.size() or (kind=="seat_request" and room.players[target].sid!=""):_error(id,request,"NOT_AUTHORIZED");return
			var previous=room.players[source];room.players[source]=room.players[target];room.players[target]=previous;room.reset_ready()
		elif kind=="start_match":
			if s.id!=room.owner:_error(id,request,"NOT_AUTHORIZED");return
			if not room.pending.is_empty():_error(id,request,"JOIN_PENDING");return
			for person in room.players:
				if person.sid=="" and not room.options.bots:_error(id,request,"NOT_READY");return
				if person.sid!="" and (not person.ready or not _connected(person.sid)):_error(id,request,"NOT_READY");return
			room.begin_match();room.bot_at=clock+int(config.bot_ms)
	else:_error(id,request,"NOT_AUTHORIZED");return
	_ack(id,request);_publish(room)

func _action(id: int,request: String,s: Dictionary,room,seat: int,b: Dictionary):
	if str(b.match_id)!=str(room.game.s.match_id):_error(id,request,"STALE_REVISION");return
	var digest=JSON.stringify(b.action,"",true).sha256_text();var key=str(b.match_id)+":"+str(b.command_id)
	if s.dedup.has(key):
		if s.dedup[key].digest!=digest:_error(id,request,"ID_REUSED");return
		_ack(id,request,{"command_id":b.command_id,"revision":s.dedup[key].revision,"duplicate":true});_publish(room);return
	if storage_failed:_error(id,request,"STORAGE_FAILED");return
	if room.interrupted:_error(id,request,"MATCH_INTERRUPTED");return
	if room.suspended:_error(id,request,"NOT_AUTHORIZED");return
	if not room.barrier.is_empty():_error(id,request,"BARRIER_PENDING");return
	if int(b.expected_revision)!=int(room.game.s.revision):_error(id,request,"STALE_REVISION");_publish(room);return
	# O cache de confirmações é limitado. Um ID antigo nunca vira um comando novo.
	if room.game.s.seen.has(s.id+":"+str(b.command_id)):_error(id,request,"ID_REUSED");_publish(room);return
	var outcome=room.game.command(seat,str(b.action.type),b.action.payload,s.id+":"+str(b.command_id),int(b.expected_revision))
	if not outcome.ok:_error(id,request,"ILLEGAL_ACTION");return
	s.dedup[key]={"digest":digest,"revision":int(outcome.revision)}
	while s.dedup.size()>128:s.dedup.erase(s.dedup.keys()[0])
	metrics.commands+=1;room.after_command(clock,int(config.bot_ms))
	_ack(id,request,{"command_id":b.command_id,"revision":int(outcome.revision),"duplicate":false});_publish(room)
func _signal_begin(id: int,request: String,s: Dictionary,room,seat: int,b: Dictionary):
	if not room.barrier.is_empty() or str(b.match_id)!=str(room.game.s.match_id) or not room.game.can_signal(seat):_error(id,request,"NOT_AUTHORIZED");return
	if int(b.expected_revision)!=int(room.game.s.revision):_error(id,request,"STALE_REVISION");_publish(room);return
	if clock-int(s.signal_at)<500:_error(id,request,"RATE_LIMITED");return
	s.signal_at=clock
	var rtt=maxi(0,int(s.rtt));var lead=120;var challenge_id=crypto.generate_random_bytes(16).hex_encode()
	s.challenge={"id":challenge_id,"kind":str(b.signal),"match_id":b.match_id,"hand":int(room.game.s.hand_no),"start":clock+lead+rtt/2,"compensation":rtt/2}
	_send(id,"signal_challenge",{"challenge_id":challenge_id,"lead_ms":lead},request)
func _signal_end(id: int,request: String,s: Dictionary,room,seat: int,b: Dictionary):
	if s.signals_done.has(b.challenge_id):_ack(id,request,{"duplicate":true});return
	var c=s.challenge;s.challenge={}
	if c.is_empty() or c.id!=b.challenge_id or c.match_id!=b.match_id or int(c.hand)!=int(room.game.s.hand_no) or not room.game.can_signal(seat) or not room.barrier.is_empty():_error(id,request,"SIGNAL_EXPIRED");return
	var elapsed=clock-int(c.start)-int(c.compensation)
	if elapsed<0 or elapsed>10000:_error(id,request,"SIGNAL_EXPIRED");return
	var outcome=room.game.command(seat,"signal",{"kind":c.kind,"timing_ms":int(elapsed)},s.id+":"+str(c.id),int(room.game.s.revision))
	if not outcome.ok:_error(id,request,"ILLEGAL_ACTION");return
	s.signals_done[c.id]=true
	while s.signals_done.size()>32:s.signals_done.erase(s.signals_done.keys()[0])
	metrics.commands+=1;_ack(id,request,{"revision":int(outcome.revision)});_publish(room)
func _advance_barrier(room):
	for sid in room.humans():
		if not room.barrier_acks.has(sid):return
	var kind=str(room.barrier.kind);room.barrier.clear();room.barrier_acks.clear()
	if kind!="deal":
		var result=room.game.command(-1,"advance",{},"server-"+crypto.generate_random_bytes(16).hex_encode(),int(room.game.s.revision))
		if not result.ok:room.interrupted=true;return
		room.after_command(clock,int(config.bot_ms))
		if kind=="hand":room.new_barrier("deal")
	room.bot_at=clock+int(config.bot_ms)
func _connected(sid: String) -> bool:
	return sessions.has(sid) and peers.has(int(sessions[sid].peer)) and peers[int(sessions[sid].peer)].socket.get_ready_state()==WebSocketPeer.STATE_OPEN
func _check_presence(room):
	var paused=false
	for sid in room.humans():
		if not _connected(sid):
			paused=true
			if clock-int(sessions[sid].disconnected)>int(config.reservation_ms):
				if room.game!=null:
					if not room.interrupted:room.interrupted=true;_publish(room)
				else:
					_leave(sessions[sid])
					if not rooms.has(room.code):return
	if room.suspended!=paused:room.suspended=paused;_publish(room)
func _leave(s: Dictionary):
	if not rooms.has(s.room):s.room="";return
	var room=rooms[s.room];room.pending.erase(s.id);var seat=room.seat_of(s.id)
	if seat>=0:
		room.players[seat]={"sid":"","profile":{"nickname":"Lugar livre","avatar":seat},"ready":false,"bot":false}
		if room.game!=null:room.interrupted=true
		else:room.reset_ready()
	s.room="";s.challenge={}
	if room.owner==s.id:
		var humans=room.humans();room.owner=str(humans[0]) if not humans.is_empty() else ""
	if room.humans().is_empty():
		for pending_id in room.pending:
			if sessions.has(pending_id):sessions[pending_id].room="";_send(int(sessions[pending_id].peer),"room_left",{})
		rooms.erase(room.code)
	else:_publish(room)
func _publish(room):
	room.room_revision+=1
	var recipients=room.humans()+room.pending
	for sid in recipients:
		if not sessions.has(sid) or not _connected(sid):continue
		var s=sessions[sid];var seat=room.seat_of(sid);var people=[]
		for person in room.players:
			var p=person.duplicate(true);p.connected=p.bot or (p.sid!="" and _connected(p.sid));people.append(p)
		var body={"code":room.code,"owner":room.owner,"options":room.options.duplicate(),"lobby_revision":room.lobby_revision,"room_revision":room.room_revision,"players":people,"pending":[],"seat":seat,"status":"interrupted" if room.interrupted else ("lobby" if room.game==null else ("finished" if room.game.s.phase=="match_over" else "active")),"suspended":room.suspended,"barrier":room.barrier.duplicate(),"opinions":{},"rematch_ready":room.rematch_votes.has(sid),"rematch_count":room.rematch_votes.size(),"view":{},"match_id":""}
		if sid==room.owner:
			for applicant in room.pending:
				if sessions.has(applicant):body.pending.append({"id":applicant,"profile":sessions[applicant].profile.duplicate()})
		if not room.barrier.is_empty():body.barrier["mine_ready"]=room.barrier_acks.has(sid);body.barrier["waiting"]=room.humans().size()-room.barrier_acks.size()
		if room.game!=null and seat>=0:
			body.view=Projector.for_seat(room.game,seat);body.match_id=str(room.game.s.match_id)
			for opinion_seat in room.opinions:
				if int(opinion_seat)%2==seat%2:body.opinions[opinion_seat]=room.opinions[opinion_seat]
		_send(int(s.peer),"room",body)
func _bot(room):
	if clock<room.bot_at:return
	var game=room.game;var actor=int(game.s.turn) if game.s.phase=="play" else -1
	if game.s.phase in ["offer","eleven"]:
		for candidate in game.response_seats():
			if not room.players[int(candidate)].bot:return
		actor=int(game.response_seats()[0])
	if not room.bots.has(actor):return
	var started=Time.get_ticks_usec();var action=room.bots[actor].decide(game.view(actor));metrics.bot_ms_max=maxf(float(metrics.bot_ms_max),(Time.get_ticks_usec()-started)/1000.0)
	if action.is_empty():return
	var result=game.command(actor,str(action.type),action.get("payload",{}),"bot-"+crypto.generate_random_bytes(16).hex_encode(),int(game.s.revision))
	if result.ok:metrics.commands+=1;room.after_command(clock,int(config.bot_ms));_publish(room)
