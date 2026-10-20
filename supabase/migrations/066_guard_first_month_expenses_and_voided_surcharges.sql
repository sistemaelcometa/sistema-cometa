-- Ejecutar antes de la reparacion puntual de COLONIZADORES.
-- No elimina cobros ni imputaciones historicas. No modifica liquidaciones.
-- El primer mes de contrato no hereda expensas del mes anterior.
begin;

create or replace function reconcile_urban_expense_period_charges(
  target_organization_id uuid,
  target_period_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  allocation_record record;
  ensured_charge urban_charges;
  ensured_charge_item_id uuid;
  stale_charge_id uuid;
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
begin
  if auth.uid() is null
     and nullif(current_setting('request.jwt.claim.role', true), '') is null
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'Usuario no autenticado.';
  end if;

  if auth.uid() is not null
     and not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para reconciliar expensas.';
  end if;

  for allocation_record in
    select
      a.id as allocation_id,
      a.unit_id,
      a.tenant_amount,
      a.currency,
      a.charge_item_id,
      i.description,
      (p.period_month + interval '1 month')::date as charge_month,
      coalesce(existing_charge.due_date, (
        (p.period_month + interval '1 month')::date
        + ((least(coalesce(l.monthly_due_day, 10), 28) - 1) * interval '1 day')
      )::date) as due_date,
      coalesce(existing_charge.lease_id, l.id) as lease_id
    from urban_expense_allocations a
    join urban_expense_items i on i.id = a.expense_item_id
    join urban_expense_periods p on p.id = a.period_id
    left join lateral (
      select ch.id, ch.lease_id, ch.due_date
      from urban_charges ch
      join urban_leases charge_lease
        on charge_lease.id = ch.lease_id
       and charge_lease.organization_id = ch.organization_id
       and charge_lease.unit_id = ch.unit_id
      where p.period_month >= date_trunc('month', charge_lease.start_date)::date
        and ch.period_month between date_trunc('month', charge_lease.start_date)::date
                                and date_trunc('month', charge_lease.end_date)::date
        and ch.organization_id = a.organization_id
        and ch.unit_id = a.unit_id
        and ch.period_month = (p.period_month + interval '1 month')::date
        and ch.status <> 'cancelled'::charge_status
      order by ch.updated_at desc, ch.created_at desc
      limit 1
    ) existing_charge on true
    left join urban_leases l
      on l.unit_id = a.unit_id
     and l.organization_id = a.organization_id
     and l.status in ('active', 'upcoming')
     and (p.period_month + interval '1 month')::date between date_trunc('month', l.start_date)::date and date_trunc('month', l.end_date)::date
     and p.period_month >= date_trunc('month', l.start_date)::date
    where a.organization_id = target_organization_id
      and a.period_id = target_period_id
      and a.transfer_to_tenant
      and a.tenant_amount > 0
      and i.status = 'valid'
      and coalesce(existing_charge.lease_id, l.id) is not null
  loop
    if allocation_record.charge_item_id is not null
       and exists (
         select 1
         from urban_charge_items ci
         join urban_charges ch on ch.id = ci.charge_id
         where ci.id = allocation_record.charge_item_id
           and ci.organization_id = target_organization_id
           and ch.lease_id = allocation_record.lease_id
           and ch.unit_id = allocation_record.unit_id
           and ch.period_month = allocation_record.charge_month
           and ci.item_type in ('building_expense', 'unit_expense')
       ) then
      update urban_charge_items
      set
        description = allocation_record.description,
        amount_due = allocation_record.tenant_amount,
        currency = allocation_record.currency,
        source_entity_type = 'urban_expense_allocation',
        source_entity_id = allocation_record.allocation_id
      where id = allocation_record.charge_item_id
        and organization_id = target_organization_id
        and not exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = allocation_record.charge_item_id
            and pay.status = 'valid'
        );

      continue;
    end if;

    stale_charge_id := null;

    if allocation_record.charge_item_id is not null then
      update urban_charge_items old_item
      set
        description = 'Expensas movidas al periodo correcto',
        amount_due = 0
      where old_item.id = allocation_record.charge_item_id
        and old_item.organization_id = target_organization_id
        and old_item.item_type in ('building_expense', 'unit_expense')
        and old_item.source_entity_type = 'urban_expense_allocation'
        and old_item.source_entity_id = allocation_record.allocation_id
        and not exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = old_item.id
            and pay.status = 'valid'
        )
      returning old_item.charge_id into stale_charge_id;
    end if;

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
      allocation_record.lease_id,
      allocation_record.unit_id,
      allocation_record.charge_month,
      allocation_record.due_date,
      'pending',
      auth.uid()
    )
    on conflict (lease_id, period_month) do update
    set
      due_date = excluded.due_date,
      status = case
        when urban_charges.status = 'cancelled' then 'pending'::charge_status
        else urban_charges.status
      end,
      updated_at = now()
    returning * into ensured_charge;

    select ci.id
      into ensured_charge_item_id
    from urban_charge_items ci
    where ci.organization_id = target_organization_id
      and ci.charge_id = ensured_charge.id
      and ci.source_entity_type = 'urban_expense_allocation'
      and ci.source_entity_id = allocation_record.allocation_id
    limit 1;

    if ensured_charge_item_id is null then
      insert into urban_charge_items (
        organization_id,
        charge_id,
        item_type,
        description,
        amount_due,
        currency,
        source_entity_type,
        source_entity_id
      )
      values (
        target_organization_id,
        ensured_charge.id,
        'building_expense',
        allocation_record.description,
        allocation_record.tenant_amount,
        allocation_record.currency,
        'urban_expense_allocation',
        allocation_record.allocation_id
      )
      returning id into ensured_charge_item_id;
    else
      update urban_charge_items
      set
        description = allocation_record.description,
        amount_due = allocation_record.tenant_amount,
        currency = allocation_record.currency
      where id = ensured_charge_item_id
        and not exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = ensured_charge_item_id
            and pay.status = 'valid'
        );
    end if;

    update urban_expense_allocations
    set charge_item_id = ensured_charge_item_id
    where id = allocation_record.allocation_id
      and organization_id = target_organization_id;

    if stale_charge_id is not null then
      perform recalculate_urban_charge_status(target_organization_id, stale_charge_id);
    end if;
  end loop;

  for ensured_charge in
    select distinct ch.*
    from urban_charges ch
    join urban_charge_items ci on ci.charge_id = ch.id
    join urban_expense_allocations a on a.charge_item_id = ci.id
    where a.organization_id = target_organization_id
      and a.period_id = target_period_id
  loop
    select coalesce(sum(amount_due), 0)
      into total_due
    from urban_charge_items
    where charge_id = ensured_charge.id;

    select coalesce(sum(pa.allocated_amount), 0)
      into total_paid
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    join urban_payments pay on pay.id = pa.payment_id
    where ci.charge_id = ensured_charge.id
      and pay.status = 'valid';

    update urban_charges
    set status = case
      when total_due > 0 and total_paid >= total_due then 'paid'::charge_status
      when total_paid > 0 then 'partial'::charge_status
      else 'pending'::charge_status
    end,
    updated_at = now()
    where id = ensured_charge.id;
  end loop;
