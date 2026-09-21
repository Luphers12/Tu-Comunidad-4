# TU COMUNIDAD — LOGISTICS EXECUTION FOUNDATION PASS

**Local date:** 2026-09-20  
**Repository:** `Luphers12/Tu-Comunidad-4`  
**Branch:** `tc/full-build-20260918`  
**STAGING:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`

## Gate

```text
FORENSIC_SOT_104:               PASS
VERIFIED_REPRODUCIBLE_BASELINE: PASS
NETWORK_FOUNDATION:             PASS
LOGISTICS_EXECUTION_FOUNDATION: PASS
```

## Migrations

- `20260921023424_canonical_real_trip_foundation_v1.sql` — SHA-256 `e9a3db3746b6b32488e1da4d850b404ce809e038f381c1981a3c5052c4d61070`
- `20260921023426_trip_segment_capacity_foundation_v1.sql` — SHA-256 `ea8c33909af6e429ecc6a5b00fcda9140ae593e3896106e6803be50ea943bbe3`
- `20260921023428_movement_trip_bridge_foundation_v1.sql` — SHA-256 `e126b77ce018a86378bed19ca10a54469d3dde48b6ba45295b8c592bb7b20c60`
- `20260921023441_manifest_reconciliation_foundation_v1.sql` — SHA-256 `6f722fcc7eb5e1ab98571c249020222d9200f085d4a642f11a6d5b7dec351eec`

Migration count moved from 109 to **113**.

## HECHO VERIFICADO — TRIP

Created canonical real-trip objects:

- `logistics_trips`
- `logistics_trip_stops`

A TRIP:

- must use an active `CON` profile;
- must use an active vehicle;
- requires an active driver↔vehicle authorization valid at planned departure;
- begins and ends at active `operational_locations` promoted with `network_enabled=true`;
- is either `DRIVER_DECLARED` or `LEGACY_ADAPTER`;
- intentionally has no `SYSTEM_GENERATED` source type;
- keeps `route_opportunities/route_assignments` only as nullable legacy adapters.

The route plan is editable only in `DRAFT`. Publication requires a START node, one END node matching the declared destination, at least two stops, and declared trip capacity.

## HECHO VERIFICADO — CAPACITY

Created:

- `logistics_trip_capacity`
- `logistics_capacity_reservations`

Declared free capacity cannot exceed the selected vehicle's physical limits/capabilities and locks when the trip is published.

Capacity reservations are segment-based:

```text
[board_stop_sequence, alight_stop_sequence)
```

The reservation trigger locks the trip-capacity row and evaluates every covered segment before allowing HELD/CONFIRMED capacity. This prevents overbooking without conflating capacity with inventory or custody.

Reservation identity/amount/segment fields become immutable after insert. State transitions are constrained and versioned.

## HECHO VERIFICADO — MOV bridge

The existing `public.movements` table was reused and extended. No second MOV engine was created.

Legacy fields remain:

- `route_id`
- `route_assignment_id`

Canonical bridge fields added:

- `logistics_trip_id`
- `origin_operational_location_id`
- `destination_operational_location_id`
- `logistics_edge_id`
- `board_stop_sequence`
- `alight_stop_sequence`

`NODE_TO_NODE` was added to the existing movement-type contract.

Created `logistics_movement_demands` for many-to-many MOV↔LGD association tied to a confirmed/consumed capacity reservation.

Movement validation checks:

- trip is not DRAFT/CANCELLED;
- stop sequences map to the stated origin/destination nodes;
- EDGE direction matches origin→destination;
- reservation trip/demand/segment covers the MOV.

This bridge does **not** transfer custody.

## HECHO VERIFICADO — MANIFEST / RECONCILIATION

Created immutable manifest snapshots:

- `logistics_manifests`
- `logistics_manifest_items`

Manifest versions are monotonic per TRIP. A new version must supersede the immediately previous snapshot.

Manifest items require:

- PKG belongs to LGD;
- confirmed capacity reservation matches TRIP/LGD/segment;
- if a MOV is specified, the PKG is in `movement_packages` and MOV↔LGD/reservation linkage exists.

Created append-only:

- `logistics_reconciliation_events`

Reconciliation records expected-vs-observed differences only. It does **not** mutate `custody_events` or `movement_custody_handshakes`.

## Runtime test — transaction rolled back

PASS:

- authorized real TRIP creation;
- publication gate;
- stop-plan lock after publication;
- trip-capacity lock after publication;
- segment reservation;
- attempted overbooking rejected with `TC_TRIP_CAPACITY_OVERBOOKED`;
- HELD→CONFIRMED reservation transition;
- NODE_TO_NODE MOV bridge;
- MOV↔LGD/reservation bridge;
- manifest snapshot + item;
- reconciliation event;
- manifest append-only guard;
- custody untouched;
- custody handshake untouched.

Post-rollback:

```text
orders:                 2
packages:               4
movements:              0
custody_events:         0
movement_handshakes:    0

trips:                  0
trip_stops:             0
trip_capacity:          0
reservations:           0
movement_demands:       0
manifests:              0
manifest_items:         0
reconciliation_events:  0
```

## Security

The 8 new tables are fail-closed:

- RLS enabled;
- 0 user-facing policies;
- anon/authenticated direct reads denied;
- service_role only according to table semantics.

No new SECURITY DEFINER function was introduced by this block.

Security Advisor after the block:

```text
rls_enabled_no_policy:                       137 INFO
anon_security_definer_function_executable:    10 WARN
authenticated_security_definer_function_executable: 86 WARN
auth_leaked_password_protection:               1 WARN
```

The RLS count increased from 129 to 137 exactly because of the 8 new fail-closed tables.

## Deferred

Still deferred to routing/execution blocks:

- candidate generation / compatibility matcher;
- HOP RESOLVER;
- structural reachability vs no-trip-now distinction;
- anti-oscillation / LOOP_DETECTED;
- Promise Engine;
- scan/sort runtime;
- automatic reroute/recovery;
- RSG redesign;
- user-facing CON publication/accept/reject RPCs.

No Production, FlutterFlow, merge or deploy action was performed.
