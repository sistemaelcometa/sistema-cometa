-- Cierre de huecos criticos urbanos:
-- - Los cobros anulados dejan de computar en saldos.
-- - Se puede anular un cobro urbano por RPC transaccional.
-- - Se puede cerrar un periodo de expensas urbanas para congelarlo.
-- - Los comprobantes urbanos quedan disponibles en la lectura de cobros.

create or replace function get_urban_billing(target_organization_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with item_totals as (
    select
      i.charge_id,
      coalesce(sum(i.amount_due) filter (where i.item_type = 'rent'), 0)::numeric(14, 2) as rent_amount,
      coalesce(sum(i.amount_due) filter (where i.item_type in ('building_expense', 'unit_expense')), 0)::numeric(14, 2) as expenses_amount,
      coalesce(sum(i.amount_due) filter (where i.item_type not in ('rent', 'building_expense', 'unit_expense')), 0)::numeric(14, 2) as other_amount,
      coalesce(sum(i.amount_due), 0)::numeric(14, 2) as total_amount,
      max(i.currency) as currency
    from urban_charge_items i
    group by i.charge_id
  ),
  paid_totals as (
    select
      i.charge_id,
      coalesce(sum(a.allocated_amount), 0)::numeric(14, 2) as paid_amount
    from urban_charge_items i
    join urban_payment_allocations a on a.charge_item_id = i.id
    join urban_payments p on p.id = a.payment_id
    where p.status = 'valid'
    group by i.charge_id
  ),
  charge_rows as (
    select
      ch.id,
      ch.lease_id,
      ch.unit_id,
      u.name as unit_name,
      b.name as building_name,
      c.first_name,
      c.last_name,
      c.business_name,
      ch.period_month,
      ch.due_date,
      ch.status,
      coalesce(it.rent_amount, 0)::numeric(14, 2) as rent_amount,
      coalesce(it.expenses_amount, 0)::numeric(14, 2) as expenses_amount,
      coalesce(it.other_amount, 0)::numeric(14, 2) as other_amount,
      coalesce(it.total_amount, 0)::numeric(14, 2) as total_amount,
      coalesce(pt.paid_amount, 0)::numeric(14, 2) as paid_amount,
      coalesce(it.currency, l.currency) as currency
    from urban_charges ch
    join urban_leases l on l.id = ch.lease_id
    join urban_units u on u.id = ch.unit_id
    join urban_buildings b on b.id = u.building_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join item_totals it on it.charge_id = ch.id
    left join paid_totals pt on pt.charge_id = ch.id
    where ch.organization_id = target_organization_id
      and is_org_member(target_organization_id)
  ),
  payments as (
    select
      p.id,
      p.lease_id,
      p.unit_id,
      u.name as unit_name,
      b.name as building_name,
      c.first_name,
      c.last_name,
      c.business_name,
      p.payment_date,
      p.received_amount,
      p.currency,
      p.payment_method,
      p.notes,
      ch.id as charge_id,
      ch.period_month,
      receipt.id as receipt_file_id,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.original_filename as receipt_name,
      coalesce(sum(a.allocated_amount) filter (where i.item_type = 'rent'), 0)::numeric(14, 2) as rent_paid,
      coalesce(sum(a.allocated_amount) filter (where i.item_type = 'rent_surcharge'), 0)::numeric(14, 2) as rent_surcharge_paid,
      coalesce(sum(a.allocated_amount) filter (where i.item_type in ('building_expense', 'unit_expense')), 0)::numeric(14, 2) as expenses_paid,
      coalesce(sum(a.allocated_amount) filter (where i.item_type = 'expense_surcharge'), 0)::numeric(14, 2) as expense_surcharge_paid
    from urban_payments p
    join urban_units u on u.id = p.unit_id
    join urban_buildings b on b.id = u.building_id
    join urban_leases l on l.id = p.lease_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join urban_payment_allocations a on a.payment_id = p.id
    left join urban_charge_items i on i.id = a.charge_item_id
    left join urban_charges ch on ch.id = i.charge_id
    left join lateral (
      select f.id, f.bucket, f.storage_path, f.original_filename
      from file_links fl
      join files f on f.id = fl.file_id
      where fl.organization_id = p.organization_id
        and fl.entity_type = 'urban_payment'
        and fl.entity_id = p.id
        and f.status = 'active'
      order by f.created_at desc
      limit 1
    ) receipt on true
    where p.organization_id = target_organization_id
      and p.status = 'valid'
      and is_org_member(target_organization_id)
    group by p.id, p.lease_id, p.unit_id, u.name, b.name, c.id, ch.id, ch.period_month, receipt.id, receipt.bucket, receipt.storage_path, receipt.original_filename
  )
  select jsonb_build_object(
    'charges',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', cr.id,
          'leaseId', cr.lease_id,
          'unitId', cr.unit_id,
          'unit', cr.unit_name,
          'building', cr.building_name,
          'tenant', nullif(trim(coalesce(cr.business_name, '') || ' ' || coalesce(cr.first_name, '') || ' ' || coalesce(cr.last_name, '')), ''),
          'dueDate', cr.due_date,
          'periodMonth', cr.period_month,
          'rent', cr.rent_amount,
          'expenses', cr.expenses_amount,
          'transferredExpenses', 0,
          'other', cr.other_amount,
          'paid', cr.paid_amount,
          'currency', cr.currency,
          'status', case
            when cr.total_amount > 0 and cr.paid_amount >= cr.total_amount then 'paid'
            when cr.paid_amount > 0 then 'partial'
            else cr.status::text
          end
        )
        order by cr.due_date
      ),
      '[]'::jsonb
    ),
    'payments',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'chargeId', p.charge_id,
            'unitId', p.unit_id,
            'unit', p.unit_name,
            'building', p.building_name,
            'tenant', nullif(trim(coalesce(p.business_name, '') || ' ' || coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''),
            'paidAt', p.payment_date,
            'amount', p.received_amount,
            'method', case p.payment_method
              when 'transfer' then 'Transferencia'
              when 'cash' then 'Efectivo'
              when 'deposit' then 'Deposito'
              when 'card' then 'Tarjeta'
              else 'Otro'
            end,
            'notes', p.notes,
            'receiptName', coalesce(p.receipt_name, ''),
            'receiptBucket', coalesce(p.receipt_bucket, ''),
            'receiptPath', coalesce(p.receipt_path, ''),
            'fileId', p.receipt_file_id,
            'chargePeriod', to_char(p.period_month, 'YYYY-MM'),
            'currency', p.currency,
            'allocation', jsonb_build_object(
              'expensesPaid', p.expenses_paid,
              'expenseSurchargePaid', p.expense_surcharge_paid,
              'rentPaid', p.rent_paid,
              'rentSurchargePaid', p.rent_surcharge_paid
            )
          )
          order by p.payment_date desc, p.id
        )
        from payments p
      ),
      '[]'::jsonb
    )
  )
  from charge_rows cr;
