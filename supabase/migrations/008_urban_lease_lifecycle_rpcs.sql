-- RPCs para editar y finalizar contratos urbanos.

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
    notes = coalesce(nullif(trim(coalesce(unit_notes, '')), ''), notes)
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

create or replace function update_active_urban_lease(
  target_organization_id uuid,
  target_unit_id uuid,
  lease_end_date date default null,
  lease_amount numeric default null,
  lease_currency char(3) default null,
  lease_due_day integer default null,
  lease_adjustment_frequency_months integer default null,
  lease_next_adjustment_date date default null,
  lease_notes text default null
)
returns urban_leases
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_lease urban_leases;
  updated_lease urban_leases;
  amount_changed boolean;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para editar contratos.';
  end if;

  select *
    into previous_lease
  from urban_leases
  where organization_id = target_organization_id
    and unit_id = target_unit_id
    and status = 'active'
  order by start_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay contrato activo para editar.';
  end if;

  if lease_end_date is not null and lease_end_date <= previous_lease.start_date then
    raise exception 'La fecha de fin debe ser posterior al inicio.';
  end if;

  if lease_amount is not null and lease_amount < 0 then
    raise exception 'El importe del alquiler no puede ser negativo.';
  end if;

  if lease_currency is not null and lease_currency not in ('ARS', 'USD') then
    raise exception 'La moneda del contrato no es valida.';
  end if;

  if lease_due_day is not null and lease_due_day not between 1 and 28 then
    raise exception 'El dia de vencimiento debe estar entre 1 y 28.';
  end if;

  if lease_adjustment_frequency_months is not null and lease_adjustment_frequency_months <= 0 then
    raise exception 'La frecuencia de ajuste debe ser mayor a cero.';
  end if;

  amount_changed :=
    lease_amount is not null
    and (
      lease_amount <> previous_lease.current_amount
      or coalesce(lease_currency, previous_lease.currency) <> previous_lease.currency
    );

  update urban_leases
  set
    end_date = coalesce(lease_end_date, end_date),
    current_amount = coalesce(lease_amount, current_amount),
    currency = coalesce(lease_currency, currency),
    monthly_due_day = coalesce(lease_due_day, monthly_due_day),
    adjustment_frequency_months = coalesce(lease_adjustment_frequency_months, adjustment_frequency_months),
    next_adjustment_date = coalesce(lease_next_adjustment_date, next_adjustment_date),
    last_adjustment_date = case when amount_changed then current_date else last_adjustment_date end,
    notes = coalesce(nullif(trim(coalesce(lease_notes, '')), ''), notes)
  where id = previous_lease.id
  returning * into updated_lease;

  if amount_changed then
    insert into urban_lease_adjustments (
      organization_id,
      lease_id,
      effective_date,
      previous_amount,
      new_amount,
      currency,
      next_adjustment_date,
      notes,
      created_by
    )
    values (
      target_organization_id,
      updated_lease.id,
      current_date,
      previous_lease.current_amount,
      updated_lease.current_amount,
      updated_lease.currency,
      updated_lease.next_adjustment_date,
      'Actualizacion manual desde el sistema',
      auth.uid()
    );
  end if;

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
    'urban_lease_updated',
    'urban_lease',
    updated_lease.id,
    to_jsonb(previous_lease),
    to_jsonb(updated_lease)
  );

  return updated_lease;
end;
$$;

create or replace function finalize_active_urban_lease(
  target_organization_id uuid,
  target_unit_id uuid,
  finalized_at date default current_date,
  final_notes text default null,
  compensation_amount numeric default null,
  compensation_currency char(3) default null
)
returns urban_leases
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_lease urban_leases;
  finalized_lease urban_leases;
  previous_unit urban_units;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para finalizar contratos.';
  end if;

  select *
    into previous_lease
  from urban_leases
  where organization_id = target_organization_id
    and unit_id = target_unit_id
    and status = 'active'
  order by start_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay contrato activo para finalizar.';
  end if;

  if finalized_at is null then
    finalized_at := current_date;
  end if;

  if finalized_at < previous_lease.start_date then
    raise exception 'La fecha de finalizacion no puede ser anterior al inicio del contrato.';
  end if;

  if compensation_amount is not null and compensation_amount < 0 then
    raise exception 'La compensacion no puede ser negativa.';
  end if;

  if compensation_currency is not null and compensation_currency not in ('ARS', 'USD') then
    raise exception 'La moneda de compensacion no es valida.';
  end if;

  select *
    into previous_unit
  from urban_units
  where id = target_unit_id
    and organization_id = target_organization_id
  for update;

  update urban_leases
  set
    status = 'finalized',
    end_date = finalized_at,
    notes = concat_ws(
      E'\n',
      nullif(notes, ''),
      nullif(trim(coalesce(final_notes, '')), '')
    )
  where id = previous_lease.id
  returning * into finalized_lease;

  update urban_units
  set status = 'available'
  where id = target_unit_id;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    'urban_lease_finalized',
    'urban_lease',
    finalized_lease.id,
    jsonb_build_object('lease', to_jsonb(previous_lease), 'unit', to_jsonb(previous_unit)),
    jsonb_build_object('lease', to_jsonb(finalized_lease), 'unit_status', 'available'),
    jsonb_build_object(
      'compensation_amount', compensation_amount,
      'compensation_currency', compensation_currency
    )
  );

  return finalized_lease;
end;
$$;
