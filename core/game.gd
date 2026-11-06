extends RefCounted
## Domínio puro: não depende de cena, animação, rede ou interface.
const Signals = preload("res://core/signal_rules.gd")
const Cards = preload("res://core/cards.gd")
const STEPS = [1, 3, 6, 9, 12] # Compatibilidade com ferramentas antigas; use steps().
const Variants=preload("res://core/variants.gd")
var s: Dictionary = {}
var qa_rng = RandomNumberGenerator.new()
var deterministic = false
var initial_seed: int = -1
var crypto = Crypto.new()
var command_log: Array = []

func new_match(seed_value: int = -1, scores: Array = [0, 0], dealer: int = -1, player_count: int = 4, deck_mode: String = "sujo", variant: String = "paulista") -> void:
	assert(player_count in [2, 4, 6])
	assert(deck_mode in ["limpo", "sujo"])
	assert(Variants.NAMES.has(variant))
	if variant!="paulista":deck_mode="sujo"
	initial_seed = seed_value
	deterministic = seed_value >= 0
	if deterministic: qa_rng.seed = seed_value
	command_log.clear()
	s = {"variant":variant,"maluco_bag":[],"schema": 3, "ruleset": "paulista_v3" if variant=="paulista" else variant+"_v1", "ruleset_version": 3 if variant=="paulista" else 1, "player_count": player_count, "deck_mode": deck_mode,
		"revision": 0, "match_id": crypto.generate_random_bytes(8).hex_encode(),
		"scores": scores.duplicate(), "dealer": _random_below(player_count) if dealer < 0 else dealer % player_count,
		"hand_no": 0, "history": [], "seen": {}, "qa": seed_value >= 0,
		"public_actions": []}
	_deal(false)

func _random_below(n: int) -> int:
	if deterministic: return qa_rng.randi_range(0, n - 1)
	# Rejection sampling: sem viés de módulo para a distribuição.
	var ceiling: int = 4294967296 - (4294967296 % n)
	while true:
		var number: int = crypto.generate_random_bytes(4).decode_u32(0)
		if number < ceiling: return number % n
	return 0

func _deal(rotate: bool = true) -> void:
	if rotate: s.dealer = (int(s.dealer) + 1) % int(s.player_count)
	s.hand_no = int(s.hand_no) + 1
	s.rule="normal"
	if s.variant=="maluco":
		if s.maluco_bag.is_empty():
			s.maluco_bag=Variants.CHAOS.duplicate()
			for i in range(s.maluco_bag.size()-1,0,-1):
				var j=_random_below(i+1);var tmp=s.maluco_bag[i];s.maluco_bag[i]=s.maluco_bag[j];s.maluco_bag[j]=tmp
			if s.maluco_bag.back()==s.get("previous_rule",""):
				var tmp=s.maluco_bag[0];s.maluco_bag[0]=s.maluco_bag.back();s.maluco_bag[s.maluco_bag.size()-1]=tmp
		s.rule=s.maluco_bag.pop_back();s.previous_rule=s.rule
	s.hand_variant="mineiro" if s.variant=="mineiro" or s.rule=="mineiro" else "paulista"
	s.vira_revealed=s.rule!="surpresa"
	var shuffled = Cards.deck(str(s.deck_mode))
	for i in range(shuffled.size() - 1, 0, -1):
		var j = _random_below(i + 1)
		var temp = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = temp
	var hands = []
	for i in range(int(s.player_count)): hands.append([])
	var pointer = 0
	for round_i in range(3):
		for offset in range(1, int(s.player_count) + 1):
			var seat = (int(s.dealer) + offset) % int(s.player_count)
			hands[seat].append({"token": "h%d-s%d-c%d" % [s.hand_no, seat, round_i], "card": shuffled[pointer]})
			pointer += 1
	s.hands = hands
	s.vira = shuffled[int(s.player_count) * 3] if s.hand_variant=="paulista" else -1
	s.turn = (int(s.dealer) + 1) % int(s.player_count)
	s.leader = s.turn
	s.hand_leader = s.turn
	s.trick = []
	s.rounds = []
	s.round_records = []
	s.accepted = int(steps()[0])
	s.offer = 0
	s.offer_team = -1
	s.offer_seat = -1
	s.last_raise_team = -1
	s.resume_seat = s.turn
	var limit=Variants.special_limit(str(s.variant))
	s.iron = s.variant!="maluco" and int(s.scores[0])==limit and int(s.scores[1])==limit
	s.eleven_team = -1
	if not s.iron and s.variant!="maluco":
		if int(s.scores[0]) == limit: s.eleven_team = 0
		elif int(s.scores[1]) == limit: s.eleven_team = 1
	s.phase = "eleven" if int(s.eleven_team) >= 0 else "play"
	s.hand_winner = -2
	s.awarded = 0
	s.reason = "Mão de ferro: escolha sem ver suas cartas." if s.iron else ("Manilhas fixas. Boa mão!" if s.hand_variant=="mineiro" else "Leia a vira e jogue com sua equipe.")
	s.scored = false
	s.public_actions = []
	s.signals = []
	s.signal_counts = []
	for i in range(int(s.player_count)): s.signal_counts.append(0)

