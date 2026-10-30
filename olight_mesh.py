#!/usr/bin/env python3
"""Bluetooth Mesh proxy client for Olight Sphere bulbs (Tuya vendor model, company 0x07D0).

Run with:  uv run python olight_mesh.py <command>
Keys are read from keys.json next to this file (see keys.example.json).
"""
import argparse
import asyncio
import json
import os
import sys
import time

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import cmac
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

HERE = os.path.dirname(os.path.abspath(__file__))
KEYS_PATH = os.path.join(HERE, 'keys.json')
STATE_PATH = os.path.join(HERE, 'state.json')

COMPANY = 0x07D0          # Tuya vendor company id (little-endian on the wire: d0 07)
WORK_MODE = {'white': 0, 'colour': 1}  # byte after the company id = app DP 'work_mode' (Tuya DP 2: white|colour)
SEQ_BASE = 0x100000       # first seq used when no state.json (the bulb rejects replays, so start high)
DST_ALL_NODES = 0xFFFF
RETRIES = 3               # connection attempts per command
DP_COUNTDOWN = 7          # seconds until off; reported every second, 0 = none; bulb then sends OnOff Status off
DATA_IN = '00002add-0000-1000-8000-00805f9b34fb'   # Mesh Proxy Data In (write w/o response)
DATA_OUT = '00002ade-0000-1000-8000-00805f9b34fb'  # Mesh Proxy Data Out (notify)


def load_bulbs(path=KEYS_PATH):
    """BLE address -> unicast address, from the optional "bulbs" map in keys.json (None = unknown)."""
    if not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8') as f:
        return {a.upper(): (int(str(u), 0) if u else None) for a, u in json.load(f).get('bulbs', {}).items()}


KNOWN_BULBS = load_bulbs()  # probe unknown bulbs with 0xFFFF and read the SRC of the replies

OP_GENERIC_ONOFF_GET = 0x8201
OP_GENERIC_ONOFF_SET = 0x8202
OP_GENERIC_ONOFF_STATUS = 0x8204
VENDOR_SET, VENDOR_QUERY, VENDOR_REPORT = 0x09, 0x0C, 0x0D  # opcodes 0xC9 / 0xCC / 0xCD

DP_TYPES = {'bool': (0x01, 1), 'int': (0x02, 4), 'enum': (0x04, 1)}


# ---------- crypto primitives (Bluetooth Mesh spec) ----------

def aes_ecb(key, block):
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(block) + enc.finalize()


def aes_cmac(key, msg):
    c = cmac.CMAC(algorithms.AES(key))
    c.update(msg)
    return c.finalize()


def s1(msg):
    return aes_cmac(bytes(16), msg)


def k4(app_key):
    """Application key identifier (6 bits)."""
    t = aes_cmac(s1(b'smk4'), app_key)
    return aes_cmac(t, b'id6' + bytes([1]))[15] & 0x3F


# ---------- keys / state ----------

def load_keys(path=KEYS_PATH):
    with open(path, encoding='utf-8') as f:
        raw = json.load(f)
    k = {'nid': int(raw['nid']), 'iv_index': int(raw.get('iv_index', 0)),
         'src': int(str(raw.get('src', '0x6100')), 0)}
    for name in ('enc_key', 'priv_key', 'app_key'):
        k[name] = bytes.fromhex(raw[name])
        if len(k[name]) != 16:
            raise ValueError('%s must be 16 bytes' % name)
    k['aid'] = k4(k['app_key'])
    return k


def next_seq(path=STATE_PATH):
    """Return the next sequence number and persist it so restarts never reuse one."""
    seq = SEQ_BASE
    if os.path.exists(path):
        with open(path) as f:
            seq = json.load(f)['seq']
    seq += 1
    with open(path, 'w') as f:
        json.dump({'seq': seq}, f)
    return seq


# ---------- network layer ----------

def _net_nonce(ctl_ttl, seq, src, iv_index):
    return (bytes(1) + bytes([ctl_ttl]) + seq.to_bytes(3, 'big') + src.to_bytes(2, 'big')
            + bytes(2) + iv_index.to_bytes(4, 'big'))


