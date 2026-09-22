-- Adds three related features on top of the existing trip flow:
--   1) Optional scheduling (up to 2 days ahead) instead of "now" only.
--   2) One-time patient safety brief (age + condition) collected on the
--      requester's profile, surfaced to the volunteer with every trip.
--   3) A hard 20km cap between the volunteer and the trip origin: a
--      volunteer outside that radius never sees the trip, and accepting it
--      is rejected server-side even if the trip id is somehow known.
-- Apply locally first and review against the linked project before any remote deployment.

alter table public.profiles
  add column patient_age smallint check (patient_age is null or patient_age between 0 and 120),
  add column patient_condition text check (patient_condition is null or char_length(patient_condition) between 2 and 300);

alter table public.trips
  add column scheduled_at timestamptz,
  add constraint trip_scheduled_within_window check (
    scheduled_at is null or (scheduled_at >= created_at and scheduled_at <= created_at + interval '2 days')
  );

-- Expose scheduled_at through the same restricted column grant the other
-- public trip columns already use (lat/lng stay private in trip_locations).
grant select (scheduled_at) on public.trips to authenticated;

create or replace function public.haversine_km(
  lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision
)
returns double precision
language sql
immutable
as $$
  select 6371 * acos(
    least(1, greatest(-1,
      cos(radians(lat1)) * cos(radians(lat2)) * cos(radians(lng2) - radians(lng1))
      + sin(radians(lat1)) * sin(radians(lat2))
    ))
  );
$$;

-- Appends optional parameters to the existing signatures via CREATE OR
-- REPLACE (Postgres allows this as long as new params have defaults), so
-- the existing execute grants on these functions keep applying unchanged.

