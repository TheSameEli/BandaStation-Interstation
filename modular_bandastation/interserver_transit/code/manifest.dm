/datum/transit_manifest
	var/error
	var/datum/transit_characters/characters
	var/datum/transit_items/items
	var/list/bodies = list()
	var/list/cargo = list()
	var/list/passengers = list()
	var/list/data
	var/owns_staging = FALSE

/datum/transit_manifest/New(local_server, local_round)
	characters = new(local_server, local_round)
	items = new(local_server, local_round)

/datum/transit_manifest/Destroy()
	if(owns_staging)
		discard_objects()
	bodies = null
	cargo = null
	passengers = null
	data = null
	QDEL_NULL(characters)
	QDEL_NULL(items)
	return ..()

/datum/transit_manifest/proc/discard_objects()
	var/list/all_items = list()
	for(var/mob/living/carbon/human/human as anything in bodies)
		if(QDELETED(human))
			continue
		all_items |= human.get_all_contents_type(/obj/item)
		var/datum/mind/mind = human.mind
		qdel(human)
		qdel(mind)
	for(var/obj/item/item as anything in cargo)
		if(!QDELETED(item))
			all_items |= item.get_all_contents_type(/obj/item)
	QDEL_LIST(all_items)
	cargo.Cut()
	bodies.Cut()
	passengers.Cut()
	owns_staging = FALSE

/datum/transit_manifest/proc/reject(reason)
	error = reason
	return null

/datum/transit_manifest/proc/encode(obj/docking_port/mobile/interserver_transit/ship, list/baseline, allow_clientless = FALSE)
	var/list/tiles = ship.return_ordered_turfs(ship.x, ship.y, ship.z, ship.dir)
	var/list/current_layout = layout(ship)
	if(json_encode(current_layout) != json_encode(baseline))
		for(var/index = 1; index <= length(current_layout); index++)
			if(json_encode(current_layout[index]) != json_encode(baseline[index]))
				log_world("INTERSERVER layout difference at tile [index]: [json_encode(baseline[index])] -> [json_encode(current_layout[index])]")
		return reject("Корпус или оборудование шаттла изменены. Первый этап поддерживает исходную тестовую компоновку.")
	var/list/people_records = list()
	var/list/cargo_records = list()
	var/list/fixture_records = list()
	for(var/index = 1; index <= length(tiles); index++)
		var/turf/tile = tiles[index]
		if(!tile || !ship.shuttle_areas[get_area(tile)])
			continue
		for(var/obj/fixture in tile.contents)
			if(isitem(fixture) || istype(fixture, /obj/docking_port) || istype(fixture, /obj/effect/interserver_transit_barrier) || istype(fixture, /obj/effect/abstract/z_holder))
				continue
			if(istype(fixture, /obj/structure/closet/interserver_transit))
				var/obj/structure/closet/locker = fixture
				fixture_records += list(list("tile" = index, "type" = "[fixture.type]", "dir" = fixture.dir, "opened" = locker.opened))
				for(var/atom/movable/contained as anything in locker.contents)
					if(!isitem(contained))
						return reject("В шкафу находится неподдерживаемое существо или объект")
					cargo_records += list(list("tile" = index, "container" = "[fixture.type]", "item" = items.encode_item(contained)))
					cargo += contained
			else if(istype(fixture, /obj/structure/chair))
				fixture_records += list(list("tile" = index, "type" = "[fixture.type]", "facing" = dir2angle(fixture.dir) - dir2angle(ship.dir)))
		for(var/mob/living/mob in tile.contents)
			if(!ishuman(mob) || (!allow_clientless && (!mob.client || (is_guest_key(mob.key) && !SSinterserver_transit.diagnostic_mode))))
				log_world("INTERSERVER boarding refused: type=[mob.type], connected=[!!mob.client], guest=[is_guest_key(mob.key)], diagnostic=[SSinterserver_transit.diagnostic_mode]")
				return reject("Пассажиры должны быть живыми людьми с учётной записью BYOND; существа без клиента не поддерживаются")
			var/mob/living/carbon/human/human = mob
			var/list/person = characters.encode_human(human, allow_clientless)
			if(!person)
				return reject("[human.real_name]: [characters.error]")
			var/list/entry = list("tile" = index, "facing" = dir2angle(human.dir) - dir2angle(ship.dir), "person" = person)
			if(human.buckled)
				if(!istype(human.buckled, /obj/structure/chair) || human.buckled.loc != tile)
					return reject("[human.real_name]: неподдерживаемая привязка к объекту")
				entry["chair"] = "[human.buckled.type]"
			people_records += list(entry)
			bodies += human
			passengers[person["ckey"]] = human
		for(var/obj/item/item in tile.contents)
			cargo_records += list(list("tile" = index, "item" = items.encode_item(item)))
			cargo += item
	if(length(people_records) > 8)
		return reject("Не более восьми пассажиров за рейс")
	if(items.error)
		return reject(items.error)
	if(items.count + characters.items.count > 500)
		return reject("Общий предел багажа и груза — 500 предметов")
	data = list("schema" = 1, "layout" = rustg_hash_string(RUSTG_HASH_SHA256, json_encode(baseline)), "people" = people_records, "cargo" = cargo_records, "fixtures" = fixture_records)
	return data

