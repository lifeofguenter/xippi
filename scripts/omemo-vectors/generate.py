"""Writes the test vectors that Packages/CurveMath and Packages/OMEMO tests read.

- xeddsa-vectors.json (CurveMath): XEdDSA and key conversion vectors from python-xeddsa (libxeddsa,
  libsodium); the scalar cases from Python integers.
- omemo-vectors.json (OMEMO): X3DH, Double Ratchet KDF, payload, protobuf and whole-session vectors
  for both OMEMO versions, from python-x3dh, python-doubleratchet, python-oldmemo
  (eu.siacs.conversations.axolotl) and python-twomemo (urn:xmpp:omemo:2).
- omemo-stanzas.json (OMEMO): what another OMEMO implementation puts on the wire, serialized by
  python-oldmemo's and python-twomemo's etree modules: device lists, bundles and complete
  <message/> stanzas with <encrypted/> elements (key exchanges, a repeat, an empty message), plus
  the private keys of the receiving device so the Swift engine can decrypt them.

Fixed seeds make every run write the same files: the randomness the OMEMO libraries draw (keys,
nonces, initialization vectors, pre key choice) is replaced by a seeded generator, and every
ratchet key a session generates is recorded so the Swift tests can replay the sessions exactly.
"""

import asyncio
import base64
import json
import xml.etree.ElementTree as ET
import pathlib
import random
import secrets
import sys

import doubleratchet
import oldmemo
import oldmemo.etree
import oldmemo.oldmemo
import omemo
import twomemo
import twomemo.etree
import twomemo.twomemo
import x3dh
import x3dh.identity_key_pair
import xeddsa
from doubleratchet.recommended import HashFunction, diffie_hellman_ratchet_curve25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from doubleratchet.recommended.crypto_provider_impl import CryptoProviderImpl
from oldmemo import oldmemo_pb2
from omemo.session import Initiation
from twomemo import twomemo_pb2

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Packages/CurveMath/Tests/CurveMathTests/Resources/xeddsa-vectors.json"
OMEMO_OUTPUT = ROOT / "Packages/OMEMO/Tests/OMEMOTests/Resources/omemo-vectors.json"
STANZA_OUTPUT = ROOT / "Packages/OMEMO/Tests/OMEMOTests/Resources/omemo-stanzas.json"

# Order of the Ed25519 base point.
L = 2**252 + 27742317777372353535851937790883648493

MESSAGE_LENGTHS = [0, 1, 31, 32, 33, 64, 100, 255, 1000]

rng = random.Random(20261119)


def random_bytes(count: int) -> bytes:
    return rng.randbytes(count)


def clamp(key: bytes) -> bytes:
    clamped = bytearray(key)
    clamped[0] &= 248
    clamped[31] &= 127
    clamped[31] |= 64
    return bytes(clamped)


def edwards_sign_bit(private_key: bytes) -> int:
    return xeddsa.priv_to_ed25519_pub(private_key)[31] >> 7


def xeddsa_signatures(count: int) -> list[dict]:
    """XEdDSA as specified: the private key is negated when its Edwards key has the sign bit set."""
    vectors = []
    for index in range(count):
        private_key = random_bytes(32)
        public_key = xeddsa.priv_to_curve25519_pub(private_key)
        message = random_bytes(MESSAGE_LENGTHS[index % len(MESSAGE_LENGTHS)])
        nonce = random_bytes(64)
        signature = xeddsa.ed25519_priv_sign(
            xeddsa.priv_force_sign(private_key, False), message, nonce
        )
        edwards_key = xeddsa.curve25519_pub_to_ed25519_pub(public_key, False)
        assert xeddsa.ed25519_verify(signature, edwards_key, message)
        vectors.append({
            "privateKey": private_key.hex(),
            "publicKey": public_key.hex(),
            "message": message.hex(),
            "random": nonce.hex(),
            "signature": signature.hex(),
            "edwardsSignBit": edwards_sign_bit(private_key),
        })
    assert {vector["edwardsSignBit"] for vector in vectors} == {0, 1}
    return vectors


def libsignal_signatures(count: int) -> list[dict]:
    """Signatures as libsignal's curve25519_sign makes them, which legacy OMEMO clients publish.

    The private key is used without negation and the sign bit of its Edwards key is carried in
    the top bit of the signature, as python-oldmemo reads and writes bundles.
    """
    vectors = []
    for index in range(count):
        private_key = clamp(random_bytes(32))
        public_key = xeddsa.priv_to_curve25519_pub(private_key)
        message = random_bytes(MESSAGE_LENGTHS[index % len(MESSAGE_LENGTHS)])
        sign_bit = edwards_sign_bit(private_key)
        signature = bytearray(xeddsa.ed25519_priv_sign(private_key, message, random_bytes(64)))
        signature[63] |= sign_bit << 7
        unmarked = bytes(signature[:63]) + bytes([signature[63] & 0x7F])
        edwards_key = xeddsa.curve25519_pub_to_ed25519_pub(public_key, bool(sign_bit))
        assert xeddsa.ed25519_verify(unmarked, edwards_key, message)
        vectors.append({
            "publicKey": public_key.hex(),
            "message": message.hex(),
            "signature": bytes(signature).hex(),
            "edwardsSignBit": sign_bit,
        })
    assert {vector["edwardsSignBit"] for vector in vectors} == {0, 1}
    return vectors


