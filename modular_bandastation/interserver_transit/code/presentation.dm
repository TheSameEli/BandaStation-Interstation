/// Technical causes stay in the flight log; terminals show dispatch messages.
/proc/transit_passenger_notice(reason)
	if(!reason)
		return null
	var/message = lowertext("[reason]")
	if(findtext(message, "peer") || findtext(message, "authentication") || findtext(message, "response"))
		return "Диспетчерская не подтвердила связь. Ожидайте повторного согласования рейса."
	if(findtext(message, "док занят"))
		return "Посадочная площадка занята. Ожидайте разрешения на стыковку."
	if(findtext(message, "стыковк"))
		return "Стыковка отложена. Оставайтесь на борту до разрешения диспетчера."
	if(findtext(message, "раунд") || findtext(message, "reconciliation"))
		return "Станция назначения временно не принимает рейсы. Ожидайте указаний диспетчера."
	if(findtext(message, "у игрока уже"))
		return "Обнаружена повторная запись пассажира. Диспетчерская проводит сверку посадочных документов."
	if(findtext(message, "не допускает") || findtext(message, "професси"))
		return "Допуск к высадке на станции назначения не подтверждён. Обратитесь в диспетчерскую."
	if(findtext(message, "восьми пассажиров"))
		return "Превышена пассажировместимость: не более восьми пассажиров за рейс."
	if(findtext(message, "500") || findtext(message, "много предметов") || findtext(message, "миб"))
		return "Превышен допустимый объём багажа. Разделите груз на несколько рейсов."
	if(findtext(message, "состав"))
		return "Состав пассажиров изменился после сверки. Повторите регистрацию рейса."
	if(findtext(message, "не готовы") || findtext(message, "недоступен") || findtext(message, "предел рейсов"))
		return "Отправление временно приостановлено диспетчерской."
	if(findtext(message, "уже находится здесь"))
		return "Шаттл уже находится у причала этой станции."
	if(findtext(message, "обув") || findtext(message, "завяжите"))
		return "Перед посадкой приведите обувь в порядок и завяжите шнурки."
	if(findtext(message, "орган") || findtext(message, "тела") || findtext(message, "мозг") || findtext(message, "конечност") || findtext(message, "живыми людьми"))
		return "Медицинский допуск пассажира к этому рейсу не подтверждён."
	if(findtext(message, "банковск") || findtext(message, "счёт"))
		return "Не удалось подтвердить банковские реквизиты пассажира. Обратитесь в диспетчерскую."
	return "Диспетчерская не смогла подтвердить пассажирский манифест или опись багажа. Рейс приостановлен до сверки."
