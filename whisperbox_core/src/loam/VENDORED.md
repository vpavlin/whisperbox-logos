# Vendored: Loam's delivery wire

From github.com/vpavlin/loam-basecamp, commit efaeaec (branch feat/delivery-transport-header),
`core/include/loam/`. Previously 87b2acd (loam_core 0.7.4); efaeaec changes only delivery_transport.hpp:
the peerless watchdog also re-dials a node that never had peers (2x peerlessSeconds; a node started
offline never re-dials on delivery < v0.40, and an Edge node has no connectivity loop), and waits 3x on
an ADOPTED node so two modules on one node don't take turns restarting it.

- delivery_transport.hpp (LOAM_DELIVERY_WIRE_VERSION 1)
- segment_compat.hpp

Used by whisperbox_core's direct transport (ADR 0021): delivery_module without loam_core, on the same
wire as loam_core and the Loam phones. Don't edit here: change it upstream (with the shared vectors in
core/test/delivery_vectors.json), then copy both files again and update this commit.
