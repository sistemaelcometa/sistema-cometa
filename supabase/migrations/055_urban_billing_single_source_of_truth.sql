-- Ordena la logica de cobros urbanos:
-- 1) los contratos activos generan cargos reales desde el mes actual en adelante,
-- 2) las expensas liquidadas se reconcilian contra esos cargos reales,
-- 3) la pantalla de cobros lee cargos fisicos, sin proyecciones invisibles.

create or replace function can_manage_urban_billing_sync(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    (
      auth.uid() is null
      and
      nullif(current_setting('request.jwt.claim.role', true), '') is null
      and current_user in ('postgres', 'supabase_admin', 'service_role')
    )
    or (
      auth.uid() is not null
      and has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[])
    );
$$;

create or replace function can_read_urban_billing_sync(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    (
      auth.uid() is null
      and
      nullif(current_setting('request.jwt.claim.role', true), '') is null
      and current_user in ('postgres', 'supabase_admin', 'service_role')
    )
    or (
      auth.uid() is not null
      and is_org_member(target_organization_id)
    );
$$;

create or replace function recalculate_urban_charge_status(
  target_organization_id uuid,
  target_charge_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
begin
  if not can_manage_urban_billing_sync(target_organization_id) then
    raise exception 'No tenes permisos para recalcular cargos.';
  end if;

  select coalesce(sum(amount_due), 0)
    into total_due
  from urban_charge_items
  where organization_id = target_organization_id
    and charge_id = target_charge_id;

  select coalesce(sum(pa.allocated_amount), 0)
    into total_paid
  from urban_payment_allocations pa
  join urban_charge_items ci on ci.id = pa.charge_item_id
  join urban_payments pay on pay.id = pa.payment_id
  where ci.organization_id = target_organization_id
    and ci.charge_id = target_charge_id
    and pay.status = 'valid';

  update urban_charges
  set status = case
      when total_due > 0 and total_paid >= total_due then 'paid'::charge_status
      when total_paid > 0 then 'partial'::charge_status
      else 'pending'::charge_status
    end,
    updated_at = now()
  where id = target_charge_id
    and organization_id = target_organization_id
    and status <> 'cancelled'::charge_status;
end;
$$;

create or replace function sync_urban_lease_charges(target_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record record;
  ensured_charge urban_charges;
  rent_item_id uuid;
begin
  if not can_manage_urban_billing_sync(target_organization_id) then
    raise exception 'No tenes permisos para sincronizar cobros.';
  end if;

  for period_record in
    with leases as (
      select
        l.id as lease_id,
        l.unit_id,
        l.start_date,
        l.end_date,
        l.current_amount,
        l.currency,
        l.monthly_due_day
      from urban_leases l
      join urban_units u on u.id = l.unit_id
      join urban_buildings b on b.id = u.building_id
      where l.organization_id = target_organization_id
        and l.status in ('active', 'upcoming')
        and u.status <> 'archived'
        and b.status = 'active'
    ),
    first_due as (
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
    )
    select
      fd.*,
      generated_month::date as period_month,
      (generated_month::date + ((least(fd.monthly_due_day, 28) - 1) * interval '1 day'))::date as due_date
    from first_due fd
    cross join lateral generate_series(
      greatest(
        date_trunc('month', fd.first_due_date)::date,
        date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date
      ),
      date_trunc('month', fd.end_date)::date,
      interval '1 month'
    ) generated(generated_month)
    where fd.first_due_date <= fd.end_date
      and (generated_month::date + ((least(fd.monthly_due_day, 28) - 1) * interval '1 day'))::date between fd.start_date and fd.end_date
  loop
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
      period_record.lease_id,
      period_record.unit_id,
      period_record.period_month,
      period_record.due_date,
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
      into rent_item_id
    from urban_charge_items ci
    where ci.organization_id = target_organization_id
      and ci.charge_id = ensured_charge.id
      and ci.item_type = 'rent'
    order by
      case when ci.source_entity_type in ('urban_lease', 'urban_lease_monthly_rent') then 0 else 1 end,
      ci.created_at
    limit 1;

    if rent_item_id is null then
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
        'rent',
        'Alquiler',
        period_record.current_amount,
        period_record.currency,
        'urban_lease',
        period_record.lease_id
      )
      returning id into rent_item_id;
    else
      update urban_charge_items
      set
        description = 'Alquiler',
        amount_due = period_record.current_amount,
        currency = period_record.currency,
        source_entity_type = 'urban_lease',
        source_entity_id = period_record.lease_id
      where id = rent_item_id
        and not exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = rent_item_id
            and pay.status = 'valid'
        );
    end if;

    delete from urban_charge_items duplicate_rent
    where duplicate_rent.organization_id = target_organization_id
      and duplicate_rent.charge_id = ensured_charge.id
      and duplicate_rent.item_type = 'rent'
      and duplicate_rent.id <> rent_item_id
      and not exists (
        select 1
        from urban_payment_allocations pa
        join urban_payments pay on pay.id = pa.payment_id
        where pa.charge_item_id = duplicate_rent.id
          and pay.status = 'valid'
      );

    perform recalculate_urban_charge_status(target_organization_id, ensured_charge.id);
  end loop;
end;
$$;

create or replace function sync_urban_expense_charges(target_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record record;
begin
  if not can_manage_urban_billing_sync(target_organization_id) then
    raise exception 'No tenes permisos para sincronizar expensas.';
  end if;

  for period_record in
    select id
    from urban_expense_periods
    where organization_id = target_organization_id
      and status in ('calculated', 'closed')
  loop
    perform reconcile_urban_expense_period_charges(target_organization_id, period_record.id);
  end loop;
end;
$$;

create or replace function sync_urban_billing(target_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not can_manage_urban_billing_sync(target_organization_id) then
    raise exception 'No tenes permisos para sincronizar cobros.';
  end if;

  perform sync_urban_lease_charges(target_organization_id);
  perform sync_urban_expense_charges(target_organization_id);
end;
$$;

create or replace function prevent_duplicate_manual_expense_breakdown()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.item_type in ('building_expense', 'unit_expense')
     and new.source_entity_type = 'manual_payment_breakdown'
     and exists (
       select 1
       from urban_charge_items existing_item
       where existing_item.organization_id = new.organization_id
         and existing_item.charge_id = new.charge_id
         and existing_item.item_type in ('building_expense', 'unit_expense')
         and existing_item.source_entity_type = 'urban_expense_allocation'
     ) then
    return null;
  end if;

  return new;
end;
$$;

drop trigger if exists prevent_duplicate_manual_expense_breakdown_before_insert on urban_charge_items;

create trigger prevent_duplicate_manual_expense_breakdown_before_insert
before insert on urban_charge_items
for each row
execute function prevent_duplicate_manual_expense_breakdown();

delete from urban_charge_items manual_item
where manual_item.source_entity_type = 'manual_payment_breakdown'
  and manual_item.item_type in ('building_expense', 'unit_expense')
  and exists (
    select 1
    from urban_charge_items real_item
    where real_item.organization_id = manual_item.organization_id
      and real_item.charge_id = manual_item.charge_id
      and real_item.item_type in ('building_expense', 'unit_expense')
      and real_item.source_entity_type = 'urban_expense_allocation'
  )
  and not exists (
    select 1
    from urban_payment_allocations pa
    where pa.charge_item_id = manual_item.id
  );

update urban_charge_items manual_item
set
  description = 'Expensas duplicadas por cobro manual',
  amount_due = 0
where manual_item.source_entity_type = 'manual_payment_breakdown'
  and manual_item.item_type in ('building_expense', 'unit_expense')
  and exists (
    select 1
    from urban_charge_items real_item
    where real_item.organization_id = manual_item.organization_id
      and real_item.charge_id = manual_item.charge_id
      and real_item.item_type in ('building_expense', 'unit_expense')
      and real_item.source_entity_type = 'urban_expense_allocation'
  )
  and not exists (
    select 1
    from urban_payment_allocations pa
    join urban_payments pay on pay.id = pa.payment_id
    where pa.charge_item_id = manual_item.id
      and pay.status = 'valid'
  );

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
    perform sync_urban_billing(target_organization_id);
  end if;

  with item_totals as (
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
      (ch.period_month - interval '1 month')::date as expense_period_month,
      ch.due_date,
      ch.status as stored_status,
      coalesce(it.rent_amount, 0)::numeric(14, 2) as rent_amount,
      coalesce(it.expenses_amount, 0)::numeric(14, 2) as expenses_amount,
      coalesce(it.other_amount, 0)::numeric(14, 2) as other_amount,
      coalesce(pt.paid_amount, 0)::numeric(14, 2) as paid_amount,
      eps.status as expense_period_status,
      coalesce(it.currency, l.currency) as currency,
      false as projected
    from urban_charges ch
    join urban_leases l on l.id = ch.lease_id
    join urban_units u on u.id = ch.unit_id
    join urban_buildings b on b.id = u.building_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join item_totals it on it.charge_id = ch.id
    left join paid_totals pt on pt.charge_id = ch.id
    left join urban_expense_periods eps
      on eps.organization_id = target_organization_id
     and eps.building_id = b.id
     and eps.period_month = (ch.period_month - interval '1 month')::date
    where ch.organization_id = target_organization_id
      and l.organization_id = target_organization_id
      and l.status in ('active', 'upcoming')
      and u.status <> 'archived'
      and b.status = 'active'
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

do $$
declare
  org_record record;
begin
  for org_record in
    select id
    from organizations
  loop
    perform sync_urban_billing(org_record.id);
  end loop;
end;
$$;
