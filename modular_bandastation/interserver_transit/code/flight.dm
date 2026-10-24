/datum/controller/subsystem/interserver_transit/proc/drive_operation()
	var/list/operation = operations[current_id]
	try
		if(operation && !fault)
			if(operation["role"] == "source")
				drive_source(operation)
			else
				drive_destination(operation)
	catch(var/exception/failure)
		last_error = "Ошибка переноса: [failure.name]. Персонажи остаются заблокированы до сверки."
		log_world("INTERSERVER [peer.server_id]: operation [current_id]: [failure.name]")
		operation["error"] = last_error
		save_state()
		fault = last_error
	driver_busy = FALSE

/datum/controller/subsystem/interserver_transit/proc/source_abort(list/operation, reason)
	last_error = reason
	operation["error"] = reason
	set_phase(operation, "ABORTING")

/datum/controller/subsystem/interserver_transit/proc/drive_source(list/operation)
	var/phase = operation["phase"]
	var/id = operation["id"]
	if(phase == "DONE")
		return
	if(phase == "RESERVING")
		if(coordinate("RESERVE", operation))
			countdown_end = world.time + warning_seconds SECONDS
			if(set_phase(operation, "COUNTDOWN"))
				ship.hyperspace_sound(HYPERSPACE_WARMUP, ship.shuttle_areas)
				for(var/mob/living/passenger in get_area_people())
					to_chat(passenger, span_boldwarning("Пассажирский шаттл отправляется к станции «[destination_name]» через [warning_seconds] секунд. Завершите посадку и займите места. Если вы не следуете этим рейсом, покиньте борт."))
		return
	if(phase == "COUNTDOWN")
		if(SSticker.current_state != GAME_STATE_PLAYING)
			source_abort(operation, "Раунд заканчивается; отправление отменено")
			return
		if(world.time < countdown_end)
			return
		manifest = new(peer.server_id, peer.round_id)
		if(!manifest.encode(ship, ship_baseline))
			source_abort(operation, manifest.error)
			return
		var/list/admissions = list()
		for(var/mob/living/carbon/human/human as anything in manifest.bodies)
			admissions += list(list("ckey" = human.ckey, "identity" = human.mind.transit_identity, "address" = human.client.address || "127.0.0.1", "computer_id" = human.client.computer_id))
		operation["admissions"] = admissions
		set_phase(operation, "CHECK")
		return
	if(phase == "CHECK")
		var/list/reply = rpc(list("command" = "CHECK", "id" = id, "admissions" = operation["admissions"]))
		if(reply?["error"])
			source_abort(operation, reply["error"])
		else if(reply)
			set_phase(operation, "AWAIT_CHECK")
		return
	if(phase == "AWAIT_CHECK")
		var/list/reply = rpc(list("command" = "STATUS", "id" = id))
		if(reply?["phase"] == "REJECTED" || reply?["error"])
			source_abort(operation, reply["error"] || "Приём отклонён")
		else if(reply?["phase"] == "ADMITTED")
			set_phase(operation, "FREEZE")
		return
	if(phase == "FREEZE")
		if(SSticker.current_state != GAME_STATE_PLAYING || ship.get_docked() != station_dock)
			source_abort(operation, "Отправление больше недоступно")
			return
		ship.set_transfer_lock(TRUE)
		ship.hyperspace_sound(HYPERSPACE_LAUNCH, ship.shuttle_areas)
		QDEL_NULL(manifest)
		manifest = new(peer.server_id, peer.round_id)
		if(!manifest.encode(ship, ship_baseline))
			source_abort(operation, manifest.error)
			return
		var/list/admissions = operation["admissions"]
		if(length(admissions) != length(manifest.passengers))
			source_abort(operation, "Состав пассажиров изменился во время проверки; вызовите новый рейс")
			return
		for(var/list/admission as anything in admissions)
			var/mob/living/carbon/human/human = manifest.passengers[admission["ckey"]]
			if(!human || human.mind.transit_identity != admission["identity"])
				source_abort(operation, "Состав пассажиров изменился")
				return
		for(var/mob/living/carbon/human/human as anything in manifest.bodies)
			human.transit_freeze()
			human.transit_fade(fade_seconds)
		// Isolate the original group before the immutable checkpoint. Stripping/storage
		// actions from the station lose adjacency; passengers cannot interact while frozen.
		if(ship.get_docked() != ship.assigned_transit && ship.initiate_docking(ship.assigned_transit) != DOCKING_SUCCESS)
			source_abort(operation, "Не удалось изолировать шаттл для фиксации состояния")
			return
		ship.protect_fixtures()
		var/datum/transit_manifest/isolated = new(peer.server_id, peer.round_id)
		if(!isolated.encode(ship, ship_baseline))
			source_abort(operation, isolated.error)
			qdel(isolated)
			return
		var/roster_matches = length(admissions) == length(isolated.passengers)
		for(var/list/admission as anything in admissions)
			var/mob/living/carbon/human/human = isolated.passengers[admission["ckey"]]
			if(!human || human.mind.transit_identity != admission["identity"])
				roster_matches = FALSE
		if(!roster_matches)
			source_abort(operation, "Состав изменился при изоляции; исходные пассажиры сохранены")
			qdel(isolated)
			return
		qdel(manifest)
		manifest = isolated
		// Chunks are ASCII: byte boundaries must never split a UTF-8 character in JSON.
		var/body = rustg_encode_base64(json_encode(manifest.data))
		if(length(body) > 2097152)
			source_abort(operation, "Снимок превышает 2 МиБ")
			return
		operation["digest"] = rustg_hash_string(RUSTG_HASH_SHA256, body)
		operation["bytes"] = length(body)
		operation["chunks"] = ceil(length(body) / 4096)
		operation["next_chunk"] = 1
		var/datum/transit_snapshot_store/spool = operation_spool(operation)
		for(var/index = 1; index <= operation["chunks"]; index++)
			if(!spool.put(index, copytext(body, (index - 1) * 4096 + 1, index * 4096 + 1)))
				source_abort(operation, spool.error)
				qdel(spool)
				return
		qdel(spool)
		set_phase(operation, "BEGIN_UPLOAD")
		return
	if(phase == "BEGIN_UPLOAD")
		var/list/reply = rpc(list("command" = "BEGIN", "id" = id, "digest" = operation["digest"], "bytes" = operation["bytes"], "chunks" = operation["chunks"]))
		if(reply?["error"])
			source_abort(operation, reply["error"])
		else if(reply?["phase"] == "RECEIVING")
			set_phase(operation, "UPLOAD")
		return
	if(phase == "UPLOAD")
		var/datum/transit_snapshot_store/spool = operation_spool(operation)
		var/body = spool.assemble()
		qdel(spool)
		if(!body)
			source_abort(operation, "Исходный снимок повреждён; исходные тела сохранены")
			return
		for(var/batch = 1; batch <= 16 && operation["next_chunk"] <= operation["chunks"]; batch++)
			var/index = operation["next_chunk"]
			var/list/reply = rpc(list("command" = "CHUNK", "id" = id, "index" = index, "chunk" = copytext(body, (index - 1) * 4096 + 1, index * 4096 + 1)))
			if(!reply)
				return
			if(reply["error"])
				source_abort(operation, reply["error"])
				return
			operation["next_chunk"]++
		if(operation["next_chunk"] > operation["chunks"])
			set_phase(operation, "PREPARE")
		return
	if(phase == "PREPARE")
		var/list/reply = rpc(list("command" = "PREPARE", "id" = id))
		if(reply?["error"])
			source_abort(operation, reply["error"])
		else if(reply)
			set_phase(operation, "AWAIT_PREPARED")
		return
	if(phase == "AWAIT_PREPARED")
		var/list/reply = rpc(list("command" = "STATUS", "id" = id))
		if(reply?["phase"] == "REJECTED" || reply?["error"])
			source_abort(operation, reply["error"] || "Не удалось восстановить персонажей")
		else if(reply?["phase"] == "PREPARED")
			set_phase(operation, "DEPART")
		return
	if(phase == "DEPART")
		if(SSticker.current_state != GAME_STATE_PLAYING)
			source_abort(operation, "Раунд закончился до отправления")
			return
		if(ship.get_docked() != ship.assigned_transit && ship.initiate_docking(ship.assigned_transit) != DOCKING_SUCCESS)
			source_abort(operation, "Не удалось покинуть док")
			return
		ship.protect_fixtures()
		// This durable fence precedes any request that can commit ownership remotely.
		set_phase(operation, "RELEASED")
		return
	if(phase == "RELEASED")
		if(coordinate("RELEASED", operation) && ledger["owner"] == peer.peer_id)
			set_phase(operation, "AWAIT_ARRIVAL")
		return
	if(phase == "AWAIT_ARRIVAL")
		var/list/reply = rpc(list("command" = "STATUS", "id" = id))
		if(reply?["phase"] != "PLAY" && reply?["phase"] != "DONE")
			return
		// The destination created, validated and durably released the whole group to play.
		for(var/ckey in manifest.passengers)
			var/mob/living/carbon/human/human = manifest.passengers[ckey]
			departed_accounts[ckey] = list("identity" = human.mind.transit_identity, "destination" = peer.peer_id, "operation" = id)
		if(!set_phase(operation, "CLEANUP"))
			return
		redirect_source_clients()
		return
	if(phase == "CLEANUP")
		redirect_source_clients()
		manifest.discard_objects()
		QDEL_NULL(manifest)
		set_phase(operation, "DONE")
		return
	if(phase == "ABORTING")
		if(!coordinate("ABORT", operation))
			return
		var/list/results = ledger["results"]
		var/list/result = results[id]
		if(result?["outcome"] != "ABORTED")
			return
		if(ship.get_docked() != station_dock && ship.initiate_docking(station_dock) != DOCKING_SUCCESS)
			return
		ship.protect_fixtures()
		ship.set_transfer_lock(FALSE)
		if(manifest)
			for(var/mob/living/carbon/human/human as anything in manifest.bodies)
				human.clear_fullscreen("interserver_transit", fade_seconds SECONDS)
				human.transit_unfreeze()
				to_chat(human, span_warning("Рейс отменён. [transit_passenger_notice(operation["error"])]"))
			QDEL_NULL(manifest)
		set_phase(operation, "DONE")

