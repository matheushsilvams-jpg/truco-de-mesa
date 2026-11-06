extends RefCounted
const FIELDS=["variant","rule","hand_variant","blind","vira_revealed","special_limit","base_points","special_points","next_bid","bid_steps","hand_leader","deck_mode","signals","can_signal","can_concede","signals_left","signals_unlimited","signals_sent","player_count","ruleset","revision","hand_no","seat","phase","scores","dealer","turn","hands","vira","iron","eleven_team","accepted","offer","offer_team","offer_seat","rounds","trick","round_records","history","actions","reason","hand_winner","awarded","can_play","can_raise","can_cover","can_respond","can_decide_eleven"]
static func for_seat(game, seat: int) -> Dictionary:
	var allowed=game.view(seat);var out={}
	for key in FIELDS:out[key]=allowed[key]
	# Janela de animações, não uma quota lógica de sinais.
	out.actions=out.actions.slice(maxi(0,out.actions.size()-64))
	out.signals=out.signals.slice(maxi(0,out.signals.size()-16))
	out.history=out.history.slice(maxi(0,out.history.size()-64))
	return out
