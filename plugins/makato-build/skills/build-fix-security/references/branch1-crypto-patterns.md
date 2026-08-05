# Branch 1 — Autofix: Cryptographic Fix Patterns

Load this reference **only when executing Branch 1 for a CWE-327/CWE-326/CWE-330 rule**
(B303, B304, B305, B311, B324, B502, B503, B504, B505).
Do NOT load for other branches or other CWE groups.

## B303 — MD5/SHA-1 (general hashing)

Substitution spec: replace `hashlib.md5` / `hashlib.sha1` with `hashlib.sha256`.

```python
# Before
digest = hashlib.md5(data).hexdigest()

# After
digest = hashlib.sha256(data).hexdigest()
```

If variable names suggest password storage (`password_hash`, `pwd_hash`, `stored_password`),
escalate to the B324 pattern below — sha256 is still weak for passwords.

## B324 — Weak password hash (bcrypt/argon2)

Non-obvious: sha256 is NOT a safe swap here — it is still fast-hashable and brute-forceable.
The correct fix requires a new dependency and a fundamentally different algorithm.

```python
# Before
import hashlib
stored = hashlib.md5(password.encode()).hexdigest()

# After (bcrypt)
import bcrypt
stored = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
# Add to project dependencies: bcrypt>=4.0
```

If the project already uses `argon2-cffi`:

```python
from argon2 import PasswordHasher
ph = PasswordHasher()
stored = ph.hash(password)
# Add to project dependencies: argon2-cffi>=21.3
```

Add a comment: `# dependency: bcrypt>=4.0 (or argon2-cffi>=21.3)`.

## B304 — DES/Blowfish

Substitution spec: replace `Crypto.Cipher.DES` / Blowfish with `cryptography.fernet.Fernet`.

```python
# Before
from Crypto.Cipher import DES
cipher = DES.new(key, DES.MODE_ECB)

# After
from cryptography.fernet import Fernet
key = Fernet.generate_key()
cipher = Fernet(key)
# Add to project dependencies: cryptography
```

## B305 — ECB cipher mode

Non-obvious: do NOT just swap ECB → CBC. CBC without an authenticated MAC is also
vulnerable (padding oracle). Use GCM (authenticated encryption) with a fresh random nonce
per encryption call.

```python
# Before
cipher = AES.new(key, AES.MODE_ECB)

# After
import os
iv = os.urandom(16)
cipher = AES.new(key, AES.MODE_GCM, nonce=iv)
# GCM produces a tag; store/transmit it alongside ciphertext for authentication
```

## B311 — security-context random

Substitution spec: `random.X()` → `secrets` module equivalent.

```python
# Before
import random
token = random.randint(0, 2**32)

# After
import secrets
token = secrets.token_hex(32)
# For choices: secrets.choice(sequence)
# For integers: secrets.randbelow(n)
```

## B502 / B503 — deprecated SSL protocol

Substitution spec: `ssl.PROTOCOL_TLSv1` / `ssl.PROTOCOL_SSLv2` / `ssl.PROTOCOL_SSLv3`
→ `ssl.PROTOCOL_TLS_CLIENT`.

```python
# Before
ctx = ssl.SSLContext(ssl.PROTOCOL_TLSv1)

# After
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
```

## B504 — SSLContext without hostname verification

```python
# Before
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS)
# missing check_hostname / verify_mode

# After
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
```

## B505 — RSA key size

Substitution spec: `key_size=<N>` where N < 2048 → `key_size=4096`.

```python
# Before
key = rsa.generate_private_key(public_exponent=65537, key_size=1024, ...)

# After
key = rsa.generate_private_key(public_exponent=65537, key_size=4096, ...)
```
