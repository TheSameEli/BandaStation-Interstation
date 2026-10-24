/// Pure coordinator state machine. Callers must durably store a returned image before acting on it.
/// No timeout changes ownership. Reboots with different round IDs quarantine this ledger.
/datum/transit_ownership
	var/error

/datum/transit_ownership/proc/bootstrap(pair_id, server_a, round_a, server_b, round_b)
	if(!istext(pair_id) || !length(pair_id) || !istext(server_a) || !length(server_a) || !istext(server_b) || !length(server_b) || server_a == server_b || !istext(round_a) || !length(round_a) || !istext(round_b) || !length(round_b))
		return null
	var/list/rounds = list()
	rounds[server_a] = round_a
	rounds[server_b] = round_b
	return list("pair" = pair_id, "rounds" = rounds, "owner" = server_a, "epoch" = 1, "phase" = "IDLE", "operation" = null, "results" = list())

/datum/transit_ownership/proc/reject(reason)
	error = reason
	return null

/datum/transit_ownership/proc/apply(list/current, list/message)
	error = null
	if(!islist(current) || !islist(message))
		return reject("Malformed state or message")
	var/list/rounds = current["rounds"]
	var/list/message_rounds = message["rounds"]
	if(!islist(rounds) || length(rounds) != 2 || !islist(message_rounds) || length(message_rounds) != 2 || message["pair"] != current["pair"])
		return reject("Wrong pair")
	for(var/server in rounds)
		if(message_rounds[server] != rounds[server])
			return reject("Wrong round")
	var/sender = message["sender"]
	if(!(sender in rounds))
		return reject("Unknown sender")
	var/id = message["id"]
	if(!istext(id) || length(id) < 16 || length(id) > 128)
		return reject("Invalid operation ID")
	var/list/next = json_decode(json_encode(current))
	var/list/results = next["results"]
	if(!islist(results))
		return reject("Invalid result ledger")
	var/list/finished = results[id]
	if(finished)
		// Only an identical completed operation is a retry, not a new command.
		if(message["source"] != finished["source"] || message["destination"] != finished["destination"] || message["epoch"] != finished["epoch"])
			return reject("Conflicting reused operation ID")
		return next
	if(message["epoch"] != next["epoch"])
		return reject("Stale ownership epoch")
	var/command = message["command"]
	var/list/operation = next["operation"]
	if(command == "RESERVE")
		if(sender != message["source"])
			return reject("Only the owner may reserve departure")
		if(operation)
			if(operation["id"] == id && operation["source"] == message["source"] && operation["destination"] == message["destination"])
				return next
			return reject("Another flight is reserved")
		if(next["phase"] != "IDLE" || message["source"] != next["owner"] || !(message["destination"] in rounds) || message["destination"] == next["owner"])
			return reject("Invalid route or unavailable shuttle")
		next["operation"] = list("id" = id, "source" = message["source"], "destination" = message["destination"], "epoch" = next["epoch"], "prepared" = FALSE, "released" = FALSE, "digest" = null)
		next["phase"] = "PREPARING"
		return next
	if(!operation || operation["id"] != id || operation["source"] != message["source"] || operation["destination"] != message["destination"])
		return reject("Unknown operation")
	if(command == "ABORT")
		if(sender != operation["source"] || operation["released"])
			return reject("Source release is irreversible")
		operation["outcome"] = "ABORTED"
		results[id] = operation
		next["operation"] = null
		next["phase"] = "IDLE"
		return next
	if(command == "PREPARED" || command == "RELEASED")
		var/digest = message["digest"]
		if(!istext(digest) || length(digest) != 64)
			return reject("Missing snapshot digest")
		if(operation["digest"] && operation["digest"] != digest)
			return reject("Snapshot digest conflict")
		if(command == "PREPARED")
			if(sender != operation["destination"])
				return reject("Only destination may acknowledge preparation")
			operation["prepared"] = TRUE
		else
			if(sender != operation["source"] || !operation["prepared"])
				return reject("Release requires durable destination preparation")
			operation["released"] = TRUE
		operation["digest"] = digest
		if(operation["prepared"] && operation["released"])
			next["owner"] = operation["destination"]
			next["epoch"]++
			next["phase"] = "COMMITTED"
			operation["outcome"] = "COMMITTED"
			results[id] = operation.Copy()
		return next
	return reject("Unknown command")

/// Arrival is local to the coordinator after a checked destination receipt for the commit epoch.
/datum/transit_ownership/proc/arrive(list/current, operation_id, sender, epoch)
	error = null
	var/list/results = current?["results"]
	var/list/result = results?[operation_id]
	if(current?["phase"] == "IDLE" && result?["outcome"] == "ARRIVED" && result["destination"] == sender && result["epoch"] + 1 == epoch)
		return json_decode(json_encode(current))
	var/list/operation = current?["operation"]
	if(!operation || current["phase"] != "COMMITTED" || operation["id"] != operation_id || current["owner"] != sender || current["epoch"] != epoch)
		return reject("Invalid arrival receipt")
	var/list/next = json_decode(json_encode(current))
	next["operation"] = null
	next["phase"] = "IDLE"
	results = next["results"]
	result = results[operation_id]
	result["outcome"] = "ARRIVED"
	return next