def build_network_pdu(k, src, dst, transport, seq, ttl=8):
    """Encrypt and obfuscate a network PDU (unsegmented control=0)."""
    ctl_ttl = ttl & 0x7F
    enc = AESCCM(k['enc_key'], tag_length=4).encrypt(
        _net_nonce(ctl_ttl, seq, src, k['iv_index']), dst.to_bytes(2, 'big') + transport, None)
    pecb = aes_ecb(k['priv_key'], bytes(5) + k['iv_index'].to_bytes(4, 'big') + enc[:7])
    hdr = bytes([ctl_ttl]) + seq.to_bytes(3, 'big') + src.to_bytes(2, 'big')
    obf = bytes(a ^ b for a, b in zip(hdr, pecb))
    return bytes([((k['iv_index'] & 1) << 7) | k['nid']]) + obf + enc


def parse_network_pdu(k, pdu):
    """Return dict(ctl, ttl, seq, src, dst, transport) or None if NID or NetMIC does not match."""
    if len(pdu) < 1 + 6 + 2 + 4 or (pdu[0] & 0x7F) != k['nid']:
        return None
    enc = pdu[7:]
    pecb = aes_ecb(k['priv_key'], bytes(5) + k['iv_index'].to_bytes(4, 'big') + enc[:7])
    hdr = bytes(a ^ b for a, b in zip(pdu[1:7], pecb))
    ctl_ttl = hdr[0]
    seq = int.from_bytes(hdr[1:4], 'big')
    src = int.from_bytes(hdr[4:6], 'big')
    try:
        clear = AESCCM(k['enc_key'], tag_length=8 if ctl_ttl >> 7 else 4).decrypt(
            _net_nonce(ctl_ttl, seq, src, k['iv_index']), enc, None)
    except InvalidTag:
        return None
    return {'ctl': ctl_ttl >> 7, 'ttl': ctl_ttl & 0x7F, 'seq': seq, 'src': src,
            'dst': int.from_bytes(clear[:2], 'big'), 'transport': clear[2:]}


# ---------- access / upper transport layer (app key) ----------

def access_encrypt(k, seq, src, dst, access, akf=1):
    """Unsegmented application-key access PDU (returns transport bytes)."""
    nonce = (bytes([1, 0]) + seq.to_bytes(3, 'big') + src.to_bytes(2, 'big')
             + dst.to_bytes(2, 'big') + k['iv_index'].to_bytes(4, 'big'))
    upper = AESCCM(k['app_key'], tag_length=4).encrypt(nonce, access, None)
    return bytes([(akf << 6) | k['aid']]) + upper


def access_decrypt(k, net):
    """Return (aid, access_bytes) for an app-key message, or None if not decryptable with our key."""
    t = net['transport']
    if not t or t[0] & 0x80:           # segmented: not handled
        return None
    if not ((t[0] >> 6) & 1):          # device-key message: we do not have device keys
        return None
    aid = t[0] & 0x3F
    if aid != k['aid']:
        return None
    nonce = (bytes([1, 0]) + net['seq'].to_bytes(3, 'big') + net['src'].to_bytes(2, 'big')
             + net['dst'].to_bytes(2, 'big') + k['iv_index'].to_bytes(4, 'big'))
    try:
        return aid, AESCCM(k['app_key'], tag_length=4).decrypt(nonce, t[1:], None)
    except InvalidTag:
        return None


def proxy_pdu(net_pdu):
    """Proxy PDU: SAR=complete (00), type=network PDU (00)."""
    return bytes(1) + net_pdu


# ---------- access message builders ----------

def generic_onoff_get():
    return OP_GENERIC_ONOFF_GET.to_bytes(2, 'big')


def generic_onoff_set(on, tid):
    return OP_GENERIC_ONOFF_SET.to_bytes(2, 'big') + bytes([1 if on else 0, tid & 0xFF])


def dp_item(dp, dtype, value):
    code, size = DP_TYPES[dtype]
    return bytes([dp, code]) + int(value).to_bytes(size, 'big', signed=(dtype == 'int'))


def dp_write_access(items, work_mode=WORK_MODE['colour']):
    """items: list of (dp_id, dtype, value); may be empty. Vendor opcode 0xC9 (DP write).
    work_mode byte: 0 = white, 1 = colour (c9 d0 07 00 = white, c9 d0 07 01 = colour)."""
    body = bytes([work_mode]) + b''.join(dp_item(*it) for it in items)
    return bytes([0xC0 | VENDOR_SET]) + COMPANY.to_bytes(2, 'little') + body


