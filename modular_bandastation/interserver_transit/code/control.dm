/datum/controller/subsystem/interserver_transit
	var/coordinator_id = "A"
	var/coordinator_revision = 0
	var/datum/transit_ownership/ownership
	var/list/ledger
	var/list/operations = list()
	var/list/departed_accounts = list()
	var/list/arrived_accounts = list()
	var/list/arrival_credentials = list()
	var/list/visitor_accounts = list()
	var/current_id
	var/driver_busy = FALSE
	var/last_error
	var/last_transport_error
	var/station_name = "Станция отправления"
	var/destination_name = "Станция назначения"
	var/countdown_end = 0
	var/warning_seconds = 5
	var/flight_seconds = 15
	var/fade_seconds = 2
	var/datum/transit_manifest/manifest
	var/obj/docking_port/mobile/interserver_transit/ship
	var/obj/docking_port/stationary/station_dock
	var/list/ship_baseline

/datum/controller/subsystem/interserver_transit/proc/initialize_game(list/settings)
	station_name = settings["station_name"] || station_name
	destination_name = settings["destination_name"] || destination_name
	diagnostic_mode = settings["diagnostic_mode"] == TRUE
	coordinator_id = settings["coordinator_id"] || "A"
	if(coordinator_id != peer.server_id && coordinator_id != peer.peer_id)
		fault = "Invalid coordinator ID"
		return
	if(isnum(settings["warning_seconds"]))
		warning_seconds = clamp(round(settings["warning_seconds"]), 5, 120)
	if(isnum(settings["flight_seconds"]))
		flight_seconds = clamp(round(settings["flight_seconds"]), 1, 300)
	if(isnum(settings["fade_seconds"]))
		fade_seconds = clamp(settings["fade_seconds"], 0, 10)
	ownership = new
	for(var/obj/docking_port/stationary/dock as anything in SSshuttle.stationary_docking_ports)
		if(dock.shuttle_id == "interserver_stationary")
			station_dock = dock
	if(!station_dock)
		return
	var/datum/map_template/shuttle/template = SSmapping.shuttle_templates["interserver_box"]
	ship = SSshuttle.action_load(template, null)
	if(!ship || !istype(ship))
		fault = "Failed to load interserver shuttle in transit space"
		return
	var/datum/transit_manifest/probe = new(peer.server_id, peer.round_id)
	ship_baseline = probe.layout(ship)
	qdel(probe)
	ship.protect_fixtures()
	if(settings["test_autostart"] && findtext(SSmapping.current_map.map_name, "InterserverTest") == 1)
		SSticker.start_immediately = TRUE

/datum/controller/subsystem/interserver_transit/proc/save_state()
	if(fault || !journal.store(list("round" = peer.round_id, "ledger" = ledger, "operations" = operations, "departed" = departed_accounts, "coordinator_revision" = coordinator_revision)))
		fault ||= journal.fault || "Journal write failed; transfer locked"
		log_world("INTERSERVER [peer.server_id]: [fault]")
		return FALSE
	return TRUE

/datum/controller/subsystem/interserver_transit/proc/ledger_reply()
	return list("ledger" = ledger, "revision" = peer.server_id == coordinator_id ? journal.sequence : coordinator_revision)

/datum/controller/subsystem/interserver_transit/proc/adopt_ledger(list/incoming, revision)
	if(peer.peer_id != coordinator_id || !islist(incoming) || !isnum(revision) || revision < coordinator_revision)
		return FALSE
	var/list/rounds = incoming["rounds"]
	if(incoming["pair"] != peer.pair_id || !islist(rounds) || rounds[peer.server_id] != peer.round_id || rounds[peer.peer_id] != peer_round || !(incoming["owner"] in rounds))
		return FALSE
	if(revision == coordinator_revision && ledger)
		return json_encode(ledger) == json_encode(incoming)
	ledger = incoming
	coordinator_revision = revision
	return save_state()

