/// Geometry and visuals derive from arrival_box; this type does not register as SSshuttle.arrivals.
/area/shuttle/interserver_transit
	name = "Межстанционный пассажирский шаттл"

/datum/map_template/shuttle/interserver_transit
	port_id = "interserver"
	prefix = "_maps/shuttles/interserver/"
	who_can_purchase = null

/datum/map_template/shuttle/interserver_transit/box
	suffix = "box"
	name = "Межстанционный пассажирский шаттл"

/obj/docking_port/mobile/interserver_transit
	name = "пассажирский шаттл"
	shuttle_id = "interserver"
	dir = WEST
	port_direction = SOUTH
	preferred_direction = WEST
	area_type = /area/shuttle/interserver_transit
	movement_force = list("KNOCKDOWN" = 0, "THROW" = 0)
	var/transfer_locked = FALSE
	var/list/transfer_barriers = list()

/obj/docking_port/mobile/interserver_transit/Destroy()
	QDEL_LIST(transfer_barriers)
	return ..()

/// Dense invisible barriers fence ordinary entry while the immutable snapshot is in flight.
/obj/effect/interserver_transit_barrier
	name = "защитное поле"
	density = TRUE
	anchored = TRUE
	invisibility = INVISIBILITY_ABSTRACT

/obj/docking_port/mobile/interserver_transit/proc/set_transfer_lock(locked)
	transfer_locked = locked
	QDEL_LIST(transfer_barriers)
	transfer_barriers = list()
	if(!locked)
		return
	for(var/turf/tile as anything in return_ordered_turfs(x, y, z, dir))
		if(!tile || !shuttle_areas[get_area(tile)])
			continue
		transfer_barriers += new /obj/effect/interserver_transit_barrier(tile)
		for(var/obj/item/item in tile.get_all_contents_type(/obj/item))
			item.LoadComponent(/datum/component/transit_fixture)

/obj/docking_port/mobile/interserver_transit/check()
	// Custody and timers belong to SSinterserver_transit, not the ordinary arrivals scheduler.
	return

/obj/structure/closet/interserver_transit
	name = "пассажирский шкаф"
	desc = "Пустой шкаф для перевозимого багажа."

/obj/structure/closet/interserver_transit/PopulateContents()
	return

/// Available only on the explicitly derived local test maps.
/obj/structure/closet/interserver_test_supplies
	name = "шкаф дорожных принадлежностей"
	desc = "Запасная одежда и ручная кладь для пассажиров межстанционных рейсов."

/obj/structure/closet/interserver_test_supplies/PopulateContents()
	for(var/index = 1; index <= 8; index++)
		new /obj/item/clothing/under/color/grey(src)
		new /obj/item/clothing/shoes/sneakers/black(src)
		new /obj/item/storage/backpack(src)
		new /obj/item/storage/box(src)

/// Stage one has a fixed hull/fixture layout. Tools cannot create unrepresented fixture state.
/datum/component/transit_fixture

/datum/component/transit_fixture/Initialize()
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE
	RegisterSignals(parent, list(COMSIG_ATOM_ITEM_INTERACTION, COMSIG_ATOM_ITEM_INTERACTION_SECONDARY, COMSIG_ATOM_RANGED_ITEM_INTERACTION, COMSIG_ATOM_RANGED_ITEM_INTERACTION_SECONDARY), PROC_REF(block_item))
	RegisterSignal(parent, COMSIG_ATOM_TAKE_DAMAGE, PROC_REF(block_damage))
	RegisterSignals(parent, list(COMSIG_ATOM_ATTACK_HAND, COMSIG_ATOM_ATTACK_HAND_SECONDARY), PROC_REF(block_hand))
	RegisterSignal(parent, COMSIG_ATOM_EXIT, PROC_REF(block_exit))

/datum/component/transit_fixture/proc/is_locked()
	return istype(get_area(parent), /area/shuttle/interserver_transit) && SSinterserver_transit.ship?.transfer_locked

/datum/component/transit_fixture/proc/block_exit(datum/source, atom/movable/leaving)
	SIGNAL_HANDLER
	return is_locked() && !isobserver(leaving) ? COMPONENT_ATOM_BLOCK_EXIT : NONE

/datum/component/transit_fixture/proc/block_hand(datum/source, mob/user)
	SIGNAL_HANDLER
	if(!istype(get_area(parent), /area/shuttle/interserver_transit))
		return NONE
	if(is_locked())
		return COMPONENT_CANCEL_ATTACK_CHAIN
	if(ishuman(user))
		var/mob/living/carbon/human/human = user
		if(human.transit_frozen)
			return COMPONENT_CANCEL_ATTACK_CHAIN
	if(istype(parent, /obj/structure/chair) || istype(parent, /obj/structure/closet/interserver_transit) || istype(parent, /obj/machinery/computer/interserver_transit) || istype(parent, /obj/machinery/door))
		return NONE
	return COMPONENT_CANCEL_ATTACK_CHAIN

/datum/component/transit_fixture/proc/block_item(datum/source, mob/user)
	SIGNAL_HANDLER
	if(!istype(get_area(parent), /area/shuttle/interserver_transit))
		return NONE
	if(ismob(user))
		to_chat(user, span_warning("Бортовое оборудование опломбировано транспортной службой. Разместите багаж в пассажирских шкафах или на полу, не загораживая проход."))
	return ITEM_INTERACT_BLOCKING

/datum/component/transit_fixture/proc/block_damage()
	SIGNAL_HANDLER
	return istype(get_area(parent), /area/shuttle/interserver_transit) ? COMPONENT_NO_TAKE_DAMAGE : NONE

/obj/docking_port/mobile/interserver_transit/proc/protect_fixtures()
	for(var/turf/tile as anything in return_ordered_turfs(x, y, z, dir))
		if(!tile || !shuttle_areas[get_area(tile)])
			continue
		tile.LoadComponent(/datum/component/transit_fixture)
		for(var/obj/fixture in tile)
			if(!isitem(fixture) && !istype(fixture, /obj/docking_port))
				fixture.LoadComponent(/datum/component/transit_fixture)