def lightness_set_access(pct, tid):
    """Light Lightness Set (0x824C): lightness LE16, 0xFFFF = 100 %."""
    return b'\x82\x4c' + round(pct * 65535 / 100).to_bytes(2, 'little') + bytes([tid & 0xFF])


def hsl_set_access(lightness_pct, hue_deg, sat_pct, tid):
    """Light HSL Set (0x8276): lightness, hue (0..65535 = 0..360 deg), saturation, all LE16."""
    return (b'\x82\x76' + round(lightness_pct * 65535 / 100).to_bytes(2, 'little')
            + (round(hue_deg * 65536 / 360) & 0xFFFF).to_bytes(2, 'little')
            + round(sat_pct * 65535 / 100).to_bytes(2, 'little') + bytes([tid & 0xFF]))


LIGHT_OPS = {  # standard model opcodes seen on the wire; LE16 fields
    0x8202: 'onoff_set', 0x8204: 'onoff_status', 0x8201: 'onoff_get',
    0x824C: 'lightness_set', 0x824E: 'lightness_status',
    0x825E: 'ctl_set', 0x8260: 'ctl_status', 0x825D: 'ctl_get',
    0x8276: 'hsl_set', 0x8278: 'hsl_status', 0x826D: 'hsl_get',
}


def parse_access(access):
    """Decode an access payload into a readable dict (fields as observed; see README for encodings)."""
    op2 = int.from_bytes(access[:2], 'big') if len(access) >= 2 else None
    if op2 in LIGHT_OPS:
        name = LIGHT_OPS[op2]
        p = access[2:]
        le = lambda i: int.from_bytes(p[i:i + 2], 'little')  # noqa: E731
        if name in ('onoff_set', 'onoff_status'):
            return {'op': name, 'on': bool(p[0]), 'tid_or_param': p[1:].hex()}
        if name in ('lightness_set', 'lightness_status'):
            return {'op': name, 'lightness_pct': round(le(0) * 100 / 65535, 1), 'raw': p.hex()}
        if name in ('ctl_set', 'ctl_status'):
            return {'op': name, 'lightness_pct': round(le(0) * 100 / 65535, 1), 'temp_k': le(2), 'raw': p.hex()}
        if name in ('hsl_set', 'hsl_status'):
            return {'op': name, 'lightness_pct': round(le(0) * 100 / 65535, 1),
                    'hue_deg': round(le(2) * 360 / 65536, 1), 'sat_pct': round(le(4) * 100 / 65535, 1),
                    'raw': p.hex()}
        return {'op': name, 'raw': p.hex()}
    if access[0] & 0xC0 == 0xC0 and access[1:3] == COMPANY.to_bytes(2, 'little'):
        vop = access[0] & 0x3F
        dps = parse_dps(access[3:]) if vop in (VENDOR_SET, VENDOR_REPORT) else []
        mode_byte = access[3:4]
        return {'op': 'vendor_%02x' % vop,
                'work_mode': 'white' if mode_byte == bytes(1) else 'colour' if mode_byte else None,
                'dps': dps, 'raw': access.hex()}
    return {'op': 'raw', 'raw': access.hex()}


def parse_dps(body):
    """Parse [work_mode][dp][type][value]... as produced by 0xC9 / 0xCD (body starts after company id)."""
    out = []
    if not body:
        return out
    i = 1
    rev = {code: (name, size) for name, (code, size) in DP_TYPES.items()}
    while i + 2 <= len(body):
        dp, code = body[i], body[i + 1]
        if code not in rev:
            out.append((dp, 'type%02x' % code, body[i + 2:].hex()))
            break
        name, size = rev[code]
        val = body[i + 2:i + 2 + size]
        if len(val) < size:
            break
        out.append((dp, name, int.from_bytes(val, 'big', signed=(name == 'int'))))
        i += 2 + size
    return out


# ---------- BLE session ----------