/datum/controller/subsystem/interserver_transit/proc/drive_destination(list/operation)
	var/phase = operation["phase"]
	if(phase == "DONE")
		return
	var/list/results = ledger?["results"]
	var/list/result = results?[operation["id"]]
	if(result?["outcome"] == "ABORTED")
		QDEL_NULL(manifest)
		set_phase(operation, "DONE")
		return
	if(phase == "REJECTED")
		return
	if(phase == "CHECKING")
		var/reason = check_admission(operation)
		if(reason)
			operation["error"] = reason
			set_phase(operation, "REJECTED")
		else
			set_phase(operation, "ADMITTED")
		return
	if(phase == "PREPARING")
		var/datum/transit_snapshot_store/spool = operation_spool(operation)
		var/body = spool.assemble()
		var/reason = spool.error
		qdel(spool)
		if(!body)
			operation["error"] = reason
			set_phase(operation, "REJECTED")
			return
		var/decoded_body = rustg_decode_base64(body)
		if(!length(decoded_body))
			operation["error"] = "Повреждена кодировка снимка"
			set_phase(operation, "REJECTED")
			return
		var/list/snapshot = json_decode(decoded_body)
		var/list/admissions = operation["admissions"]
		var/list/people = snapshot?["people"]
		if(!islist(people) || length(people) != length(admissions))
			operation["error"] = "Состав снимка не совпадает с разрешённым составом"
			set_phase(operation, "REJECTED")
			return
		for(var/index = 1; index <= length(admissions); index++)
			var/list/person_entry = people[index]
			var/list/person = person_entry?["person"]
			var/list/admission = admissions[index]
			if(person?["ckey"] != admission["ckey"] || person?["identity"] != admission["identity"])
				operation["error"] = "Идентичность пассажира не совпадает с разрешением сервера"
				set_phase(operation, "REJECTED")
				return
		manifest = new(peer.server_id, peer.round_id)
		if(!manifest.decode(snapshot, ship))
			operation["error"] = manifest.error
			QDEL_NULL(manifest)
			set_phase(operation, "REJECTED")
			return
		set_phase(operation, "PREPARED")
		return
	if(phase == "PREPARED")
		if(!coordinate("PREPARED", operation))
			return
		var/list/reservation = ledger["operation"]
		if(ledger["owner"] == peer.server_id && ledger["phase"] == "COMMITTED" && reservation?["id"] == operation["id"] && reservation["digest"] == operation["digest"])
			countdown_end = world.time + flight_seconds SECONDS
			set_phase(operation, "ARRIVING")
		return
	if(phase == "ARRIVING")
		if(world.time < countdown_end || SSticker.current_state != GAME_STATE_PLAYING)
			return
		if(station_dock.get_docked() && station_dock.get_docked() != ship)
			last_error = "Приёмный док занят; пассажиры сохранены в состоянии переноса"
			return
		if(ship.get_docked() != station_dock && ship.initiate_docking(station_dock) != DOCKING_SUCCESS)
			last_error = "Ошибка стыковки; пассажиры остаются заблокированными"
			return
		ship.protect_fixtures()
		// Once this record exists, snapshots are never replayed as live characters after a crash.
		ship.hyperspace_sound(HYPERSPACE_END, ship.shuttle_areas)
		if(!set_phase(operation, "PLAY"))
			return
		ship.set_transfer_lock(FALSE)
		manifest.owns_staging = FALSE
		for(var/ckey in manifest.passengers)
			var/mob/living/carbon/human/human = manifest.passengers[ckey]
			departed_accounts -= ckey
			arrived_accounts[ckey] = WEAKREF(human)
			for(var/list/admission as anything in operation["admissions"])
				if(admission["ckey"] == ckey)
					arrival_credentials[ckey] = admission.Copy()
			SSticker.minds |= human.mind
			human.transit_unfreeze()
			var/client/client = GLOB.directory[ckey]
			if(client?.fully_created)
				claim_client(client)
		return
	if(phase == "PLAY")
		if(coordinate("ARRIVED", operation))
			set_phase(operation, "DONE")