func steps() -> Array:
	return Variants.steps(str(s.get("hand_variant","paulista")))

func next_bid() -> int:
	return Variants.next_value(int(s.accepted),str(s.get("hand_variant","paulista")))

func can_raise(seat: int) -> bool:
	return s.get("phase", "") == "play" and int(s.turn) == seat and not s.iron and int(s.eleven_team) < 0 and int(s.accepted) < 12 and int(s.last_raise_team) != seat % 2

func can_concede(seat: int) -> bool:
	return s.get("phase", "") == "play" and int(s.turn) == seat and not s.iron

func can_signal(seat: int) -> bool:
	return s.get("phase", "") in ["play", "offer"] and not s.iron and seat >= 0 and seat < int(s.player_count) and s.player_count > 2

func can_cover(seat: int) -> bool:
	return s.phase == "play" and int(s.turn) == seat and not s.iron and s.rule not in ["escuro","uma_oculta"] and s.rounds.size() >= 1 and s.trick.size() > 0

func team_seats(team: int) -> Array:
	var seats = []
	if team < 0: return seats
	for seat in range(int(s.player_count)):
		if seat % 2 == team: seats.append(seat)
	return seats

func response_seats() -> Array:
	var team = 1 - int(s.offer_team) if s.phase == "offer" else (int(s.eleven_team) if s.phase == "eleven" else -1)
	return team_seats(team)

func command(actor: int, kind: String, payload: Dictionary = {}, command_id: String = "", expected_revision: int = -1) -> Dictionary:
	if s.is_empty(): return {"ok": false, "error": "Partida não iniciada."}
	if command_id != "" and s.seen.has(command_id):
		return {"ok": true, "duplicate": true, "revision": s.revision}
	if expected_revision >= 0 and expected_revision != int(s.revision): return {"ok": false, "error": "A partida mudou. Tente novamente."}
	var error = _validate(actor, kind, payload)
	if error != "": return {"ok": false, "error": error}
	var event = {"type": kind, "actor": actor}
	match kind:
		"play":
			var index = _find_card(actor, str(payload.get("token", "")))
			var chosen = s.hands[actor][index]
			var covered = bool(payload.get("covered", false))
			s.hands[actor].remove_at(index)
			s.trick.append({"seat": actor, "card": int(chosen.card), "covered": covered, "token": str(chosen.token)})
			event["covered"] = covered
			# Nunca registrar carta coberta / seleção de ferro como informação pública.
			if not covered and not s.iron: event["card"] = chosen.card
			if s.trick.size() == int(s.player_count): _end_trick()
			else: s.turn = (actor + 1) % int(s.player_count)
		"raise":
			s.resume_seat = s.turn
			s.offer = next_bid()
			s.offer_team = actor % 2
			s.offer_seat = actor
			s.last_raise_team = actor % 2
			s.phase = "offer"
			event["offer"] = s.offer
		"accept":
			s.accepted = s.offer
			s.offer = 0
			s.phase = "play"
			s.turn = s.resume_seat
		"counter":
			s.accepted = s.offer
			s.offer = Variants.next_value(int(s.offer),str(s.hand_variant))
			s.offer_team = actor % 2
			s.offer_seat = actor
			s.last_raise_team = actor % 2
			event["offer"] = s.offer
		"concede":
			_finish_hand(1 - actor % 2, int(s.accepted), "A equipe abriu mão da disputa. Rival recebe %d." % s.accepted)
		"signal":
			var exposure = Signals.exposure(int(payload.timing_ms))
			var tell = {"sender": actor, "team": actor % 2, "kind": str(payload.kind), "visibility": exposure, "hand": int(s.hand_no), "round": s.rounds.size()}
			s.signals.append(tell)
			s.signal_counts[actor] = int(s.signal_counts[actor]) + 1
			event["signal"] = tell.duplicate(true)
			if exposure == "private": event["private_team"] = actor % 2
		"fold":
			_finish_hand(int(s.offer_team), int(s.accepted), "A equipe adversária correu. Vale o último valor aceito: %d." % s.accepted)
		"eleven_yes":
			s.accepted = 4 if s.hand_variant=="mineiro" else 3
			s.phase = "play"
			s.reason = "Mão especial aceita. Vale %d; sem aumentos."%s.accepted
		"eleven_no":
			_finish_hand(1-int(s.eleven_team),int(steps()[0]),"A equipe correu na mão especial. Rivais recebem %d."%steps()[0])
		"advance":
			if s.phase == "round_over":
				s.trick = []
				s.turn = s.leader
				s.phase = "play"
			else: _deal()
	s.revision = int(s.revision) + 1
	if command_id != "": s.seen[command_id] = s.revision
	event["revision"] = s.revision
	s.public_actions.append(event)
	command_log.append({"actor": actor, "type": kind, "payload": payload.duplicate(true), "id": command_id})
	return {"ok": true, "revision": s.revision, "event": event}

