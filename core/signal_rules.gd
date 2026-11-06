extends RefCounted
## A janela é uma convenção explícita do jogo offline, não regra de campeonato.
const KINDS = {"zap":"ZAP ♣", "copas":"COPAS ♥", "espadas":"ESPADILHA ♠", "ouros":"PICA-FUMO ♦", "fraca":"MÃO FRACA", "segura":"SEGURA A MÃO"}
const START_MS = 650
const END_MS = 1050
const BAR_MS = 1600
static func exposure(milliseconds: int) -> String:
	return "private" if milliseconds >= START_MS and milliseconds <= END_MS else "public"
