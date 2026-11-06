extends RefCounted
## Decide exclusivamente a partir de uma PlayerView. Nunca recebe o motor ou o baralho.
const Cards = preload("res://core/cards.gd")
const Bid=preload("res://ai/bid_evaluator.gd")
var cached_key=-1
var cached_probability=.5
var profile: String = "cauteloso"
var rng = RandomNumberGenerator.new()

func _init(style: String = "cauteloso", seed_value: int = -1) -> void:
	profile = style
	if seed_value >= 0: rng.seed = seed_value
	else: rng.randomize()

func decide(v: Dictionary) -> Dictionary:
	var seat = int(v.seat)
	var hand = v.hands[seat]
	var confidence = _confidence(v)
	var boldness = 0.14 if profile == "pressionador" else (0.045 if profile == "observador" else 0.025)
	if profile == "observador":
		# Histórico é público: reconhece quantas vezes os rivais correram.
		var past_folds = 0.0
		var inspected = 0.0
		for record in v.history.slice(max(0,v.history.size()-12)):
			inspected += 1.0
			if int(record.winner)==seat%2 and str(record.reason).contains("correu"):past_folds+=1.0
		if inspected>0:boldness += 0.12*past_folds/inspected
	if v.can_decide_eleven:
		return {"type": "eleven_yes" if confidence > 0.42 else "eleven_no", "payload": {}}
	if v.can_respond:
		var threshold=Bid.accept_threshold(v,profile)
		if int(v.offer)<12 and confidence>=.82 and rng.randf()<(0.42 if profile=="pressionador" else .23):return {"type":"counter","payload":{}}
		return {"type":"fold" if confidence+rng.randf_range(-.025,.025)<threshold else "accept","payload":{}}
	if not v.can_play or hand.is_empty(): return {}
	if v.get("can_signal",false) and rng.randf()<0.08:
		for c in hand:
			if int(c.card)>=0 and Cards.is_manilha(int(c.card),int(v.vira),str(v.get("deck_mode","sujo")),str(v.get("hand_variant","paulista"))) and not _already_signaled(v,["ouros","espadas","copas","zap"][Cards.suit(int(c.card))]):
				return {"type":"signal","payload":{"kind":["ouros","espadas","copas","zap"][Cards.suit(int(c.card))],"timing_ms":850 if rng.randf()>.12 else 420}}

	if v.can_raise:
		var floor=.66 if profile=="pressionador" else (.75 if profile=="cauteloso" else .71)
		var chance=clampf(.22+(confidence-floor)*1.7,.22,.70) if confidence>=floor else minf(.035,boldness*.15)
		if int(v.scores[1-seat%2])>=9 and confidence<floor:chance*=.25
		if rng.randf() < chance: return {"type": "raise", "payload": {}}
	if v.get("blind",v.iron):
		return {"type": "play", "payload": {"token": hand[rng.randi_range(0, hand.size() - 1)].token}}
	if v.get("rule","")=="uma_oculta":return _mixed_play(v,hand)
	var ordered = hand.duplicate(true)
	var vira = int(v.vira)
	ordered.sort_custom(func(a, b): return Cards.strength(int(a.card), vira, str(v.get("deck_mode","sujo")),str(v.get("hand_variant","paulista"))) < Cards.strength(int(b.card), vira, str(v.get("deck_mode","sujo")),str(v.get("hand_variant","paulista"))))
	var chosen = ordered[0]
	var best_power = -1
	var best_team = -1
	var tie = false
	for p in v.trick:
		var power = -1 if p.covered else Cards.strength(int(p.card), vira, str(v.get("deck_mode","sujo")),str(v.get("hand_variant","paulista")))
		if power > best_power:
			best_power = power
			best_team = int(p.seat) % 2
			tie = false
		elif power == best_power and int(p.seat) % 2 != best_team: tie = true
	if v.trick.is_empty():
		if ordered.size() >= 2 and v.rounds.is_empty(): chosen = ordered[ordered.size() - 2]
		else: chosen = ordered.back()
	elif best_team != seat % 2 or tie:
		for c in ordered:
			if Cards.strength(int(c.card), vira, str(v.get("deck_mode","sujo")),str(v.get("hand_variant","paulista"))) > best_power:
				chosen = c
				break
	var covered = v.can_cover and not v.iron and Cards.strength(int(chosen.card), vira, str(v.get("deck_mode","sujo")),str(v.get("hand_variant","paulista"))) < best_power and rng.randf() < 0.22
	return {"type": "play", "payload": {"token": chosen.token, "covered": covered}}

func _confidence(v: Dictionary) -> float:
	var view_key=Bid.key(v)
	if view_key!=cached_key:cached_key=view_key;cached_probability=Bid.estimate(v,view_key)
	return clampf(cached_probability+Bid.signal_adjustment(v),0,1)
func advice(v: Dictionary) -> String:
	var value=_confidence(v)
	if value>=.84 and int(v.offer)<12:return "counter"
	return "accept" if value>=Bid.accept_threshold(v,profile) else "fold"
func thinking_seconds(v: Dictionary) -> float:
	var confidence=_confidence(v)
	return 1.15+1.25*(1.0-absf(confidence-.5)*2.0)+float(v.offer)/48.0
func _already_signaled(v: Dictionary,kind: String) -> bool:
	for tell in v.get("signals",[]):
		if int(tell.sender)==int(v.seat) and tell.kind==kind:return true
	return false

func _mixed_play(v: Dictionary,hand: Array) -> Dictionary:
	# Recebe apenas a PlayerView. A carta surpresa nunca é consultada no domínio.
	var visible=[];var hidden=[]
	for c in hand:
		if int(c.card)<0:hidden.append(c)
		else:visible.append(c)
	if visible.is_empty():return {"type":"play","payload":{"token":hidden[0].token}}
	var power=func(c):return Cards.strength(int(c.card),int(v.vira),str(v.deck_mode),str(v.hand_variant))
	visible.sort_custom(func(a,b):return power.call(a)<power.call(b))
	var chosen=visible[0];var best=-1;var team=-1;var tied=false
	for play in v.trick:
		var strength=-1 if play.covered else Cards.strength(int(play.card),int(v.vira),str(v.deck_mode),str(v.hand_variant))
		if strength>best:best=strength;team=int(play.seat)%2;tied=false
		elif strength==best and int(play.seat)%2!=team:tied=true
	if v.trick.is_empty():
		if not hidden.is_empty() and int(power.call(visible.back()))<8 and rng.randf()<.4:chosen=hidden[0]
		else:chosen=visible.back() if v.rounds.size()>0 else visible[0]
	elif team!=int(v.seat)%2 or tied:
		var can_win=false
		for c in visible:
			if int(power.call(c))>best:chosen=c;can_win=true;break
		if not can_win and not hidden.is_empty():chosen=hidden[0]
	return {"type":"play","payload":{"token":chosen.token,"covered":false}}