def seed_conversions(count: int) -> list[dict]:
    vectors = []
    for _ in range(count):
        seed = random_bytes(32)
        montgomery_private = xeddsa.seed_to_priv(seed)
        edwards_public = xeddsa.seed_to_ed25519_pub(seed)
        montgomery_public = xeddsa.ed25519_pub_to_curve25519_pub(edwards_public)
        assert montgomery_public == xeddsa.priv_to_curve25519_pub(montgomery_private)
        vectors.append({
            "seed": seed.hex(),
            "montgomeryPrivate": montgomery_private.hex(),
            "edwardsPublic": edwards_public.hex(),
            "montgomeryPublic": montgomery_public.hex(),
        })
    return vectors


def montgomery_to_edwards(count: int) -> list[dict]:
    vectors = []
    for index in range(count):
        montgomery_public = xeddsa.priv_to_curve25519_pub(random_bytes(32))
        sign_bit = index % 2
        vectors.append({
            "montgomeryPublic": montgomery_public.hex(),
            "signBit": sign_bit,
            "edwardsPublic": xeddsa.curve25519_pub_to_ed25519_pub(
                montgomery_public, bool(sign_bit)
            ).hex(),
        })
    return vectors


def to_bytes(value: int, count: int) -> str:
    return value.to_bytes(count, "little").hex()


def scalar_reductions(count: int) -> list[dict]:
    inputs = [0, L - 1, L, L + 1, 16 * L, 2**252, 2**512 - 1]
    inputs += [int.from_bytes(random_bytes(64), "little") for _ in range(count)]
    return [{"input": to_bytes(value, 64), "output": to_bytes(value % L, 32)} for value in inputs]


def scalar_multiply_adds(count: int) -> list[dict]:
    cases = [(L - 1, L - 1, L - 1), (2**256 - 1, 2**256 - 1, 2**256 - 1), (0, 0, 0)]
    cases += [
        tuple(int.from_bytes(random_bytes(32), "little") for _ in range(3)) for _ in range(count)
    ]
    return [
        {
            "a": to_bytes(a, 32),
            "b": to_bytes(b, 32),
            "c": to_bytes(c, 32),
            "output": to_bytes((a * b + c) % L, 32),
        }
        for a, b, c in cases
    ]


# OMEMO -----------------------------------------------------------------------------------------

omemo_rng = random.Random(20261120)

# Every ratchet private key python-doubleratchet generated, by party, in the order it made them.
ratchet_keys: dict[str, list[bytes]] = {}
# The party whose operation is running, so that a generated ratchet key is recorded for it.
current_party = ""
# While not None, collects the bytes drawn from secrets.token_bytes (the X3DH ephemeral key).
drawn_bytes: list[bytes] | None = None

original_ed25519_priv_sign = xeddsa.ed25519_priv_sign


def seeded_token_bytes(count: int | None = None) -> bytes:
    value = omemo_rng.randbytes(32 if count is None else count)
    if drawn_bytes is not None:
        drawn_bytes.append(value)
    return value


def seeded_choice(sequence):
    ordered = sorted(sequence)
    return ordered[omemo_rng.randrange(len(ordered))]


def seeded_ratchet_priv() -> bytes:
    value = omemo_rng.randbytes(32)
    ratchet_keys.setdefault(current_party, []).append(value)
    return value


def seeded_ed25519_priv_sign(priv, msg, nonce=None):
    return original_ed25519_priv_sign(priv, msg, omemo_rng.randbytes(64) if nonce is None else nonce)


def make_omemo_libraries_deterministic() -> None:
    """Replaces the randomness python-x3dh, python-doubleratchet and the OMEMO backends draw."""
    secrets.token_bytes = seeded_token_bytes
    secrets.choice = seeded_choice
    diffie_hellman_ratchet_curve25519.DiffieHellmanRatchet._generate_priv = staticmethod(
        seeded_ratchet_priv
    )
    xeddsa.ed25519_priv_sign = seeded_ed25519_priv_sign


VERSIONS = {
    "v03": (oldmemo.oldmemo, oldmemo.oldmemo.Oldmemo),
    "v2": (twomemo.twomemo, twomemo.twomemo.Twomemo),
}


def identity_vector(version: str, seed: bytes) -> dict:
    """Legacy OMEMO identity keys are X25519 keys; OMEMO 2 identity keys are Ed25519 seeds."""
    if version == "v03":
        private_key = xeddsa.seed_to_priv(seed)
        return {
            "privateKey": private_key.hex(),
            "publicKey": xeddsa.priv_to_curve25519_pub(private_key).hex(),
        }
    return {"privateKey": seed.hex(), "publicKey": xeddsa.seed_to_ed25519_pub(seed).hex()}


