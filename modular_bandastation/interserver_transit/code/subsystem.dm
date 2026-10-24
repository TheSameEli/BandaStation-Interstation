SUBSYSTEM_DEF(interserver_transit)
	name = "Interserver transit"
	wait = 1 SECONDS
	runlevels = RUNLEVEL_LOBBY | RUNLEVEL_SETUP | RUNLEVEL_GAME | RUNLEVEL_POSTGAME
	dependencies = list(/datum/controller/subsystem/shuttle)
	can_fire = FALSE
	var/enabled = FALSE
	var/request_pending = FALSE
	var/peer_reachable = FALSE
	var/peer_round
	var/last_reply = 0
	var/next_probe = 0
	var/fault
	var/datum/transit_peer/game/peer
	var/datum/transit_journal/journal
	var/list/quarantined_accounts = list()

/datum/controller/subsystem/interserver_transit/Initialize()
	var/path = "[global.config.directory]/interserver_transit.json"
	if(!fexists(path))
		return SS_INIT_SUCCESS
	var/list/settings
	try
		settings = json_decode(file2text(path))
	catch
		fault = "Invalid interserver_transit.json"
		return SS_INIT_SUCCESS
	if(!islist(settings) || !settings["enabled"])
		return SS_INIT_SUCCESS
	if(!fexists("transit_crypto.dll"))
		fault = "Missing transit_crypto.dll"
		return SS_INIT_SUCCESS
	var/regex/identifier = regex("^\[A-Za-z0-9_-]{1,40}$")
	var/regex/key_pattern = regex("^\[a-fA-F0-9]{64}$")
	var/regex/address_pattern = regex("^127\\.0\\.0\\.1:\[0-9]{4,5}$")
	if(!istext(settings["server_id"]) || !identifier.Find(settings["server_id"]) || !istext(settings["peer_id"]) || !identifier.Find(settings["peer_id"]) || settings["server_id"] == settings["peer_id"] || !istext(settings["pair_id"]) || !identifier.Find(settings["pair_id"]) || !istext(settings["secret"]) || !key_pattern.Find(settings["secret"]) || !istext(settings["peer_address"]) || !address_pattern.Find(settings["peer_address"]))
		fault = "Invalid local transit configuration"
		return SS_INIT_SUCCESS
	peer = new
	peer.server_id = settings["server_id"]
	peer.peer_id = settings["peer_id"]
	peer.pair_id = settings["pair_id"]
	peer.peer_address = settings["peer_address"]
	peer.secret = settings["secret"]
	peer.build_id = rustg_hash_file(RUSTG_HASH_SHA256, "tgstation.dmb")
	peer.round_id = rustg_csprng_chacha20("hex", 32)
	if(length(peer.build_id) != 64 || length(peer.round_id) != 64 || length(peer.sign_payload("self-test")) != 64)
		fault = "Transit crypto initialization failed"
		return SS_INIT_SUCCESS
	journal = new("data/interserver/[peer.pair_id]/")
	if(!journal.read_existing())
		fault = journal.fault
		return SS_INIT_SUCCESS
	// Existing operations must be reconciled before any game action after a cold restart.
	if(journal.sequence)
		var/list/old_departed = journal.state["departed"]
		for(var/account in old_departed)
			quarantined_accounts[account] = TRUE
		var/list/old_operations = journal.state["operations"]
		for(var/id in old_operations)
			var/list/old_operation = old_operations[id]
			for(var/list/admission as anything in old_operation["admissions"])
				quarantined_accounts[admission["ckey"]] = TRUE
		fault = "Previous transit journal requires round reconciliation"
		log_world("INTERSERVER [peer.server_id]: [fault]; previous passengers cannot create another body")
		return SS_INIT_SUCCESS
	enabled = TRUE
	can_fire = TRUE
	// A server with no clients must still answer reservations and complete recovery.
	Master.sleep_offline_after_initializations = FALSE
	world.sleep_offline = FALSE
	initialize_game(settings)
	log_world("INTERSERVER [peer.server_id]: authenticated transport initialized")
	return SS_INIT_SUCCESS

/datum/controller/subsystem/interserver_transit/fire(resumed)
	if(!enabled || fault)
		return
	if(!request_pending && world.time >= next_probe)
		request_pending = TRUE
		next_probe = world.time + 5 SECONDS
		INVOKE_ASYNC(src, PROC_REF(probe_peer))
	if(current_id && !driver_busy)
		driver_busy = TRUE
		INVOKE_ASYNC(src, PROC_REF(drive_operation))

/datum/controller/subsystem/interserver_transit/proc/probe_peer()
	var/list/response = peer.request(list("command" = "HELLO"))
	var/list/payload = response?["payload"]
	var/was_reachable = peer_reachable
	peer_reachable = islist(payload) && payload["command"] == "HELLO" && payload["server"] == peer.peer_id
	if(peer_reachable)
		clear_transport_error()
		peer_round = response["round"]
		last_reply = world.time
		synchronize(response)
	if(peer_reachable != was_reachable)
		log_world("INTERSERVER [peer.server_id]: peer [peer.peer_id] [peer_reachable ? "authenticated" : "unavailable"]")
	request_pending = FALSE

/datum/transit_peer/game/dispatch(list/payload, remote_round)
	if(!SSinterserver_transit.enabled)
		return list("error" = "Transit unavailable")
	return SSinterserver_transit.handle_request(payload, remote_round)

/datum/world_topic/interserver_transit
	keyword = "interserver_transit"
	log = FALSE
	require_comms_key = FALSE // Exact request and response bytes are authenticated with the pair's separate HMAC key.

/datum/world_topic/interserver_transit/Run(list/input)
	if(!SSinterserver_transit.enabled)
		return "UNAVAILABLE"
	return SSinterserver_transit.peer.receive(input["body"], input["signature"])
