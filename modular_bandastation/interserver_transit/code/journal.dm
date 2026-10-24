/// A checked, append-only sequence of immutable state images. The index is the directory itself.
/// A missing or corrupt record fails closed; it never means a fresh pair may be bootstrapped.
/datum/transit_journal
	var/root
	var/sequence = 0
	var/previous_hash = "genesis"
	var/list/state
	var/fault

/datum/transit_journal/New(directory)
	root = directory
	state = list()

/datum/transit_journal/proc/read_existing()
	if(sequence || fault)
		return FALSE
	var/list/files = flist(root)
	var/list/records = list()
	for(var/filename in files)
		if(copytext(filename, -5) != ".json")
			continue
		var/number = text2num(copytext(filename, 1, -5))
		if(number < 1 || number != round(number) || filename != "[number].json" || records["[number]"])
			fault = "Invalid journal filename"
			return FALSE
		records["[number]"] = filename
	for(var/number = 1; number <= length(records); number++)
		var/filename = records["[number]"]
		if(!filename)
			fault = "Missing journal record [number]"
			return FALSE
		var/list/record
		try
			record = json_decode(file2text("[root][filename]"))
		catch
			fault = "Unreadable journal record [number]"
			return FALSE
		if(!islist(record) || record["sequence"] != number || record["previous"] != previous_hash || !istext(record["body"]))
			fault = "Invalid journal chain at [number]"
			return FALSE
		var/record_hash = rustg_hash_string(RUSTG_HASH_SHA256, "[number]|[previous_hash]|[record["body"]]")
		if(record["hash"] != record_hash)
			fault = "Journal checksum mismatch at [number]"
			return FALSE
		try
			state = json_decode(record["body"])
		catch
			fault = "Invalid journal state at [number]"
			return FALSE
		if(!islist(state))
			fault = "Non-object journal state"
			return FALSE
		sequence = number
		previous_hash = record_hash
	return TRUE

/datum/transit_journal/proc/store(list/next_state)
	if(fault || !islist(next_state))
		return FALSE
	var/next_sequence = sequence + 1
	var/body = json_encode(next_state)
	var/record_hash = rustg_hash_string(RUSTG_HASH_SHA256, "[next_sequence]|[previous_hash]|[body]")
	var/encoded = json_encode(list("sequence" = next_sequence, "previous" = previous_hash, "hash" = record_hash, "body" = body))
	var/path = "[root][next_sequence].json"
	if(fexists(path))
		fault = "Refusing to overwrite journal record"
		return FALSE
	if(call_ext("transit_crypto", "transit_write")(path, encoded) != "1" || file2text(path) != encoded)
		fault = "Journal write failed"
		return FALSE
	sequence = next_sequence
	previous_hash = record_hash
	// Retain a detached image; callers may continue changing their working state.
	state = json_decode(body)
	return TRUE