/datum/controller/subsystem/interserver_transit/proc/synchronize(list/response)
	var/list/payload = response["payload"]
	var/list/rounds = ledger?["rounds"]
	if(rounds && rounds[peer.peer_id] != response["round"])
		fault = "Соседний сервер сменил раунд. Перелёты заблокированы; прежние операции сохранены."
		return
	if(peer.server_id == coordinator_id)
		if(!ledger && !payload["ledger"] && ship && payload["dock"])
			ledger = ownership.bootstrap(peer.pair_id, peer.server_id, peer.round_id, peer.peer_id, response["round"])
			if(!save_state())
				return
	else if(payload["ledger"])
		adopt_ledger(payload["ledger"], payload["revision"])
	// Initial activation requires matching durable ledgers on both sides.
	if(ship && ledger && ledger["owner"] == peer.server_id && ledger["epoch"] == 1 && ledger["phase"] == "IDLE" && !current_id && json_encode(payload["ledger"]) == json_encode(ledger) && ship.get_docked() != station_dock)
		if(ship.initiate_docking(station_dock) != DOCKING_SUCCESS)
			last_error = "Тестовый док недоступен"
		else
			ship.protect_fixtures()

/datum/controller/subsystem/interserver_transit/proc/rpc(list/payload)
	if(!peer_reachable || !peer_round || fault)
		return null
	payload["target_round"] = peer_round
	if(peer.server_id == coordinator_id && (payload["command"] == "CHECK" || payload["command"] == "BEGIN"))
		payload["ledger"] = ledger
		payload["revision"] = journal.sequence
	var/expected_round = peer_round
	var/list/response = peer.request(payload)
	if(!response)
		last_transport_error = peer.error
		last_error = last_transport_error
		return null
	if(response["round"] != expected_round)
		fault = "Ответ пришёл из другого раунда; перенос заблокирован"
		return null
	clear_transport_error()
	return response["payload"]

/datum/controller/subsystem/interserver_transit/proc/clear_transport_error()
	if(last_transport_error && last_error == last_transport_error)
		last_error = null
	last_transport_error = null

/datum/controller/subsystem/interserver_transit/proc/apply_event(list/event)
	var/list/next
	if(event["command"] == "ARRIVED")
		next = ownership.arrive(ledger, event["id"], event["sender"], event["epoch"])
	else
		next = ownership.apply(ledger, event)
	if(!next)
		return list("error" = ownership.error) + ledger_reply()
	if(json_encode(next) == json_encode(ledger))
		return ledger_reply()
	ledger = next
	if(!save_state())
		return list("error" = fault)
	return ledger_reply()

/datum/controller/subsystem/interserver_transit/proc/coordinate(command, list/operation)
	var/list/event = list("command" = command, "pair" = peer.pair_id, "rounds" = ledger["rounds"], "sender" = peer.server_id, "id" = operation["id"], "source" = operation["source"], "destination" = operation["destination"], "epoch" = command == "ARRIVED" ? ledger["epoch"] : operation["epoch"], "digest" = operation["digest"])
	var/list/response = peer.server_id == coordinator_id ? apply_event(event) : rpc(list("command" = "EVENT", "event" = event))
	if(!response)
		return FALSE
	if(peer.server_id != coordinator_id && response["ledger"])
		adopt_ledger(response["ledger"], response["revision"])
	if(response["error"])
		last_error = response["error"]
		return FALSE
	return TRUE