end;
$$;

create or replace function get_urban_billing(target_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  billing_payload jsonb;
begin
  if not can_read_urban_billing_sync(target_organization_id) then
    raise exception 'No tenes permisos para ver cobros.';
  end if;

  if can_manage_urban_billing_sync(target_organization_id) then
    perform sync_urban_lease_charges(target_organization_id);
  end if;

  with expense_totals as (
    select
      a.unit_id,
      (p.period_month + interval '1 month')::date as charge_month,
      p.period_month as expense_period_month,
      p.status as expense_period_status,
      coalesce(sum(a.tenant_amount), 0)::numeric(14, 2) as expenses_amount,
      max(a.currency) as currency
    from urban_expense_allocations a
    join urban_expense_periods p on p.id = a.period_id
    join urban_expense_items i on i.id = a.expense_item_id
    where a.organization_id = target_organization_id
      and p.organization_id = target_organization_id
      and i.organization_id = target_organization_id
      and p.status in ('calculated', 'closed')
      and i.status = 'valid'
      and a.transfer_to_tenant
      and a.tenant_amount > 0
    group by a.unit_id, p.period_month, p.status
  ),
  paid_totals as (
    select
      i.charge_id,
      coalesce(sum(a.allocated_amount), 0)::numeric(14, 2) as paid_amount
    from urban_charge_items i
    join urban_payment_allocations a on a.charge_item_id = i.id
    join urban_payments p on p.id = a.payment_id
    where i.organization_id = target_organization_id
      and p.status = 'valid'
    group by i.charge_id
  ),
  charge_rows as (
    select
      ch.id::text as id,
      ch.id as physical_charge_id,
      ch.lease_id,
      ch.unit_id,
      b.id as building_id,
      b.has_expenses as building_has_expenses,
      u.name as unit_name,
      b.name as building_name,
      c.first_name,
      c.last_name,
      c.business_name,
      ch.period_month,
      (ch.period_month - interval '1 month')::date as fallback_expense_period_month,
      coalesce(et.expense_period_month, (ch.period_month - interval '1 month')::date) as expense_period_month,
      ch.due_date,
      ch.status as stored_status,
      coalesce(l.current_amount, 0)::numeric(14, 2) as rent_amount,
      case
        when b.has_expenses is false
          or (ch.period_month - interval '1 month')::date < date_trunc('month', l.start_date)::date
          then 0::numeric(14, 2)
        else coalesce(et.expenses_amount, 0)::numeric(14, 2)
      end as expenses_amount,
      0::numeric(14, 2) as other_amount,
      coalesce(pt.paid_amount, 0)::numeric(14, 2) as paid_amount,
      coalesce(et.expense_period_status, eps.status) as expense_period_status,
      coalesce(l.currency, et.currency, 'ARS') as currency,
      false as projected
    from urban_charges ch
    join urban_leases l on l.id = ch.lease_id
    join urban_units u on u.id = ch.unit_id
    join urban_buildings b on b.id = u.building_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join expense_totals et
      on et.unit_id = ch.unit_id
     and et.charge_month = ch.period_month
    left join urban_expense_periods eps
      on eps.organization_id = target_organization_id
     and eps.building_id = b.id
     and eps.period_month = (ch.period_month - interval '1 month')::date
    left join paid_totals pt on pt.charge_id = ch.id
    where ch.organization_id = target_organization_id
      and l.organization_id = target_organization_id
      and l.status in ('active', 'upcoming')
      and u.status <> 'archived'
      and b.status = 'active'
      and ch.status <> 'cancelled'::charge_status
      and ch.period_month >= date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date
      and ch.period_month <= date_trunc('month', l.end_date)::date
  ),
  display_rows as (
    select
      cr.*,
      (cr.rent_amount + cr.expenses_amount + cr.other_amount)::numeric(14, 2) as total_amount,
      case
        when cr.stored_status = 'cancelled' then 'cancelled'
        when cr.rent_amount + cr.expenses_amount + cr.other_amount > 0
          and cr.paid_amount >= cr.rent_amount + cr.expenses_amount + cr.other_amount then 'paid'
        when cr.paid_amount > 0 then 'partial'
        else 'pending'
      end as display_status
    from charge_rows cr
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
    group by p.id, p.lease_id, p.unit_id, u.name, b.name, c.id, ch.id, ch.period_month, receipt.id, receipt.bucket, receipt.storage_path, receipt.original_filename
  )
  select jsonb_build_object(
    'charges',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', dr.id,
            'chargeId', dr.physical_charge_id,
            'leaseId', dr.lease_id,
            'unitId', dr.unit_id,
            'unit', dr.unit_name,
            'building', dr.building_name,
            'buildingHasExpenses', dr.building_has_expenses,
            'expensePeriodStatus', dr.expense_period_status,
            'expensePeriodMonth', dr.expense_period_month,
            'tenant', nullif(trim(coalesce(dr.business_name, '') || ' ' || coalesce(dr.first_name, '') || ' ' || coalesce(dr.last_name, '')), ''),
            'dueDate', dr.due_date,
            'periodMonth', dr.period_month,
            'rent', dr.rent_amount,
            'expenses', dr.expenses_amount,
            'transferredExpenses', 0,
            'other', dr.other_amount,
            'paid', dr.paid_amount,
            'currency', dr.currency,
            'status', dr.display_status,
            'projected', dr.projected,
            'canCancel', false
          )
          order by dr.due_date, dr.building_name, dr.unit_name
        )
        from display_rows dr
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
  into billing_payload;

  return billing_payload;
end;
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


  -- Un recargo creado al cobrar no queda como deuda al anular ese cobro.
  -- Si otro pago valido lo usa, conservamos el concepto y su saldo.
  update urban_charge_items ci
  set amount_due = 0
  where ci.organization_id = target_organization_id
    and ci.source_entity_type = 'payment_surcharge'
    and ci.item_type in ('rent_surcharge', 'expense_surcharge')
    and ci.amount_due <> 0
    and exists (
      select 1 from urban_payment_allocations pa
      where pa.charge_item_id = ci.id
        and pa.payment_id = target_payment_id
        and pa.allocated_amount > 0
    )
    and not exists (
      select 1
      from urban_payment_allocations pa
      join urban_payments p on p.id = pa.payment_id
      where pa.charge_item_id = ci.id
        and p.status = 'valid'
        and pa.allocated_amount > 0
    );

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

commit;

