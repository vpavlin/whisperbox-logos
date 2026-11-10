# Vendored: Loam's delivery wire

From github.com/vpavlin/loam-basecamp, commit 87b2acd6a4d604484e79eabb97c3cb0f0e29bd80
(loam_core 0.7.4, branch feat/delivery-transport-header), `core/include/loam/`:

- delivery_transport.hpp (LOAM_DELIVERY_WIRE_VERSION 1)
- segment_compat.hpp

Used by whisperbox_core's direct transport (ADR 0021): delivery_module without loam_core, on the same
wire as loam_core and the Loam phones. Don't edit here: change it upstream (with the shared vectors in
core/test/delivery_vectors.json), then copy both files again and update this commit.
