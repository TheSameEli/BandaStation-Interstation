/// Bounded, immutable snapshot spool. No transmitted path is ever used as a filename.
/// An operation is reserved separately in the ownership journal before allocating this store.
/datum/transit_snapshot_store
	var/root
	var/digest
	var/total_chunks
	var/total_bytes
	var/error

/datum/transit_snapshot_store/New(directory, expected_digest, expected_chunks, expected_bytes)
	root = directory
	digest = expected_digest
	total_chunks = expected_chunks
	total_bytes = expected_bytes

/datum/transit_snapshot_store/proc/valid_manifest()
	if(!istext(digest) || length(digest) != 64 || !isnum(total_chunks) || total_chunks != round(total_chunks) || total_chunks < 1 || total_chunks > 512 || !isnum(total_bytes) || total_bytes != round(total_bytes) || total_bytes < 1 || total_bytes > 2097152)
		return FALSE
	return total_chunks == ceil(total_bytes / 4096)

/datum/transit_snapshot_store/proc/put(index, chunk)
	error = null
	if(!valid_manifest() || !isnum(index) || index != round(index) || index < 1 || index > total_chunks || !istext(chunk))
		error = "Invalid snapshot chunk"
		return FALSE
	var/expected_size = index == total_chunks ? total_bytes - (total_chunks - 1) * 4096 : 4096
	if(length(chunk) != expected_size)
		error = "Snapshot chunk size mismatch"
		return FALSE
	var/path = "[root][index].chunk"
	if(fexists(path))
		if(file2text(path) != chunk)
			error = "Conflicting duplicate snapshot chunk"
			return FALSE
		return TRUE
	if(call_ext("transit_crypto", "transit_write")(path, chunk) != "1" || file2text(path) != chunk)
		error = "Snapshot storage failed"
		return FALSE
	return TRUE

/datum/transit_snapshot_store/proc/assemble()
	error = null
	if(!valid_manifest())
		error = "Invalid snapshot manifest"
		return null
	var/list/pieces = list()
	for(var/index = 1; index <= total_chunks; index++)
		var/path = "[root][index].chunk"
		if(!fexists(path))
			error = "Missing snapshot chunk [index]"
			return null
		pieces += file2text(path)
	var/body = jointext(pieces, "")
	if(length(body) != total_bytes || rustg_hash_string(RUSTG_HASH_SHA256, body) != digest)
		error = "Snapshot checksum mismatch"
		return null
	return body
