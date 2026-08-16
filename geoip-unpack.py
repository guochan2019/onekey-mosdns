#!/usr/bin/env python3
"""从 geoip.dat / geosite.dat 解包指定 tag 到纯文本"""
import struct, sys, ipaddress

def _read_varint(data, offset):
    result = 0; shift = 0
    while offset < len(data):
        byte = data[offset]
        result |= (byte & 0x7F) << shift
        shift += 7; offset += 1
        if not (byte & 0x80): return result, offset
    raise ValueError("truncated varint")

def _read_bytes(data, offset):
    length, offset = _read_varint(data, offset)
    return data[offset:offset + length], offset + length

def unpack_geoip(dat_path, target_tags):
    """解包 geoip.dat → CIDR 列表"""
    target_tags = set(target_tags)
    with open(dat_path, 'rb') as f: raw = f.read()
    offset = 0; results = []
    while offset < len(raw):
        field, offset = _read_varint(raw, offset)
        if (field & 0x7) != 2: continue
        length, offset = _read_varint(raw, offset)
        entry_data = raw[offset:offset + length]; offset += length
        if (field >> 3) != 1: continue
        eo = 0; country_code = None; cidrs = []
        while eo < len(entry_data):
            ef, eo = _read_varint(entry_data, eo)
            ew = ef & 0x7; en = ef >> 3
            if en == 1 and ew == 2:
                country_code, eo = _read_bytes(entry_data, eo)
                country_code = country_code.decode()
            elif en == 2 and ew == 2:
                cl, eo = _read_varint(entry_data, eo)
                cd = entry_data[eo:eo+cl]; eo += cl
                co = 0; ipb = None; pre = None
                while co < len(cd):
                    cf, co = _read_varint(cd, co)
                    cw = cf & 0x7; cn = cf >> 3
                    if cn == 1 and cw == 2:
                        ipb, co = _read_bytes(cd, co)
                    elif cn == 2 and cw == 0:
                        pre, co = _read_varint(cd, co)
                if ipb and pre is not None:
                    cidrs.append(f"{ipaddress.ip_address(ipb)}/{pre}")
        if country_code in target_tags:
            results.extend(cidrs)
    return results

_TYPE_MAP = {0: "keyword", 1: "regexp", 2: None, 3: "full"}

def unpack_geosite(dat_path, target_tags):
    """解包 geosite.dat → 域名列表"""
    target_tags = set(target_tags)
    with open(dat_path, 'rb') as f: raw = f.read()
    offset = 0; results = []
    while offset < len(raw):
        field, offset = _read_varint(raw, offset)
        if (field & 0x7) != 2: continue
        length, offset = _read_varint(raw, offset)
        entry_data = raw[offset:offset + length]; offset += length
        if (field >> 3) != 1: continue
        eo = 0; country_code = None; domains = []
        while eo < len(entry_data):
            ef, eo = _read_varint(entry_data, eo)
            ew = ef & 0x7; en = ef >> 3
            if en == 1 and ew == 2:
                country_code, eo = _read_bytes(entry_data, eo)
                country_code = country_code.decode()
            elif en == 2 and ew == 2:
                dl, eo = _read_varint(entry_data, eo)
                dd = entry_data[eo:eo+dl]; eo += dl
                do = 0; dtype = None; dval = None
                while do < len(dd):
                    df, do = _read_varint(dd, do)
                    dw = df & 0x7; dn = df >> 3
                    if dn == 1 and dw == 0:
                        dtype, do = _read_varint(dd, do)
                    elif dn == 2 and dw == 2:
                        dval, do = _read_bytes(dd, do)
                        dval = dval.decode()
                    else:
                        # skip unknown fields (e.g. attribute)
                        if dw == 0: _read_varint(dd, do)[1]
                        elif dw == 2:
                            sk, do = _read_varint(dd, do); do += sk
                if dval:
                    prefix = _TYPE_MAP.get(dtype)
                    if prefix:
                        domains.append(f"{prefix}:{dval}")
                    else:
                        domains.append(dval)
        if country_code in target_tags:
            results.extend(domains)
    return results

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <geoip|geosite> <dat_file> <tag> [tag...]", file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1]
    dat_path = sys.argv[2]
    tags = sys.argv[3:]
    if mode == "geoip":
        entries = unpack_geoip(dat_path, tags)
        entries.sort(key=lambda x: int(ipaddress.ip_address(x.split('/')[0])))
    elif mode == "geosite":
        entries = unpack_geosite(dat_path, tags)
        entries.sort()
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)
    for e in entries:
        print(e)
