/datum/mind
	var/transit_identity
	var/transit_home_server
	var/transit_home_round

/mob/living/carbon/human
	var/transit_frozen = FALSE
	var/list/transit_home_bank

/mob/living/carbon/human/proc/transit_freeze()
	if(transit_frozen)
		return
	transit_frozen = TRUE
	ADD_TRAIT(src, TRAIT_NO_TRANSFORM, "interserver_transit")
	ADD_TRAIT(src, TRAIT_GODMODE, "interserver_transit")
	ADD_TRAIT(src, TRAIT_IMMOBILIZED, "interserver_transit")
	// HANDS_BLOCKED normally drops held items. Keep the validated loadout in its original slots.
	var/list/original_hands = held_items.Copy()
	ADD_TRAIT(src, TRAIT_HANDS_BLOCKED, "interserver_transit")
	for(var/index = 1; index <= length(original_hands); index++)
		var/obj/item/item = original_hands[index]
		if(item && !put_in_hand(item, index, forced = TRUE))
			CRASH("Failed to retain a validated hand item while freezing transit")
	STOP_PROCESSING(SSmood, mob_mood)
	var/datum/bank_account/account = SSeconomy.bank_accounts_by_id["[account_id]"]
	if(account)
		account.transit_locked = TRUE

/mob/living/carbon/human/proc/transit_unfreeze()
	if(!transit_frozen)
		return
	transit_frozen = FALSE
	REMOVE_TRAIT(src, TRAIT_NO_TRANSFORM, "interserver_transit")
	REMOVE_TRAIT(src, TRAIT_GODMODE, "interserver_transit")
	REMOVE_TRAIT(src, TRAIT_IMMOBILIZED, "interserver_transit")
	REMOVE_TRAIT(src, TRAIT_HANDS_BLOCKED, "interserver_transit")
	START_PROCESSING(SSmood, mob_mood)
	var/datum/bank_account/account = SSeconomy.bank_accounts_by_id["[account_id]"]
	if(account)
		account.transit_locked = FALSE

/mob/living/carbon/human/ghostize(can_reenter_corpse = TRUE, forced = FALSE)
	if(transit_frozen && !QDELING(src))
		to_chat(src, span_warning("Шаттл выполняет манёвр. Оставайтесь на своём месте до завершения рейса."))
		return
	return ..()

/datum/transit_characters
	var/error
	var/server_id
	var/round_id
	var/datum/transit_values/values
	var/datum/transit_items/items
	var/static/list/default_traits
	var/static/list/default_components
	var/static/list/default_organ_traits
	var/list/human_fields = list("name", "real_name", "gender", "age", "physique", "hair_color", "hairstyle", "grad_color", "grad_style", "facial_hair_color", "facial_hairstyle", "eye_color_left", "eye_color_right", "eye_color_heterochromatic", "eye_color_left_overrides", "eye_color_right_overrides", "skin_tone", "lip_style", "lip_color", "underwear", "underwear_color", "undershirt", "socks", "backpack", "jumpsuit_style", "override_voice", "coretemperature", "bodytemperature", "nutrition", "satiety", "disgust", "dir", "transit_home_bank")
	var/list/dna_fields = list("unique_enzymes", "unique_identity", "features", "unique_features", "real_name", "mutation_index", "default_mutation_genes", "stability", "scrambled")
	var/list/mind_fields = list("name", "ghostname", "late_joiner", "has_ever_been_ai", "force_escaped", "known_skills", "skills_rewarded", "original_character_slot_index", "current_scar_slot_index", "experience_multiplier", "experience_multiplier_reasons", "book_titles_read", "desensitized_level", "deaths_witnessed", "transit_identity", "transit_home_server", "transit_home_round")
	var/list/language_fields = list("understood_languages", "spoken_languages", "blocked_understanding", "blocked_speaking", "omnitongue", "selected_language")
	var/list/mood_fields = list("mood", "sanity", "shown_mood", "mood_modifier", "positive_mood_modifier", "negative_mood_modifier", "positive_moodlet_length_modifier", "negative_moodlet_length_modifier", "mood_level", "sanity_level", "insanity_effect")
	var/list/account_memory_fields = list("name", "memorizer", "story_value", "memory_flags", "mood_verb", "protagonist_name", "deuteragonist_name", "antagonist_name", "where", "remembered_id")
	var/list/bank_fields = list("account_balance", "account_debt", "mining_points", "bitrunning_points", "payday_modifier", "paydays_to_skip")
	var/list/slots = list(ITEM_SLOT_BACK, ITEM_SLOT_HEAD, ITEM_SLOT_GLOVES, ITEM_SLOT_EARS, ITEM_SLOT_EYES, ITEM_SLOT_FEET, ITEM_SLOT_NECK, ITEM_SLOT_MASK, ITEM_SLOT_OCLOTHING, ITEM_SLOT_ICLOTHING, ITEM_SLOT_BELT, ITEM_SLOT_ID, ITEM_SLOT_RPOCKET, ITEM_SLOT_LPOCKET, ITEM_SLOT_SUITSTORE)
	var/list/organ_types = list(/obj/item/organ/brain, /obj/item/organ/heart, /obj/item/organ/lungs, /obj/item/organ/eyes, /obj/item/organ/ears, /obj/item/organ/tongue, /obj/item/organ/liver, /obj/item/organ/stomach, /obj/item/organ/appendix)
	var/list/mood_types = list(/datum/mood_event/area, /datum/mood_event/fat, /datum/mood_event/wellfed, /datum/mood_event/fed, /datum/mood_event/hungry, /datum/mood_event/hungry_very, /datum/mood_event/starving)