def published_signature(version: str, identity_ed25519: bytes, signature: bytes) -> bytes:
    """The signed pre key signature as a bundle carries it.

    python-oldmemo (oldmemo.etree.serialize_bundle) and libsignal carry the sign bit of the Edwards
    identity key in the top bit of the signature; OMEMO 2 publishes the Ed25519 signature as is.
    """
    if version != "v03":
        return signature
    marked = bytearray(signature)
    marked[63] |= identity_ed25519[31] & 0x80
    return bytes(marked)


def check_published_signature(version: str, identity: bytes, signed_pre_key: bytes,
                              signature: bytes) -> None:
    if version == "v03":
        sign_bit = signature[63] >> 7
        unmarked = signature[:63] + bytes([signature[63] & 0x7F])
        edwards = xeddsa.curve25519_pub_to_ed25519_pub(identity, bool(sign_bit))
        assert xeddsa.ed25519_verify(unmarked, edwards, b"\x05" + signed_pre_key)
    else:
        assert xeddsa.ed25519_verify(signature, identity, signed_pre_key)


def state_identity_seed(state: x3dh.BaseState) -> bytes:
    identity = state.model.identity_key
    assert identity.secret_type is x3dh.types.SecretType.SEED
    return identity.secret


async def x3dh_vectors(version: str, count: int) -> list[dict]:
    """Key agreements made directly with python-x3dh, configured as each backend configures it."""
    global drawn_bytes
    module, _ = VERSIONS[version]
    state_class = module.StateImpl
    vectors = []
    for _ in range(count):
        states = [
            state_class.create(
                x3dh.IdentityKeyFormat.ED_25519,
                x3dh.HashFunction.SHA_256,
                state_class.INFO,
                x3dh.identity_key_pair.IdentityKeyPairSeed(omemo_rng.randbytes(32)),
            )
            for _ in range(2)
        ]
        alice, bob = states
        bob.generate_pre_keys(3)

        drawn_bytes = []
        shared_secret, associated_data, header = await alice.get_shared_secret_active(bob.bundle)
        (ephemeral,) = drawn_bytes
        drawn_bytes = None
        passive_secret, passive_data, _ = await bob.get_shared_secret_passive(header)
        assert (passive_secret, passive_data) == (shared_secret, associated_data)

        bundle = bob.bundle
        model = bob.model
        signature = published_signature(
            version, bundle.identity_key, model.signed_pre_key.sig
        )
        bob_identity = identity_vector(version, state_identity_seed(bob))
        check_published_signature(
            version, bytes.fromhex(bob_identity["publicKey"]), bundle.signed_pre_key, signature
        )
        pre_keys = sorted(
            (xeddsa.priv_to_curve25519_pub(private_key), private_key)
            for private_key in model.pre_keys
        )
        pre_key_ids = {public_key: 31 + 7 * index for index, (public_key, _) in enumerate(pre_keys)}
        vectors.append({
            "aliceIdentity": identity_vector(version, state_identity_seed(alice)),
            "bobIdentity": bob_identity,
            "signedPreKey": {
                "id": 4,
                "privateKey": model.signed_pre_key.priv.hex(),
                "publicKey": bundle.signed_pre_key.hex(),
                "signature": signature.hex(),
            },
            "preKeys": [
                {
                    "id": pre_key_ids[public_key],
                    "privateKey": private_key.hex(),
                    "publicKey": public_key.hex(),
                }
                for public_key, private_key in pre_keys
            ],
            "usedPreKeyID": pre_key_ids[header.pre_key],
            "ephemeral": {
                "privateKey": ephemeral.hex(),
                "publicKey": header.ephemeral_key.hex(),
            },
            "sharedSecret": shared_secret.hex(),
            "associatedData": associated_data.hex(),
        })
    if version == "v03":
        # Bundles whose identity key has either Edwards sign bit, carried in the signature.
        signatures = [bytes.fromhex(vector["signedPreKey"]["signature"]) for vector in vectors]
        assert {signature[63] >> 7 for signature in signatures} == {0, 1}
    return vectors


async def kdf_vectors(version: str, count: int) -> list[dict]:
    """The root chain, message chain and message key KDFs of python-doubleratchet as configured."""
    module, _ = VERSIONS[version]
    vectors = []
    for _ in range(count):
        root_key, dh_output, chain_key, message_key = (omemo_rng.randbytes(32) for _ in range(4))
        root = await module.RootChainKDFImpl.derive(root_key, dh_output, 64)
        chain = await module.MessageChainKDFImpl.derive(
            chain_key, module.DoubleRatchetImpl.MESSAGE_CHAIN_CONSTANT, 64
        )
        expanded = await CryptoProviderImpl.hkdf_derive(
            HashFunction.SHA_256, 80, b"\x00" * 32, module.AEADImpl._get_info(), message_key
        )
        vectors.append({
            "rootKey": root_key.hex(),
            "dhOutput": dh_output.hex(),
            "nextRootKey": root[:32].hex(),
            "newChainKey": root[32:].hex(),
            "chainKey": chain_key.hex(),
            "nextChainKey": chain[:32].hex(),
            "chainMessageKey": chain[32:].hex(),
            "messageKey": message_key.hex(),
            "encryptionKey": expanded[:32].hex(),
            "authenticationKey": expanded[32:64].hex(),
            "iv": expanded[64:].hex(),
        })
    return vectors


