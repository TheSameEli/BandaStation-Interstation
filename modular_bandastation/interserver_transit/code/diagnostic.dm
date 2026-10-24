/// Explicitly lossy local testing, never enabled by an absent production config.
/datum/controller/subsystem/interserver_transit
	var/diagnostic_mode = FALSE
	var/list/diagnostic_notices = list()

/proc/transit_diagnostic_note(message, notify = TRUE)
	log_world("INTERSERVER DEVIATION: [message]")
	if(!notify)
		return
	var/flight_id = SSinterserver_transit.current_id || "inspection"
	if(SSinterserver_transit.diagnostic_notices[flight_id])
		return
	SSinterserver_transit.diagnostic_notices[flight_id] = TRUE
	if(SSinterserver_transit.ship)
		for(var/mob/living/passenger as anything in SSinterserver_transit.get_area_people())
			to_chat(passenger, span_warning("При сверке пассажирского манифеста и багажа выявлены несоответствия. Сведения переданы в диспетчерскую. По прибытии проверьте личные вещи и самочувствие."))

/// Engine bookkeeping, placement and local reference graphs are reconstructed locally.
/proc/transit_portable_field(field)
	return istext(field) && copytext(field, 1, 2) != "_" && !(field in list("vars", "type", "parent_type", "tag", "loc", "locs", "x", "y", "z", "contents", "vis_contents", "vis_locs", "verbs", "overlays", "underlays", "appearance", "datum_flags", "gc_destroyed", "flags_1", "atom_flags", "initialized", "memorizer_mind", "registered_account", "transit_bank_server", "transit_bank_round", "transit_bank_id"))

/// Capture value data with a fresh codec per field: one unportable reference cannot poison the rest.
/proc/transit_export_portable(datum/source)
	var/list/record = list()
	for(var/field in source.vars)
		if(!transit_portable_field(field) || !issaved(source.vars[field]))
			continue
		var/value = source.vars[field]
		if(isnull(value) || value == initial(source.vars[field]))
			continue
		var/datum/transit_values/codec = new
		var/list/encoded = codec.encode(value)
		if(!codec.error)
			record[field] = encoded
		else
			transit_diagnostic_note("[source.type].[field]: локальная ссылка/ресурс не копируется; используется восстановленное локальное состояние", notify = FALSE)
		qdel(codec)
	return record

/proc/transit_import_portable(datum/target, list/record)
	if(!islist(record))
		return FALSE
	for(var/field in record)
		if(!transit_portable_field(field) || !(field in target.vars))
			return FALSE
		var/datum/transit_values/codec = new
		var/value = codec.decode(record[field])
		if(codec.error)
			qdel(codec)
			return FALSE
		target.vars[field] = value
		qdel(codec)
	return TRUE
