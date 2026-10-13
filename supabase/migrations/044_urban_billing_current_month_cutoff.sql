-- Limita la proyeccion de cobros urbanos al mes actual en adelante.
-- Esto permite cargar contratos historicos sin mostrar pendientes viejos desde 2024.

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
      greatest(
        date_trunc('month', lfd.first_due_date)::date,
        date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date
      ),
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
      (ep.period_month - interval '1 month')::date as expense_period_month,
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
     and eps.period_month = (ep.period_month - interval '1 month')::date
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
