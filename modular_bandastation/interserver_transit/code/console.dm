/obj/machinery/computer/interserver_transit
	name = "консоль пассажирских перевозок"
	desc = "Вызов и отправление общего шаттла между двумя станциями."
	icon_screen = "shuttle"
	use_power = NO_POWER_USE
	density = FALSE
	var/on_board = FALSE

/obj/machinery/computer/interserver_transit/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "InterserverTransit", name)
		ui.open()

/obj/machinery/computer/interserver_transit/ui_data(mob/user)
	var/datum/controller/subsystem/interserver_transit/controller = SSinterserver_transit
	var/list/operation = controller.operations[controller.current_id]
	var/status = "Рейсы приостановлены"
	if(controller.enabled && !controller.fault && controller.ledger)
		if(controller.ledger["phase"] != "IDLE" || (operation && operation["phase"] != "DONE"))
			status = operation?["phase"] == "COUNTDOWN" ? "Подготовка к отправлению" : "Рейс выполняется"
		else
			status = controller.ledger["owner"] == controller.peer.server_id ? "Шаттл у причала. Посадка открыта" : "Шаттл у причала станции «[controller.destination_name]»"
	return list("status" = status, "station" = controller.station_name, "destination" = controller.destination_name, "connected" = controller.peer_reachable, "on_board" = on_board, "remaining" = max(0, ceil((controller.countdown_end - world.time) / 10)), "timer_label" = operation?["phase"] == "ARRIVING" ? "До прибытия" : "До отправления", "error" = transit_passenger_notice(controller.fault || controller.last_error), "enabled" = controller.enabled && controller.peer_reachable && !!controller.ship && !!controller.ledger && !controller.fault && controller.ledger["phase"] == "IDLE" && (!operation || operation["phase"] == "DONE"))

/obj/machinery/computer/interserver_transit/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	if(action != "call" && action != "depart")
		return
	var/mob/living/user = usr
	if(!istype(user) || !user.client || user.stat != STABLE || get_dist(user, src) > 1 || user.z != z)
		return
	var/datum/controller/subsystem/interserver_transit/controller = SSinterserver_transit
	if(!controller.enabled || controller.fault || !controller.ship || !controller.ledger)
		return
	if(action == "depart")
		if(!on_board || !controller.ship.shuttle_areas[get_area(user)] || get_area(src) != get_area(user))
			return
		controller.begin_flight()
	else
		if(on_board)
			return
		if(controller.ledger["owner"] == controller.peer.server_id)
			controller.last_error = "Шаттл уже находится здесь"
		else
			INVOKE_ASYNC(controller, TYPE_PROC_REF(/datum/controller/subsystem/interserver_transit, request_call))
	return TRUE

/datum/controller/subsystem/interserver_transit/proc/request_call()
	var/list/response = rpc(list("command" = "CALL", "epoch" = ledger?["epoch"]))
	if(response?["error"])
		last_error = response["error"]
