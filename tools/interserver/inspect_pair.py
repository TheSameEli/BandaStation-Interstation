"""One-shot authenticated diagnostics. Not a bridge; game servers communicate directly.

--call sends the same reservation request as a station terminal. Use on an EMPTY
test shuttle only: occupants get the ordinary warning, validation and countdown.
"""
import argparse
import datetime
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import socket
import struct
import sys


def read_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        part = connection.recv(size - len(result))
        if not part:
            raise RuntimeError('Truncated BYOND response')
        result.extend(part)
    return bytes(result)


def topic(port, query):
    body = b'\x00' * 5 + query.encode('utf-8') + b'\x00'
    with socket.create_connection(('127.0.0.1', port), timeout=10) as connection:
        connection.sendall(b'\x00\x83' + struct.pack('>H', len(body)) + body)
        header = read_exact(connection, 4)
        result = read_exact(connection, struct.unpack('>H', header[2:])[0])
    if result[0] != 6:
        raise RuntimeError(f'Unexpected BYOND response type {result[0]}')
    return result[1:].rstrip(b'\x00').decode('utf-8')


def request(root, side, source_round, payload):
    # Avoid urllib's form encoding: list2params expects percent escapes, not '+' spaces.
    from urllib.parse import quote
    settings = json.loads((root / side / 'config/interserver_transit.json').read_text(encoding='utf-8'))
    nonce = secrets.token_hex(32)
    ticks = int((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime(2000, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds() * 10)
    envelope = dict(protocol=1, build=hashlib.sha256((root / side / 'tgstation.dmb').read_bytes()).hexdigest(), byond='516.1685', pair=settings['pair_id'], sender=settings['peer_id'], recipient=side, round=source_round, nonce=nonce, time=str(ticks), payload=payload)
    body = json.dumps(envelope, ensure_ascii=False, separators=(',', ':'))
    key = settings['secret'].encode()
    signature = hmac.new(key, body.encode(), hashlib.sha256).hexdigest()
    raw = topic(1337 if side == 'A' else 1338, '?interserver_transit=1&body=' + quote(body, safe='') + '&signature=' + signature)
    if raw in ('UNAVAILABLE', 'REJECTED', 'BUSY'):
        raise RuntimeError(f'{side}: {raw}')
    packet = json.loads(raw)
    if not hmac.compare_digest(packet['signature'], hmac.new(key, packet['body'].encode(), hashlib.sha256).hexdigest()):
        raise RuntimeError('Invalid response signature')
    response = json.loads(packet['body'])
    if response['nonce'] != nonce or response['sender'] != side or response['recipient'] != settings['peer_id'] or response['pair'] != settings['pair_id']:
        raise RuntimeError('Invalid response binding')
    return response


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--call', choices=['A', 'B'], help='Ask this server to send its shuttle to the opposite station')
    args = parser.parse_args()
    states = {side: request(args.root, side, 'diagnostic', {'command': 'HELLO'}) for side in ('A', 'B')}
    for side, response in states.items():
        payload = response['payload']
        ledger = payload.get('ledger') or {}
        print(json.dumps(dict(server=side, map=payload.get('map'), ready=payload.get('ready'), dock=payload.get('dock'), active=payload.get('active'), fault=payload.get('fault'), error=payload.get('error'), local_phase=payload.get('local_phase'), owner=ledger.get('owner'), phase=ledger.get('phase'), epoch=ledger.get('epoch'), flights=len(ledger.get('results', {})), revision=payload.get('revision')), ensure_ascii=False))
    if args.call:
        side = args.call
        opposite = 'B' if side == 'A' else 'A'
        result = request(args.root, side, states[opposite]['round'], dict(command='CALL', epoch=states[side]['payload']['ledger']['epoch'], target_round=states[side]['round']))
        print(json.dumps(result['payload'], ensure_ascii=False))


if __name__ == '__main__':
    main()
