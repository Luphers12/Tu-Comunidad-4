
create unique index logistics_matches_one_accepted_per_hop_uidx
  on public.logistics_matches(routing_hop_id)
  where state='ACCEPTED';

comment on index public.logistics_matches_one_accepted_per_hop_uidx is
'At most one ACCEPTED human candidate may own a routing hop at a time. Other OFFERED candidates remain available as recovery alternatives until explicitly resolved.';
