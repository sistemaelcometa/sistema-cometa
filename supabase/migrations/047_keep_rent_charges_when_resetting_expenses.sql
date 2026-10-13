-- Evita que "volver atras" una liquidacion de expensas o recalcularla oculte el cobro mensual.
-- Si al limpiar expensas el cargo queda sin items fisicos, debe volver a pendiente para que
-- get_urban_billing pueda proyectar el alquiler vigente, no quedar cancelado.

create or replace function cleanup_urban_expense_period_allocations(
  target_organization_id uuid,
  target_period_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  affected_charge_id uuid;
  affected_charge_ids uuid[] := '{}';
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para recalcular expensas.';
  end if;

  select coalesce(array_agg(distinct ci.charge_id), '{}')
    into affected_charge_ids
  from urban_expense_allocations a
  join urban_charge_items ci on ci.id = a.charge_item_id
  where a.period_id = target_period_id
    and a.organization_id = target_organization_id;

  delete from urban_charge_items i
  using urban_expense_allocations a
  where a.charge_item_id = i.id
    and a.period_id = target_period_id
    and a.organization_id = target_organization_id
    and i.item_type in ('building_expense', 'unit_expense')
    and not exists (
      select 1
      from urban_payment_allocations pa
      where pa.charge_item_id = i.id
    );

  delete from urban_expense_allocations a
  where a.period_id = target_period_id
    and a.organization_id = target_organization_id
    and (
      a.charge_item_id is null
      or not exists (
        select 1
        from urban_payment_allocations pa
        where pa.charge_item_id = a.charge_item_id
      )
    );

  foreach affected_charge_id in array affected_charge_ids
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

  update urban_expense_periods
  set status = 'draft'
  where id = target_period_id
    and organization_id = target_organization_id
    and status <> 'closed';
end;
$$;

-- Repara cargos actuales/futuros que pudieron quedar cancelados solo por volver atras expensas.
update urban_charges ch
set status = 'pending'::charge_status
from urban_leases l
where ch.lease_id = l.id
  and ch.organization_id = l.organization_id
  and ch.status = 'cancelled'
  and ch.period_month >= date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date
  and l.status in ('active', 'upcoming')
  and not exists (
    select 1
    from urban_charge_items ci
    join urban_payment_allocations pa on pa.charge_item_id = ci.id
    join urban_payments p on p.id = pa.payment_id
    where ci.charge_id = ch.id
      and p.status = 'valid'
  );