func _find_card(seat: int, token: String) -> int:
	for i in range(s.hands[seat].size()):
		if str(s.hands[seat][i].token) == token: return i
	return -1

func _validate(actor: int, kind: String, payload: Dictionary) -> String:
	if s.phase == "match_over": return "A partida acabou. Peça revanche para jogar de novo."
	if kind == "advance":
		if actor != -1 or s.phase not in ["round_over", "hand_over"]: return "Não é hora de continuar."
		return ""
	if actor < 0 or actor >= int(s.player_count): return "Lugar inválido."
	match kind:
		"play":
			if s.phase != "play" or int(s.turn) != actor: return "Aguarde sua vez."
			if _find_card(actor, str(payload.get("token", ""))) < 0: return "Essa carta não está na sua mão."
			if bool(payload.get("covered", false)) and not can_cover(actor): return "Só cubra após a primeira rodada e sem abrir a rodada."
		"concede":
			if not can_concede(actor): return "Só pode correr na sua vez, fora da mão de ferro."
		"signal":
			if not can_signal(actor): return "Sinal indisponível: sem parceiros, mão de ferro ou disputa encerrada."
			if not Signals.KINDS.has(str(payload.get("kind", ""))): return "Sinal desconhecido."
			if not payload.get("timing_ms", null) is int or int(payload.timing_ms) < 0 or int(payload.timing_ms) > 10000: return "Tempo de sinal inválido."
		"raise":
			if not can_raise(actor): return "O aumento não é permitido agora."
		"accept", "counter", "fold":
			if s.phase != "offer" or actor % 2 == int(s.offer_team): return "A equipe rival deve responder."
			if kind == "counter" and int(s.offer) >= 12: return "Doze é o último aumento."
		"eleven_yes", "eleven_no":
			if s.phase != "eleven" or actor % 2 != int(s.eleven_team): return "Apenas a dupla com onze decide."
		_: return "Ação desconhecida."
	return ""

func _end_trick() -> void:
	if s.rule=="surpresa" and not s.vira_revealed:
		s.rounds.append(-2)
		s.round_records.append({"winner":-2,"plays":_visible_trick(true)})
		s.leader=int(s.hand_leader)
		if s.rounds.size()<3:
			s.phase="round_over";s.reason="Resultado pendente. A vira aparece após as três rodadas.";return
		s.vira_revealed=true;s.rounds.clear()
		for record in s.round_records:
			var pending=Cards.trick_result(record.plays,int(s.vira),int(s.hand_leader),str(s.deck_mode),str(s.hand_variant))
			record.winner=int(pending.team);s.rounds.append(int(pending.team))
		var resolved=Cards.hand_winner(s.rounds)
		_finish_hand(resolved,0 if resolved<0 else int(s.accepted),"Vira revelada! Agora as três rodadas foram resolvidas.")
		return
	var result = Cards.trick_result(s.trick, int(s.vira), int(s.leader), str(s.deck_mode),str(s.hand_variant))
	s.rounds.append(int(result.team))
	s.leader = int(result.leader)
	var visible_plays = _visible_trick(true)
	s.round_records.append({"winner": result.team, "plays": visible_plays})
	var winner = Cards.hand_winner(s.rounds)
	if winner == -2:
		s.phase = "round_over"
		s.reason = "Rodada empatada. Quem abriu começa de novo." if int(result.team) == -1 else ("Nossa equipe venceu a rodada." if int(result.team) == 0 else "A equipe rival venceu a rodada.")
	elif winner == -1:
		_finish_hand(-1, 0, "Três rodadas empatadas. Ninguém pontua; o carteador avança.")
	else:
		var reason = "Duas rodadas vencidas."
		if s.rounds.has(-1):
			if int(s.rounds[0]) == -1: reason = "A primeira empatou; vale a próxima vitória."
			else: reason = "Houve empate. Vence a equipe que ganhou a primeira."
		elif s.rounds.size() == 3: reason = "Uma rodada para cada equipe; a terceira decidiu."
		_finish_hand(winner, int(s.accepted), reason)

