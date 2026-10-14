-- Evita que la sincronizacion de cobros escriba filas sin cambios reales.
-- Antes, cada lectura de cobros podia actualizar updated_at y disparar realtime
-- en loop, mostrando "Sincronizando datos..." intermitente.

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
  next_status charge_status;
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

  next_status := case
    when total_due > 0 and total_paid >= total_due then 'paid'::charge_status
    when total_paid > 0 then 'partial'::charge_status
    else 'pending'::charge_status
  end;

  update urban_charges
  set
    status = next_status,
    updated_at = now()
  where id = target_charge_id
    and organization_id = target_organization_id
    and status <> 'cancelled'::charge_status
    and status is distinct from next_status;
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
    where urban_charges.due_date is distinct from excluded.due_date
       or urban_charges.status = 'cancelled'::charge_status
    returning * into ensured_charge;

    if not found then
      select *
        into ensured_charge
      from urban_charges
      where organization_id = target_organization_id
        and lease_id = period_record.lease_id
        and period_month = period_record.period_month;
    end if;

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
        and (
          description is distinct from 'Alquiler'
          or amount_due is distinct from period_record.current_amount
          or currency is distinct from period_record.currency
          or source_entity_type is distinct from 'urban_lease'
          or source_entity_id is distinct from period_record.lease_id
        )
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