/datum/transit_characters/New(local_server, local_round)
	server_id = local_server
	round_id = local_round
	values = new
	items = new(local_server, local_round)
	if(isnull(default_traits))
		var/mob/living/carbon/human/probe = new(null)
		default_traits = probe._status_traits?.Copy() || list()
		default_components = list(/datum/component/examine_panel)
		default_organ_traits = list()
		for(var/obj/item/organ/organ as anything in probe.organs)
			default_organ_traits["[organ.type]"] = organ._status_traits?.Copy() || list()
		for(var/datum/component/component as anything in probe.GetComponents(/datum/component))
			default_components |= component.type
		qdel(probe)
	for(var/path in typesof(/datum/mutation) + typesof(/datum/skill) + typesof(/datum/language) + typesof(/obj/item/skillchip))
		values.paths["[path]"] = path

/datum/transit_characters/Destroy()
	QDEL_NULL(values)
	QDEL_NULL(items)
	return ..()

/datum/transit_characters/proc/reject(reason)
	error = reason
	return null

/datum/transit_characters/proc/encode_human(mob/living/carbon/human/human, allow_clientless = FALSE)
	if(human.type != /mob/living/carbon/human || human.dna?.species.type != /datum/species/human || !human.mind || (!allow_clientless && !human.client) || human.stat != STABLE)
		return reject("Поддерживается живой человек с активным игроком")
	if(human.mind.assigned_role?.type != /datum/job/assistant && !SSinterserver_transit.diagnostic_mode)
		return reject("В первом тесте поддерживается исходная профессия Assistant")
	var/list/personalities = list()
	for(var/personality_type in human.personalities)
		var/datum/personality/personality = SSpersonalities.personalities_by_type[personality_type]
		if(personality_type != /datum/personality/spiritual && !SSinterserver_transit.diagnostic_mode)
			return reject("В первом тесте пока не поддерживается черта личности: [personality_type]")
		personalities += personality.savefile_key
	for(var/trait in human._status_traits)
		if(trait in default_traits)
			continue
		for(var/source in human._status_traits[trait])
			if(SSinterserver_transit.diagnostic_mode)
				transit_diagnostic_note("[human.real_name]: свойство [trait] восстанавливается экипировкой/личностью; отдельные внешние источники не копируются", notify = FALSE)
				continue
			if(trait == TRAIT_SPIRITUAL && source == PERSONALITY_TRAIT && HAS_PERSONALITY(human, /datum/personality/spiritual))
				continue
			if(human.transit_frozen && source == TRAIT_HANDS_BLOCKED && (trait in list(TRAIT_UI_BLOCKED, TRAIT_PULL_BLOCKED)))
				continue
			if(trait == TRAIT_BASIC_HEALTH_HUD_VISIBLE && human.w_uniform && source == "[CLOTHING_TRAIT]_[REF(human.w_uniform)]")
				continue
			if(trait == TRAIT_NO_FLOATING_ANIM && (source == UPDATE_TRANSFORM_TRAIT || source == UPDATE_OFFSET_TRAIT))
				continue
			if(trait == TRAIT_NO_FLOATING_ANIM && istype(human.buckled, /obj/structure/chair) && source == REF(human.buckled.GetComponent(/datum/component/riding)))
				continue
			if(source == NO_GRAVITY_TRAIT && (trait in list(TRAIT_MOVE_FLOATING, TRAIT_MOVE_UPSIDE_DOWN)))
				continue
			if(source == "interserver_transit" && (trait in list(TRAIT_NO_TRANSFORM, TRAIT_GODMODE, TRAIT_IMMOBILIZED, TRAIT_HANDS_BLOCKED)))
				continue
			if(source == BUCKLED_TRAIT && (trait in list(TRAIT_IMMOBILIZED, TRAIT_NO_FLOATING_ANIM)) && istype(human.buckled, /obj/structure/chair))
				continue
			log_world("INTERSERVER unsupported human trait [trait], source [source]")
			return reject("Неподдерживаемое свойство тела: [trait]")
	for(var/datum/component/component as anything in human.GetComponents(/datum/component))
		if(SSinterserver_transit.diagnostic_mode && !(component.type in default_components))
			transit_diagnostic_note("[human.real_name]: изменённое состояние компонента [component.type] не переносится")
			continue
		if(!(component.type in default_components))
			return reject("Неподдерживаемый компонент тела: [component.type]")
		if(istype(component, /datum/component/bloodysoles))
			var/datum/component/bloodysoles/soles = component
			if(soles.total_bloodiness)
				return reject("Сначала смойте кровь со ступней")
	if(length(human.mind.antag_datums) || human.mind.holy_role || human.mind.enslaved_to || length(human.mind.special_roles) || length(human.mind.special_statuses) || length(human.mind.active_addictions) || length(human.mind.addiction_points) || length(human.mind.failed_special_equipment))
		if(!SSinterserver_transit.diagnostic_mode)
			return reject("Антагонист, особая роль, зависимость или привязка mind к исходному раунду")
		transit_diagnostic_note("[human.real_name]: антагонистические/особые роли, зависимости и привязки mind к исходному раунду не восстановлены")
	var/list/memories = list()
	for(var/memory_type in human.mind.memories)
		var/datum/memory/memory = human.mind.memories[memory_type]
		if(SSinterserver_transit.diagnostic_mode)
			memories += list(list("type" = "[memory.type]", "portable" = transit_export_portable(memory)))
		else if(memory.type != /datum/memory/key/account)
			return reject("Пока не поддерживается воспоминание: [memory.type]")
		else
			memories += list(values.export_fields(memory, account_memory_fields))
	if(length(human.mind.learned_crafting_recipes) || length(human.mind.learned_cooking_recipes) || human.mind.last_death)
		if(!SSinterserver_transit.diagnostic_mode)
			return reject("Изученные рецепты и ранее погибавшие персонажи пока не поддерживаются")
		transit_diagnostic_note("[human.real_name]: рецепты и время прошлой смерти не восстановлены")
	if(length(human.quirks) || length(human.dna.mutations) || length(human.status_effects) || length(human.diseases) || (!SSinterserver_transit.diagnostic_mode && length(human.implants)) || length(human.all_wounds) || length(human.all_scars) || human.reagents?.total_volume || human.handcuffed || human.legcuffed || human.internal || human.pulling || human.pulledby)
		if(!SSinterserver_transit.diagnostic_mode)
			return reject("Особенности, эффекты, химия, раны, шрамы, импланты, наручники, баллон или захват не поддерживаются")
		transit_diagnostic_note("[human.real_name]: quirks=[length(human.quirks)], мутации=[length(human.dna.mutations)], эффекты=[length(human.status_effects)], болезни=[length(human.diseases)], раны=[length(human.all_wounds)], шрамы=[length(human.all_scars)], химия=[human.reagents?.total_volume]; эти системы пока не восстановлены полностью; импланты передаются отдельно")
	if(human.get_tox_loss() || human.get_oxy_loss() || human.get_stamina_loss() || human.fire_stacks || human.blood_in_hands)
		if(!SSinterserver_transit.diagnostic_mode)
			return reject("Токсины, гипоксия, усталость, горение или кровь на руках не поддерживаются")
		transit_diagnostic_note("[human.real_name]: токсины/гипоксия/усталость/горение/кровь на руках не восстановлены")
	var/obj/item/organ/brain/brain = human.get_organ_slot(ORGAN_SLOT_BRAIN)
	if(!brain || length(brain.traumas) || (length(brain.skillchips) && !SSinterserver_transit.diagnostic_mode) || brain.brainmob || brain.suicided || brain.smooth_brain)
		return reject("Нестандартное состояние мозга")
	var/list/skillchips = list()
	if(SSinterserver_transit.diagnostic_mode)
		for(var/obj/item/skillchip/chip as anything in brain.skillchips)
			var/list/metadata = chip.get_metadata()
			metadata["chip_cooldown"] = max(0, chip.chip_cooldown - world.time)
			skillchips += list(values.encode(metadata))
	var/list/implants = list()
	if(SSinterserver_transit.diagnostic_mode)
		for(var/obj/item/implant/implant as anything in human.implants)
			implants += list(items.encode_item(implant))
	if(length(human.bodyparts) != 6 || length(human.organs) != length(organ_types))
		return reject("Необходим полный набор обычных органов и конечностей человека")
	var/list/limbs = list()
	for(var/obj/item/bodypart/limb as anything in human.bodyparts)
		if(limb.type != human.dna.species.bodypart_overrides[limb.body_zone] || length(limb.embedded_objects) || limb.bodypart_disabled || limb.is_husked)
			return reject("Нестандартная или повреждённая конечность: [limb.name]")
		limbs[limb.body_zone] = values.export_fields(limb, list("brute_dam", "burn_dam"))
	var/list/organs = list()
	for(var/obj/item/organ/organ as anything in human.organs)
		if(!(organ.type in organ_types) || organ.damage >= organ.low_threshold || organ.organ_flags & (ORGAN_FAILING | ORGAN_ROBOTIC))
			return reject("Повреждённый или нестандартный орган: [organ.name]")
		var/list/factory_traits = default_organ_traits["[organ.type]"]
		for(var/trait in organ._status_traits)
			if(SSinterserver_transit.diagnostic_mode && organ.type == /obj/item/organ/liver && (trait in human.mind.assigned_role.liver_traits))
				continue
			if((trait in factory_traits) || trait == TRAIT_CLIENT_STARTING_ORGAN || (organ.type == /obj/item/organ/liver && trait == TRAIT_MAINTENANCE_METABOLISM))
				continue
			return reject("Неподдерживаемое свойство органа [organ.name]: [trait]")
		organs[organ.slot] = list("type" = "[organ.type]", "damage" = num2text(organ.damage, 20), "starting" = !!HAS_TRAIT(organ, TRAIT_CLIENT_STARTING_ORGAN), "maintenance" = !!HAS_TRAIT(organ, TRAIT_MAINTENANCE_METABOLISM))
	var/list/moods = list()
	for(var/category in human.mob_mood.mood_events)
		var/datum/mood_event/event = human.mob_mood.mood_events[category]
		if(!(event.type in mood_types) || event.timeout)
			if(!SSinterserver_transit.diagnostic_mode)
				return reject("Не поддерживается действующий эффект настроения: [event.type]")
			transit_diagnostic_note("[human.real_name]: временный эффект настроения [event.type] не перенесён, настроение пересчитается локально")
			continue
		moods += list(list("category" = category, "type" = "[event.type]", "fields" = values.export_fields(event, list("description", "mood_change", "hidden"))))
	if(!human.mind.transit_identity)
		human.mind.transit_identity = rustg_csprng_chacha20("hex", 32)
		human.mind.transit_home_server = server_id
		human.mind.transit_home_round = round_id
	if(!human.transit_home_bank && human.account_id)
		human.transit_home_bank = list("server" = server_id, "round" = round_id, "id" = human.account_id)
	var/list/inventory = list()
	var/list/seen = list()
	for(var/slot in slots)
		var/obj/item/item = human.get_item_by_slot(slot)
		if(item)
			inventory += list(list("slot" = slot, "item" = items.encode_item(item)))
			seen += item
	for(var/index = 1; index <= length(human.held_items); index++)
		var/obj/item/item = human.held_items[index]
		if(item)
			inventory += list(list("hand" = index, "item" = items.encode_item(item)))
			seen += item
	for(var/atom/movable/contained as anything in human.contents)
		if(!(contained in seen) && !(contained in human.organs) && !(contained in human.bodyparts) && !(SSinterserver_transit.diagnostic_mode && (contained in human.implants)))
			if(!SSinterserver_transit.diagnostic_mode)
				return reject("В теле находится неподдерживаемый объект: [contained.name]")
			transit_diagnostic_note("[human.real_name]: объект вне слотов [contained.type] не восстановлен")
	var/list/record = list("identity" = human.mind.transit_identity, "ckey" = ckey(human.mind.key), "human" = values.export_fields(human, human_fields), "dna" = values.export_fields(human.dna, dna_fields), "blood_type" = human.dna.blood_type.id, "blood_volume" = num2text(human.get_blood_volume(), 20), "mind" = values.export_fields(human.mind, mind_fields), "languages" = values.export_fields(human.get_language_holder(), language_fields), "mood" = values.export_fields(human.mob_mood, mood_fields), "moods" = moods, "limbs" = limbs, "organs" = organs, "inventory" = inventory, "forensics" = items.encode_forensics(human))
	record["role"] = "assistant"
	if(SSinterserver_transit.diagnostic_mode)
		record["role"] = "[human.mind.assigned_role?.type]"
	record["personalities"] = personalities
	record["memories"] = memories
	if(SSinterserver_transit.diagnostic_mode)
		var/datum/bank_account/account = SSeconomy.bank_accounts_by_id["[human.account_id]"]
		record["bank"] = account ? values.export_fields(account, bank_fields) : null
		record["skillchips"] = skillchips
		record["implants"] = implants
	if(values.error || items.error)
		return reject(values.error || items.error)
	return record

