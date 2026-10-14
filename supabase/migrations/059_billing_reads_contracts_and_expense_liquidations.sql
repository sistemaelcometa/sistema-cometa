-- Reordena la lectura de cobros urbanos.
-- Fuente de verdad:
-- - alquiler: contrato vigente del cargo mensual;
-- - expensas: liquidacion calculada/cerrada del mes anterior;
-- - pagos: dinero registrado e imputado.
--
-- La tabla de cobros deja de depender de urban_charge_items para mostrar
-- el importe de expensas. Esos items quedan como soporte de imputacion.

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
        when b.has_expenses is false then 0::numeric(14, 2)
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
