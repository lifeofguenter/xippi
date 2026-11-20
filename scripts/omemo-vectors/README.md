# OMEMO test vectors

Test tooling only, never shipped. Fixed seeds make every run write the same files.

- `Packages/CurveMath/Tests/CurveMathTests/Resources/xeddsa-vectors.json`: XEdDSA and key
  conversion vectors from python-xeddsa (libxeddsa and libsodium).
- `Packages/OMEMO/Tests/OMEMOTests/Resources/omemo-vectors.json`: X3DH, Double Ratchet KDF,
  payload and protobuf vectors, and whole sessions between two parties, for legacy OMEMO
  (python-oldmemo) and OMEMO 2 (python-twomemo), on python-x3dh and python-doubleratchet.
- `Packages/OMEMO/Tests/OMEMOTests/Resources/omemo-stanzas.json`: what python-omemo puts on the
  wire, from python-oldmemo's and python-twomemo's etree modules (which need xmlschema): device
  lists, bundles, and `<message/>` stanzas with key exchanges and an empty message, with the
  receiving device's private keys; plus Curve25519 forms of the RFC 8032 public keys.

Python 3.10 to 3.14: XEdDSA publishes no wheels for newer versions, and building it from source
needs libxeddsa installed.

```sh
python3.14 -m venv "${TMPDIR:-/tmp}/omemo-vectors"
"${TMPDIR:-/tmp}/omemo-vectors/bin/pip" install -r scripts/omemo-vectors/requirements.txt
"${TMPDIR:-/tmp}/omemo-vectors/bin/python" -I scripts/omemo-vectors/generate.py
```
