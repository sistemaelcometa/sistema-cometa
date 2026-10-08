-- Permite anular un vencimiento proyectado por el frontend.
-- Guarda un cargo cancelado real para que el vencimiento no vuelva a proyectarse.

create or replace function cancel_projected_urban_charge(
  target_organization_id uuid,
  target_unit_id uuid,
  charge_due_date date,
  cancel_reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns urban_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  active_lease urban_leases;
  charge_month date;
  previous_charge urban_charges;
  cancelled_charge urban_charges;
  existing_operation operation_results;
  payment_count integer;
  request_hash text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para anular cargos.';
  end if;

  if target_unit_id is null or charge_due_date is null then
    raise exception 'El departamento y el vencimiento son obligatorios.';
  end if;

  charge_month := date_trunc('month', charge_due_date)::date;

  request_hash := md5(jsonb_build_object(
    'target_unit_id', target_unit_id,
    'charge_due_date', charge_due_date,
    'cancel_reason', nullif(trim(coalesce(cancel_reason, '')), '')
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = cancel_projected_urban_charge.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into cancelled_charge
      from urban_charges
      where id = existing_operation.result_entity_id;

      return cancelled_charge;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    cancel_projected_urban_charge.operation_id,
    'cancel_projected_urban_charge',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into active_lease
  from urban_leases ul
  where ul.organization_id = target_organization_id
    and ul.unit_id = target_unit_id
    and ul.status in ('active', 'upcoming')
    and charge_due_date between ul.start_date and ul.end_date
  order by
    case ul.status when 'active' then 0 else 1 end,
    ul.start_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay contrato activo para ese vencimiento proyectado.';
  end if;

  select *
    into previous_charge
  from urban_charges ch
  where ch.organization_id = target_organization_id
    and ch.lease_id = active_lease.id
    and ch.period_month = charge_month
  for update;

  if found then
    select count(*)
      into payment_count
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    join urban_payments p on p.id = pa.payment_id
    where ci.charge_id = previous_charge.id
      and p.status = 'valid';

    if payment_count > 0 then
      raise exception 'No se puede anular un cargo que tiene cobros validos. Primero anula el cobro.';
    end if;

    update urban_charges
    set status = 'cancelled'
    where id = previous_charge.id
    returning * into cancelled_charge;
  else
    insert into urban_charges (
      organization_id,
      lease_id,
      unit_id,
      period_month,
      due_date,
      status,
      created_by
    )
    values (
      target_organization_id,
      active_lease.id,
      target_unit_id,
      charge_month,
      charge_due_date,
      'cancelled',
      auth.uid()
    )
    returning * into cancelled_charge;
  end if;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
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
    cancel_projected_urban_charge.operation_id,
    'urban_projected_charge_cancelled',
    'urban_charge',
    cancelled_charge.id,
    to_jsonb(previous_charge),
    to_jsonb(cancelled_charge),
    jsonb_build_object('reason', nullif(trim(coalesce(cancel_reason, '')), ''))
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'urban_charge',
    result_entity_id = cancelled_charge.id,
    result_payload = jsonb_build_object('charge_id', cancelled_charge.id),
    completed_at = now()
  where operation_results.organization_id = target_organization_id
    and operation_results.operation_id = cancel_projected_urban_charge.operation_id;

  return cancelled_charge;
end;
$$;