/datum/transit_characters/proc/decode_human(list/record, turf/staging)
	if(!islist(record) || (record["role"] != "assistant" && !SSinterserver_transit.diagnostic_mode))
		return reject("Неизвестная или неподдерживаемая исходная профессия")
	if(!islist(record) || !istext(record["identity"]) || length(record["identity"]) != 64 || !istext(record["ckey"]) || ckey(record["ckey"]) != record["ckey"] || !islist(record["inventory"]) || length(record["inventory"]) > 17)
		return reject("Некорректная запись персонажа")
	var/mob/living/carbon/human/human = new(staging)
	human.transit_freeze()
	if(!values.import_fields(human, human_fields, record["human"]) || !values.import_fields(human.dna, dna_fields, record["dna"]))
		qdel(human)
		return reject(values.error)
	var/datum/blood_type/blood = GLOB.blood_types[record["blood_type"]]
	if(!blood)
		qdel(human)
		return reject("Неизвестная группа крови")
	human.set_blood_type(blood)
	human.set_blood_volume(text2num(record["blood_volume"]))
	var/datum/mind/mind = new(record["ckey"])
	if(!values.import_fields(mind, mind_fields, record["mind"]) || mind.transit_identity != record["identity"])
		qdel(mind)
		qdel(human)
		return reject(values.error || "Идентичность mind не совпадает")
	mind.active = FALSE
	var/job_path = /datum/job/assistant
	if(SSinterserver_transit.diagnostic_mode)
		job_path = null
		for(var/path in subtypesof(/datum/job))
			if("[path]" == record["role"])
				job_path = path
	if(!job_path || !SSjob.get_job_type(job_path))
		qdel(mind)
		qdel(human)
		return reject("Исходная профессия отсутствует на принимающей станции")
	mind.set_assigned_role(SSjob.get_job_type(job_path))
	if(length(mind.assigned_role.mind_traits))
		mind.add_traits(mind.assigned_role.mind_traits, JOB_TRAIT)
	mind.transfer_to(human)
	mind.set_original_character(human)
	var/list/memories = record["memories"]
	if(!islist(memories) || length(memories) > 128)
		qdel(human)
		return reject("Некорректная память банковского счёта")
	for(var/list/memory_fields as anything in memories)
		if(SSinterserver_transit.diagnostic_mode)
			var/memory_path
			for(var/path in subtypesof(/datum/memory))
				if("[path]" == memory_fields["type"])
					memory_path = path
			if(!memory_path)
				qdel(human)
				return reject("Неизвестный тип воспоминания")
			var/datum/memory/restored_memory = new memory_path(mind)
			if(!transit_import_portable(restored_memory, memory_fields["portable"]))
				qdel(restored_memory)
				qdel(human)
				return reject("Не удалось восстановить значения воспоминания")
			mind.memories[memory_path] = restored_memory
			continue
		var/datum/memory/key/account/memory = new(mind)
		if(!values.import_fields(memory, account_memory_fields, memory_fields))
			qdel(memory)
			qdel(human)
			return reject(values.error)
		mind.memories[/datum/memory/key/account] = memory
	var/list/personalities = record["personalities"]
	if(!islist(personalities) || length(personalities) > 32)
		qdel(human)
		return reject("Некорректный набор черт личности")
	for(var/personality_key in personalities)
		var/datum/personality/personality = SSpersonalities.personalities_by_key[personality_key]
		if(!personality || (!SSinterserver_transit.diagnostic_mode && personality.type != /datum/personality/spiritual))
			qdel(human)
			return reject("Неизвестная черта личности")
		human.add_personality(personality.type)
	if(!values.import_fields(human.get_language_holder(), language_fields, record["languages"]) || !values.import_fields(human.mob_mood, mood_fields, record["mood"]) || !items.decode_forensics(human, record["forensics"]))
		qdel(human)
		return reject(values.error || items.values.error)
	var/list/limbs = record["limbs"]
	var/list/organs = record["organs"]
	if(!islist(limbs) || length(limbs) != 6 || !islist(organs) || length(organs) != length(organ_types))
		qdel(human)
		return reject("Некорректная анатомия")
	for(var/obj/item/bodypart/limb as anything in human.bodyparts)
		if(!values.import_fields(limb, list("brute_dam", "burn_dam"), limbs[limb.body_zone]))
			qdel(human)
			return reject(values.error)
		if(limb.can_be_disabled)
			limb.update_disabled()
		limb.update_bodypart_damage_state()
	for(var/obj/item/organ/organ as anything in human.organs)
		var/list/organ_record = organs[organ.slot]
		if(!islist(organ_record) || organ_record["type"] != "[organ.type]" || !istext(organ_record["damage"]))
			qdel(human)
			return reject("Набор органов не совпадает")
		organ.apply_organ_damage(text2num(organ_record["damage"]))
		if(organ_record["starting"])
			ADD_TRAIT(organ, TRAIT_CLIENT_STARTING_ORGAN, ROUNDSTART_TRAIT)
		if(organ_record["maintenance"] && organ.type == /obj/item/organ/liver)
			ADD_TRAIT(organ, TRAIT_MAINTENANCE_METABOLISM, JOB_TRAIT)
		if(SSinterserver_transit.diagnostic_mode && organ.type == /obj/item/organ/liver && length(mind.assigned_role.liver_traits))
			organ.add_traits(mind.assigned_role.liver_traits, JOB_TRAIT)
	if(SSinterserver_transit.diagnostic_mode)
		var/list/chip_records = record["skillchips"]
		var/list/implant_records = record["implants"]
		if(!islist(chip_records) || length(chip_records) > 32 || !islist(implant_records) || length(implant_records) > 32)
			qdel(human)
			return reject("Некорректный список нейрочипов или имплантов")
		for(var/list/chip_record as anything in chip_records)
			var/list/metadata = values.decode(chip_record)
			if(values.error || !islist(metadata) || !ispath(metadata["type"], /obj/item/skillchip) || !isnum(metadata["chip_cooldown"]))
				qdel(human)
				return reject("Некорректные метаданные нейрочипа")
			var/chip_path = metadata["type"]
			var/obj/item/skillchip/chip = new chip_path(null)
			metadata["chip_cooldown"] += world.time
			var/failure = human.implant_skillchip(chip, force = TRUE)
			if(!failure)
				failure = chip.set_metadata(metadata)
			if(failure)
				qdel(chip)
				qdel(human)
				return reject("Не удалось восстановить нейрочип: [failure]")
		for(var/list/implant_record as anything in implant_records)
			var/obj/item/implant/implant = items.decode_item(implant_record, null)
			if(!istype(implant) || !implant.implant(human, null, silent = TRUE, force = TRUE))
				qdel(implant)
				qdel(human)
				return reject("Не удалось восстановить имплант")
	for(var/list/entry as anything in record["inventory"])
		var/obj/item/item = items.decode_item(entry["item"], human)
		var/success = item && (entry["hand"] ? human.put_in_hand(item, entry["hand"], forced = TRUE) : human.equip_to_slot_if_possible(item, entry["slot"], disable_warning = TRUE, bypass_equip_delay_self = TRUE))
		if(!success)
			qdel(human)
			return reject(items.error || "Не удалось восстановить слот инвентаря")
	if(human.transit_home_bank && human.transit_home_bank["server"] == server_id)
		if(human.transit_home_bank["round"] != round_id || !SSeconomy.bank_accounts_by_id["[human.transit_home_bank["id"]]"])
			qdel(human)
			return reject("Исходный банковский счёт не принадлежит текущему раунду")
		human.account_id = human.transit_home_bank["id"]
	if(SSinterserver_transit.diagnostic_mode && record["bank"])
		var/datum/bank_account/account = SSeconomy.bank_accounts_by_id["[human.account_id]"]
		if(!account)
			account = SSinterserver_transit.visitor_accounts[mind.transit_identity]
		if(!account)
			account = new(human.real_name, mind.assigned_role)
			SSinterserver_transit.visitor_accounts[mind.transit_identity] = account
		// The source remains locked; only destination PLAY may enable this local account.
		account.transit_locked = TRUE
		if(!values.import_fields(account, bank_fields, record["bank"]))
			qdel(human)
			return reject(values.error)
		human.account_id = account.account_id
		for(var/obj/item/card/id/card as anything in human.get_all_contents_type(/obj/item/card/id))
			if(card.transit_bank_server == human.transit_home_bank?["server"] && card.transit_bank_id == human.transit_home_bank?["id"])
				card.set_account(account)
		var/datum/memory/key/account/bank_memory = mind.memories[/datum/memory/key/account]
		if(bank_memory)
			bank_memory.remembered_id = account.account_id
			bank_memory.generate_memory_name()
	var/list/moods = record["moods"]
	if(!islist(moods) || length(moods) > 16)
		qdel(human)
		return reject("Некорректные эффекты настроения")
	QDEL_LIST_ASSOC_VAL(human.mob_mood.mood_events)
	human.mob_mood.mood_events = list()
	for(var/list/entry as anything in moods)
		var/event_path
		for(var/path in mood_types)
			if("[path]" == entry["type"])
				event_path = path
		if(!event_path || !istext(entry["category"]))
			qdel(human)
			return reject("Неподдерживаемый эффект настроения")
		var/datum/mood_event/event = new event_path(entry["category"])
		event.owner = human
		if(!values.import_fields(event, list("description", "mood_change", "hidden"), entry["fields"]))
			qdel(event)
			qdel(human)
			return reject(values.error)
		human.mob_mood.mood_events[entry["category"]] = event
	// Imported DNA and appearance fields must rebuild factory-created limb render data.
	human.updateappearance(mutcolor_update = TRUE, mutations_overlay_update = TRUE)
	human.update_body_parts(update_limb_data = TRUE)
	human.regenerate_icons()
	human.updatehealth()
	// A successful constructor is insufficient: every supported field must roundtrip exactly.
	var/datum/transit_characters/verifier = new(server_id, round_id)
	var/list/verified = verifier.encode_human(human, allow_clientless = TRUE)
	var/verified_ok = verified && json_encode(verified) == json_encode(record)
	var/reason = verifier.error
	qdel(verifier)
	if(!verified_ok)
		if(SSinterserver_transit.diagnostic_mode)
			for(var/field in record)
				if(!verified || json_encode(verified[field]) != json_encode(record[field]))
					transit_diagnostic_note("[human.real_name]: после восстановления отличается раздел [field]; [reason]")
			return human
		var/list/all_items = human.get_all_contents_type(/obj/item)
		qdel(mind)
		qdel(human)
		QDEL_LIST(all_items)
		return reject(reason || "Восстановленное состояние не совпало со снимком; исходный персонаж сохранён")
	return human