class MemoryStorage(omemo.Storage):
    def __init__(self) -> None:
        super().__init__(True)
        self.values: dict = {}

    async def _load(self, key: str) -> omemo.Maybe:
        return omemo.Just(self.values[key]) if key in self.values else omemo.Nothing()

    async def _store(self, key: str, value) -> None:
        self.values[key] = value

    async def _delete(self, key: str) -> None:
        self.values.pop(key, None)


PAYLOAD_LENGTHS = [1, 15, 16, 17, 31, 100, 1000]


async def payload_vectors(version: str) -> list[dict]:
    """python-oldmemo: AES-128-GCM. python-twomemo: HKDF "OMEMO Payload", AES-256-CBC, HMAC."""
    global drawn_bytes
    module, backend_class = VERSIONS[version]
    backend = backend_class(MemoryStorage())
    vectors = []
    for length in PAYLOAD_LENGTHS:
        plaintext = omemo_rng.randbytes(length)
        drawn_bytes = []
        content, key_material = await backend.encrypt_plaintext(plaintext)
        drawn = drawn_bytes
        drawn_bytes = None
        assert await backend.decrypt_plaintext(content, key_material) == plaintext
        vector = {
            "plaintext": plaintext.hex(),
            "key": key_material.key.hex(),
            "ciphertext": content.ciphertext.hex(),
            "keyMaterial": (key_material.key + key_material.auth_tag).hex(),
        }
        if version == "v03":
            assert drawn == [key_material.key, content.initialization_vector]
            vector["iv"] = content.initialization_vector.hex()
        else:
            assert drawn == [key_material.key]
        vectors.append(vector)
    return vectors


def legacy_payload_vectors() -> list[dict]:
    """Payloads as older Conversations releases sent them: the GCM tag after the ciphertext and
    only the 16-byte key as key material, with 12 and 16-byte IVs. Made with python cryptography's
    AES-GCM (OpenSSL), so a 16-byte IV, whose counter block GCM derives with GHASH, is checked
    against a second implementation. A generator of its own leaves every other vector unchanged.
    """
    legacy_rng = random.Random(20261121)
    vectors = []
    for length, iv_length in [(0, 16), (1, 16), (16, 12), (33, 16), (200, 16), (57, 12)]:
        key = legacy_rng.randbytes(16)
        iv = legacy_rng.randbytes(iv_length)
        plaintext = legacy_rng.randbytes(length)
        sealed = AESGCM(key).encrypt(iv, plaintext, None)
        assert len(sealed) == length + 16
        vectors.append({
            "plaintext": plaintext.hex(),
            "key": key.hex(),
            "ciphertext": sealed.hex(),
            "keyMaterial": key.hex(),
            "iv": iv.hex(),
        })
    return vectors


class Party:
    def __init__(self, name: str, version: str, jid: str, device_id: int) -> None:
        self.name = name
        self.version = version
        self.module, backend_class = VERSIONS[version]
        self.jid = jid
        self.device_id = device_id
        self.storage = MemoryStorage()
        self.backend = backend_class(self.storage)
        self.session = None

    async def set_up(self, signed_pre_key_id: int, pre_key_id: int) -> None:
        """One pre key, so that python-omemo's id assignment (set order) is the same every run."""
        namespace = self.module.NAMESPACE
        await self.storage.store(f"/{namespace}/pre_key_id_counter", pre_key_id - 1)
        await self.storage.store(
            f"/{namespace}/signed_pre_key_ids",
            {base64.b64encode(b"\x00" * 32).decode("ASCII"): signed_pre_key_id - 1},
        )
        await self.backend.generate_pre_keys(1)
        self.bundle = await self.backend.get_bundle(self.jid, self.device_id)
        assert self.bundle.signed_pre_key_id == signed_pre_key_id
        assert list(self.bundle.pre_key_ids.values()) == [pre_key_id]
        self.state = await getattr(self.backend, f"_{type(self.backend).__name__}__get_state")()

    def keys(self) -> dict:
        bundle = self.bundle.bundle
        model = self.state.model
        identity = identity_vector(self.version, state_identity_seed(self.state))
        signature = published_signature(self.version, bundle.identity_key, model.signed_pre_key.sig)
        check_published_signature(
            self.version, bytes.fromhex(identity["publicKey"]), bundle.signed_pre_key, signature
        )
        pre_keys = {xeddsa.priv_to_curve25519_pub(key): key for key in model.pre_keys}
        return {
            "deviceID": self.device_id,
            "identity": identity,
            "signedPreKey": {
                "id": self.bundle.signed_pre_key_id,
                "privateKey": model.signed_pre_key.priv.hex(),
                "publicKey": bundle.signed_pre_key.hex(),
                "signature": signature.hex(),
            },
            "preKeys": [
                {"id": key_id, "privateKey": pre_keys[key].hex(), "publicKey": key.hex()}
                for key, key_id in self.bundle.pre_key_ids.items()
            ],
        }


