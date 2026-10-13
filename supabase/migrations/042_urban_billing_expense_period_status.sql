-- Agrega estado de liquidacion de expensas por mes de vencimiento.
-- La pantalla de pendientes deja de depender de cargos pre-generados:
-- proyecta los vencimientos del contrato, mezcla cargos reales/pagos/expensas,
-- y materializa el alquiler al cobrar si todavia faltaba el item de renta.

create or replace function get_urban_billing(target_organization_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with leases as (
    select
      l.id as lease_id,
      l.unit_id,
      l.start_date,
      l.end_date,
      l.current_amount,
      l.currency,
      l.monthly_due_day,
      b.id as building_id,
      b.has_expenses as building_has_expenses,
      u.name as unit_name,
      b.name as building_name,
      c.first_name,
      c.last_name,
      c.business_name
    from urban_leases l
    join urban_units u on u.id = l.unit_id
    join urban_buildings b on b.id = u.building_id
    join contacts c on c.id = l.primary_tenant_contact_id
    where l.organization_id = target_organization_id
      and l.status in ('active', 'upcoming')
      and u.status <> 'archived'
      and b.status = 'active'
      and is_org_member(target_organization_id)
  ),
  lease_first_due as (
    select
      l.*,
      case
        when month_due < l.start_date then (month_due + interval '1 month')::date
        else month_due
      end as first_due_date
    from leases l
    cross join lateral (
      select make_date(
        extract(year from l.start_date)::int,
        extract(month from l.start_date)::int,
        least(l.monthly_due_day, 28)
      ) as month_due
    ) due
  ),
  expected_periods as (
    select
      lfd.*,
      generated_month::date as period_month,
      (generated_month::date + ((least(lfd.monthly_due_day, 28) - 1) * interval '1 day'))::date as due_date
    from lease_first_due lfd
    cross join lateral generate_series(
      date_trunc('month', lfd.first_due_date)::date,
      date_trunc('month', lfd.end_date)::date,
      interval '1 month'
    ) generated(generated_month)
    where lfd.first_due_date <= lfd.end_date
  ),
  item_totals as (
    select
      i.charge_id,
      coalesce(sum(i.amount_due) filter (where i.item_type = 'rent'), 0)::numeric(14, 2) as rent_amount,
      coalesce(sum(i.amount_due) filter (where i.item_type in ('building_expense', 'unit_expense')), 0)::numeric(14, 2) as expenses_amount,
      coalesce(sum(i.amount_due) filter (where i.item_type not in ('rent', 'building_expense', 'unit_expense')), 0)::numeric(14, 2) as other_amount,
      coalesce(sum(i.amount_due), 0)::numeric(14, 2) as stored_total_amount,
      max(i.currency) as currency
    from urban_charge_items i
    where i.organization_id = target_organization_id
    group by i.charge_id
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
      case
        when ch.status = 'cancelled' then ch.id::text
        when ch.id is not null and coalesce(it.rent_amount, 0) > 0 then ch.id::text
        else 'projected-' || ep.lease_id::text || '-' || ep.period_month::text
      end as id,
      ch.id as physical_charge_id,
      ep.lease_id,
      ep.unit_id,
      ep.building_id,
      ep.building_has_expenses,
      ep.unit_name,
      ep.building_name,
      ep.first_name,
      ep.last_name,
      ep.business_name,
      ep.period_month,
      ep.due_date,
      coalesce(ch.status, 'pending'::charge_status) as stored_status,
      coalesce(nullif(it.rent_amount, 0), ep.current_amount, 0)::numeric(14, 2) as rent_amount,
      coalesce(it.expenses_amount, 0)::numeric(14, 2) as expenses_amount,
      coalesce(it.other_amount, 0)::numeric(14, 2) as other_amount,
      coalesce(pt.paid_amount, 0)::numeric(14, 2) as paid_amount,
      eps.status as expense_period_status,
      coalesce(it.currency, ep.currency) as currency,
      (ch.id is null or coalesce(it.rent_amount, 0) <= 0) as projected
    from expected_periods ep
    left join urban_charges ch
      on ch.lease_id = ep.lease_id
     and ch.period_month = ep.period_month
     and ch.organization_id = target_organization_id
    left join item_totals it on it.charge_id = ch.id
    left join paid_totals pt on pt.charge_id = ch.id
    left join urban_expense_periods eps
      on eps.organization_id = target_organization_id
     and eps.building_id = ep.building_id
     and eps.period_month = ep.period_month
    where ep.due_date between ep.start_date and ep.end_date
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
        else cr.stored_status::text
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
      and is_org_member(target_organization_id)
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
            'canCancel', dr.display_status = 'pending' and dr.paid_amount <= 0
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
  );
$$;

create or replace function register_urban_payment(
  target_organization_id uuid,
  target_charge_id uuid default null,
  target_unit_id uuid default null,
  charge_due_date date default null,
  payment_date date default null,
  received_amount numeric default null,
  payment_currency char(3) default null,
  payment_method_text text default 'Transferencia',
  payment_notes text default null,
  rent_base numeric default 0,
  rent_surcharge numeric default 0,
  expenses_base numeric default 0,
  expense_surcharge numeric default 0,
  surcharge_waived boolean default false,
  operation_id uuid default gen_random_uuid()
)
returns urban_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  target_charge urban_charges;
  target_lease urban_leases;
  created_payment urban_payments;
  existing_payment urban_payments;
  method_value payment_method;
  remaining numeric(14, 2);
  item_record record;
  allocation_amount numeric(14, 2);
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
  request_hash text;
  previous_operation operation_results;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para registrar cobros.';
  end if;

  if payment_date is null then
    raise exception 'La fecha de cobro es obligatoria.';
  end if;

  if coalesce(received_amount, 0) <= 0 then
    raise exception 'El importe cobrado debe ser mayor a cero.';
  end if;

  if payment_currency not in ('ARS', 'USD') then
    raise exception 'La moneda del cobro no es valida.';
  end if;

  method_value := case lower(trim(coalesce(payment_method_text, '')))
    when 'transferencia' then 'transfer'::payment_method
    when 'efectivo' then 'cash'::payment_method
    when 'deposito' then 'deposit'::payment_method
    when 'depósito' then 'deposit'::payment_method
    when 'tarjeta' then 'card'::payment_method
    else 'other'::payment_method
  end;

  request_hash := md5(jsonb_build_object(
    'target_charge_id', target_charge_id,
    'target_unit_id', target_unit_id,
    'charge_due_date', charge_due_date,
    'payment_date', payment_date,
    'received_amount', received_amount,
    'payment_currency', payment_currency,
    'payment_method_text', payment_method_text,
    'rent_base', rent_base,
    'rent_surcharge', rent_surcharge,
    'expenses_base', expenses_base,
    'expense_surcharge', expense_surcharge,
    'surcharge_waived', surcharge_waived
  )::text);

  select *
    into previous_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = register_urban_payment.operation_id
  for update;

  if found then
    if previous_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if previous_operation.status = 'succeeded' then
      select *
        into existing_payment
      from urban_payments
      where id = previous_operation.result_entity_id;

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
    register_urban_payment.operation_id,
    'register_urban_payment',
    request_hash,
    'in_progress',
    auth.uid()
  );

  if target_charge_id is not null then
    select *
      into target_charge
    from urban_charges
    where id = target_charge_id
      and organization_id = target_organization_id
    for update;

    if not found then
      raise exception 'El cargo no existe.';
    end if;
  else
    target_charge := ensure_urban_charge(
      target_organization_id,
      target_unit_id,
      charge_due_date,
      rent_base,
      payment_currency
    );
  end if;

  select *
    into target_lease
  from urban_leases
  where id = target_charge.lease_id
    and organization_id = target_organization_id
  for update;

  if not found then
    raise exception 'El contrato asociado al cargo no existe.';
  end if;

  if exists (
    select 1
    from urban_charge_items i
    where i.charge_id = target_charge.id
      and i.currency <> payment_currency
  ) then
    raise exception 'La moneda del cobro no coincide con el cargo.';
  end if;

  if coalesce(rent_base, 0) > 0 and not exists (
    select 1
    from urban_charge_items
    where charge_id = target_charge.id
      and item_type = 'rent'
      and source_entity_type = 'urban_lease'
      and source_entity_id = target_charge.lease_id
  ) then
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
      target_charge.id,
      'rent',
      'Alquiler',
      rent_base,
      payment_currency,
      'urban_lease',
      target_charge.lease_id
    );
  end if;

  if expenses_base > 0 and not exists (
    select 1
    from urban_charge_items
    where charge_id = target_charge.id
      and item_type = 'building_expense'
      and source_entity_type = 'manual_payment_breakdown'
  ) then
    insert into urban_charge_items (
      organization_id,
      charge_id,
      item_type,
      description,
      amount_due,
      currency,
      source_entity_type
    )
    values (
      target_organization_id,
      target_charge.id,
      'building_expense',
      'Expensas',
      expenses_base,
      payment_currency,
      'manual_payment_breakdown'
    );
  end if;

  if rent_surcharge > 0 then
    insert into urban_charge_items (
      organization_id,
      charge_id,
      item_type,
      description,
      amount_due,
      currency,
      source_entity_type
    )
    values (
      target_organization_id,
      target_charge.id,
      'rent_surcharge',
      'Recargo alquiler',
      rent_surcharge,
      payment_currency,
      'payment_surcharge'
    );
  end if;

  if expense_surcharge > 0 then
    insert into urban_charge_items (
      organization_id,
      charge_id,
      item_type,
      description,
      amount_due,
      currency,
      source_entity_type
    )
    values (
      target_organization_id,
      target_charge.id,
      'expense_surcharge',
      'Recargo expensas',
      expense_surcharge,
      payment_currency,
      'payment_surcharge'
    );
  end if;

  select coalesce(sum(amount_due), 0)
    into total_due
  from urban_charge_items
  where charge_id = target_charge.id;

  select coalesce(sum(a.allocated_amount), 0)
    into total_paid
  from urban_payment_allocations a
  join urban_charge_items i on i.id = a.charge_item_id
  join urban_payments p on p.id = a.payment_id
  where i.charge_id = target_charge.id
    and p.status = 'valid';

  if total_paid + received_amount > total_due then
    raise exception 'El cobro supera el saldo pendiente.';
  end if;

  insert into urban_payments (
    organization_id,
    lease_id,
    unit_id,
    payment_date,
    received_amount,
    currency,
    payment_method,
    notes,
    operation_id,
    created_by
  )
  values (
    target_organization_id,
    target_charge.lease_id,
    target_charge.unit_id,
    payment_date,
    received_amount,
    payment_currency,
    method_value,
    nullif(trim(coalesce(payment_notes, '')), ''),
    register_urban_payment.operation_id,
    auth.uid()
  )
  returning * into created_payment;

  remaining := received_amount;

  for item_record in
    select
      i.id,
      i.amount_due,
      coalesce(sum(a.allocated_amount) filter (where p.status = 'valid'), 0) as already_allocated
    from urban_charge_items i
    left join urban_payment_allocations a on a.charge_item_id = i.id
    left join urban_payments p on p.id = a.payment_id
    where i.charge_id = target_charge.id
    group by i.id
    order by case i.item_type
      when 'building_expense' then 1
      when 'unit_expense' then 2
      when 'expense_surcharge' then 3
      when 'rent' then 4
      when 'rent_surcharge' then 5
      else 6
    end, i.created_at
  loop
    exit when remaining <= 0;

    allocation_amount := least(remaining, greatest(0, item_record.amount_due - item_record.already_allocated));

    if allocation_amount > 0 then
      insert into urban_payment_allocations (
        organization_id,
        payment_id,
        charge_item_id,
        allocated_amount,
        currency
      )
      values (
        target_organization_id,
        created_payment.id,
        item_record.id,
        allocation_amount,
        payment_currency
      );

      remaining := remaining - allocation_amount;
    end if;
  end loop;

  select coalesce(sum(a.allocated_amount), 0)
    into total_paid
  from urban_payment_allocations a
  join urban_charge_items i on i.id = a.charge_item_id
  join urban_payments p on p.id = a.payment_id
  where i.charge_id = target_charge.id
    and p.status = 'valid';

  update urban_charges
  set status = case
    when total_paid >= total_due and total_due > 0 then 'paid'::charge_status
    when total_paid > 0 then 'partial'::charge_status
    else 'pending'::charge_status
  end
  where id = target_charge.id;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    register_urban_payment.operation_id,
    'urban_payment_registered',
    'urban_payment',
    created_payment.id,
    to_jsonb(created_payment)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'urban_payment',
    result_entity_id = created_payment.id,
    result_payload = jsonb_build_object(
      'payment_id', created_payment.id,
      'charge_id', target_charge.id
    ),
    completed_at = now()
  where operation_results.organization_id = target_organization_id
    and operation_results.operation_id = register_urban_payment.operation_id;

  return created_payment;
end;
$$;
