# Yardlet Harness Protocol v1 SDK

This directory is the language-neutral distribution surface for building an independently installed
Yardlet harness adapter. An adapter is any executable that owns stdin/stdout, emits one `hello`
JSONL frame, accepts Yardlet's selected `ready` version, and then exchanges versioned request,
response, and event frames.

Included artifacts:

- `yardlet-harness-protocol-v1.schema.json`: wire-envelope and portable lifecycle schema.
- `bin/yardlet-harness-conformance`: dependency-free baseline conformance CLI.
- [`../../Examples/YardletSampleAdapter`](../../Examples/YardletSampleAdapter): independently
  runnable Python sample with create/send/stream/interrupt/resume/close and a namespaced extension.
- [`../../docs/YARDLET_HARNESS_PROTOCOL_V1.md`](../../docs/YARDLET_HARNESS_PROTOCOL_V1.md): normative
  version, capability, lifecycle, extension, security, and failure rules.

Run the external sample without installing Yardlet or linking its Swift executable:

```sh
python3 SDK/YardletHarnessProtocolV1/bin/yardlet-harness-conformance \
  Examples/YardletSampleAdapter/yardlet_sample_adapter.py
```

The CLI exits nonzero on malformed framing, negotiation, response correlation, session identity,
event sequence, missing streaming/interrupt/resume behavior, or extension round-trip failure. It
always closes the adapter's stdin and terminates it if it does not exit within the bounded deadline.

Provider-specific features belong in explicit namespaces owned by the adapter, for example
`acme.provider.*`. They must never silently widen a standard capability or permission.