async def _session(address, action):
    from bleak import BleakClient, BleakScanner
    k = load_keys()
    inbox = asyncio.Queue()
    # WinRT only connects to addresses its own scan cache has seen in this process
    dev = await BleakScanner.find_device_by_address(address, timeout=15) or address
    async with BleakClient(dev, timeout=20) as client:
        def on_notify(_, data):
            inbox.put_nowait(bytes(data))
        proxy = client.services.get_service('00001828-0000-1000-8000-00805f9b34fb')
        data_in, data_out = proxy.get_characteristic(DATA_IN), proxy.get_characteristic(DATA_OUT)
        await client.start_notify(data_out, on_notify)

        async def send(dst, access):
            seq = next_seq()
            net = build_network_pdu(k, k['src'], dst, access_encrypt(k, seq, k['src'], dst, access), seq)
            await client.write_gatt_char(data_in, proxy_pdu(net), response=False)
            return seq

        async def collect(seconds):
            got = []
            loop = asyncio.get_running_loop()
            end = loop.time() + seconds
            while True:
                left = end - loop.time()
                if left <= 0:
                    break
                try:
                    raw = await asyncio.wait_for(inbox.get(), left)
                except asyncio.TimeoutError:
                    break
                if raw[0] & 0xC0:          # SAR != complete: not handled
                    continue
                net = parse_network_pdu(k, raw[1:])
                if not net:
                    continue
                acc = access_decrypt(k, net)
                if acc:
                    got.append((net['src'], parse_access(acc[1])))
            return got

        return await action(send, collect, k)


def _run(address, action):
    # back-to-back connections often time out on Windows: retry after a pause
    # ponytail: retries any failure, so a send that failed late may be sent twice (all commands are idempotent)
    for attempt in range(RETRIES):
        try:
            return asyncio.run(_session(address, action))
        except Exception as e:
            if attempt == RETRIES - 1:
                raise
            print('connect failed (%s), retry %d/%d' % (type(e).__name__, attempt + 1, RETRIES - 1), file=sys.stderr)
            time.sleep(6)


def _dst(addr, dst_arg):
    if dst_arg is not None:
        return int(str(dst_arg), 0)
    return KNOWN_BULBS.get(addr.upper()) or DST_ALL_NODES


def _print_replies(replies):
    if not replies:
        print('no replies within the wait window')
    for src, info in replies:
        print('from 0x%04x: %s' % (src, info))


# ---------- commands ----------

async def scan(seconds):
    from bleak import BleakScanner
    devices = await BleakScanner.discover(timeout=seconds, return_adv=True)
    for dev, adv in devices.values():
        uuids = ''.join(adv.service_uuids).lower()
        mesh = '1828' in uuids or '1827' in uuids
        if mesh or dev.address.upper() in KNOWN_BULBS:
            print('%s  name=%r  rssi=%s  mesh_proxy=%s' % (dev.address, adv.local_name, adv.rssi, mesh))


def cmd_scan(args):
    asyncio.run(scan(args.seconds))


def cmd_status(args):
    async def action(send, collect, k):
        await send(_dst(args.addr, args.dst), generic_onoff_get())
        _print_replies(await collect(args.wait))
    _run(args.addr, action)


def cmd_onoff(args):
    async def action(send, collect, k):
        await send(_dst(args.addr, args.dst), generic_onoff_set(args.cmd == 'on', args.tid))
        _print_replies(await collect(args.wait))
    _run(args.addr, action)


def cmd_access(args, make):
    async def action(send, collect, k):
        await send(_dst(args.addr, args.dst), make(args))
        _print_replies(await collect(args.wait))
    _run(args.addr, action)


def cmd_dp_write(args):
    items = [(args.dp, args.type, int(args.value, 0))]
    cmd_access(args, lambda x: dp_write_access(items, WORK_MODE[x.mode]))


def cmd_mode(args):
    """Switch work mode with an empty DP write: c9 d0 07 00 (white) / 01 (colour)."""
    cmd_access(args, lambda x: dp_write_access([], WORK_MODE[x.mode]))