class Transcript:
    """A session between Alice and Bob run by python-oldmemo or python-twomemo.

    `events` lists every encryption and decryption in the order they ran; `ratchetKeys` the ratchet
    private keys each party generated, in order. Alice wraps her messages in a key exchange until
    she has decrypted a message from Bob, as python-omemo does.
    """

    def __init__(self, name: str, version: str) -> None:
        self.name = name
        self.version = version
        self.module, _ = VERSIONS[version]
        self.alice = Party("alice", version, "alice@example.org", 1_001)
        self.bob = Party("bob", version, "bob@example.org", 2_002)
        self.messages: list[dict] = []
        self.sent: list[tuple] = []
        self.events: list[dict] = []
        self.ephemeral: bytes | None = None

    async def set_up(self) -> None:
        ratchet_keys.clear()
        await self.alice.set_up(signed_pre_key_id=11, pre_key_id=101)
        await self.bob.set_up(signed_pre_key_id=23, pre_key_id=2_345)

    def other(self, party: Party) -> Party:
        return self.bob if party is self.alice else self.alice

    async def send(self, sender: Party, plaintext: bytes | None) -> int:
        """Encrypts `plaintext`, or an empty OMEMO message when None."""
        global current_party, drawn_bytes
        current_party = sender.name
        receiver = self.other(sender)
        if plaintext is None:
            content, key_material = await sender.backend.encrypt_empty()
        else:
            content, key_material = await sender.backend.encrypt_plaintext(plaintext)
        if sender.session is None:
            drawn_bytes = []
            sender.session, encrypted = await sender.backend.build_session_active(
                receiver.jid, receiver.device_id, receiver.bundle, key_material
            )
            (self.ephemeral,) = drawn_bytes
            drawn_bytes = None
        else:
            encrypted = await sender.backend.encrypt_key_material(sender.session, key_material)
        authenticated = encrypted.serialize()
        key_exchange = (
            sender.session.initiation is Initiation.ACTIVE and not sender.session.confirmed
        )
        key = authenticated
        if key_exchange:
            serialized = sender.session.key_exchange.serialize(authenticated)
            key = serialized[0] if isinstance(serialized, tuple) else serialized
        index = len(self.messages)
        self.messages.append({
            "sender": sender.name,
            "keyExchange": key_exchange,
            "key": key.hex(),
            "keyMaterial": (key_material.key + key_material.auth_tag).hex(),
            "payload": None if plaintext is None else content.ciphertext.hex(),
            "iv": content.initialization_vector.hex() if self.version == "v03" else None,
            "plaintext": None if plaintext is None else plaintext.hex(),
        })
        self.sent.append((content, key_material, plaintext))
        self.events.append({"encrypt": index})
        return index

    async def deliver(self, index: int) -> None:
        global current_party
        message = self.messages[index]
        sender = self.alice if message["sender"] == "alice" else self.bob
        receiver = self.other(sender)
        current_party = receiver.name
        key = bytes.fromhex(message["key"])
        module = self.module
        if message["keyExchange"]:
            if self.version == "v03":
                sign_bit = bool(sender.bundle.bundle.identity_key[31] >> 7)
                key_exchange, authenticated = module.KeyExchangeImpl.parse(key, sign_bit)
            else:
                key_exchange, authenticated = module.KeyExchangeImpl.parse(key)
            encrypted = module.EncryptedKeyMaterialImpl.parse(
                authenticated, sender.jid, sender.device_id
            )
            if receiver.session is not None and receiver.session.key_exchange.builds_same_session(
                key_exchange
            ):
                key_material = await receiver.backend.decrypt_key_material(
                    receiver.session, encrypted
                )
            else:
                receiver.session, key_material = await receiver.backend.build_session_passive(
                    sender.jid, sender.device_id, key_exchange, encrypted
                )
        else:
            encrypted = module.EncryptedKeyMaterialImpl.parse(key, sender.jid, sender.device_id)
            key_material = await receiver.backend.decrypt_key_material(receiver.session, encrypted)
        content, sent_key_material, plaintext = self.sent[index]
        assert key_material.key + key_material.auth_tag == (
            sent_key_material.key + sent_key_material.auth_tag
        )
        if plaintext is not None:
            assert await receiver.backend.decrypt_plaintext(content, key_material) == plaintext
        self.events.append({"decrypt": index})

    def vector(self) -> dict:
        assert self.ephemeral is not None
        return {
            "name": self.name,
            "alice": self.alice.keys(),
            "bob": self.bob.keys(),
            "aliceEphemeralKey": self.ephemeral.hex(),
            "ratchetKeys": {
                party: [key.hex() for key in keys] for party, keys in ratchet_keys.items()
            },
            "messages": self.messages,
            "events": self.events,
        }


