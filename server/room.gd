extends RefCounted
const Game=preload("res://core/game.gd")
const Bot=preload("res://ai/bot.gd")
var code=""
var owner=""
var options: Dictionary={}
var players: Array=[]
var pending: Array=[]
var lobby_revision=0
var room_revision=0
var game
var bots: Dictionary={}
var bot_at=0
var barrier: Dictionary={}
var barrier_acks: Dictionary={}
var suspended=false
var interrupted=false
var opinions: Dictionary={}
var rematch_votes: Dictionary={}
var last_activity=0

func _init(room_code: String="",sid: String="",config: Dictionary={}):
	code=room_code;owner=sid;options=config.duplicate(true)
	for i in range(int(options.get("players",0))):players.append({"sid":"","profile":{"nickname":"Lugar livre","avatar":i},"ready":false,"bot":false})
func seat_of(sid: String) -> int:
	for i in range(players.size()):
		if players[i].sid==sid and sid!="":return i
	return -1
func empty_seat() -> int:
	for i in range(players.size()):
		if players[i].sid=="" and not players[i].bot:return i
	return -1
func humans() -> Array:
	var result=[]
	for person in players:
		if person.sid!="" and not person.bot:result.append(person.sid)
	return result
func reset_ready():
	lobby_revision+=1
	for person in players:person.ready=false
func begin_match():
	game=Game.new();game.new_match(-1,[0,0],-1,int(options.players),str(options.deck_mode),str(options.variant))
	interrupted=false;suspended=false;opinions.clear();rematch_votes.clear();bots.clear()
	var names=["Rui","Lia","Nina","Zeca","Bia","Dito"]
	for i in range(players.size()):
		if players[i].sid=="" or players[i].bot:
			players[i]={"sid":"","profile":{"nickname":names[i]+" · bot","avatar":i},"ready":true,"bot":true}
			bots[i]=Bot.new(["pressionador","cauteloso","observador"][i%3])
	new_barrier("deal")
func new_barrier(kind: String):
	barrier={"id":Crypto.new().generate_random_bytes(16).hex_encode(),"kind":kind,"revision":int(game.s.revision)}
	barrier_acks.clear()
func after_command(now: int,delay_ms: int):
	opinions.clear();bot_at=now+delay_ms
	if game.s.phase=="round_over":new_barrier("round")
	elif game.s.phase=="hand_over":new_barrier("hand")
	elif game.s.phase=="match_over":barrier.clear();barrier_acks.clear()
	if game.s.phase=="offer":
		for seat in bots:
			if int(seat)%2!=int(game.s.offer_team):opinions[str(seat)]=bots[seat].advice(game.view(int(seat)))