$$;

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
    'void_reason', void_reason
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
    void_reason = nullif(trim(coalesce(void_reason, '')), '')
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

create or replace function close_urban_expense_period(
  target_organization_id uuid,
  target_building_id uuid,
  period_month date,
  close_notes text default null,
  operation_id uuid default gen_random_uuid()
)
returns urban_expense_periods
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_period urban_expense_periods;
  closed_period urban_expense_periods;
  existing_period urban_expense_periods;
  existing_operation operation_results;
  request_hash text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para cerrar expensas.';
  end if;

  if period_month is null or period_month <> date_trunc('month', period_month)::date then
    raise exception 'El periodo debe ser el primer dia del mes.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_building_id', target_building_id,
    'period_month', period_month,
    'close_notes', close_notes
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = close_urban_expense_period.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into existing_period
      from urban_expense_periods
      where id = existing_operation.result_entity_id;

      return existing_period;
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
    close_urban_expense_period.operation_id,
    'close_urban_expense_period',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into previous_period
  from urban_expense_periods
  where organization_id = target_organization_id
    and building_id = target_building_id
    and urban_expense_periods.period_month = close_urban_expense_period.period_month
  for update;

  if not found then
    raise exception 'No existe el periodo de expensas.';
  end if;

  if previous_period.status = 'closed' then
    raise exception 'El periodo ya esta cerrado.';
  end if;

  if previous_period.status <> 'calculated' then
    raise exception 'Antes de cerrar hay que calcular el periodo.';
  end if;

  update urban_expense_periods
  set
    status = 'closed',
    notes = concat_ws(E'\n', nullif(notes, ''), nullif(trim(coalesce(close_notes, '')), '')),
    closed_at = now(),
    closed_by = auth.uid()
  where id = previous_period.id
  returning * into closed_period;

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
    close_urban_expense_period.operation_id,
    'urban_expense_period_closed',
    'urban_expense_period',
    closed_period.id,
    to_jsonb(previous_period),
    to_jsonb(closed_period)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'urban_expense_period',
    result_entity_id = closed_period.id,
    result_payload = jsonb_build_object(
      'period_id', closed_period.id,
      'building_id', closed_period.building_id,
      'period_month', closed_period.period_month
    ),
    completed_at = now()
  where operation_results.organization_id = target_organization_id
    and operation_results.operation_id = close_urban_expense_period.operation_id;

  return closed_period;
end;
$$;