def text(value: str) -> bytes:
    return value.encode("utf-8")


async def conversation(version: str) -> dict:
    """Turns taken in order, a reply that confirms the key exchange, and a long message."""
    transcript = Transcript("conversation", version)
    await transcript.set_up()
    alice, bob = transcript.alice, transcript.bob
    for sender, plaintext in [
        (alice, text("Hello Bob")),
        (alice, text("Are you there?")),
        (bob, text("Hi Alice")),
        (alice, text("Good to see you")),
        (bob, text("Same here")),
        (bob, text("Two in a row")),
        (alice, text("Grüße aus Köln, " + "🙂" * 300)),
    ]:
        await transcript.deliver(await transcript.send(sender, plaintext))
    return transcript.vector()


async def out_of_order(version: str) -> dict:
    """Late and reordered messages within a chain and across ratchet steps."""
    transcript = Transcript("outOfOrder", version)
    await transcript.set_up()
    alice, bob = transcript.alice, transcript.bob
    send, deliver = transcript.send, transcript.deliver
    await deliver(await send(alice, text("m0")))
    m1, m2, m3 = [await send(alice, text(f"m{index}")) for index in range(1, 4)]
    for index in (m3, m1, m2):
        await deliver(index)
    r0, r1, r2 = [await send(bob, text(f"r{index}")) for index in range(3)]
    await deliver(r2)
    await deliver(r0)
    await deliver(await send(alice, text("m4")))
    m5, m6 = await send(alice, text("m5")), await send(alice, text("m6"))
    await deliver(await send(bob, text("r3")))
    await deliver(r1)
    await deliver(await send(alice, text("m7")))
    await deliver(m6)
    await deliver(m5)
    await deliver(await send(bob, text("r4")))
    return transcript.vector()


async def empty_messages(version: str) -> dict:
    """Empty OMEMO messages: the reply that completes a key exchange, and a heartbeat."""
    transcript = Transcript("emptyMessages", version)
    await transcript.set_up()
    alice, bob = transcript.alice, transcript.bob
    await transcript.deliver(await transcript.send(alice, text("first")))
    await transcript.deliver(await transcript.send(bob, None))
    await transcript.deliver(await transcript.send(alice, None))
    await transcript.deliver(await transcript.send(alice, text("after the heartbeat")))
    return transcript.vector()


def protobuf_fixtures() -> list[dict]:
    """Messages serialized by the protobuf schemas python-oldmemo and python-twomemo ship."""

    def key() -> bytes:
        return omemo_rng.randbytes(32)

    def optional(value: bytes | None) -> str | None:
        return None if value is None else value.hex()

    fixtures = []
    for n, pn, length in [(0, 0, None), (1, 127, 16), (128, 16_384, 48), (300, 2**21, 0),
                          (2**32 - 1, 2**31, 32)]:
        dh_pub = key()
        ciphertext = None if length is None else omemo_rng.randbytes(length)
        message = twomemo_pb2.OMEMOMessage(n=n, pn=pn, dh_pub=dh_pub)
        if ciphertext is not None:
            message.ciphertext = ciphertext
        fixtures.append({
            "type": "OMEMOMessage", "n": n, "pn": pn, "dhPub": dh_pub.hex(),
            "ciphertext": optional(ciphertext), "encoded": message.SerializeToString().hex(),
        })
    for length in [16, 70]:
        mac, body = omemo_rng.randbytes(16), omemo_rng.randbytes(length)
        fixtures.append({
            "type": "OMEMOAuthenticatedMessage", "mac": mac.hex(), "message": body.hex(),
            "encoded": twomemo_pb2.OMEMOAuthenticatedMessage(mac=mac, message=body)
            .SerializeToString().hex(),
        })
    for pk_id, spk_id in [(1, 2**31 - 1), (2**31 - 1, 1), (0, 0)]:
        ik, ek = key(), key()
        mac, body = omemo_rng.randbytes(16), omemo_rng.randbytes(60)
        message = twomemo_pb2.OMEMOKeyExchange(
            pk_id=pk_id, spk_id=spk_id, ik=ik, ek=ek,
            message=twomemo_pb2.OMEMOAuthenticatedMessage(mac=mac, message=body),
        )
        fixtures.append({
            "type": "OMEMOKeyExchange", "pkID": pk_id, "spkID": spk_id, "ik": ik.hex(),
            "ek": ek.hex(), "mac": mac.hex(), "message": body.hex(),
            "encoded": message.SerializeToString().hex(),
        })
    for counter, previous_counter, length in [(0, 0, 32), (53, 2, 48), (2**32 - 1, 2**32 - 1, 16)]:
        ratchet_key = key()
        ciphertext = omemo_rng.randbytes(length)
        message = oldmemo_pb2.OMEMOMessage(
            n=counter, pn=previous_counter, dh_pub=b"\x05" + ratchet_key, ciphertext=ciphertext
        )
        fixtures.append({
            "type": "WhisperMessage", "counter": counter, "previousCounter": previous_counter,
            "ratchetKey": ratchet_key.hex(), "ciphertext": ciphertext.hex(),
            "encoded": (b"\x33" + message.SerializeToString()).hex(),
        })
    for pre_key_id, signed_pre_key_id, registration_id in [(1, 2, None), (16_777_215, 1, 12_345),
                                                           (2**31 - 1, 2**31 - 1, 0)]:
        identity_key, base_key = key(), key()
        inner = omemo_rng.randbytes(57)
        message = oldmemo_pb2.OMEMOKeyExchange(
            pk_id=pre_key_id, spk_id=signed_pre_key_id, ik=b"\x05" + identity_key,
            ek=b"\x05" + base_key, message=inner,
        )
        if registration_id is not None:
            message.unused = registration_id
        fixtures.append({
            "type": "PreKeyWhisperMessage", "preKeyID": pre_key_id,
            "signedPreKeyID": signed_pre_key_id, "registrationID": registration_id,
            "identityKey": identity_key.hex(), "baseKey": base_key.hex(), "message": inner.hex(),
            "encoded": (b"\x33" + message.SerializeToString()).hex(),
        })
    return fixtures


