/// One authenticated peer connection, used from inside each game process.
/// Authentication covers the exact JSON bytes, including recipient, nonce and protocol versions.
/datum/transit_peer
	var/server_id
	var/peer_id
	var/pair_id
	var/peer_address
	var/secret
	var/build_id
	var/round_id
	var/error
	var/verification_error
	var/busy = FALSE
	var/list/replies = list()
	var/list/reply_times = list()
	var/list/reply_bodies = list()

/datum/transit_peer/proc/sign_payload(body)
	return call_ext("transit_crypto", "transit_sign")(secret, body)

/datum/transit_peer/proc/envelope(list/payload, nonce)
	// json_encode's default number precision is insufficient for an epoch timestamp.
	return json_encode(list("protocol" = 1, "build" = build_id, "byond" = "[world.byond_version].[world.byond_build]", "pair" = pair_id, "sender" = server_id, "recipient" = peer_id, "round" = round_id, "nonce" = nonce, "time" = num2text(world.realtime, 20), "payload" = payload))

/datum/transit_peer/proc/verify(body, signature)
	verification_error = "invalid envelope size or signature format"
	if(!istext(body) || !length(body) || length(body) > 12000 || !istext(signature) || length(signature) != 64)
		return null
	verification_error = "signature mismatch"
	if(call_ext("transit_crypto", "transit_verify")(secret, body, signature) != "1")
		return null
	var/list/decoded
	verification_error = "invalid JSON"
	try
		decoded = json_decode(body)
	catch
		return null
	verification_error = "protocol, build, pair or endpoint mismatch"
	if(!islist(decoded) || decoded["protocol"] != 1 || decoded["build"] != build_id || decoded["byond"] != "[world.byond_version].[world.byond_build]" || decoded["pair"] != pair_id || decoded["sender"] != peer_id || decoded["recipient"] != server_id)
		return null
	verification_error = "invalid round, nonce, timestamp or payload"
	if(!istext(decoded["round"]) || !length(decoded["round"]) || length(decoded["round"]) > 128 || !istext(decoded["nonce"]) || length(decoded["nonce"]) != 64 || !istext(decoded["time"]) || !isnum(text2num(decoded["time"])) || abs(world.realtime - text2num(decoded["time"])) > 600 || !islist(decoded["payload"]))
		return null
	verification_error = null
	return decoded

/datum/transit_peer/proc/receive(body, signature)
	var/list/decoded = verify(body, signature)
	if(!decoded)
		return "REJECTED"
	var/nonce = decoded["nonce"]
	// A reused nonce with different signed content is never another action.
	if(replies[nonce])
		return reply_bodies[nonce] == body ? replies[nonce] : "REJECTED"
	var/list/expired = list()
	for(var/old_nonce in reply_times)
		if(world.time - reply_times[old_nonce] > 1200)
			expired += old_nonce
	for(var/old_nonce in expired)
		replies -= old_nonce
		reply_times -= old_nonce
		reply_bodies -= old_nonce
	if(busy || length(replies) >= 2048)
		return "BUSY"
	// dispatch must not yield. Game work is scheduled only after the durable reservation.
	busy = TRUE
	var/list/result
	try
		result = dispatch(decoded["payload"], decoded["round"])
	catch
		result = list("error" = "Internal transfer error; state remains locked")
	busy = FALSE
	var/response_body = envelope(result || list("error" = "Unsupported request"), nonce)
	if(length(response_body) > 12000)
		return "REJECTED"
	var/response = json_encode(list("body" = response_body, "signature" = sign_payload(response_body)))
	replies[nonce] = response
	reply_times[nonce] = world.time
	reply_bodies[nonce] = body
	return response

/datum/transit_peer/proc/dispatch(list/payload, remote_round)
	return null

/datum/transit_peer/proc/request(list/payload)
	error = null
	var/started = world.realtime
	var/nonce = rustg_csprng_chacha20("hex", 32)
	var/body = envelope(payload, nonce)
	if(length(body) > 12000)
		error = "Transfer message exceeds limit"
		return null
	var/query = list2params(list("interserver_transit" = 1, "body" = body, "signature" = sign_payload(body)))
	// BYOND topics return Topic's value directly; only HTTP exports have CONTENT headers.
	var/raw = world.Export("byond://[peer_address]?[query]", null, FALSE)
	if(isnull(raw))
		error = "Peer unavailable"
		return null
	if(!istext(raw) || length(raw) > 25000)
		error = "Invalid response size"
		return null
	var/list/packet
	try
		packet = json_decode(raw)
	catch
		error = "Peer refused request"
		return null
	if(!islist(packet))
		error = "Invalid response structure"
		return null
	var/list/decoded = verify(packet["body"], packet["signature"])
	if(!decoded || decoded["nonce"] != nonce)
		error = "Peer authentication failed"
		log_world("INTERSERVER RPC [server_id] -> [peer_id]: [payload["command"]]: [decoded ? "response nonce mismatch" : verification_error]; elapsed [world.realtime - started] deciseconds")
		return null
	error = null
	return decoded
