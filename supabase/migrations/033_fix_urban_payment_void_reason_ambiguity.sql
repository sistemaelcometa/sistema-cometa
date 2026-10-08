-- Fix de ambiguedad en void_urban_payment:
-- el parametro void_reason chocaba con urban_payments.void_reason.

create or replace function void_urban_payment(
  target_organization_id uuid,
  target_payment_id uuid,
  void_reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns urban_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_void_reason text := nullif(trim(coalesce(void_urban_payment.void_reason, '')), '');
  previous_payment urban_payments;
  voided_payment urban_payments;
  existing_payment urban_payments;
  existing_operation operation_results;
  request_hash text;
  affected_charge_id uuid;
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para anular cobros.';
  end if;

  if target_payment_id is null then
    raise exception 'El cobro es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_payment_id', target_payment_id,
    'void_reason', payment_void_reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = void_urban_payment.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into existing_payment
      from urban_payments
      where id = existing_operation.result_entity_id;

      return existing_payment;
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
    void_urban_payment.operation_id,
    'void_urban_payment',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into previous_payment
  from urban_payments
  where id = target_payment_id
    and organization_id = target_organization_id
    and status = 'valid'
  for update;

  if not found then
    raise exception 'El cobro no existe o ya fue anulado.';
  end if;

  perform 1
  from urban_charges ch
  join urban_charge_items ci on ci.charge_id = ch.id
  join urban_payment_allocations pa on pa.charge_item_id = ci.id
  where pa.payment_id = target_payment_id
    and ch.organization_id = target_organization_id
  for update;

  update urban_payments
  set
    status = 'voided',
    voided_at = now(),
    voided_by = auth.uid(),
    void_reason = payment_void_reason
  where id = target_payment_id
  returning * into voided_payment;

  for affected_charge_id in
    select distinct ci.charge_id
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    where pa.payment_id = target_payment_id
  loop
    select coalesce(sum(amount_due), 0)
      into total_due
    from urban_charge_items
    where charge_id = affected_charge_id;

    select coalesce(sum(pa.allocated_amount), 0)
      into total_paid
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    join urban_payments p on p.id = pa.payment_id
    where ci.charge_id = affected_charge_id
      and p.status = 'valid';

    update urban_charges
    set status = case
      when total_paid >= total_due and total_due > 0 then 'paid'::charge_status
      when total_paid > 0 then 'partial'::charge_status
      else 'pending'::charge_status
    end
    where id = affected_charge_id;
  end loop;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    void_urban_payment.operation_id,
    'urban_payment_voided',
    'urban_payment',
    voided_payment.id,
    to_jsonb(previous_payment),
    to_jsonb(voided_payment)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'urban_payment',
    result_entity_id = voided_payment.id,
    result_payload = jsonb_build_object('payment_id', voided_payment.id),
    completed_at = now()
  where operation_results.organization_id = target_organization_id
    and operation_results.operation_id = void_urban_payment.operation_id;

  return voided_payment;
end;
$$;
