-- Ajusta la administracion de usuarios:
-- - owner/dueño conserva el control superior.
-- - admin opera el sistema y puede habilitar usuarios comunes.
-- - admin no puede crear/modificar/desactivar owners ni admins.

drop policy if exists organization_members_insert_admin on organization_members;
drop policy if exists organization_members_update_admin on organization_members;

create policy organization_members_insert_owner on organization_members
  for insert with check (has_org_role(organization_id, array['owner']::app_role[]));

create policy organization_members_update_owner on organization_members
  for update using (has_org_role(organization_id, array['owner']::app_role[]))
  with check (has_org_role(organization_id, array['owner']::app_role[]));

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
  previous_member organization_members;
  updated_member organization_members;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para habilitar usuarios.';
  end if;

  if target_role in ('owner', 'admin')
    and not has_org_role(target_organization_id, array['owner']::app_role[])
  then
    raise exception 'Solo un duenio puede asignar roles sensibles.';
  end if;

  select *
    into previous_member
  from organization_members
  where organization_id = target_organization_id
    and user_id = target_user_id
  for update;

  if not found then
    raise exception 'No existe una solicitud de acceso para ese usuario.';
  end if;

  if previous_member.role in ('owner', 'admin')
    and not has_org_role(target_organization_id, array['owner']::app_role[])
  then
    raise exception 'Solo un duenio puede modificar duenios o administradores.';
  end if;

  if previous_member.role = 'owner'
    and target_role <> 'owner'
    and (
      select count(*)
      from organization_members
      where organization_id = target_organization_id
        and role = 'owner'
        and status = 'active'
    ) <= 1
  then
    raise exception 'No se puede quitar el ultimo duenio activo.';
  end if;

  update organization_members
  set
    role = target_role,
    status = 'active',
    enabled_at = now(),
    enabled_by = auth.uid(),
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
    'member_enabled',
    'organization_member',
    updated_member.id,
    to_jsonb(previous_member),
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

  if previous_member.role in ('owner', 'admin')
    and not has_org_role(target_organization_id, array['owner']::app_role[])
  then
    raise exception 'Solo un duenio puede deshabilitar duenios o administradores.';
  end if;

  if previous_member.role = 'owner'
    and previous_member.status = 'active'
    and (
      select count(*)
      from organization_members
      where organization_id = target_organization_id
        and role = 'owner'
        and status = 'active'
    ) <= 1
  then
    raise exception 'No se puede deshabilitar el ultimo duenio activo.';
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
