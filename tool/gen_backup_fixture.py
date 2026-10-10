#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bağımsız (Dart'tan ayrı) .quanta v1 referans uygulaması + test fixture üreticisi.
docs/DATA.md §9 belirtimini uygular. Gereksinim: pip install cryptography>=46
Kullanım: python3 tool/gen_backup_fixture.py [çıktı.quanta]   (varsayılan: test/fixtures/backup_v1.quanta)
"""
import base64, hashlib, hmac, json, struct, sys, os
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

PASSWORD = "yedek-parolasi-2026"
VMK = bytes(range(32))
KDF = dict(mem=256, iters=1, par=1)
SALT = bytes(range(100, 116))
CREATED = 1_760_000_000_000
OUTER_NONCE = bytes(range(1, 13))
INNER_NONCE = bytes(range(50, 74))

def hkdf512(ikm, info):
    return HKDF(algorithm=hashes.SHA512(), length=32, salt=None, info=info).derive(ikm)

def rotl(x, n): return ((x << n) & 0xffffffff) | (x >> (32 - n))
def hchacha20(key, nonce16):
    s = list(struct.unpack('<4I', b'expand 32-byte k')) + list(struct.unpack('<8I', key)) + list(struct.unpack('<4I', nonce16))
    def qr(a, b, c, d):
        s[a] = (s[a] + s[b]) & 0xffffffff; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = (s[c] + s[d]) & 0xffffffff; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = (s[a] + s[b]) & 0xffffffff; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = (s[c] + s[d]) & 0xffffffff; s[b] = rotl(s[b] ^ s[c], 7)
    for _ in range(10):
        qr(0,4,8,12); qr(1,5,9,13); qr(2,6,10,14); qr(3,7,11,15)
        qr(0,5,10,15); qr(1,6,11,12); qr(2,7,8,13); qr(3,4,9,14)
    return struct.pack('<8I', *(s[0:4] + s[12:16]))

def xchacha_encrypt(key, nonce24, pt, aad):
    sub = hchacha20(key, nonce24[:16])
    out = ChaCha20Poly1305(sub).encrypt(b'\0\0\0\0' + nonce24[16:], pt, aad)
    return out[:-16], out[-16:]

def xchacha_decrypt(key, nonce24, ct, tag, aad):
    sub = hchacha20(key, nonce24[:16])
    return ChaCha20Poly1305(sub).decrypt(b'\0\0\0\0' + nonce24[16:], ct + tag, aad)

def header_bytes():
    return (b'QNTB' + bytes([1, 0]) + struct.pack('>Q', CREATED) +
            struct.pack('>IIBBB', KDF['mem'], KDF['iters'], KDF['par'], 32, 16) + SALT)

def vault_header():  # yapısal olarak geçerli VaultHeader v1 (MAC sahte; fixture'da açılmaz)
    core = (b'QNTA' + bytes([1, 0]) + struct.pack('>Q', CREATED) +
            struct.pack('>IIBB', KDF['mem'], KDF['iters'], KDF['par'], 32) + bytes([16]) + SALT)
    return core + bytes([7]) * 72 + bytes([9]) * 32

def payload():
    def item(id_, kind, title, data, **kw):
        d = {"v": 1, "kind": kind, "title": title, "category": kw.get("category"),
             "tags": kw.get("tags", []), "color": None, "notes": kw.get("notes", ""),
             "custom": kw.get("custom", []), "secretChangedAt": kw.get("secretChangedAt"),
             "data": data, "id": id_, "favorite": kw.get("favorite", False),
             "createdAt": CREATED - 86400000, "updatedAt": CREATED - 1000,
             "lastUsedAt": None, "trashedAt": kw.get("trashedAt"),
             "history": kw.get("history", []), "attachments": kw.get("attachments", [])}
        return d
    att = base64.b64encode(b"kurtarma-kodu-0123456789").decode()
    items = [
        item("11111111-1111-4111-8111-111111111111", "login", "Örnek Site",
             {"username": "ali", "password": "p@ss-Yeni-9", "urls": ["https://example.com"], "totp": ""},
             category="Alışveriş", tags=["iş"], favorite=True, secretChangedAt=CREATED - 5000,
             custom=[{"n": "PIN", "v": "4321", "t": "hidden"}],
             history=[{"id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "changedAt": CREATED - 5000, "setAt": CREATED - 99999, "password": "eski-parola"}],
             attachments=[{"id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "name": "kurtarma.txt", "createdAt": CREATED - 4000, "data": att}]),
        item("22222222-2222-4222-8222-222222222222", "note", "Çöpteki not",
             {"body": "gizli gövde"}, trashedAt=CREATED - 2000),
    ]
    return json.dumps({"format": 1, "createdAt": CREATED, "items": items}, ensure_ascii=False, separators=(',', ':')).encode()

def build():
    hdr = header_bytes()
    k_backup = hkdf512(VMK, b'quanta/v1/backup')
    ct, tag = xchacha_encrypt(k_backup, INNER_NONCE, payload(), b'quanta/v1/backup-inner' + hdr)
    vh = vault_header()
    outer_plain = struct.pack('>H', len(vh)) + vh + INNER_NONCE + ct + tag
    pw_key = Argon2id(salt=SALT, length=32, iterations=KDF['iters'], lanes=KDF['par'], memory_cost=KDF['mem']).derive(PASSWORD.encode())
    k_outer, k_mac = hkdf512(pw_key, b'quanta/v1/backup-outer'), hkdf512(pw_key, b'quanta/v1/backup-mac')
    o = AESGCM(k_outer).encrypt(OUTER_NONCE, outer_plain, b'quanta/v1/backup-file' + hdr)
    body = hdr + OUTER_NONCE + o  # o = ciphertext | tag(16)
    return body + hmac.new(k_mac, body, hashlib.sha256).digest()

def verify(blob):
    assert blob[:4] == b'QNTB' and blob[4] == 1 and blob[5] == 0
    hdr = blob[:41]; salt = blob[25:41]
    pw_key = Argon2id(salt=salt, length=32, iterations=1, lanes=1, memory_cost=256).derive(PASSWORD.encode())
    k_outer, k_mac = hkdf512(pw_key, b'quanta/v1/backup-outer'), hkdf512(pw_key, b'quanta/v1/backup-mac')
    assert hmac.compare_digest(hmac.new(k_mac, blob[:-32], hashlib.sha256).digest(), blob[-32:])
    plain = AESGCM(k_outer).decrypt(blob[41:53], blob[53:-32], b'quanta/v1/backup-file' + hdr)
    n = struct.unpack('>H', plain[:2])[0]
    inner = plain[2 + n:]
    pt = xchacha_decrypt(hkdf512(VMK, b'quanta/v1/backup'), inner[:24], inner[24:-16], inner[-16:], b'quanta/v1/backup-inner' + hdr)
    return json.loads(pt)

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'test', 'fixtures', 'backup_v1.quanta')
    blob = build()
    doc = verify(blob)
    assert len(doc['items']) == 2
    open(out, 'wb').write(blob)
    print('yazıldı', out, len(blob), 'bayt; sha256', hashlib.sha256(blob).hexdigest())
