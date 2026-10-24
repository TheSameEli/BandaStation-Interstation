#ifdef UNIT_TESTS
/datum/unit_test/interserver_character_roundtrip
#ifdef TRANSIT_PROFILE_TEST
	test_flags = UNIT_TEST_FOCUS
#endif

/datum/unit_test/interserver_character_roundtrip/Run()
	var/mob/living/carbon/human/source = allocate(/mob/living/carbon/human)
	var/datum/mind/original_mind = new("TransitTest")
	allocated += original_mind
	original_mind.set_assigned_role(SSjob.get_job_type(/datum/job/assistant))
	original_mind.transfer_to(source)
	source.add_personality(/datum/personality/spiritual)
	for(var/obj/item/organ/organ as anything in source.organs)
		ADD_TRAIT(organ, TRAIT_CLIENT_STARTING_ORGAN, ROUNDSTART_TRAIT)
	var/obj/item/organ/liver/liver = source.get_organ_slot(ORGAN_SLOT_LIVER)
	liver.add_traits(original_mind.assigned_role.liver_traits, JOB_TRAIT)
	source.real_name = "Тестовый Пассажир"
	source.name = source.real_name
	source.hairstyle = "Bald"
	var/obj/item/storage/backpack/bag = allocate(/obj/item/storage/backpack)
	var/obj/item/storage/backpack/inner_bag = allocate(/obj/item/storage/backpack, bag)
	inner_bag.name = "Вложенная сумка"
	source.equip_to_slot_if_possible(bag, ITEM_SLOT_BACK, disable_warning = TRUE, bypass_equip_delay_self = TRUE)
	var/obj/item/clothing/under/color/grey/uniform = allocate(/obj/item/clothing/under/color/grey)
	source.equip_to_slot_if_possible(uniform, ITEM_SLOT_ICLOTHING, disable_warning = TRUE, bypass_equip_delay_self = TRUE)
	var/obj/item/clothing/shoes/sneakers/black/shoes = allocate(/obj/item/clothing/shoes/sneakers/black)
	source.equip_to_slot_if_possible(shoes, ITEM_SLOT_FEET, disable_warning = TRUE, bypass_equip_delay_self = TRUE)
	var/datum/bank_account/account = new(source.real_name, original_mind.assigned_role)
	allocated += account
	account.adjust_money(321)
	source.account_id = account.account_id
	original_mind.add_memory(/datum/memory/key/account, remembered_id = account.account_id)
	var/obj/item/card/id/advanced/card = allocate(/obj/item/card/id/advanced)
	SSid_access.apply_trim_to_card(card, /datum/id_trim/job/assistant)
	card.registered_name = source.real_name
	card.set_account(account)
	card.update_label()
	source.equip_to_slot_if_possible(card, ITEM_SLOT_ID, disable_warning = TRUE, bypass_equip_delay_self = TRUE)
	var/obj/item/storage/box/held_box = allocate(/obj/item/storage/box)
	source.put_in_hand(held_box, 2, forced = TRUE)
	var/obj/item/bodypart/arm = source.get_bodypart(BODY_ZONE_L_ARM)
	arm.receive_damage(7, 3, wound_bonus = CANT_WOUND)
	var/datum/transit_characters/writer = new("A", "round-A")
	var/list/snapshot = writer.encode_human(source, allow_clientless = TRUE)
	if(!snapshot)
		Fail("Export rejected fixture: [writer.error]", __FILE__, __LINE__)
		qdel(writer)
		return
	var/datum/transit_characters/reader = new("B", "round-B")
	var/mob/living/carbon/human/restored = reader.decode_human(json_decode(json_encode(snapshot)), run_loc_floor_bottom_left)
	if(!restored)
		Fail("Import rejected fixture: [reader.error]", __FILE__, __LINE__)
		qdel(writer)
		qdel(reader)
		return
	allocated += restored
	allocated += restored.mind
	if(!HAS_PERSONALITY(restored, /datum/personality/spiritual) || !HAS_TRAIT_FROM(restored, TRAIT_SPIRITUAL, PERSONALITY_TRAIT))
		Fail("Spiritual personality and its trait were not restored", __FILE__, __LINE__)
	if(restored.real_name != source.real_name || restored.mind.transit_identity != source.mind.transit_identity || restored.mind.key != ckey(original_mind.key) || restored.mind.assigned_role != original_mind.assigned_role || restored.get_brute_loss() != source.get_brute_loss() || restored.get_fire_loss() != source.get_fire_loss() || length(restored.back.contents) != 1 || !restored.transit_frozen || restored.client)
		Fail("Character identity, health, inventory or staging isolation mismatch", __FILE__, __LINE__)
	var/obj/item/card/id/foreign_card = restored.wear_id
	if(foreign_card.registered_account || restored.account_id || foreign_card.transit_bank_id != account.account_id || json_encode(foreign_card.access) != json_encode(card.access))
		Fail("Foreign account was duplicated or ID data changed", __FILE__, __LINE__)
	source.transit_freeze()
	if(source.held_items[2] != held_box || held_box.loc != source)
		Fail("Freezing lost a held item", __FILE__, __LINE__)
	if(!account.transit_locked || account.adjust_money(10) || account.account_balance != 321)
		Fail("Home bank account is spendable while travelling", __FILE__, __LINE__)
	var/datum/transit_characters/return_writer = new("B", "round-B")
	var/list/return_snapshot = return_writer.encode_human(restored, allow_clientless = TRUE)
	if(!return_snapshot)
		Fail("Return export rejected: [return_writer.error]", __FILE__, __LINE__)
	else
		if(json_encode(snapshot) != json_encode(return_snapshot))
			Fail("State differs after serialization roundtrip", __FILE__, __LINE__)
		var/datum/transit_characters/home_reader = new("A", "round-A")
		var/mob/living/carbon/human/returned = home_reader.decode_human(return_snapshot, run_loc_floor_bottom_left)
		if(!returned)
			Fail("Return import rejected: [home_reader.error]", __FILE__, __LINE__)
		else
			allocated += returned
			allocated += returned.mind
			var/obj/item/card/id/home_card = returned.wear_id
			returned.transit_unfreeze()
			if(returned.account_id != account.account_id || home_card.registered_account != account || account.transit_locked || account.account_balance != 321)
				Fail("Return did not restore the original account", __FILE__, __LINE__)
		qdel(home_reader)
	var/obj/item/unsupported = allocate(/obj/item/crowbar, source)
	if(writer.encode_human(source, allow_clientless = TRUE))
		Fail("Unsupported cargo was silently dropped", __FILE__, __LINE__)
	qdel(unsupported)
	qdel(writer)
	qdel(reader)
	qdel(return_writer)

