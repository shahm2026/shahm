-- Adds a real privilege hierarchy on top of the existing admin roles.
-- super_admin becomes the only role that can:
--   * delete a user's account entirely (profile + auth user + dependent rows)
--   * delete/remove another admin's privileges
--   * pull a user's full record (profile + trips + verification docs + reports) in one call
-- No role — including super_admin itself — can ever delete a super_admin account.
-- Apply locally first and review against the linked project before any remote deployment.

create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role = 'super_admin'
      and is_active
  );
$$;

-- Returns the full picture of a user for the super_admin panel: profile,
-- their trips (as requester and as volunteer), verification documents and
-- any reports they filed or were reported in. One call instead of five.
create or replace function public.get_user_full_details(p_target_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_super_admin() then
    raise exception 'super admin role required';
  end if;

  select jsonb_build_object(
    'profile', to_jsonb(p),
    'trips_as_requester', (
      select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
      from public.trips t where t.requester_id = p_target_profile_id
    ),
    'trips_as_volunteer', (
      select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
      from public.trips t where t.volunteer_id = p_target_profile_id
    ),
    'verification_documents', (
      select coalesce(jsonb_agg(to_jsonb(v) order by v.submitted_at desc), '[]'::jsonb)
      from public.verification_documents v where v.profile_id = p_target_profile_id
    ),
    'reports_filed', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
      from public.reports r where r.reporter_id = p_target_profile_id
    ),
    'reports_against', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
      from public.reports r where r.reported_profile_id = p_target_profile_id
    )
  ) into v_result
  from public.profiles p
  where p.id = p_target_profile_id;

  if v_result is null then
    raise exception 'user not found';
  end if;

  return v_result;
end;
$$;

-- Permanently deletes a user (any role except super_admin). Cleans up every
-- dependent row first so the delete never fails on a foreign key, then
-- removes the auth.users row, which cascades to profiles/push_subscriptions.
create or replace function public.delete_user(p_target_profile_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_role public.user_role;
begin
  if not public.is_super_admin() then
    raise exception 'super admin role required';
  end if;

  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'a reason of at least 5 characters is required';
  end if;

  select role into v_target_role from public.profiles where id = p_target_profile_id;

  if v_target_role is null then
    raise exception 'user not found';
  end if;

  if v_target_role = 'super_admin' then
    raise exception 'super admin accounts cannot be deleted';
  end if;

  -- Record the action before the profile disappears. Keep the deleted
  -- user's id/role in metadata rather than as an FK, since the row is
  -- about to be removed.
  insert into public.audit_logs (actor_id, action, reason, metadata)
  values (
    auth.uid(),
    'delete_user',
    trim(p_reason),
    jsonb_build_object('deleted_profile_id', p_target_profile_id, 'deleted_role', v_target_role)
  );

  -- Detach dangling references so the delete never fails on a foreign key.
  update public.audit_logs set actor_id = null where actor_id = p_target_profile_id;
  update public.audit_logs set target_profile_id = null where target_profile_id = p_target_profile_id;
  update public.verification_documents set reviewed_by = null where reviewed_by = p_target_profile_id;
  update public.reports set reported_profile_id = null where reported_profile_id = p_target_profile_id;
  delete from public.reports where reporter_id = p_target_profile_id;
  update public.trips set volunteer_id = null where volunteer_id = p_target_profile_id;
  delete from public.trips where requester_id = p_target_profile_id;

  -- Cascades to public.profiles, public.verification_documents and
  -- public.push_subscriptions via their existing "on delete cascade" FKs.
  delete from auth.users where id = p_target_profile_id;
end;
$$;

revoke all on function public.get_user_full_details(uuid), public.delete_user(uuid, text) from public, anon;
grant execute on function public.get_user_full_details(uuid), public.delete_user(uuid, text) to authenticated;
