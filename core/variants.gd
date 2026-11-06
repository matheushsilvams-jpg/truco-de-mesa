extends RefCounted
## Convenções de cada mesa. Maluco é um modo autoral, não uma regra regional.
const NAMES={"paulista":"Paulista","mineiro":"Mineiro","maluco":"Maluco"}
const PAULISTA=[1,3,6,9,12]
const MINEIRO=[2,4,6,10,12]
const CHAOS=["escuro","surpresa","mineiro","uma_oculta"]
const EVENTS={
	"uma_oculta":{"title":"UMA NO ESCURO","short":"Duas cartas à vista. A terceira é surpresa.","detail":"Cada jogador vê duas das próprias cartas. A terceira carta distribuída fica oculta até ser jogada ou a mão acabar. Vira e pontos do Paulista, sem jogar coberta.","icon":"eye_closed"},
	"escuro":{"title":"NO ESCURO","short":"Escolha sem olhar. A carta aparece ao jogar.","detail":"Ninguém vê a própria mão. Cada carta é revelada quando chega à mesa. Vira visível e contagem paulista.","icon":"eye_closed"},
	"surpresa":{"title":"VIRA SURPRESA","short":"Três rodadas. A vira só aparece no final.","detail":"A vira fica oculta até a terceira rodada. Quem abriu a mão abre todas as rodadas; resultados e pontos só aparecem na revelação.","icon":"reveal"},
	"mineiro":{"title":"VIROU MINEIRO","short":"Sem vira. Manilhas fixas e mão valendo 2.","detail":"4♣ > 7♥ > A♠ > 7♦. Esta mão usa 2 → 4 → 6 → 10 → 12. Na próxima mão a regra muda outra vez.","icon":"mountain"}}
static func steps(hand_variant: String) -> Array:
	return MINEIRO if hand_variant=="mineiro" else PAULISTA
static func next_value(accepted: int,hand_variant: String) -> int:
	var values=steps(hand_variant);var i=values.find(accepted)
	return int(values[i+1]) if i>=0 and i<values.size()-1 else 0
static func special_limit(variant: String) -> int:
	return 10 if variant=="mineiro" else 11
static func event(rule: String) -> Dictionary:
	return EVENTS.get(rule,{"title":"PAULISTA","short":"Manilhas pela vira.","detail":"","icon":"cards"})
