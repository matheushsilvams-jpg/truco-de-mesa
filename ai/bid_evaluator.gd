extends RefCounted
## Rollouts de mundos possíveis: só recebe a observação autorizada.
const Cards=preload("res://core/cards.gd")
const WORLDS=32
static func key(v: Dictionary) -> int:
	# Preserva a sequência de amostras do Paulista já instalado.
	var fields=[v.deck_mode,v.player_count,v.seat,v.hands,v.vira,v.turn,v.trick,v.rounds,v.round_records]
	if v.get("hand_variant","paulista")!="paulista" or v.get("rule","normal")!="normal":fields.append([v.get("hand_variant","paulista"),v.get("rule","normal"),v.get("blind",v.iron)])
	return hash(JSON.stringify(fields))
static func estimate(v: Dictionary,seed_value: int) -> float:
	if v.get("blind",v.iron):return .5
	var known={int(v.vira):true}
	for hand in v.hands:
		for c in hand:
			if int(c.card)>=0:known[int(c.card)]=true
	for p in v.trick:
		if int(p.card)>=0:known[int(p.card)]=true
	for record in v.round_records:
		for p in record.plays:
			if int(p.card)>=0:known[int(p.card)]=true
	var pool=[]
	for card in Cards.deck(str(v.deck_mode)):
		if not known.has(card):pool.append(card)
	var sample_rng=RandomNumberGenerator.new();sample_rng.seed=seed_value
	var wins=0.0
	for _world in range(WORLDS):
		var remaining=pool.duplicate();var hands=[]
		for hand in v.hands:
			var cards=[]
			for c in hand:
				if int(c.card)>=0:cards.append(int(c.card))
				elif not remaining.is_empty():
					var index=sample_rng.randi_range(0,remaining.size()-1);cards.append(remaining[index]);remaining.remove_at(index)
			hands.append(cards)
		var world=v.duplicate(true)
		if world.get("rule","")=="surpresa" and not world.get("vira_revealed",true) and not remaining.is_empty():world.vira=remaining[sample_rng.randi_range(0,remaining.size()-1)]
		wins+=_surprise_rollout(world,hands) if world.get("rule","")=="surpresa" and not world.get("vira_revealed",true) else _rollout(world,hands)
	return wins/WORLDS
static func _rollout(v: Dictionary,hands: Array) -> float:
	var rounds=v.rounds.duplicate();var trick=v.trick.duplicate(true)
	var actor=int(v.turn);var leader=int(trick[0].seat) if not trick.is_empty() else actor
	var n=int(v.player_count);var winner=Cards.hand_winner(rounds)
	while winner==-2 and rounds.size()<3:
		while trick.size()<n:
			if hands[actor].is_empty():return .5
			var card=_choose(hands[actor],trick,int(v.vira),str(v.deck_mode),actor,rounds.size(),str(v.get("hand_variant","paulista")))
			hands[actor].erase(card);trick.append({"seat":actor,"card":card,"covered":false});actor=(actor+1)%n
		var result=Cards.trick_result(trick,int(v.vira),leader,str(v.deck_mode),str(v.get("hand_variant","paulista")))
		rounds.append(int(result.team));leader=int(result.leader);actor=leader;trick=[]
		winner=Cards.hand_winner(rounds)
	if winner<0:return .5
	return 1.0 if winner==int(v.seat)%2 else 0.0
static func _choose(hand: Array,trick: Array,vira: int,mode: String,seat: int,round_no: int,variant: String="paulista") -> int:
	var ordered=hand.duplicate();ordered.sort_custom(func(a,b):return Cards.strength(a,vira,mode,variant)<Cards.strength(b,vira,mode,variant))
	if trick.is_empty():return ordered[ordered.size()-2] if ordered.size()>2 and round_no==0 else ordered.back()
	var best=-2;var best_team=-1;var tied=false
	for p in trick:
		var power=-1 if p.covered else Cards.strength(int(p.card),vira,mode,variant)
		if power>best:best=power;best_team=int(p.seat)%2;tied=false
		elif power==best and int(p.seat)%2!=best_team:tied=true
	if best_team!=seat%2 or tied:
		for card in ordered:
			if Cards.strength(card,vira,mode,variant)>best:return card
	return ordered[0]
static func _surprise_rollout(v: Dictionary,hands: Array) -> float:
	# Não usa ganhadores secretos para escolher quem abre: a regra mantém o abridor.
	var rounds=[];var n=int(v.player_count);var leader=int(v.hand_leader)
	for record in v.round_records:
		rounds.append(int(Cards.trick_result(record.plays,int(v.vira),leader,str(v.deck_mode)).team))
	var trick=v.trick.duplicate(true);var actor=int(v.turn)
	while rounds.size()<3:
		while trick.size()<n:
			if hands[actor].is_empty():return .5
			# A política também não conhece a vira sorteada: só a força comum.
			var card=_choose(hands[actor],trick,-1,str(v.deck_mode),actor,rounds.size())
			hands[actor].erase(card);trick.append({"seat":actor,"card":card,"covered":false});actor=(actor+1)%n
		rounds.append(int(Cards.trick_result(trick,int(v.vira),leader,str(v.deck_mode)).team));trick=[];actor=leader
	var winner=Cards.hand_winner(rounds)
	return .5 if winner<0 else (1.0 if winner==int(v.seat)%2 else 0.0)
static func signal_adjustment(v: Dictionary) -> float:
	# Uma afirmação recente por emissor; repetição não soma confiança.
	var latest={}
	for tell in v.get("signals",[]):latest[int(tell.sender)]=tell
	var adjustment=0.0
	for sender in latest:
		var tell=latest[sender]
		if sender==int(v.seat):continue
		if int(tell.team)==int(v.seat)%2:
			if tell.kind in ["zap","copas"]:adjustment+=.035
			elif tell.kind=="fraca":adjustment-=.04
		elif tell.visibility=="public" and tell.kind in ["zap","copas"]:adjustment-=.025
	return clampf(adjustment,-.10,.10)
static func _utility(ours: int,theirs: int) -> float:
	if ours>=12:return 1.0
	if theirs>=12:return 0.0
	return .5+float(ours-theirs)/26.0
static func accept_threshold(v: Dictionary,profile: String) -> float:
	var team=int(v.seat)%2;var ours=int(v.scores[team]);var theirs=int(v.scores[1-team])
	var win=_utility(ours+int(v.offer),theirs);var lose=_utility(ours,theirs+int(v.offer))
	var fold=_utility(ours,theirs+int(v.accepted))
	var risk=.03 if profile=="pressionador" else (.10 if profile=="cauteloso" else .07)
	return clampf((fold-lose)/maxf(.01,win-lose)+risk,.12,.90)
