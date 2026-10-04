-- RPCs para edificios y departamentos urbanos.

create or replace function get_urban_structure(target_organization_id uuid)
returns table (
  building_id uuid,
  building_name text,
  building_address text,
  building_has_expenses boolean,
  unit_id uuid,
  unit_name text,
  unit_surface_m2 numeric,
  unit_status urban_unit_status
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id as building_id,
    b.name as building_name,
    b.address as building_address,
    b.has_expenses as building_has_expenses,
    u.id as unit_id,
    u.name as unit_name,
    u.surface_m2 as unit_surface_m2,
    u.status as unit_status
  from urban_buildings b
  left join urban_units u
    on u.building_id = b.id
   and u.status <> 'archived'
  where b.organization_id = target_organization_id
    and b.status = 'active'
    and is_org_member(target_organization_id)
  order by b.name, u.name;
$$;

create or replace function create_urban_building(
  target_organization_id uuid,
  building_name text,
  building_address text default null,
  building_has_expenses boolean default true
)
returns urban_buildings
language plpgsql
security definer
set search_path = public
as $$
declare
  created_building urban_buildings;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para crear edificios.';
  end if;

  if nullif(trim(building_name), '') is null then
    raise exception 'El nombre del edificio es obligatorio.';
  end if;

  insert into urban_buildings (
    organization_id,
    name,
    address,
    has_expenses,
    created_by
  )
  values (
    target_organization_id,
    trim(building_name),
    nullif(trim(coalesce(building_address, '')), ''),
    coalesce(building_has_expenses, true),
    auth.uid()
  )
  returning * into created_building;

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
    'urban_building_created',
    'urban_building',
    created_building.id,
    to_jsonb(created_building)
  );

  return created_building;
end;
$$;

create or replace function update_urban_building(
  target_organization_id uuid,
  target_building_id uuid,
  building_name text,
  building_address text default null,
  building_has_expenses boolean default true
)
returns urban_buildings
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_building urban_buildings;
  updated_building urban_buildings;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para editar edificios.';
  end if;

  if nullif(trim(building_name), '') is null then
    raise exception 'El nombre del edificio es obligatorio.';
  end if;

  select *
    into previous_building
  from urban_buildings
  where id = target_building_id
    and organization_id = target_organization_id
    and status = 'active'
  for update;

  if not found then
    raise exception 'El edificio no existe o esta archivado.';
  end if;

  update urban_buildings
  set
    name = trim(building_name),
    address = nullif(trim(coalesce(building_address, '')), ''),
    has_expenses = coalesce(building_has_expenses, true)
  where id = target_building_id
  returning * into updated_building;

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
    'urban_building_updated',
    'urban_building',
    updated_building.id,
    to_jsonb(previous_building),
    to_jsonb(updated_building)
  );

  return updated_building;
end;
$$;

create or replace function archive_urban_building(
  target_organization_id uuid,
  target_building_id uuid
)
returns urban_buildings
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_building urban_buildings;
  archived_building urban_buildings;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para archivar edificios.';
  end if;

  select *
    into previous_building
  from urban_buildings
  where id = target_building_id
    and organization_id = target_organization_id
    and status = 'active'
  for update;

  if not found then
    raise exception 'El edificio no existe o ya esta archivado.';
  end if;

  if exists (
    select 1
    from urban_leases l
    join urban_units u on u.id = l.unit_id
    where u.building_id = target_building_id
      and l.status in ('upcoming', 'active')
  ) then
    raise exception 'No se puede archivar un edificio con contratos activos o futuros.';
  end if;

  update urban_units
  set status = 'archived'
  where building_id = target_building_id
    and status <> 'archived';

  update urban_buildings
  set status = 'archived'
  where id = target_building_id
  returning * into archived_building;

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
    'urban_building_archived',
    'urban_building',
    archived_building.id,
    to_jsonb(previous_building),
    to_jsonb(archived_building)
  );

  return archived_building;
end;
$$;

create or replace function create_urban_unit(
  target_organization_id uuid,
  target_building_id uuid,
  unit_name text,
  unit_surface_m2 numeric
)
returns urban_units
language plpgsql
security definer
set search_path = public
as $$
declare
  created_unit urban_units;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para crear departamentos.';
  end if;

  if nullif(trim(unit_name), '') is null then
    raise exception 'El nombre del departamento es obligatorio.';
  end if;

  if coalesce(unit_surface_m2, 0) <= 0 then
    raise exception 'La superficie debe ser mayor a cero.';
  end if;

  if not exists (
    select 1
    from urban_buildings
    where id = target_building_id
      and organization_id = target_organization_id
      and status = 'active'
  ) then
    raise exception 'El edificio no existe o esta archivado.';
  end if;

  insert into urban_units (
    organization_id,
    building_id,
    name,
    surface_m2,
    status,
    created_by
  )
  values (
    target_organization_id,
    target_building_id,
    trim(unit_name),
    unit_surface_m2,
    'available',
    auth.uid()
  )
  returning * into created_unit;

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
    'urban_unit_created',
    'urban_unit',
    created_unit.id,
    to_jsonb(created_unit)
  );

  return created_unit;
end;
$$;

create or replace function archive_urban_unit(
  target_organization_id uuid,
  target_unit_id uuid
)
returns urban_units
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_unit urban_units;
  archived_unit urban_units;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para archivar departamentos.';
  end if;

  select *
    into previous_unit
  from urban_units
  where id = target_unit_id
    and organization_id = target_organization_id
    and status <> 'archived'
  for update;

  if not found then
    raise exception 'El departamento no existe o ya esta archivado.';
  end if;

  if exists (
    select 1
    from urban_leases
    where unit_id = target_unit_id
      and status in ('upcoming', 'active')
  ) then
    raise exception 'No se puede archivar un departamento con contrato activo o futuro.';
  end if;

  update urban_units
  set status = 'archived'
  where id = target_unit_id
  returning * into archived_unit;

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
    'urban_unit_archived',
    'urban_unit',
    archived_unit.id,
    to_jsonb(previous_unit),
    to_jsonb(archived_unit)
  );

  return archived_unit;
end;
$$;
