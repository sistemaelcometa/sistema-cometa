-- Muestra y permite editar el detalle interno de cada departamento.

drop function if exists get_urban_structure(uuid);

create or replace function get_urban_structure(target_organization_id uuid)
returns table (
  building_id uuid,
  building_name text,
  building_address text,
  building_has_expenses boolean,
  unit_id uuid,
  unit_name text,
  unit_surface_m2 numeric,
  unit_status urban_unit_status,
  unit_notes text,
  lease_id uuid,
  tenant_contact_id uuid,
  tenant_name text,
  tenant_document_number text,
  tenant_phone text,
  tenant_email text,
  tenant_address text,
  tenant_notes text,
  lease_start_date date,
  lease_end_date date,
  lease_amount numeric,
  lease_currency char(3),
  lease_due_day integer,
  lease_next_adjustment_date date,
  lease_adjustment_frequency_months integer,
  lease_status urban_lease_status
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
    u.status as unit_status,
    u.notes as unit_notes,
    l.id as lease_id,
    c.id as tenant_contact_id,
    nullif(
      trim(
        coalesce(c.business_name, '') || ' ' ||
        coalesce(c.first_name, '') || ' ' ||
        coalesce(c.last_name, '')
      ),
      ''
    ) as tenant_name,
    c.document_number as tenant_document_number,
    c.phone as tenant_phone,
    c.email as tenant_email,
    c.address as tenant_address,
    c.notes as tenant_notes,
    l.start_date as lease_start_date,
    l.end_date as lease_end_date,
    l.current_amount as lease_amount,
    l.currency as lease_currency,
    l.monthly_due_day as lease_due_day,
    l.next_adjustment_date as lease_next_adjustment_date,
    l.adjustment_frequency_months as lease_adjustment_frequency_months,
    l.status as lease_status
  from urban_buildings b
  left join urban_units u
    on u.building_id = b.id
   and u.status <> 'archived'
  left join lateral (
    select *
    from urban_leases ul
    where ul.unit_id = u.id
      and ul.status in ('active', 'upcoming')
    order by
      case ul.status when 'active' then 0 else 1 end,
      ul.start_date
    limit 1
  ) l on true
  left join contacts c on c.id = l.primary_tenant_contact_id
  where b.organization_id = target_organization_id
    and b.status = 'active'
    and is_org_member(target_organization_id)
  order by b.name, u.name;
$$;

create or replace function update_urban_unit_details(
  target_organization_id uuid,
  target_unit_id uuid,
  unit_surface_m2 numeric default null,
  unit_status urban_unit_status default null,
  unit_notes text default null
)
returns urban_units
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_unit urban_units;
  updated_unit urban_units;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para editar departamentos.';
  end if;

  select *
    into previous_unit
  from urban_units
  where id = target_unit_id
    and organization_id = target_organization_id
    and status <> 'archived'
  for update;

  if not found then
    raise exception 'El departamento no existe o esta archivado.';
  end if;

  if unit_surface_m2 is not null and unit_surface_m2 <= 0 then
    raise exception 'La superficie debe ser mayor a cero.';
  end if;

  if unit_status = 'available' and exists (
    select 1
    from urban_leases l
    where l.unit_id = target_unit_id
      and l.status in ('active', 'upcoming')
  ) then
    raise exception 'No se puede marcar como disponible un departamento con contrato activo o futuro.';
  end if;

  update urban_units
  set
    surface_m2 = coalesce(unit_surface_m2, surface_m2),
    status = coalesce(unit_status, status),
    notes = case
      when unit_notes is null then notes
      else nullif(trim(unit_notes), '')
    end
  where id = target_unit_id
  returning * into updated_unit;

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
    'urban_unit_updated',
    'urban_unit',
    updated_unit.id,
    to_jsonb(previous_unit),
    to_jsonb(updated_unit)
  );

  return updated_unit;
end;
$$;
