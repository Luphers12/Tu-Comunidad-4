# TU COMUNIDAD — PRIVATE DESTINATION NETWORK → RSG ADAPTER PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

PRIVATE_DESTINATION_NETWORK_ADAPTER: PASS
NETWORK_TO_RSG_RUNTIME: PASS
END_TO_END_PROMISE_WITH_LAST_MILE: PASS
RUNTIME_STATE_REGRESSION_GUARD: PASS

Migration count moved from 173 to 182.

## Migrations

- 20260921065411_private_destination_network_adapter_foundation_v1.sql — SHA-256 636f56035181803ede94e945e9dd5b9b7db4257dab28aad19cc5e14830fc5a2b
- 20260921065439_private_destination_routing_adapter_v1.sql — SHA-256 4859e701a8dbbbad4526cfe90266dfbadbf5dcd4832477318ab1ca0137cc22a5
- 20260921065518_private_destination_promise_execution_v1.sql — SHA-256 652c85b9bd0b70faccf85f2143f6037f24ca14b3acabe6b2b8119a97b3d67eca
- 20260921065619_last_mile_ready_runtime_v1.sql — SHA-256 7012f0ce125a3740405c7a03a006020dc0b7578c3029e962437bc0c8ae81d097
- 20260921065646_last_mile_demand_state_sync_v1.sql — SHA-256 c1e294ed44cf382c494ee76a441902e564ff5828f6d7ef02f837257029afe9c6
- 20260921070034_private_destination_arrival_state_fix_v1.sql — SHA-256 fd9653e68995332dc1745180b5e54e88cd19946024588037f77c34537c15f285
- 20260921114959_runtime_state_regression_guard_v1.sql — SHA-256 2d73ea1fb87ace1f195daf345ea75b0dd9b5eb720b5016949e65519502a68e08
- 20260921115331_promise_evaluation_sequence_v1.sql — SHA-256 09d4752a22e4a92db10be71370a67e4dd1e6439887a2e4076348a2dca9a208f7
- 20260921115343_last_mile_accept_promise_reference_v1.sql — SHA-256 d9991df88d8af8d3781a2e4883bbeb0eaa129fec677ffda046225c96bb926f92

## Canonical private-destination adapter

A logistics demand may keep PRIVATE_LOCATION as its immutable final destination while using a separate network egress NODE for intercommunity execution.

Selection rule:
- final destination must be PRIVATE_LOCATION
- destination community must have active home-delivery coverage
- egress NODE must be structurally reachable
- egress NODE must be active/network-enabled
- egress NODE must have owner_profile_id
- egress NODE must declare RECEIVE_CARGO
- egress NODE must declare HANDOFF_CARGO
- egress NODE must declare LAST_MILE_ORIGIN

The adapter does not replace the customer's private destination.

## Promise semantics

New state:
NETWORK_COMMITTED_LAST_MILE_PENDING

Meaning:
- network path exists and its real-trip capacity is committed
- private final destination still requires an RSG assignment
- therefore end_to_end_committed=false

Once RSG accepts and its capacity reservation is confirmed:
- last_mile_committed=true
- Promise becomes END_TO_END_COMMITTED

Promise evaluations now have evaluation_seq identity ordering.
This avoids transaction-stable timestamp ties when several evaluations occur inside one transaction.

RSG ACCEPT now returns promise_evaluation_ids for exact evaluation references.

## Runtime bridge

Network plan complete for private-final LGD:
-> demand AWAITING_LAST_MILE
-> adapter AWAITING_LAST_MILE
-> outbox LAST_MILE_READY
-> worker creates last-mile task
-> worker refreshes RSG candidates

RSG ACCEPT:
-> confirmed RSG capacity reservation
-> assignment ACTIVE
-> demand LAST_MILE_ASSIGNED
-> adapter LAST_MILE_ASSIGNED
-> Promise END_TO_END_COMMITTED

RSG pickup:
-> custody NODE -> RSG
-> demand IN_TRANSIT

RSG delivery with package-specific evidence:
-> custody RSG -> CLI
-> last-mile task DELIVERED
-> demand DELIVERED
-> adapter COMPLETED

## Stale runtime regression diagnosis

During testing, an old MATCH_ACCEPTED outbox event from the CON stage was processed after the network movement completed.

Previous behavior:
AWAITING_LAST_MILE -> stale tc_commit_routing_attempt() -> ASSIGNED

This prevented RSG acceptance from applying LAST_MILE_ASSIGNED.

Forward fix:
- tc_commit_routing_attempt is lifecycle-monotonic
- stale/replayed network acceptance cannot regress IN_TRANSIT, AWAITING_LAST_MILE, LAST_MILE_ASSIGNED, DELIVERED or CANCELLED
- runtime MATCH_ACCEPTED returns IGNORED_STALE / DEMAND_ALREADY_ADVANCED for advanced demands

## Arrival-state correction

Canonical network ARRIVAL previously marked a demand DELIVERED when the network execution plan finished.
For private-final demands this was incorrect.

Now:
- network execution plan may complete
- private-final LGD becomes AWAITING_LAST_MILE
- only completed RSG physical delivery may mark the LGD DELIVERED

## Verification — full rollback scenario

End-to-end test:
HOME private destination
-> LGD PRIVATE_LOCATION
-> reachable LAST_MILE_ORIGIN NODE selected
-> real CON trip A -> B
-> network capacity accepted/committed
-> Promise NETWORK_COMMITTED_LAST_MILE_PENDING
-> canonical load/departure/arrival custody
-> package custody at egress NODE
-> LGD AWAITING_LAST_MILE
-> stale pending runtime events deliberately drained
-> LGD remained AWAITING_LAST_MILE
-> LAST_MILE_READY produced RSG task automatically
-> RSG candidate OFFERED
-> RSG ACCEPT
-> exact returned Promise evaluation END_TO_END_COMMITTED
-> NODE -> RSG custody
-> LGD IN_TRANSIT
-> GPS arrival candidate did not deliver
-> package-specific delivery evidence
-> RSG -> CLI custody
-> LGD DELIVERED
-> adapter COMPLETED

Exactly four custody transfers were observed:
1. origin NODE/store -> CON
2. CON -> last-mile egress NODE
3. last-mile egress NODE -> RSG
4. RSG -> CLI

All test data rolled back.

## LIVE post-test state

Private adapter test rows: 0
Last-mile demand-link rows from tests: 0
Rollback evidence rows: 0
Runtime outbox nonterminal rows: 0
Cron active: yes
Cron failures: 0

Important operational note:
STAGING currently has zero real enabled LAST_MILE_ORIGIN nodes.
The adapter is therefore dormant for real data until a node is explicitly configured with that capability.
No node was invented or auto-enabled by this block.

## Security

logistics_private_destination_adapters and logistics_last_mile_task_demands are RLS-enabled fail-closed internal tables.
anon/authenticated direct SELECT is denied.
service_role retains internal access.

No Production, merge, deploy or FlutterFlow write was performed.