-- Storage privado y RPCs base de acceso.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'contracts',
    'contracts',
    false,
    20971520,
    array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
  ),
  (
    'receipts',
    'receipts',
    false,
    20971520,
    array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
  ),
  (
    'maintenance',
    'maintenance',
    false,
    20971520,
    array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
  ),
  (
    'settlements',
    'settlements',
    false,
    20971520,
    array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
  )
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function storage_object_organization_id(object_name text)
returns uuid
language plpgsql
stable
as $$
declare
  parts text[];
begin
  parts := storage.foldername(object_name);

  if array_length(parts, 1) >= 2
    and parts[1] = 'org'
    and parts[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return parts[2]::uuid;
  end if;

  return null;
end;
$$;

create policy storage_objects_select_org_member
  on storage.objects
  for select
  using (
    bucket_id in ('contracts', 'receipts', 'maintenance', 'settlements')
    and public.is_org_member(public.storage_object_organization_id(name))
  );

create policy storage_objects_insert_org_editor
  on storage.objects
  for insert
  with check (
    bucket_id in ('contracts', 'receipts', 'maintenance', 'settlements')
    and public.has_org_role(
      public.storage_object_organization_id(name),
      array['owner', 'admin', 'editor']::public.app_role[]
    )
  );

create policy storage_objects_update_org_editor
  on storage.objects
  for update
  using (
    bucket_id in ('contracts', 'receipts', 'maintenance', 'settlements')
    and public.has_org_role(
      public.storage_object_organization_id(name),
      array['owner', 'admin', 'editor']::public.app_role[]
    )
  )
  with check (
    bucket_id in ('contracts', 'receipts', 'maintenance', 'settlements')
    and public.has_org_role(
      public.storage_object_organization_id(name),
      array['owner', 'admin', 'editor']::public.app_role[]
    )
  );

create or replace function get_my_memberships()
returns table (
  organization_id uuid,
  organization_name text,
  role app_role,
  member_status member_status
)
language sql
stable
security definer
set search_path = public
as $$
  select
    o.id as organization_id,
    o.name as organization_name,
    om.role,
    om.status as member_status
  from organization_members om
  join organizations o on o.id = om.organization_id
  where om.user_id = auth.uid()
  order by o.name;
$$;

create or replace function enable_member(
  target_organization_id uuid,
  target_user_id uuid,
  target_role app_role
)
returns organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_member organization_members;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para habilitar usuarios.';
  end if;

  if target_role = 'owner'
    and not has_org_role(target_organization_id, array['owner']::app_role[])
  then
    raise exception 'Solo un owner puede asignar el rol owner.';
  end if;

  update organization_members
  set
    role = target_role,
    status = 'active',
    enabled_at = now(),
    enabled_by = auth.uid()
  where organization_id = target_organization_id
    and user_id = target_user_id
  returning * into updated_member;

  if not found then
    raise exception 'No existe una solicitud de acceso para ese usuario.';
  end if;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    'member_enabled',
    'organization_member',
    updated_member.id,
    to_jsonb(updated_member)
  );

  return updated_member;
end;
$$;

create or replace function disable_member(
  target_organization_id uuid,
  target_user_id uuid
)
returns organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_member organization_members;
  updated_member organization_members;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para deshabilitar usuarios.';
  end if;

  select *
    into previous_member
  from organization_members
  where organization_id = target_organization_id
    and user_id = target_user_id
  for update;

  if not found then
    raise exception 'No existe ese usuario en la organizacion.';
  end if;

  if previous_member.role = 'owner'
    and not has_org_role(target_organization_id, array['owner']::app_role[])
  then
    raise exception 'Solo un owner puede deshabilitar a otro owner.';
  end if;

  update organization_members
  set
    status = 'disabled',
    updated_at = now()
  where id = previous_member.id
  returning * into updated_member;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    'member_disabled',
    'organization_member',
    updated_member.id,
    to_jsonb(previous_member),
    to_jsonb(updated_member)
  );

  return updated_member;
end;
$$;

create or replace function request_organization_access(target_organization_id uuid)
returns organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  user_email text;
  existing_profile profiles;
  requested_member organization_members;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  select email
    into user_email
  from auth.users
  where id = auth.uid();

  insert into profiles (id, email, display_name)
  values (auth.uid(), user_email, coalesce(user_email, 'Usuario'))
  on conflict (id) do update
  set
    email = excluded.email,
    updated_at = now()
  returning * into existing_profile;

  insert into organization_members (
    organization_id,
    user_id,
    role,
    status
  )
  values (
    target_organization_id,
    auth.uid(),
    'viewer',
    'pending'
  )
  on conflict (organization_id, user_id) do update
  set updated_at = now()
  returning * into requested_member;

  return requested_member;
end;
$$;

create or replace function claim_initial_owner(target_organization_id uuid)
returns organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  user_email text;
  claimed_member organization_members;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if exists (
    select 1
    from organization_members
    where organization_id = target_organization_id
      and status = 'active'
  ) then
    raise exception 'La organizacion ya tiene usuarios activos.';
  end if;

  select email
    into user_email
  from auth.users
  where id = auth.uid();

  insert into profiles (id, email, display_name)
  values (auth.uid(), user_email, coalesce(user_email, 'Usuario'))
  on conflict (id) do update
  set
    email = excluded.email,
    updated_at = now();

  insert into organization_members (
    organization_id,
    user_id,
    role,
    status,
    enabled_at,
    enabled_by
  )
  values (
    target_organization_id,
    auth.uid(),
    'owner',
    'active',
    now(),
    auth.uid()
  )
  on conflict (organization_id, user_id) do update
  set
    role = 'owner',
    status = 'active',
    enabled_at = now(),
    enabled_by = auth.uid(),
    updated_at = now()
  returning * into claimed_member;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    'initial_owner_claimed',
    'organization_member',
    claimed_member.id,
    to_jsonb(claimed_member)
  );

  return claimed_member;
end;
$$;
