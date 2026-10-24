/obj/item/card/id
	var/transit_bank_server
	var/transit_bank_round
	var/transit_bank_id

/// Finite factories. A wire token can never select an arbitrary DM type.
/datum/transit_items
	var/error
	var/count = 0
	var/server_id
	var/round_id
	var/datum/transit_values/values
	var/static/list/factory_traits
	var/list/factories = list(
		"backpack" = /obj/item/storage/backpack,
		"satchel" = /obj/item/storage/backpack/satchel,
		"box" = /obj/item/storage/box,
		"grey_uniform" = /obj/item/clothing/under/color/grey,
		"black_uniform" = /obj/item/clothing/under/color/black,
		"black_shoes" = /obj/item/clothing/shoes/sneakers/black,
		"id" = /obj/item/card/id,
		"advanced_id" = /obj/item/card/id/advanced,
	)
	var/list/common_fields = list("name", "desc", "dir", "color", "greyscale_colors", "pixel_x", "pixel_y", "fingerprintslast")
	var/list/forensic_fields = list("fingerprints", "hiddenprints", "fibers")
	var/list/id_fields = list("registered_name", "registered_age", "assignment", "access", "wildcard_slots", "is_intern", "trim_changeable", "honorific_position", "chosen_honorific", "icon_state", "transit_bank_server", "transit_bank_round", "transit_bank_id")

/datum/transit_items/New(local_server, local_round)
	server_id = local_server
	round_id = local_round
	values = new
	if(isnull(factory_traits))
		factory_traits = list()
		for(var/token in factories)
			var/path = factories[token]
			var/obj/item/probe = new path(null)
			var/list/traits = list()
			for(var/trait in probe._status_traits)
				traits += trait
			factory_traits[token] = traits
			qdel(probe)
	for(var/path in typesof(/datum/id_trim))
		values.paths["[path]"] = path
	if(SSinterserver_transit.diagnostic_mode)
		for(var/path in typesof(/obj/item))
			factories["[path]"] = path

/datum/transit_items/Destroy()
	QDEL_NULL(values)
	return ..()

/datum/transit_items/proc/reject(reason)
	error = reason
	return null

/datum/transit_items/proc/encode_forensics(atom/source)
	if(!source.forensics)
		return null
	if(length(source.forensics.blood_DNA))
		if(!SSinterserver_transit.diagnostic_mode)
			return reject("[source.name]: следы крови пока не поддерживаются")
		transit_diagnostic_note("[source.name]: следы крови не восстановлены; остальные следы переносятся")
	var/list/record = values.export_fields(source.forensics, forensic_fields)
	if(values.error)
		return reject(values.error)
	return record

/datum/transit_items/proc/decode_forensics(atom/target, list/record)
	if(isnull(record))
		return TRUE
	if(!target.forensics)
		target.forensics = new /datum/forensics(target)
	return values.import_fields(target.forensics, forensic_fields, record)

/datum/transit_items/proc/encode_item(obj/item/item, depth = 0)
	if(error)
		return null
	if(++count > 500 || depth > 8 || QDELETED(item))
		return reject("Слишком много предметов или слишком глубокая вложенность")
	var/token
	for(var/candidate in factories)
		if(item.type == factories[candidate])
			token = candidate
			break
	if(!token)
		return reject("Не поддерживается предмет: [item.name] ([item.type])")
	var/diagnostic = SSinterserver_transit.diagnostic_mode
	for(var/trait in item._status_traits)
		if(diagnostic)
			continue
		if(trait in factory_traits[token])
			continue // Local factories recreate innate/derived traits with local references.
		if(trait != TRAIT_TASTEFULLY_THICK_ID_CARD || !isidcard(item))
			return reject("[item.name]: неподдерживаемое свойство [trait]")
	if(!diagnostic && (item.anchored != initial(item.anchored) || item.w_class != initial(item.w_class) || item.resistance_flags != initial(item.resistance_flags)))
		return reject("[item.name]: изменены крепление, размер или сопротивления")
	if(!diagnostic && (item.reagents?.total_volume || item.get_integrity() != item.max_integrity || item.max_integrity != initial(item.max_integrity) || item.force != initial(item.force) || item.throwforce != initial(item.throwforce)))
		return reject("[item.name]: реагенты, повреждения или изменённые параметры")
	for(var/datum/component/component as anything in item.GetComponents(/datum/component))
		if(diagnostic)
			transit_diagnostic_note("[item.type]: компонент [component.type] восстанавливается конструктором, его изменённое состояние отдельно не переносится", notify = FALSE)
			continue
		if(istype(component, /datum/component/transit_fixture))
			continue
		if(!istype(component, /datum/component/bloodysoles))
			return reject("[item.name]: неподдерживаемый компонент [component.type]")
		var/datum/component/bloodysoles/soles = component
		if(soles.total_bloodiness)
			return reject("[item.name]: окровавленная одежда")
	var/list/record = list("kind" = token, "fields" = values.export_fields(item, common_fields), "forensics" = encode_forensics(item), "children" = list())
	if(diagnostic)
		record["portable"] = transit_export_portable(item)
		var/list/links = list()
		for(var/field in item.vars)
			if(transit_portable_field(field) && isitem(item.vars[field]) && (item.vars[field] in item.contents))
				links[field] = item.contents.Find(item.vars[field])
		record["links"] = links
		if(item.reagents?.total_volume)
			transit_diagnostic_note("[item.type]: химия предмета пока не восстановлена из локальной ссылки reagents")
	if(istype(item, /obj/item/clothing))
		var/obj/item/clothing/clothes = item
		if(!diagnostic && (clothes.damaged_clothes != CLOTHING_PRISTINE || length(clothes.zones_disabled)))
			return reject("[item.name]: повреждённая одежда")
	if(istype(item, /obj/item/clothing/under))
		var/obj/item/clothing/under/uniform = item
		if(!diagnostic && (length(uniform.attached_accessories) || uniform.adjusted != NORMAL_STYLE || uniform.has_sensor != initial(uniform.has_sensor)))
			return reject("[item.name]: снимите аксессуары, расправьте форму и восстановите датчики")
		record["uniform"] = values.export_fields(uniform, list("sensor_mode", "adjusted"))
	if(istype(item, /obj/item/clothing/shoes))
		var/obj/item/clothing/shoes/shoes = item
		if(!diagnostic && shoes.tied != SHOES_TIED)
			return reject("[item.name]: сначала завяжите обувь")
		record["shoes"] = values.export_fields(item, list("tied", "alternate_worn_layer"))
	if(isidcard(item))
		var/obj/item/card/id/card = item
		record["thick"] = !!HAS_TRAIT(card, TRAIT_TASTEFULLY_THICK_ID_CARD)
		if(card.registered_account && !card.registered_account.replaceable && !card.transit_bank_server)
			card.transit_bank_server = server_id
			card.transit_bank_round = round_id
			card.transit_bank_id = card.registered_account.account_id
		record["id"] = values.export_fields(card, id_fields)
		record["trim"] = values.encode(card.trim?.type)
	var/list/children = record["children"]
	if(!diagnostic && length(item.contents) && !istype(item, /obj/item/storage))
		return reject("[item.name]: неподдерживаемое содержимое")
	for(var/atom/movable/child as anything in item.contents)
		if(!isitem(child))
			return reject("В контейнере [item.name] находится живое существо или неподдерживаемый объект")
		var/list/child_record = encode_item(child, depth + 1)
		if(error)
			return null
		children += list(child_record)
	if(values.error)
		return reject(values.error)
	return error ? null : record

