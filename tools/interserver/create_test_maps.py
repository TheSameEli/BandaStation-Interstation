"""Derive the controlled stage-one maps without modifying production arrivals."""
import json
import sys
from pathlib import Path

repository = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repository / "tools/mapmerge2"))
from dmm import DMM

station_directory = repository / '_maps/map_files/InterserverTest'
station_directory.mkdir(parents=True, exist_ok=True)
for map_name, config_name, terminal_coordinate in (
    ('Cyberiad', 'cyberiad', (39, 152, 2)),
    ('MetaStation', 'metastation', (43, 145, 1)),
):
    station = DMM.from_file(repository / f'_maps/map_files/{map_name}/{map_name}.dmm')
    changed_docks = 0
    for coordinate in list(station.grid):
        tile = list(station.get_tile(coordinate))
        if any('shuttle_id = "arrival_stationary"' in atom for atom in tile):
            assert any('roundstart_template = /datum/map_template/shuttle/arrival/box;' in atom for atom in tile)
            tile = [atom.replace('roundstart_template = /datum/map_template/shuttle/arrival/box;', '')
                        .replace('shuttle_id = "arrival_stationary"', 'shuttle_id = "interserver_stationary"')
                        .replace('name = "arrivals"', 'name = "пассажирский причал"') for atom in tile]
            station.set_tile(coordinate, tile)
            changed_docks += 1
    assert changed_docks == 1, f'Expected exactly one {map_name} arrivals dock'
    tile = list(station.get_tile(terminal_coordinate))
    assert any(atom.startswith('/turf/open/floor/') for atom in tile)
    assert not any(atom.startswith(('/obj/machinery', '/obj/structure/chair')) for atom in tile)
    tile.insert(0, '/obj/machinery/computer/interserver_transit{name = "Вызов пассажирского шаттла";dir = 2}')
    # Explicit test-only latejoin bypass: no ordinary shuttle can occupy this dock.
    tile.insert(0, '/obj/effect/landmark/latejoin')
    station.set_tile(terminal_coordinate, tile)
    supplies_coordinate = (terminal_coordinate[0] + 1, terminal_coordinate[1], terminal_coordinate[2])
    supplies_tile = list(station.get_tile(supplies_coordinate))
    assert any(atom.startswith('/turf/open/floor/') for atom in supplies_tile)
    supplies_tile.insert(0, '/obj/structure/closet/interserver_test_supplies')
    station.set_tile(supplies_coordinate, supplies_tile)
    station.remove_unused_keys(list(station.dictionary))
    station.to_file(station_directory / f'{map_name}.dmm')
    config = json.loads((repository / f'_maps/map_jsons/{config_name}.json').read_text(encoding='utf-8'))
    config.update(map_name=f'InterserverTest{map_name}', map_path='map_files/InterserverTest', fluff_name=f'{map_name} — межсерверный тест')
    (repository / f'_maps/map_jsons/interserver_test_{config_name}.json').write_text(json.dumps(config, ensure_ascii=False, indent='\t') + '\n', encoding='utf-8')

shuttle = DMM.from_file(repository / '_maps/shuttles/arrival/arrival_box.dmm')
for coordinate in list(shuttle.grid):
    tile = []
    for atom in shuttle.get_tile(coordinate):
        if atom.startswith(('/obj/item/storage/medkit', '/obj/effect/spawner/random/entertainment/arcade', '/obj/item/radio/intercom')):
            continue
        if atom.startswith('/obj/structure/closet/'):
            atom = '/obj/structure/closet/interserver_transit'
        elif atom.startswith('/obj/machinery/requests_console'):
            atom = '/obj/machinery/computer/interserver_transit{on_board = 1}'
        else:
            atom = atom.replace('/obj/docking_port/mobile/arrivals', '/obj/docking_port/mobile/interserver_transit')
            atom = atom.replace('/area/shuttle/arrival', '/area/shuttle/interserver_transit')
            atom = atom.replace('Arrivals Shuttle Airlock', 'Шлюз пассажирского шаттла')
        tile.append(atom)
    shuttle.set_tile(coordinate, tile)
shuttle_directory = repository / '_maps/shuttles/interserver'
shuttle_directory.mkdir(parents=True, exist_ok=True)
shuttle.remove_unused_keys(list(shuttle.dictionary))
shuttle.to_file(shuttle_directory / 'interserver_box.dmm')
print('Generated test Cyberiad, MetaStation and arrivals-derived shuttle; production maps unchanged.')
