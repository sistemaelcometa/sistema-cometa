-- Corrige la reconciliacion de expensas con cobros:
-- un item de expensa calculada solo es valido si esta pegado al cargo del mes
-- que corresponde cobrar. Antes podia aceptar un charge_item_id viejo del mismo
-- contrato/departamento aunque perteneciera a otro periodo, dejando el mes real
-- con expensas en cero.

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
      coalesce(l.monthly_due_day, 10) as monthly_due_day,
      l.id as lease_id
    from urban_expense_allocations a
    join urban_expense_items i on i.id = a.expense_item_id
    join urban_expense_periods p on p.id = a.period_id
    join urban_leases l
      on l.unit_id = a.unit_id
     and l.organization_id = a.organization_id
     and l.status = 'active'
     and (p.period_month + interval '1 month')::date between date_trunc('month', l.start_date)::date and date_trunc('month', l.end_date)::date
     and p.period_month >= date_trunc('month', l.start_date)::date
    where a.organization_id = target_organization_id
      and a.period_id = target_period_id
      and a.transfer_to_tenant
      and a.tenant_amount > 0
      and i.status = 'valid'
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
      (
        allocation_record.charge_month
        + ((least(coalesce(allocation_record.monthly_due_day, 10), 28) - 1) * interval '1 day')
      )::date,
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