func _finish_hand(team: int, points: int, why: String) -> void:
	if bool(s.scored): return
	s.scored = true
	s.vira_revealed=true
	s.hand_winner = team
	s.awarded = points
	s.reason = why
	if team >= 0: s.scores[team] = int(s.scores[team]) + points
	var record = {"hand": s.hand_no, "winner": team, "points": points, "rounds": s.rounds.duplicate(), "reason": why, "scores": s.scores.duplicate(),"variant":s.variant,"rule":s.rule,"vira":int(s.vira)}
	s.history.append(record)
	s.phase = "match_over" if max(int(s.scores[0]), int(s.scores[1])) >= 12 else "hand_over"

func _visible_trick(reveal_iron: bool = false) -> Array:
	var out = []
	for p in s.trick:
		var visible = not bool(p.covered) and (not s.iron or reveal_iron or s.trick.size() == int(s.player_count))
		out.append({"seat": int(p.seat), "card": int(p.card) if visible else -1, "covered": bool(p.covered), "token": str(p.token)})
	return out

func view(seat: int) -> Dictionary:
	var hands = []
	var ended=s.phase in ["hand_over","match_over"]
	for player in range(int(s.player_count)):
		var allowed = not s.iron and s.rule!="escuro" and (player == seat or (int(s.eleven_team) == seat % 2 and player % 2 == seat % 2))
		var reveal_own=ended and player==seat and s.variant=="maluco" and s.rule in ["escuro","uma_oculta"]
		var visible = []
		for c in s.hands[player]:
			# O token é imutável: retirar cartas da mão não desloca qual é a oculta.
			var hidden=s.rule=="uma_oculta" and str(c.token).ends_with("-c2")
			visible.append({"token":str(c.token),"card":int(c.card) if reveal_own or (allowed and not hidden) else -1})
		hands.append(visible)

	return {"variant":s.variant,"rule":s.rule,"hand_variant":s.hand_variant,"blind":bool(s.iron) or s.rule=="escuro","vira_revealed":bool(s.vira_revealed),"special_limit":Variants.special_limit(str(s.variant)),"base_points":int(steps()[0]),"special_points":4 if s.hand_variant=="mineiro" else 3,"next_bid":next_bid(),"bid_steps":steps().duplicate(),"hand_leader":int(s.hand_leader),"deck_mode": str(s.deck_mode), "signals": _signals_for(seat), "can_signal": can_signal(seat), "can_concede": can_concede(seat), "signals_left": -1, "signals_unlimited": true, "signals_sent": int(s.signal_counts[seat]), "player_count": int(s.player_count), "ruleset": s.ruleset, "revision": int(s.revision), "hand_no": int(s.hand_no), "seat": seat,
		"phase": str(s.phase), "scores": s.scores.duplicate(), "dealer": int(s.dealer), "turn": int(s.turn),
		"hands": hands, "vira": int(s.vira) if s.vira_revealed else -1, "iron": bool(s.iron), "eleven_team": int(s.eleven_team),
		"accepted": int(s.accepted), "offer": int(s.offer), "offer_team": int(s.offer_team), "offer_seat": int(s.offer_seat),
		"rounds": s.rounds.duplicate(), "trick": _visible_trick(), "round_records": s.round_records.duplicate(true),
		"history": s.history.duplicate(true), "actions": _actions_for(seat),
		"reason": str(s.reason), "hand_winner": int(s.hand_winner), "awarded": int(s.awarded),
		"can_play": s.phase == "play" and int(s.turn) == seat, "can_raise": can_raise(seat), "can_cover": can_cover(seat),
		"can_respond": s.phase == "offer" and int(s.offer_team) != seat % 2,
		"can_decide_eleven": s.phase == "eleven" and int(s.eleven_team) == seat % 2, "qa": bool(s.qa)}