async def omemo_vectors() -> dict:
    make_omemo_libraries_deterministic()
    vectors: dict = {
        "generator": "scripts/omemo-vectors/generate.py",
        "versions": {
            "x3dh": x3dh.__version__,
            "doubleratchet": doubleratchet.__version__,
            "omemo": omemo.__version__,
            "oldmemo": oldmemo.__version__,
            "twomemo": twomemo.__version__,
            "xeddsa": xeddsa.__version__,
        },
        "protobuf": protobuf_fixtures(),
    }
    for version in VERSIONS:
        vectors[version] = {
            "x3dh": await x3dh_vectors(version, 6),
            "kdf": await kdf_vectors(version, 6),
            "payload": await payload_vectors(version),
            "sessions": [
                await conversation(version),
                await out_of_order(version),
                await empty_messages(version),
            ],
        }
    vectors["v03"]["legacyPayload"] = legacy_payload_vectors()
    return vectors


# MARK: - Stanzas

ETREE = {"v03": oldmemo.etree, "v2": twomemo.etree}

# RFC 8032 section 7.1, the public keys of TEST 1, TEST 2, TEST 3 and TEST 1024.
RFC8032_PUBLIC_KEYS = [
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
    "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
    "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
]


def xml_text(element: ET.Element, namespace: str) -> str:
    """The element as text, its namespace the default one, as XMPP clients write it."""
    ET.register_namespace("", namespace)
    return ET.tostring(element, encoding="unicode")


class StanzaParty:
    """One device of an account whose single identity serves both OMEMO versions, as
    python-omemo's SessionManager keeps it: every backend reads the same /ikp entry."""

    def __init__(self, jid: str, device_id: int) -> None:
        self.jid = jid
        self.device_id = device_id
        self.storage = MemoryStorage()
        self.parties = {}

    async def set_up(self, version: str, signed_pre_key_id: int, pre_key_id: int) -> Party:
        party = Party(self.jid.split("@")[0], version, self.jid, self.device_id)
        party.storage = self.storage
        _, backend_class = VERSIONS[version]
        party.backend = backend_class(self.storage)
        await party.set_up(signed_pre_key_id=signed_pre_key_id, pre_key_id=pre_key_id)
        self.parties[version] = party
        return party


def envelope(body: str, to: str, sender: str, stamp: str) -> bytes:
    """An XEP-0420 envelope as an OMEMO 2 client writes it around a message."""
    padding = base64.b64encode(omemo_rng.randbytes(omemo_rng.randrange(8, 120))).decode("ASCII")
    return (
        "<envelope xmlns='urn:xmpp:sce:1'><content>"
        f"<body xmlns='jabber:client'>{body}</body>"
        "</content>"
        f"<rpad>{padding.rstrip('=')}</rpad>"
        f"<time stamp='{stamp}'/><to jid='{to}'/><from jid='{sender}'/>"
        "</envelope>"
    ).encode("utf-8")


