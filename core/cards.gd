extends RefCounted
## O identificador inteiro de uma carta só existe no estado interno e em views autorizadas.
const RANKS = ["4", "5", "6", "7", "Q", "J", "K", "A", "2", "3"]
const SUITS = ["♦", "♠", "♥", "♣"]

static func deck(mode: String = "sujo") -> Array:
	return range(16,40) if mode == "limpo" else range(40)

static func rank_index(card: int) -> int:
	return card / 4

static func rank_name(card: int) -> String:
	if card < 0: return "?"
	return RANKS[rank_index(card)]

static func suit(card: int) -> int:
	return card % 4

static func manilha_rank(vira: int, mode: String = "sujo") -> int:
	if vira < 0: return -1
	var next = (rank_index(vira) + 1) % 10
	return 4 if mode == "limpo" and next < 4 else next

static func is_manilha(card: int, vira: int, mode: String = "sujo", variant: String = "paulista") -> bool:
	if card < 0: return false
	if variant == "mineiro": return card in [12,29,14,3]
	return rank_index(card) == manilha_rank(vira,mode)

static func strength(card: int, vira: int, mode: String = "sujo", variant: String = "paulista") -> int:
	if card < 0: return -1
	if variant == "mineiro":
		var fixed = [12,29,14,3].find(card)
		return 10 + fixed if fixed >= 0 else rank_index(card)
	if rank_index(card) == manilha_rank(vira, mode): return 10 + suit(card)
	return rank_index(card)

static func label(card: int) -> String:
	if card < 0: return "Carta oculta"
	return rank_name(card) + SUITS[suit(card)]

static func card(rank: String, naipe: int) -> int:
	return RANKS.find(rank) * 4 + naipe

static func trick_result(plays: Array, vira: int, leader: int, mode: String = "sujo", variant: String = "paulista") -> Dictionary:
	var best = -2
	var winners = []
	for p in plays:
		var power = -1 if p.get("covered", false) else strength(int(p.card), vira, mode,variant)
		if power > best:
			best = power
			winners = [int(p.seat)]
		elif power == best:
			winners.append(int(p.seat))
	var team = int(winners[0]) % 2
	for seat in winners:
		if int(seat) % 2 != team:
			return {"team": -1, "leader": leader}
	return {"team": team, "leader": int(winners[0])}

## -2: segue, -1: três empates, 0/1: dupla vencedora.
static func hand_winner(rounds: Array) -> int:
	if rounds.size() < 2: return -2
	var a = int(rounds[0])
	var b = int(rounds[1])
	if a == b and a != -1: return a
	if a == -1 and b != -1: return b
	if a != -1 and b == -1: return a
	if rounds.size() < 3: return -2
	var c = int(rounds[2])
	if c != -1: return c
	return a
