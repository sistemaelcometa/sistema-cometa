create or replace function void_pde_payment(
  target_organization_id uuid,
  payment_id uuid,
  reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns pde_reservation_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  old_payment pde_reservation_payments;
  voided_payment pde_reservation_payments;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo duenio o administrador pueden anular cobros.';
  end if;

  request_hash := md5(jsonb_build_object(
    'payment_id', payment_id,
    'reason', reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = void_pde_payment.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into voided_payment
      from pde_reservation_payments
      where id = existing_operation.result_entity_id;

      return voided_payment;
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
    void_pde_payment.operation_id,
    'void_pde_payment',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_payment
  from pde_reservation_payments
  where id = void_pde_payment.payment_id
    and organization_id = target_organization_id
  for update;

  if not found then
    raise exception 'El cobro no existe.';
  end if;

  if old_payment.status <> 'valid' then
    raise exception 'El cobro ya esta anulado.';
  end if;

  update pde_reservation_payments
  set
    status = 'voided',
    voided_at = now(),
    voided_by = auth.uid(),
    void_reason = nullif(trim(coalesce(reason, '')), '')
  where id = void_pde_payment.payment_id
  returning * into voided_payment;

  perform refresh_pde_reservation_status(voided_payment.reservation_id);

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
    void_pde_payment.operation_id,
    'pde_payment_voided',
    'pde_reservation_payment',
    voided_payment.id,
    to_jsonb(old_payment),
    to_jsonb(voided_payment),
    jsonb_build_object(
      'reason', reason,
      'reservationId', voided_payment.reservation_id
    )
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'pde_reservation_payment',
    result_entity_id = voided_payment.id,
    result_payload = to_jsonb(voided_payment),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = void_pde_payment.operation_id;

  return voided_payment;
end;
$$;
