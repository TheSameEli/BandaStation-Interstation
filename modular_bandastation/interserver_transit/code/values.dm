/// Explicit values only: no datum references, arbitrary vars, executable paths or JSON float rounding.
/datum/transit_values
	var/error
	var/nodes = 0
	var/list/paths = list()

/datum/transit_values/proc/reject(reason)
	error = reason
	return null

/datum/transit_values/proc/encode(value, depth = 0)
	if(error || ++nodes > 20000 || depth > 12)
		return reject("State exceeds value limits")
	if(isnull(value))
		return list("null" = TRUE)
	if(isnum(value))
		return list("number" = num2text(value, 20))
	if(istext(value))
		if(length(value) > 16384)
			return reject("Text exceeds transfer limit")
		return list("text" = value)
	if(ispath(value))
		if(paths["[value]"] != value)
			return reject("Unsupported data path [value]")
		return list("path" = "[value]")
	if(!islist(value) || length(value) > 1024)
		return reject("Unsupported reference in state")
	var/list/rows = list()
	var/list/values = value
	for(var/index = 1; index <= length(values); index++)
		var/key = values[index]
		var/list/row = list("key" = encode(key, depth + 1))
		if(istext(key) || ispath(key))
			if(!isnull(values[key]))
				row["value"] = encode(values[key], depth + 1)
		rows += list(row)
	return list("list" = rows)

/datum/transit_values/proc/decode(list/node, depth = 0)
	if(error || ++nodes > 20000 || depth > 12 || !islist(node) || length(node) != 1)
		return reject("Malformed state value")
	if("null" in node)
		return null
	if("text" in node)
		if(!istext(node["text"]) || length(node["text"]) > 16384)
			return reject("Invalid text value")
		return node["text"]
	if("number" in node)
		if(!istext(node["number"]) || length(node["number"]) > 64)
			return reject("Invalid numeric value")
		var/value = text2num(node["number"])
		if(!isnum(value))
			return reject("Invalid numeric value")
		return value
	if("path" in node)
		if(!istext(node["path"]) || !paths[node["path"]])
			return reject("Unknown data path")
		return paths[node["path"]]
	var/list/rows = node["list"]
	if(!islist(rows) || length(rows) > 1024)
		return reject("Invalid list value")
	var/list/result = list()
	for(var/list/row as anything in rows)
		if(!islist(row) || !("key" in row) || length(row) > 2)
			return reject("Invalid list entry")
		var/key = decode(row["key"], depth + 1)
		if("value" in row)
			if(!istext(key) && !ispath(key))
				return reject("Invalid associative key")
			result[key] = decode(row["value"], depth + 1)
		else
			result += list(key)
	return result

/datum/transit_values/proc/export_fields(datum/source, list/fields)
	var/list/result = list()
	for(var/field in fields)
		if(!(field in source.vars))
			return reject("Unsupported build field [field]")
		result[field] = encode(source.vars[field])
	return error ? null : result

/datum/transit_values/proc/import_fields(datum/target, list/fields, list/record)
	if(!islist(record) || length(record) != length(fields))
		reject("Malformed field record")
		return FALSE
	var/list/decoded = list()
	for(var/field in fields)
		if(!(field in target.vars) || !(field in record))
			reject("Unknown or missing state field")
			return FALSE
		decoded[field] = decode(record[field])
	if(error)
		return FALSE
	for(var/field in fields)
		target.vars[field] = decoded[field]
	return TRUE
