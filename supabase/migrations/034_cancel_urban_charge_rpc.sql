-- Permite anular cargos urbanos pendientes sin borrar datos fisicamente.
-- Se usa para limpiar cargos generados por contratos de prueba o cargados por error.

create or replace function cancel_urban_charge(
  target_organization_id uuid,
  target_charge_id uuid,
  cancel_reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns urban_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  charge_to_cancel urban_charges;
  cancelled_charge urban_charges;
  existing_charge urban_charges;
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

  if target_charge_id is null then
    raise exception 'El cargo es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_charge_id', target_charge_id,
    'cancel_reason', nullif(trim(coalesce(cancel_reason, '')), '')
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = cancel_urban_charge.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into existing_charge
      from urban_charges
      where id = existing_operation.result_entity_id;

      return existing_charge;
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
    cancel_urban_charge.operation_id,
    'cancel_urban_charge',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into charge_to_cancel
  from urban_charges ch
  where ch.id = target_charge_id
    and ch.organization_id = target_organization_id
  for update;

  if not found then
    raise exception 'El cargo no existe.';
  end if;

  if charge_to_cancel.status = 'cancelled' then
    update operation_results
    set
      status = 'succeeded',
      result_entity_type = 'urban_charge',
      result_entity_id = charge_to_cancel.id,
      result_payload = jsonb_build_object('charge_id', charge_to_cancel.id),
      completed_at = now()
    where operation_results.organization_id = target_organization_id
      and operation_results.operation_id = cancel_urban_charge.operation_id;

    return charge_to_cancel;
  end if;

  select count(*)
    into payment_count
  from urban_payment_allocations pa
  join urban_charge_items ci on ci.id = pa.charge_item_id
  join urban_payments p on p.id = pa.payment_id
  where ci.charge_id = charge_to_cancel.id
    and p.status = 'valid';

  if payment_count > 0 then
    raise exception 'No se puede anular un cargo que tiene cobros validos. Primero anula el cobro.';
  end if;

  update urban_charges
  set status = 'cancelled'
  where id = charge_to_cancel.id
  returning * into cancelled_charge;

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
    cancel_urban_charge.operation_id,
    'urban_charge_cancelled',
    'urban_charge',
    cancelled_charge.id,
    to_jsonb(charge_to_cancel),
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
    and operation_results.operation_id = cancel_urban_charge.operation_id;

  return cancelled_charge;
end;
$$;