/datum/unit_test/interserver_manifest_roundtrip
#ifdef TRANSIT_PROFILE_TEST
	test_flags = UNIT_TEST_FOCUS
#endif

/datum/unit_test/interserver_manifest_roundtrip/Run()
	var/datum/map_template/shuttle/template = SSmapping.shuttle_templates["interserver_box"]
	var/obj/docking_port/mobile/interserver_transit/source = SSshuttle.action_load(template, null)
	if(!source)
		TEST_FAIL("Could not load arrivals-derived source shuttle")
		return
	var/datum/transit_manifest/writer = new("A", "round-A")
	var/list/baseline = writer.layout(source)
	var/passengers = 0
	for(var/area/area as anything in source.shuttle_areas)
		for(var/obj/structure/chair/chair in area)
			var/mob/living/carbon/human/human = new(get_turf(chair))
			var/datum/mind/mind = new("TransitTest[passengers]")
			mind.set_assigned_role(SSjob.get_job_type(/datum/job/assistant))
			mind.transfer_to(human)
			chair.buckle_mob(human, force = TRUE)
			if(++passengers == 2)
				break
		if(passengers == 2)
			break
	if(passengers != 2)
		TEST_FAIL("Expected passenger chairs on arrival_box")
	var/list/snapshot = writer.encode(source, baseline, allow_clientless = TRUE)
	if(!snapshot)
		TEST_FAIL("Group export failed: [writer.error]")
	else
		var/obj/docking_port/mobile/interserver_transit/destination = SSshuttle.action_load(template, null)
		var/datum/transit_manifest/reader = new("B", "round-B")
		if(!reader.decode(json_decode(json_encode(snapshot)), destination))
			TEST_FAIL("Group import failed: [reader.error]")
		else
			if(length(reader.bodies) != 2 || length(reader.passengers) != 2)
				TEST_FAIL("Passenger group size changed")
			for(var/mob/living/carbon/human/human as anything in reader.bodies)
				if(!human.buckled || !human.transit_frozen || human.client)
					TEST_FAIL("Passenger buckle or staging isolation lost")
			var/datum/transit_manifest/return_writer = new("B", "round-B")
			var/list/again = return_writer.encode(destination, return_writer.layout(destination), allow_clientless = TRUE)
			if(json_encode(again) != json_encode(snapshot))
				TEST_FAIL("Group positions, chairs or passenger state changed")
			qdel(return_writer)
		qdel(reader)
		destination.jumpToNullSpace()
	writer.discard_objects()
	qdel(writer)
	source.jumpToNullSpace()
#endif
