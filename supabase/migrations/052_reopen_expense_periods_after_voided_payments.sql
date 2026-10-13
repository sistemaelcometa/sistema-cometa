-- Si se anulan todos los cobros imputados a una liquidacion de expensas,
-- la liquidacion debe poder volver atras. El bloqueo queda atado a cobros validos.

create or replace function refresh_urban_expense_period_payment_lock(target_period_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if target_period_id is null then
    return;
  end if;

  update urban_expense_periods p
  set status = case
      when exists (
        select 1
        from urban_expense_allocations a
        join urban_payment_allocations pa on pa.charge_item_id = a.charge_item_id
        join urban_payments pay on pay.id = pa.payment_id
        where a.period_id = p.id
          and a.organization_id = p.organization_id
          and pay.status = 'valid'
      ) then 'closed'::expense_period_status
      when p.status = 'closed' then 'calculated'::expense_period_status
      else p.status
    end,
    closed_at = case
      when exists (
        select 1
        from urban_expense_allocations a
        join urban_payment_allocations pa on pa.charge_item_id = a.charge_item_id
        join urban_payments pay on pay.id = pa.payment_id
        where a.period_id = p.id
          and a.organization_id = p.organization_id
          and pay.status = 'valid'
      ) then coalesce(p.closed_at, now())
      when p.status = 'closed' then null
      else p.closed_at
    end,
    closed_by = case
      when exists (
        select 1
        from urban_expense_allocations a
        join urban_payment_allocations pa on pa.charge_item_id = a.charge_item_id
        join urban_payments pay on pay.id = pa.payment_id
        where a.period_id = p.id
          and a.organization_id = p.organization_id
          and pay.status = 'valid'
      ) then coalesce(p.closed_by, auth.uid())
      when p.status = 'closed' then null
      else p.closed_by
    end,
    updated_at = now()
  where p.id = target_period_id;
end;
$$;

create or replace function sync_urban_expense_period_payment_lock_from_allocation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  changed_period_id uuid;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    select a.period_id
      into changed_period_id
    from urban_expense_allocations a
    where a.charge_item_id = new.charge_item_id
      and a.organization_id = new.organization_id
    limit 1;

    perform refresh_urban_expense_period_payment_lock(changed_period_id);
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    select a.period_id
      into changed_period_id
    from urban_expense_allocations a
    where a.charge_item_id = old.charge_item_id
      and a.organization_id = old.organization_id
    limit 1;

    perform refresh_urban_expense_period_payment_lock(changed_period_id);
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists close_urban_expense_period_on_payment_allocation_after_change on urban_payment_allocations;
drop trigger if exists sync_urban_expense_period_payment_lock_after_allocation_change on urban_payment_allocations;

create trigger sync_urban_expense_period_payment_lock_after_allocation_change
after insert or update or delete on urban_payment_allocations
for each row
execute function sync_urban_expense_period_payment_lock_from_allocation();

create or replace function sync_urban_expense_period_payment_lock_from_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record record;
begin
  for period_record in
    select distinct a.period_id
    from urban_payment_allocations pa
    join urban_expense_allocations a on a.charge_item_id = pa.charge_item_id
    where pa.payment_id = new.id
      and pa.organization_id = new.organization_id
  loop
    perform refresh_urban_expense_period_payment_lock(period_record.period_id);
  end loop;

  return new;
end;
$$;

drop trigger if exists sync_urban_expense_period_payment_lock_after_payment_status on urban_payments;

create trigger sync_urban_expense_period_payment_lock_after_payment_status
after update of status on urban_payments
for each row
execute function sync_urban_expense_period_payment_lock_from_payment();

create or replace function reset_urban_expense_period(
  target_organization_id uuid,
  target_building_id uuid,
  period_month date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reset_period_month date := date_trunc('month', reset_urban_expense_period.period_month)::date;
  target_period urban_expense_periods;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para volver atras la liquidacion de expensas.';
  end if;

  if reset_urban_expense_period.period_month is null
     or reset_urban_expense_period.period_month <> reset_period_month then
    raise exception 'El periodo debe ser el primer dia del mes.';
  end if;

  select *
    into target_period
  from urban_expense_periods
  where organization_id = target_organization_id
    and building_id = target_building_id
    and urban_expense_periods.period_month = reset_period_month
  for update;

  if not found then
    return jsonb_build_object(
      'status', 'missing',
      'periodMonth', reset_period_month
    );
  end if;

  perform refresh_urban_expense_period_payment_lock(target_period.id);

  if exists (
    select 1
    from urban_expense_allocations a
    join urban_payment_allocations pa on pa.charge_item_id = a.charge_item_id
    join urban_payments pay on pay.id = pa.payment_id
    where a.period_id = target_period.id
      and a.organization_id = target_organization_id
      and pay.status = 'valid'
  ) then
    raise exception 'No se puede volver atras esta liquidacion porque ya tiene cobros registrados.';
  end if;

  perform cleanup_urban_expense_period_allocations(target_organization_id, target_period.id);

  update urban_expense_periods
  set status = 'draft'::expense_period_status,
      closed_at = null,
      closed_by = null,
      updated_at = now()
  where id = target_period.id;

  return jsonb_build_object(
    'status', 'draft',
    'periodId', target_period.id,
    'periodMonth', reset_period_month
  );
end;
$$;

update urban_expense_periods p
set status = 'calculated'::expense_period_status,
    closed_at = null,
    closed_by = null,
    updated_at = now()
where p.status = 'closed'
  and not exists (
    select 1
    from urban_expense_allocations a
    join urban_payment_allocations pa on pa.charge_item_id = a.charge_item_id
    join urban_payments pay on pay.id = pa.payment_id
    where a.period_id = p.id
      and a.organization_id = p.organization_id
      and pay.status = 'valid'
  );
