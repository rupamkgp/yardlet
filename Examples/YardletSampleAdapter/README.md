# Yardlet sample echo adapter

`yardlet_sample_adapter.py` is a dependency-free external Yardlet Harness Protocol v1 adapter. It
is intentionally not linked to the Yardlet application. Copy it anywhere with Python 3 available,
make it executable, and launch it as a JSONL subprocess.

It demonstrates explicit version negotiation, manifest capabilities, runtime discovery,
create/send/stream/interrupt/resume/close, a declared `sample.fixture` extension, structured adapter
errors, and deterministic per-session event sequencing. Setting
`YARDLET_SAMPLE_MALFORMED=sequence-gap` makes its first event invalid so a host or conformance test
can prove fail-closed behavior and process cleanup.