create or replace function public.create_trip_from_proxy(
  p_requester_id uuid,
  p_origin_area_label text,
  p_origin_address text,
  p_origin_lat double precision,
  p_origin_lng double precision,
  p_destination_area_label text,
  p_destination_address text,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_requester_relation public.requester_relation,
  p_client_ip inet,
  p_scheduled_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_completed_count integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;
  if p_requester_id is null or p_client_ip is null then
    raise exception 'requester and trusted client IP are required';
  end if;
  if not exists (select 1 from profiles where id = p_requester_id and role = 'requester' and is_active) then
    raise exception 'requester role required';
  end if;
  if p_scheduled_at is not null and (p_scheduled_at < now() or p_scheduled_at > now() + interval '2 days') then
    raise exception 'scheduled time must be within the next two days';
  end if;

  select count(*) into v_completed_count
  from trips
  where requester_id = p_requester_id and status = 'completed';

  if v_completed_count < 3 and exists (
    select 1 from trips where requester_id = p_requester_id and status in ('pending', 'accepted')
  ) then
    raise exception 'one open trip is allowed until three trips are completed';
  end if;

  insert into trips (
    requester_id, origin_area_label, destination_area_label, requester_relation,
    good_faith_ack, ack_at, ack_ip, scheduled_at
  ) values (
    p_requester_id, p_origin_area_label, p_destination_area_label, p_requester_relation,
    true, now(), p_client_ip, p_scheduled_at
  ) returning id into v_trip_id;

  insert into trip_locations (
    trip_id, origin_address, origin_lat, origin_lng,
    destination_address, destination_lat, destination_lng
  ) values (
    v_trip_id, p_origin_address, p_origin_lat, p_origin_lng,
    p_destination_address, p_destination_lat, p_destination_lng
  );

  return v_trip_id;
end;
$$;

-- Volunteer-facing list: pending trips within 20km of the volunteer's
-- current position, enriched with distance, schedule and the patient
-- safety brief. Replaces direct SELECTs on public.trips for volunteers,
-- since lat/lng and patient data are not exposed via table grants.
create or replace function public.get_pending_trips_nearby(
  p_volunteer_lat double precision,
  p_volunteer_lng double precision
)
returns table (
  id uuid,
  origin_area_label text,
  destination_area_label text,
  status public.trip_status,
  requester_relation public.requester_relation,
  created_at timestamptz,
  scheduled_at timestamptz,
  distance_km double precision,
  patient_age smallint,
  patient_condition text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_volunteer_lat is null or p_volunteer_lng is null then
    raise exception 'volunteer location is required';
  end if;
  if not exists (select 1 from profiles where id = auth.uid() and role = 'volunteer' and is_active) then
    raise exception 'volunteer role required';
  end if;

  return query
  select
    t.id, t.origin_area_label, t.destination_area_label, t.status, t.requester_relation,
    t.created_at, t.scheduled_at,
    round(public.haversine_km(p_volunteer_lat, p_volunteer_lng, l.origin_lat, l.origin_lng)::numeric, 1)::double precision as distance_km,
    pr.patient_age, pr.patient_condition
  from trips t
  join trip_locations l on l.trip_id = t.id
  join profiles pr on pr.id = t.requester_id
  where t.status = 'pending'
    and public.haversine_km(p_volunteer_lat, p_volunteer_lng, l.origin_lat, l.origin_lng) <= 20
  order by t.created_at desc;
end;
$$;

-- Re-checks the 20km cap server-side so accepting a trip a volunteer was
-- never shown (e.g. a stale/guessed id) is rejected regardless of the UI.
-- Explicit drop first: guarantees only the distance-checked 3-arg version
-- of accept_trip can ever exist, instead of relying on how Postgres
-- resolves CREATE OR REPLACE against a changed parameter list.
drop function if exists public.accept_trip(uuid);

create or replace function public.accept_trip(
  p_trip_id uuid,
  p_volunteer_lat double precision default null,
  p_volunteer_lng double precision default null
)
returns table (
  trip_id uuid, requester_first_name text, requester_phone text, requester_relation public.requester_relation,
  origin_address text, origin_lat double precision, origin_lng double precision,
  destination_address text, destination_lat double precision, destination_lng double precision
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip trips%rowtype;
  v_volunteer_id uuid := auth.uid();
  v_distance double precision;
begin
  if p_volunteer_lat is null or p_volunteer_lng is null then
    raise exception 'volunteer location is required';
  end if;
  if not exists (select 1 from profiles where id = v_volunteer_id and role = 'volunteer' and is_active) then
    raise exception 'volunteer role required';
  end if;

  select * into v_trip from trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'pending' then
    raise exception 'trip is no longer available';
  end if;

  select public.haversine_km(p_volunteer_lat, p_volunteer_lng, l.origin_lat, l.origin_lng)
  into v_distance
  from trip_locations l where l.trip_id = p_trip_id;

  if v_distance is null or v_distance > 20 then
    raise exception 'trip is outside the maximum distance';
  end if;

  update trips set status = 'accepted', volunteer_id = v_volunteer_id, accepted_at = now() where id = p_trip_id;

  return query
  select t.id, p.first_name, p.phone_number, t.requester_relation,
         l.origin_address, l.origin_lat, l.origin_lng, l.destination_address, l.destination_lat, l.destination_lng
  from trips t
  join profiles p on p.id = t.requester_id
  join trip_locations l on l.trip_id = t.id
  where t.id = p_trip_id;
end;
$$;

revoke all on function public.get_pending_trips_nearby(double precision, double precision), public.haversine_km(double precision, double precision, double precision, double precision) from public, anon;
grant execute on function public.get_pending_trips_nearby(double precision, double precision), public.haversine_km(double precision, double precision, double precision, double precision) to authenticated;

-- accept_trip was dropped and recreated above, so its grants need to be
-- re-applied explicitly (DROP removes any existing grants on the OID).
revoke all on function public.accept_trip(uuid, double precision, double precision) from public, anon;
grant execute on function public.accept_trip(uuid, double precision, double precision) to authenticated;

-- Explicit re-grant for create_trip_from_proxy's new 12-arg signature too:
-- PostgreSQL grants EXECUTE to PUBLIC by default on any newly created
-- function, so this is stated explicitly rather than relying on whether
-- CREATE OR REPLACE preserved the original 11-arg grants. The function
-- also re-checks auth.role() = 'service_role' internally regardless.
revoke all on function public.create_trip_from_proxy(uuid, text, text, double precision, double precision, text, text, double precision, double precision, public.requester_relation, inet, timestamptz) from public, anon, authenticated;
grant execute on function public.create_trip_from_proxy(uuid, text, text, double precision, double precision, text, text, double precision, double precision, public.requester_relation, inet, timestamptz) to service_role;