def cmd_snapshot(args):
    """Read-only: OnOff/Lightness/CTL/HSL Get + vendor DP query, replies appended to snapshots.jsonl."""
    gets = [OP_GENERIC_ONOFF_GET.to_bytes(2, 'big'), b'\x82\x4b', b'\x82\x5d', b'\x82\x6d',
            bytes([0xC0 | VENDOR_QUERY]) + COMPANY.to_bytes(2, 'little')]

    async def action(send, collect, k):
        for g in gets:
            await send(_dst(args.addr, args.dst), g)
            await asyncio.sleep(0.3)
        replies = await collect(args.wait)
        _print_replies(replies)
        with open(os.path.join(HERE, 'snapshots.jsonl'), 'a', encoding='utf-8') as f:
            f.write(json.dumps({'label': args.label, 'replies': [(s, i) for s, i in replies]}) + '\n')
    _run(args.addr, action)


def cmd_countdown(args):
    """Write DP 7 (seconds, 0 cancels) and print the per-second reports until the bulb switches off."""
    async def action(send, collect, k):
        dst = _dst(args.addr, args.dst)
        await send(dst, dp_write_access([(DP_COUNTDOWN, 'int', args.seconds)]))
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        while loop.time() - t0 < args.seconds + args.wait:
            for src, info in await collect(1):
                print('%5.1fs from 0x%04x: %s' % (loop.time() - t0, src, info))
    _run(args.addr, action)


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('scan', help='scan for mesh proxy devices')
    s.add_argument('--seconds', type=float, default=10)
    s.set_defaults(fn=cmd_scan)

    def common(sp):
        sp.add_argument('--addr', required=True, help='BLE address, e.g. AA:BB:CC:DD:EE:FF')
        sp.add_argument('--dst', help='unicast (e.g. 0x0040) or 0xFFFF; default: known unicast or 0xFFFF')
        sp.add_argument('--wait', type=float, default=5, help='seconds to collect replies')

    s = sub.add_parser('status', help='Generic OnOff Get (harmless, read-only)')
    common(s)
    s.set_defaults(fn=cmd_status)

    for name in ('on', 'off'):
        s = sub.add_parser(name, help='Generic OnOff Set')
        common(s)
        s.add_argument('--tid', type=int, default=0)
        s.set_defaults(fn=cmd_onoff, cmd=name)

    s = sub.add_parser('countdown', help='toggle on/off after N seconds (DP 7: off if on, on if off); 0 cancels')
    common(s)
    s.add_argument('seconds', type=int)
    s.set_defaults(fn=cmd_countdown, wait=3)

    s = sub.add_parser('snapshot',help='read all state (read-only) and log it under a label')
    common(s)
    s.add_argument('label')
    s.set_defaults(fn=cmd_snapshot)

    s = sub.add_parser('dp-write',help='raw Tuya DP write (vendor 0xC9)')
    common(s)
    s.add_argument('--dp', type=int, required=True)
    s.add_argument('--type', choices=sorted(DP_TYPES), required=True)
    s.add_argument('--value', required=True)
    s.add_argument('--mode', choices=sorted(WORK_MODE), default='colour')
    s.set_defaults(fn=cmd_dp_write)

    s = sub.add_parser('mode', help='work mode: white or colour (empty vendor DP write)')
    common(s)
    s.add_argument('mode', choices=sorted(WORK_MODE))
    s.set_defaults(fn=cmd_mode)

    s = sub.add_parser('scene', help='colour/scene preset = DP 102 enum (colour_N -> N)')
    common(s)
    s.add_argument('--n', type=int, required=True)
    s.set_defaults(fn=lambda a: cmd_access(a, lambda x: dp_write_access([(102, 'enum', x.n)])))

    s = sub.add_parser('brightness', help='Light Lightness Set 0x824C (percent)')
    common(s)
    s.add_argument('--pct', type=float, required=True)
    s.add_argument('--tid', type=int, default=0)
    s.set_defaults(fn=lambda a: cmd_access(a, lambda x: lightness_set_access(x.pct, x.tid)))

    s = sub.add_parser('hsl', help='Light HSL Set 0x8276 (hue deg, sat pct, lightness pct)')
    common(s)
    s.add_argument('--hue', type=float, required=True)
    s.add_argument('--sat', type=float, required=True)
    s.add_argument('--lightness', type=float, default=100)
    s.add_argument('--tid', type=int, default=0)
    s.set_defaults(fn=lambda a: cmd_access(a, lambda x: hsl_set_access(x.lightness, x.hue, x.sat, x.tid)))
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