/datum/transit_manifest/proc/decode(list/snapshot, obj/docking_port/mobile/interserver_transit/ship)
	if(!islist(snapshot) || snapshot["schema"] != 1 || !islist(snapshot["people"]) || length(snapshot["people"]) > 8 || !islist(snapshot["cargo"]) || length(snapshot["cargo"]) > 500 || !islist(snapshot["fixtures"]) || length(snapshot["fixtures"]) > 100)
		return reject("Некорректный манифест")
	if(snapshot["layout"] != rustg_hash_string(RUSTG_HASH_SHA256, json_encode(layout(ship))))
		return reject("Геометрия или оборудование приёмного шаттла не совпадают")
	owns_staging = TRUE
	var/list/tiles = ship.return_ordered_turfs(ship.x, ship.y, ship.z, ship.dir)
	for(var/list/entry as anything in snapshot["fixtures"])
		var/turf/tile = checked_tile(tiles, entry["tile"], ship)
		if(!tile)
			return reject("Некорректное место оборудования")
		if(isnum(entry["facing"]))
			var/obj/structure/chair/chosen
			for(var/obj/structure/chair/chair in tile)
				if("[chair.type]" == entry["type"])
					chosen = chair
			if(!chosen)
				return reject("Не найдено исходное кресло")
			chosen.setDir(angle2dir(entry["facing"] + dir2angle(ship.dir)))
			continue
		var/obj/structure/closet/interserver_transit/locker = locate() in tile
		if(!tile || !locker || entry["type"] != "[locker.type]")
			return reject("Оборудование приёмного шаттла не совпадает")
		if(entry["opened"])
			locker.open()
		else
			locker.close()
	for(var/list/entry as anything in snapshot["people"])
		var/turf/tile = checked_tile(tiles, entry["tile"], ship)
		var/list/person = entry["person"]
		if(!tile || !islist(person) || passengers[person["ckey"]])
			return reject("Некорректное место или повтор пассажира")
		var/mob/living/carbon/human/human = characters.decode_human(person, tile)
		if(!human)
			return reject(characters.error)
		bodies += human
		passengers[person["ckey"]] = human
		human.setDir(angle2dir(entry["facing"] + dir2angle(ship.dir)))
		if(entry["chair"])
			var/obj/structure/chair/chosen
			for(var/obj/structure/chair/chair in tile)
				if("[chair.type]" == entry["chair"])
					chosen = chair
			if(!chosen || !chosen.buckle_mob(human, force = TRUE))
				return reject("Не удалось восстановить пристёгивание")
	for(var/list/entry as anything in snapshot["cargo"])
		var/turf/tile = checked_tile(tiles, entry["tile"], ship)
		if(!tile)
			return reject("Некорректное место груза")
		var/atom/container = tile
		if(entry["container"])
			var/obj/structure/closet/interserver_transit/locker = locate() in tile
			if(!locker || entry["container"] != "[locker.type]")
				return reject("Не найден шкаф груза")
			container = locker
		var/obj/item/item = items.decode_item(entry["item"], container)
		if(!item)
			return reject(items.error)
		cargo += item
	if(items.count + characters.items.count > 500)
		return reject("Общий предел багажа и груза превышен")
	data = snapshot
	return TRUE

/datum/transit_manifest/proc/checked_tile(list/tiles, index, obj/docking_port/mobile/ship)
	if(!isnum(index) || index != round(index) || index < 1 || index > length(tiles))
		return null
	var/turf/tile = tiles[index]
	return tile && ship.shuttle_areas[get_area(tile)] ? tile : null

/datum/transit_manifest/proc/layout(obj/docking_port/mobile/ship)
	var/list/result = list()
	for(var/turf/tile as anything in ship.return_ordered_turfs(ship.x, ship.y, ship.z, ship.dir))
		if(!tile || !ship.shuttle_areas[get_area(tile)])
			result += list(null)
			continue
		var/list/kinds = list()
		for(var/obj/fixture in tile)
			if(isitem(fixture) || istype(fixture, /obj/docking_port) || istype(fixture, /obj/effect/interserver_transit_barrier) || istype(fixture, /obj/effect/abstract/z_holder))
				continue
			kinds += "[fixture.type]"
		result += list(list("turf" = "[tile.type]", "fixtures" = sort_list(kinds)))
	return result
