-- Cualquier cobro mensual valido bloquea las expensas del mes anterior
-- para TODO el edificio, aunque el cobro solo incluya alquiler.
-- Si se anulan todos esos cobros, vuelve a permitirse deshacer la liquidacion.
-- No borra gastos, liquidaciones, pagos ni imputaciones.
begin;

create or replace function urban_expense_period_has_valid_payments(
  target_organization_id uuid, target_building_id uuid, target_period_month date
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from urban_units u
    join urban_charges ch on ch.unit_id = u.id and ch.organization_id = u.organization_id
    join urban_charge_items ci on ci.charge_id = ch.id and ci.organization_id = ch.organization_id
    join urban_payment_allocations pa on pa.charge_item_id = ci.id and pa.organization_id = ci.organization_id
    join urban_payments pay on pay.id = pa.payment_id and pay.organization_id = pa.organization_id
    where u.organization_id = target_organization_id
      and u.building_id = target_building_id
      and ch.period_month = (target_period_month + interval '1 month')::date
      and pay.status = 'valid' and pa.allocated_amount > 0
  );
$$;

-- El mismo bloqueo serializa cobros y cambios del periodo, incluso si esta en cero.
create or replace function lock_urban_expense_billing_month(
  target_organization_id uuid, target_building_id uuid, target_period_month date
)
returns void
language sql
security definer
set search_path = public
as $$
  select pg_advisory_xact_lock(hashtextextended(
    target_organization_id::text || ':' || target_building_id::text || ':' || target_period_month::text, 0
  ));
$$;

