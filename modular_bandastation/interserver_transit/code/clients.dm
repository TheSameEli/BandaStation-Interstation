/mob/living/carbon/human/proc/transit_fade(seconds)
	var/atom/movable/screen/fullscreen/screen = overlay_fullscreen("interserver_transit", /atom/movable/screen/fullscreen/blind/noflicker)
	screen.alpha = 0
	animate(screen, alpha = 255, time = seconds SECONDS)
	addtimer(CALLBACK(src, PROC_REF(transit_fade_timeout)), 30 SECONDS, TIMER_DELETE_ME)

/mob/living/carbon/human/proc/transit_fade_timeout()
	if(!transit_frozen)
		return
	clear_fullscreen("interserver_transit", 5)
	to_chat(src, span_warning("Прибытие задерживается. Оставайтесь на своём месте и ожидайте указаний диспетчера. При потере связи воспользуйтесь восстановлением связи во вкладке «Рейс»."))

/mob/dead/interserver_waiting
	name = "Пассажир в пути"
	invisibility = INVISIBILITY_ABSTRACT
	density = FALSE
	stat = DEAD

/mob/dead/interserver_waiting/Login()
	// Login's ambience refresh requires an area even for a technical waiting mob.
	if(!get_turf(src))
		forceMove(locate(1, 1, 1))
	. = ..()
	to_chat(src, span_notice("Рейс выполняется. Ожидайте прибытия. При потере связи выберите «Восстановить связь» во вкладке «Рейс»."))

/mob/dead/interserver_waiting/verb/retry_connection()
	set name = "Восстановить связь"
	set category = "Рейс"
	if(!client || !SSinterserver_transit.enabled)
		return
	if(!SSinterserver_transit.claim_client(client))
		SSinterserver_transit.redirect_client(client)

/datum/controller/subsystem/interserver_transit/proc/has_transit_account(account)
	if(quarantined_accounts[account])
		return TRUE
	if(!enabled || !account)
		return FALSE
	if(departed_accounts[account] || arrived_accounts[account])
		return TRUE
	var/list/operation = operations[current_id]
	if(!operation || operation["phase"] == "DONE" || operation["phase"] == "REJECTED")
		return FALSE
	for(var/list/admission as anything in operation["admissions"])
		if(admission["ckey"] == account)
			return TRUE
	return FALSE

/datum/controller/subsystem/interserver_transit/proc/claim_client(client/player)
	if(!player || !player.fully_created)
		return FALSE
	if(quarantined_accounts[player.ckey])
		if(!istype(player.mob, /mob/dead/interserver_waiting))
			var/mob/previous = player.mob
			var/mob/dead/interserver_waiting/waiting = new
			waiting.PossessByPlayer(player.ckey)
			SStitle.hide_title_screen_from(player)
			if(istype(previous, /mob/dead/new_player))
				qdel(previous)
		to_chat(player, span_boldwarning("Рейс приостановлен. Диспетчерская уточняет местонахождение пассажиров. Ожидайте подтверждения маршрута и указаний службы сопровождения."))
		return TRUE
	if(!enabled)
		return FALSE
	var/datum/weakref/body_ref = arrived_accounts[player.ckey]
	var/mob/living/carbon/human/body = body_ref?.resolve()
	if(body && !body.transit_frozen && !departed_accounts[player.ckey])
		// Local diagnostic guests have no account authentication: retain the source's
		// server-observed machine identity, never a client-supplied transition parameter.
		var/regex/guest_pattern = regex("^guest\[0-9]+$")
		if(diagnostic_mode && guest_pattern.Find(player.ckey))
			var/list/credential = arrival_credentials[player.ckey]
			if(!credential || credential["computer_id"] != player.computer_id)
				log_world("INTERSERVER guest arrival denied: client machine identity mismatch")
				to_chat(player, span_warning("Не удалось подтвердить посадочные документы. Свяжитесь с диспетчерской."))
				return TRUE
		if(ckey(body.mind?.key) != player.ckey || body.mind.transit_identity == null)
			return FALSE
		if(player.mob == body)
			return TRUE
		var/mob/previous = player.mob
		body.overlay_fullscreen("interserver_transit", /atom/movable/screen/fullscreen/blind/noflicker)
		body.PossessByPlayer(player.ckey)
		if(body.client != player)
			return FALSE
		SStitle.hide_title_screen_from(player)
		body.clear_fullscreen("interserver_transit", fade_seconds SECONDS)
		to_chat(body, span_notice("Шаттл со станции «[destination_name]» прибыл на станцию «[station_name]». Стыковка завершена, высадка разрешена. Не забывайте личные вещи."))
		if(diagnostic_mode)
			body.playsound_local(body, 'sound/runtime/hyperspace/hyperspace_end.ogg', 70)
			to_chat(body, span_notice("О несоответствиях в багаже или посадочных документах сообщите в диспетчерскую."))
		if(istype(previous, /mob/dead/new_player) || istype(previous, /mob/dead/interserver_waiting))
			qdel(previous)
		return TRUE
	if(!has_transit_account(player.ckey))
		return FALSE
	if(manifest && !departed_accounts[player.ckey])
		var/mob/living/carbon/human/frozen = manifest.passengers[player.ckey]
		var/list/operation = operations[current_id]
		if(frozen && operation?["role"] == "source" && frozen.transit_frozen)
			frozen.PossessByPlayer(player.ckey)
			to_chat(frozen, span_warning("Рейс выполняется. Оставайтесь на своём месте до завершения стыковки."))
			return TRUE
	if(!istype(player.mob, /mob/dead/interserver_waiting))
		var/mob/previous = player.mob
		var/mob/dead/interserver_waiting/waiting = new
		waiting.PossessByPlayer(player.ckey)
		SStitle.hide_title_screen_from(player)
		if(istype(previous, /mob/dead/new_player))
			qdel(previous)
	if(departed_accounts[player.ckey])
		redirect_client(player)
	return TRUE

/datum/controller/subsystem/interserver_transit/proc/redirect_client(client/player)
	if(!player)
		return
	to_chat(player, span_notice("Шаттл следует к станции «[destination_name]». При потере связи с диспетчерской: <a href='byond://[peer.peer_address]'>восстановить связь</a>."))
	player << link("byond://[peer.peer_address]")

/datum/controller/subsystem/interserver_transit/proc/redirect_source_clients()
	if(!manifest)
		return
	for(var/ckey in manifest.passengers)
		var/mob/living/carbon/human/human = manifest.passengers[ckey]
		var/client/player = human?.client
		if(player)
			var/mob/dead/interserver_waiting/waiting = new
			waiting.PossessByPlayer(ckey)
			redirect_client(player)
		arrived_accounts -= ckey

/// A source tombstone also fences possession through cloning/admin tools, not only lobby joins.
/datum/controller/subsystem/interserver_transit/proc/block_foreign_login(mob/body)
	if(!enabled || !body.client || !departed_accounts[body.client.ckey] || istype(body, /mob/dead/interserver_waiting))
		return FALSE
	var/mob/dead/interserver_waiting/waiting = new
	waiting.PossessByPlayer(body.client.ckey)
	return TRUE