/datum/controller/subsystem/interserver_transit/proc/check_admission(list/operation)
	var/list/seen = list()
	for(var/list/admission as anything in operation["admissions"])
		if(!islist(admission) || !istext(admission["ckey"]) || !length(admission["ckey"]) || ckey(admission["ckey"]) != admission["ckey"] || seen[admission["ckey"]] || !istext(admission["identity"]) || length(admission["identity"]) != 64 || !istext(admission["address"]) || !istext(admission["computer_id"]))
			return "Некорректное разрешение на приём"
		seen[admission["ckey"]] = TRUE
		for(var/datum/mind/mind as anything in SSticker.minds)
			if(isliving(mind.current) && !QDELETED(mind.current) && ckey(mind.key) == admission["ckey"])
				return "У игрока уже есть персонаж в принимающем раунде"
		var/list/ban = world.IsBanned(admission["ckey"], admission["address"], admission["computer_id"])
		if(ban)
			return "Принимающий сервер не допускает игрока: [ban["reason"]]"
		if(SSticker.current_state != GAME_STATE_PLAYING || fault || operations[current_id] != operation)
			return "Приёмный раунд больше не готов"
	return null

/datum/controller/subsystem/interserver_transit/proc/get_area_people()
	var/list/result = list()
	for(var/area/area as anything in ship.shuttle_areas)
		for(var/mob/living/mob in area)
			result += mob
	return result