func snapshot() -> Dictionary:
	return {"schema": 3, "state": s.duplicate(true), "deterministic": deterministic, "initial_seed": str(initial_seed), "rng_state": str(qa_rng.state), "commands": command_log.duplicate(true)}

func restore(data: Dictionary) -> bool:
	if int(data.get("schema", 0)) not in [1, 2, 3] or not data.has("state"): return false
	var state = data.state
	if state.get("ruleset", "") not in ["paulista_v1", "paulista_v2", "paulista_v3","mineiro_v1","maluco_v1"] or state.get("phase", "") not in ["play", "offer", "eleven", "round_over", "hand_over", "match_over"]: return false
	var n = int(state.get("player_count", 4))
	if n not in [2, 4, 6] or state.get("hands", []).size() != n or state.get("scores", []).size() != 2: return false
	if str(state.get("deck_mode", "sujo")) not in ["limpo", "sujo"]: return false
	if state.has("signal_counts") and state.signal_counts.size() != n: return false
	s = _normalize_numbers(state)
	s.player_count = n
	s.deck_mode = str(s.get("deck_mode", "sujo"))
	if not s.has("signals"): s.signals = []
	if not s.has("signal_counts"):
		s.signal_counts = []
		for i in range(n): s.signal_counts.append(0)
	s.variant=str(s.get("variant","paulista"))
	if not Variants.NAMES.has(s.variant):return false
	s.rule=str(s.get("rule","normal"))
	if s.rule!="normal" and not Variants.CHAOS.has(s.rule):return false
	s.hand_variant=str(s.get("hand_variant","paulista"))
	if s.hand_variant not in ["paulista","mineiro"]:return false
	if s.variant!="paulista" and s.deck_mode!="sujo":return false
	s.vira_revealed=bool(s.get("vira_revealed",true))
	s.hand_leader=int(s.get("hand_leader",s.leader))
	if not s.has("maluco_bag"):s.maluco_bag=[]
	for rule in s.maluco_bag:
		if not Variants.CHAOS.has(rule):return false
	s.schema = 3
	s.ruleset = "paulista_v3" if s.variant=="paulista" else s.variant+"_v1"
	s.ruleset_version = 3 if s.variant=="paulista" else 1
	deterministic = bool(data.get("deterministic", false))
	initial_seed = int(data.get("initial_seed", "-1"))
	qa_rng.state = int(data.get("rng_state", "0"))
	command_log = _normalize_numbers(data.get("commands", []))
	return true

func force_scenario(kind: String) -> void:
	# Exclusivo do laboratório de QA. Sempre cria uma partida marcada como teste.
	new_match(444, [11, 11] if kind == "ferro" else ([11, 8] if kind == "onze" else [0, 0]), 3)
	if kind == "parda":
		s.vira = Cards.card("4", 0)
		var cards = [[Cards.card("3", 0), Cards.card("2", 0), Cards.card("A", 0)], [Cards.card("3", 1), Cards.card("2", 1), Cards.card("A", 1)], [Cards.card("3", 2), Cards.card("2", 2), Cards.card("A", 2)], [Cards.card("3", 3), Cards.card("2", 3), Cards.card("A", 3)]]
		for seat in range(4):
			for j in range(3): s.hands[seat][j].card = cards[seat][j]
		s.reason = "Laboratório: cartas altas iguais entre duplas para explorar empates."

func _normalize_numbers(value):
	# JSON não conserva o tipo inteiro. O domínio usa somente números inteiros.
	if value is float: return int(value)
	if value is Dictionary:
		var result = {}
		for k in value: result[k] = _normalize_numbers(value[k])
		return result
	if value is Array:
		var result = []
		for item in value: result.append(_normalize_numbers(item))
		return result
	return value

func _signals_for(seat: int) -> Array:
	var visible = []
	for tell in s.signals:
		if tell.visibility == "public" or int(tell.team) == seat % 2: visible.append(tell.duplicate(true))
	return visible

func _actions_for(seat: int) -> Array:
	var visible = []
	for event in s.public_actions:
		if not event.has("private_team") or int(event.private_team) == seat % 2:
			var item = event.duplicate(true)
			item.erase("private_team")
			visible.append(item)
	return visible
