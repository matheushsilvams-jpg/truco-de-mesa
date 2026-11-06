extends SceneTree
const Service=preload("res://server/service.gd")
var service=Service.new()
func _initialize():
	Engine.max_fps=30
	var port_value=OS.get_environment("TRUCO_BACKEND_PORT")
	if port_value=="":port_value=OS.get_environment("PORT")
	var port=10000 if port_value=="" else int(port_value)
	if port<1 or port>65535:push_error("PORT inválida");quit(1);return
	var bind_address=OS.get_environment("TRUCO_BIND")
	if bind_address=="":bind_address="127.0.0.1"
	var error=service.start(port,bind_address)
	if error!=OK:push_error("Não foi possível abrir a porta do servidor");quit(1);return
	print(JSON.stringify({"service":"truco-de-mesa","build":"0.4.0-beta2","port":port,"storage":"ephemeral"}))
func _process(_delta):
	service.tick()
	return false
func _finalize():service.stop()