async def stanza_messages(version: str, alice: Party, bob: Party) -> list[dict]:
    """Alice encrypts for Bob: a key exchange, its repeat with a second message (Alice has not
    heard back), and an empty message, each serialized by the backend's etree module and wrapped
    in a <message/> stanza."""
    module, _ = VERSIONS[version]
    etree = ETREE[version]
    messages = []
    session = None
    for index, body in enumerate(["Hello from python-omemo", "Grüße, second message", None]):
        if body is None:
            content, key_material = await alice.backend.encrypt_empty()
            plaintext = None
        else:
            plaintext = (
                body.encode("utf-8") if version == "v03"
                else envelope(body, bob.jid, alice.jid, f"2026-11-19T10:0{index}:00Z")
            )
            content, key_material = await alice.backend.encrypt_plaintext(plaintext)
        if session is None:
            session, encrypted = await alice.backend.build_session_active(
                bob.jid, bob.device_id, bob.bundle, key_material
            )
        else:
            encrypted = await alice.backend.encrypt_key_material(session, key_material)
        assert session.initiation is Initiation.ACTIVE and not session.confirmed
        message = omemo.Message(
            module.NAMESPACE, alice.jid, alice.device_id, content,
            frozenset({(encrypted, session.key_exchange)}),
        )
        encrypted_xml = xml_text(etree.serialize_message(message), module.NAMESPACE)
        fallback = (
            "<body>I sent you an OMEMO encrypted message but your client doesn&apos;t seem to "
            "support that.</body>" if version == "v03" and body is not None else ""
        )
        stanza = (
            f"<message xmlns='jabber:client' from='{alice.jid}/python' to='{bob.jid}' "
            f"type='chat' id='py-{version}-{index}'>{fallback}{encrypted_xml}"
            "<store xmlns='urn:xmpp:hints'/></message>"
        )
        messages.append({"stanza": stanza, "body": body, "envelope": None if plaintext is None or version == "v03" else plaintext.decode("utf-8")})
    return messages


async def stanza_version(version: str, alice: StanzaParty, bob: StanzaParty) -> dict:
    module, _ = VERSIONS[version]
    etree = ETREE[version]
    alice_party = await alice.set_up(version, signed_pre_key_id=7, pre_key_id=77)
    bob_party = await bob.set_up(version, signed_pre_key_id=9, pre_key_id=901)
    seed = state_identity_seed(alice_party.state)
    label = "python-omemo"
    labels = {
        alice.device_id: omemo.SignedLabel(label, xeddsa.ed25519_seed_sign(seed, label.encode("utf-8")))
        if version == "v2" else None,
        424242: None,
    }
    return {
        "alice": {
            "jid": alice.jid,
            "deviceID": alice.device_id,
            "identityKey": base64.b64decode(
                etree.serialize_bundle(alice_party.bundle).find(
                    f"{{{module.NAMESPACE}}}{'identityKey' if version == 'v03' else 'ik'}"
                ).text
            ).hex(),
            "deviceList": xml_text(etree.serialize_device_list(labels), module.NAMESPACE),
            "deviceListIDs": list(labels),
            "bundle": xml_text(etree.serialize_bundle(alice_party.bundle), module.NAMESPACE),
        },
        "bob": {
            "jid": bob.jid,
            **bob_party.keys(),
            "bundle": xml_text(etree.serialize_bundle(bob_party.bundle), module.NAMESPACE),
        },
        "messages": await stanza_messages(version, alice_party, bob_party),
    }


async def stanza_vectors() -> dict:
    """Its own seed, so the other files stay as they are."""
    global omemo_rng
    omemo_rng = random.Random(20261123)
    make_omemo_libraries_deterministic()
    alice = StanzaParty("alice@example.org", 31_415)
    bob = StanzaParty("bob@example.org", 27_182)
    vectors = {
        "generator": "scripts/omemo-vectors/generate.py",
        "versions": {"omemo": omemo.__version__, "oldmemo": oldmemo.__version__,
                     "twomemo": twomemo.__version__, "xeddsa": xeddsa.__version__},
        "curve25519Forms": [
            {"ed25519": key, "curve25519": xeddsa.ed25519_pub_to_curve25519_pub(bytes.fromhex(key)).hex()}
            for key in RFC8032_PUBLIC_KEYS
        ],
    }
    for version in VERSIONS:
        vectors[version] = await stanza_version(version, alice, bob)
    # One identity for both versions: the legacy key is the Curve25519 form of the OMEMO 2 key.
    assert bytes.fromhex(vectors["v03"]["alice"]["identityKey"])[1:] == xeddsa.ed25519_pub_to_curve25519_pub(
        bytes.fromhex(vectors["v2"]["alice"]["identityKey"])
    )
    return vectors


def write(path: pathlib.Path, vectors: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(vectors, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {path.relative_to(ROOT)}", file=sys.stderr)


def main() -> None:
    write(OUTPUT, {
        "generator": "scripts/omemo-vectors/generate.py",
        "xeddsaVersion": xeddsa.__version__,
        "signatures": xeddsa_signatures(36),
        "libsignalSignatures": libsignal_signatures(18),
        "seedConversions": seed_conversions(16),
        "montgomeryToEdwards": montgomery_to_edwards(16),
        "scalarReductions": scalar_reductions(24),
        "scalarMultiplyAdds": scalar_multiply_adds(24),
    })
    write(OMEMO_OUTPUT, asyncio.run(omemo_vectors()))
    write(STANZA_OUTPUT, asyncio.run(stanza_vectors()))


if __name__ == "__main__":
    main()