create or replace function assert_urban_expense_period_unpaid(target_organization_id uuid, target_period_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record urban_expense_periods;
begin
  select * into period_record from urban_expense_periods
  where id = target_period_id and organization_id = target_organization_id;
  if not found then
    raise exception 'La liquidacion no existe en esta organizacion.';
  end if;
  perform lock_urban_expense_billing_month(target_organization_id, period_record.building_id, period_record.period_month);
  if urban_expense_period_has_valid_payments(target_organization_id, period_record.building_id, period_record.period_month) then
    raise exception 'No se puede modificar esta liquidacion: ya hay un cobro registrado de un departamento del edificio para ese mes.';
  end if;
end;
$$;

create or replace function refresh_urban_expense_period_payment_lock(target_period_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record urban_expense_periods;
  has_payments boolean;
  next_status expense_period_status;
begin
  select * into period_record from urban_expense_periods where id = target_period_id;
  if not found or period_record.status = 'cancelled' then return; end if;
  perform lock_urban_expense_billing_month(period_record.organization_id, period_record.building_id, period_record.period_month);
  has_payments := urban_expense_period_has_valid_payments(period_record.organization_id, period_record.building_id, period_record.period_month);
  next_status := case when has_payments then 'closed'::expense_period_status
    when period_record.status = 'closed' then 'calculated'::expense_period_status
    else period_record.status end;
  update urban_expense_periods
  set status = next_status,
    closed_at = case when has_payments then coalesce(closed_at, now()) else null end,
    closed_by = case when has_payments then coalesce(closed_by, auth.uid()) else null end,
    updated_at = now()
  where id = target_period_id and status is distinct from next_status;
end;
$$;

create or replace function lock_expense_month_from_payment_allocation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record record;
begin
  for period_record in
    select distinct ch.organization_id, u.building_id,
      (ch.period_month - interval '1 month')::date as expense_month
    from urban_charge_items ci
    join urban_charges ch on ch.id = ci.charge_id
    join urban_units u on u.id = ch.unit_id
    where ci.id in (
      case when tg_op <> 'DELETE' then new.charge_item_id end,
      case when tg_op <> 'INSERT' then old.charge_item_id end
    )
    order by ch.organization_id, u.building_id, expense_month
  loop
    perform lock_urban_expense_billing_month(period_record.organization_id, period_record.building_id, period_record.expense_month);
  end loop;
  return coalesce(new, old);
end;
$$;

create or replace function sync_urban_expense_period_payment_lock_from_allocation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record record;
begin
  for period_record in
    select distinct p.id
    from urban_charge_items ci
    join urban_charges ch on ch.id = ci.charge_id
    join urban_units u on u.id = ch.unit_id
    join urban_expense_periods p on p.organization_id = ch.organization_id
      and p.building_id = u.building_id
      and p.period_month = (ch.period_month - interval '1 month')::date
    where ci.id in (
      case when tg_op <> 'DELETE' then new.charge_item_id end,
      case when tg_op <> 'INSERT' then old.charge_item_id end
    )
  loop
    perform refresh_urban_expense_period_payment_lock(period_record.id);
  end loop;
  return coalesce(new, old);
end;
$$;

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
    select distinct ch.organization_id, u.building_id,
      (ch.period_month - interval '1 month')::date as expense_month
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    join urban_charges ch on ch.id = ci.charge_id
    join urban_units u on u.id = ch.unit_id
    where pa.payment_id = new.id and ch.organization_id = new.organization_id
    order by ch.organization_id, u.building_id, expense_month
  loop
    perform lock_urban_expense_billing_month(period_record.organization_id, period_record.building_id, period_record.expense_month);
    if tg_when = 'AFTER' then
      perform refresh_urban_expense_period_payment_lock(p.id)
      from urban_expense_periods p
      where p.organization_id = period_record.organization_id
        and p.building_id = period_record.building_id
        and p.period_month = period_record.expense_month;
    end if;
  end loop;
  return new;
end;
$$;

create or replace function guard_urban_expense_period_payment_lock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform assert_urban_expense_period_unpaid(old.organization_id, old.id);
    return old;
  end if;
  if tg_op = 'UPDATE' then
    perform assert_urban_expense_period_unpaid(old.organization_id, old.id)
    where new.building_id is distinct from old.building_id
      or new.organization_id is distinct from old.organization_id
      or new.period_month is distinct from old.period_month;
  end if;
  perform lock_urban_expense_billing_month(new.organization_id, new.building_id, new.period_month);
  if urban_expense_period_has_valid_payments(new.organization_id, new.building_id, new.period_month) then
    if tg_op = 'UPDATE' and new.status in ('draft', 'cancelled') then
      raise exception 'No se puede volver atras esta liquidacion porque ya tiene cobros registrados en el edificio.';
    end if;
    new.status := 'closed';
    new.closed_at := coalesce(new.closed_at, now());
    new.closed_by := coalesce(new.closed_by, auth.uid());
  end if;
  return new;
end;
$$;

create or replace function guard_urban_expense_exclusion_payment_lock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  expense_record record;
begin
  for expense_record in
    select e.organization_id, e.period_id, p.status
    from urban_expense_items e
    join urban_expense_periods p on p.id = e.period_id
    where e.id in (
      case when tg_op <> 'DELETE' then new.expense_item_id end,
      case when tg_op <> 'INSERT' then old.expense_item_id end
    )
  loop
    perform assert_urban_expense_period_unpaid(expense_record.organization_id, expense_record.period_id);
    if expense_record.status <> 'draft' then
      raise exception 'La liquidacion ya esta calculada. Volve atras antes de modificar departamentos excluidos.';
    end if;
  end loop;
  return coalesce(new, old);
end;
$$;

create or replace function guard_urban_expense_item_payment_lock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  period_record urban_expense_periods;
  expense_period_id uuid;
  expense_org uuid;
begin
  if tg_op <> 'INSERT' then
    perform assert_urban_expense_period_unpaid(old.organization_id, old.period_id);
  end if;
  expense_period_id := case when tg_op = 'DELETE' then old.period_id else new.period_id end;
  expense_org := case when tg_op = 'DELETE' then old.organization_id else new.organization_id end;
  perform assert_urban_expense_period_unpaid(expense_org, expense_period_id);
  select * into period_record from urban_expense_periods where id = expense_period_id;
  if period_record.status <> 'draft' then
    raise exception 'La liquidacion ya esta calculada. Volve atras antes de modificar gastos.';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists lock_expense_month_before_payment_allocation on urban_payment_allocations;
create trigger lock_expense_month_before_payment_allocation
before insert or update or delete on urban_payment_allocations
for each row execute function lock_expense_month_from_payment_allocation();

drop trigger if exists sync_urban_expense_period_payment_lock_after_allocation_change on urban_payment_allocations;
create trigger sync_urban_expense_period_payment_lock_after_allocation_change
after insert or update or delete on urban_payment_allocations
for each row execute function sync_urban_expense_period_payment_lock_from_allocation();

drop trigger if exists lock_expense_month_before_payment_status on urban_payments;
create trigger lock_expense_month_before_payment_status
before update of status on urban_payments
for each row execute function sync_urban_expense_period_payment_lock_from_payment();

drop trigger if exists sync_urban_expense_period_payment_lock_after_payment_status on urban_payments;
create trigger sync_urban_expense_period_payment_lock_after_payment_status
after update of status on urban_payments
for each row execute function sync_urban_expense_period_payment_lock_from_payment();

drop trigger if exists guard_urban_expense_period_payment_lock_before_change on urban_expense_periods;
create trigger guard_urban_expense_period_payment_lock_before_change
before insert or update or delete on urban_expense_periods
for each row execute function guard_urban_expense_period_payment_lock();

drop trigger if exists guard_urban_expense_item_payment_lock_before_change on urban_expense_items;
create trigger guard_urban_expense_item_payment_lock_before_change
before insert or update or delete on urban_expense_items
for each row execute function guard_urban_expense_item_payment_lock();

drop trigger if exists guard_urban_expense_exclusion_payment_lock_before_change on urban_expense_item_excluded_units;
create trigger guard_urban_expense_exclusion_payment_lock_before_change
before insert or update or delete on urban_expense_item_excluded_units
for each row execute function guard_urban_expense_exclusion_payment_lock();

revoke all on function urban_expense_period_has_valid_payments(uuid,uuid,date) from public;
revoke all on function lock_urban_expense_billing_month(uuid,uuid,date) from public;
revoke all on function assert_urban_expense_period_unpaid(uuid,uuid) from public;

-- Las siguientes funciones existentes tambien comprueban el nuevo bloqueo.

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

  perform assert_urban_expense_period_unpaid(target_organization_id, target_period_id);

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

  perform assert_urban_expense_period_unpaid(target_organization_id, target_period.id);

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

-- Repara el estado de bloqueo de los periodos existentes, sin recalcularlos.
do $$
declare
  period_record record;
begin
  for period_record in select id from urban_expense_periods where status <> 'cancelled'
  loop
    perform refresh_urban_expense_period_payment_lock(period_record.id);
  end loop;
end;
$$;

commit;