/datum/transit_items/proc/decode_item(list/record, atom/container, depth = 0)
	if(error || ++count > 500 || depth > 8 || !islist(record) || !istext(record["kind"]) || !factories[record["kind"]] || !islist(record["children"]))
		return reject("Некорректная запись предмета")
	var/path = factories[record["kind"]]
	var/obj/item/item = new path(container)
	// Only the empty container base types above are factories; never clone random PopulateContents output.
	if(length(item.contents))
		if(!SSinterserver_transit.diagnostic_mode)
			qdel(item)
			return reject("Каталог контейнеров не совпадает со сборкой")
		var/list/generated = item.get_all_contents_type(/obj/item)
		generated -= item
		QDEL_LIST(generated)
	if(SSinterserver_transit.diagnostic_mode && !transit_import_portable(item, record["portable"]))
		qdel(item)
		return reject("Некорректные значения предмета")
	if(!values.import_fields(item, common_fields, record["fields"]) || !decode_forensics(item, record["forensics"]))
		qdel(item)
		return reject(values.error || "Некорректные следы предмета")
	if(istype(item, /obj/item/clothing/under))
		var/obj/item/clothing/under/uniform = item
		if(!values.import_fields(uniform, list("sensor_mode", "adjusted"), record["uniform"]))
			qdel(item)
			return reject(values.error)
		uniform.update_wearer_status()
	if(istype(item, /obj/item/clothing/shoes))
		if(!values.import_fields(item, list("tied", "alternate_worn_layer"), record["shoes"]))
			qdel(item)
			return reject(values.error)
	if(isidcard(item))
		var/obj/item/card/id/card = item
		REMOVE_TRAIT_NOT_FROM(card, TRAIT_TASTEFULLY_THICK_ID_CARD, null)
		if(record["thick"])
			ADD_TRAIT(card, TRAIT_TASTEFULLY_THICK_ID_CARD, ROUNDSTART_TRAIT)
		card.clear_account()
		if(!values.import_fields(card, id_fields, record["id"]))
			qdel(item)
			return reject(values.error)
		var/trim_path = values.decode(record["trim"])
		card.trim = SSid_access.trim_singletons_by_path[trim_path]
		if(card.transit_bank_server == server_id)
			if(card.transit_bank_round != round_id)
				qdel(item)
				return reject("Банковский счёт принадлежит завершённому раунду")
			var/datum/bank_account/account = SSeconomy.bank_accounts_by_id["[card.transit_bank_id]"]
			if(!account)
				qdel(item)
				return reject("Исходный банковский счёт не найден")
			card.set_account(account)
		card.update_label()
	var/list/restored_children = list()
	for(var/list/child_record as anything in record["children"])
		var/obj/item/child = decode_item(child_record, item, depth + 1)
		if(!child)
			qdel(item)
			return null
		restored_children += child
	if(SSinterserver_transit.diagnostic_mode)
		var/list/links = record["links"]
		for(var/field in links)
			var/index = links[field]
			if(transit_portable_field(field) && (field in item.vars) && isnum(index) && index >= 1 && index <= length(restored_children))
				item.vars[field] = restored_children[index]
	item.update_appearance()
	return item
