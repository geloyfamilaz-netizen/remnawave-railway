#!/usr/bin/env python3
"""Reality x25519 helper (stdlib only, no xray binary needed).

  derive.py key <seed>   -> private key derived deterministically from <seed>
                            (entrypoint passes the UUID), base64url, no padding
  derive.py pub <priv>   -> matching public key (what clients put in pbk=)

Both outputs use the same encoding as `xray x25519`.
"""
import base64
import hashlib
import sys

P = 2**255 - 19
A24 = 121665


def _clamp(k):
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return bytes(k)


def x25519(k, u):
    """RFC 7748 scalar multiplication (Montgomery ladder)."""
    k = int.from_bytes(_clamp(k), "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt
        a = (x2 + z2) % P
        aa = a * a % P
        b = (x2 - z2) % P
        bb = b * b % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = d * a % P
        cb = c * b % P
        x3 = (da + cb) ** 2 % P
        z3 = x1 * (da - cb) ** 2 % P
        x2 = aa * bb % P
        z2 = e * (aa + A24 * e) % P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


def b64(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def unb64(s):
    s = s.strip()
    raw = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    if len(raw) != 32:
        raise ValueError("key must be 32 bytes (base64url)")
    return raw


def derive_private(seed):
    # Domain-separated so the key is unrelated to anything else hashed from the seed.
    return _clamp(hashlib.sha256(b"xray-railway/reality/v1:" + seed.encode()).digest())


def main(argv):
    if len(argv) != 3 or argv[1] not in ("key", "pub"):
        sys.stderr.write(__doc__)
        return 2
    try:
        if argv[1] == "key":
            print(b64(derive_private(argv[2])))
        else:
            print(b64(x25519(unb64(argv[2]), (9).to_bytes(32, "little"))))
    except Exception as exc:  # bad base64 / wrong length
        sys.stderr.write(f"derive.py: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