/datum/controller/subsystem/interserver_transit/proc/handle_request(list/payload, remote_round)
	if(payload["command"] == "HELLO")
		return list("command" = "HELLO", "server" = peer.server_id, "dock" = !!ship, "active" = ship && ship.get_docked() == station_dock, "map" = SSmapping.current_map.map_name, "ready" = SSticker.current_state == GAME_STATE_PLAYING, "fault" = fault, "error" = last_error, "local_phase" = operations[current_id]?["phase"]) + ledger_reply()
	if(fault || !ledger || payload["target_round"] != peer.round_id)
		return list("error" = fault || "Round is not ready")
	var/list/rounds = ledger["rounds"]
	if(rounds[peer.peer_id] != remote_round)
		return list("error" = "Wrong source round")
	if(payload["ledger"] && peer.peer_id == coordinator_id)
		adopt_ledger(payload["ledger"], payload["revision"])
	var/command = payload["command"]
	if(command == "EVENT")
		if(peer.server_id != coordinator_id || !islist(payload["event"]))
			return list("error" = "Not the coordinator")
		var/list/event = payload["event"]
		event["sender"] = peer.peer_id
		return apply_event(event)
	if(command == "CALL")
		if(payload["epoch"] != ledger["epoch"])
			return list("error" = "Устаревший вызов шаттла")
		return begin_flight() ? list("ok" = TRUE) : list("error" = last_error || "Flight unavailable")
	var/id = payload["id"]
	var/regex/id_pattern = regex("^\[a-f0-9]{64}$")
	if(!istext(id) || !id_pattern.Find(id))
		return list("error" = "Invalid operation ID")
	var/list/operation = operations[id]
	if(command == "STATUS")
		return operation ? list("phase" = operation["phase"], "error" = operation["error"]) : list("error" = "Unknown operation")
	var/list/reservation = ledger["operation"]
	if(!reservation || reservation["id"] != id || reservation["source"] != peer.peer_id || reservation["destination"] != peer.server_id)
		return list("error" = "No matching reservation")
	if(command == "CHECK")
		if(operation)
			return list("phase" = operation["phase"], "error" = operation["error"])
		if(!ship || ship.get_docked() == station_dock || (current_id && operations[current_id]?["phase"] != "DONE") || SSticker.current_state != GAME_STATE_PLAYING || !islist(payload["admissions"]) || length(payload["admissions"]) > 8)
			return list("error" = "Приёмная сторона или док не готовы")
		QDEL_NULL(manifest)
		current_id = id
		operation = list("id" = id, "role" = "destination", "source" = peer.peer_id, "destination" = peer.server_id, "epoch" = ledger["epoch"], "phase" = "CHECKING", "admissions" = payload["admissions"])
		operations[id] = operation
		return save_state() ? list("phase" = "CHECKING") : list("error" = fault)
	if(!operation || operation["role"] != "destination")
		return list("error" = "Unknown destination operation")
	if(command == "BEGIN")
		if(operation["phase"] != "ADMITTED")
			return list("phase" = operation["phase"], "error" = operation["error"])
		var/datum/transit_snapshot_store/spool = new("data/interserver/[peer.pair_id]/snapshots/[id]/", payload["digest"], payload["chunks"], payload["bytes"])
		if(!spool.valid_manifest())
			qdel(spool)
			return list("error" = "Invalid snapshot manifest")
		qdel(spool)
		operation["digest"] = payload["digest"]
		operation["chunks"] = payload["chunks"]
		operation["bytes"] = payload["bytes"]
		operation["phase"] = "RECEIVING"
		return save_state() ? list("phase" = "RECEIVING") : list("error" = fault)
	if(command == "CHUNK" && operation["phase"] == "RECEIVING")
		var/datum/transit_snapshot_store/spool = operation_spool(operation)
		var/success = spool.put(payload["index"], payload["chunk"])
		var/reason = spool.error
		qdel(spool)
		return success ? list("ok" = TRUE) : list("error" = reason)
	if(command == "PREPARE")
		if(operation["phase"] == "RECEIVING")
			operation["phase"] = "PREPARING"
			if(!save_state())
				return list("error" = fault)
		return list("phase" = operation["phase"], "error" = operation["error"])
	return list("error" = "Unsupported transfer command")

/datum/controller/subsystem/interserver_transit/proc/operation_spool(list/operation)
	return new /datum/transit_snapshot_store("data/interserver/[peer.pair_id]/snapshots/[operation["id"]]/", operation["digest"], operation["chunks"], operation["bytes"])

/datum/controller/subsystem/interserver_transit/proc/set_phase(list/operation, phase)
	operation["phase"] = phase
	log_world("INTERSERVER [peer.server_id]: [operation["role"]] [operation["id"]] -> [phase][operation["error"] ? ": [operation["error"]]" : ""]")
	return save_state()

/datum/controller/subsystem/interserver_transit/proc/begin_flight()
	if(fault || !peer_reachable || !ship || !ledger || ledger["phase"] != "IDLE" || ledger["owner"] != peer.server_id || ship.get_docked() != station_dock || SSticker.current_state != GAME_STATE_PLAYING || (current_id && operations[current_id]?["phase"] != "DONE"))
		last_error = fault || "Шаттл или соседний сервер не готовы к отправлению"
		return FALSE
	if(length(ledger["results"]) >= 24)
		last_error = "Достигнут предел рейсов тестового раунда; требуется новый согласованный тест"
		return FALSE
	QDEL_NULL(manifest)
	current_id = rustg_csprng_chacha20("hex", 32)
	operations[current_id] = list("id" = current_id, "role" = "source", "source" = peer.server_id, "destination" = peer.peer_id, "epoch" = ledger["epoch"], "phase" = "RESERVING")
	last_error = null
	return save_state()
