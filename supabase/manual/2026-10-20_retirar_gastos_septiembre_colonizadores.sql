-- Correccion unica solicitada: estos cuatro gastos pertenecen a octubre,
-- donde YA estan cargados. Se archivan solo los de septiembre de COLONIZADORES.
-- Ejecutar como postgres desde SQL Editor, despues del SQL 067.
-- No reabre periodos ni elimina pagos, imputaciones o comprobantes.
begin;

-- Impide escrituras concurrentes durante la excepcion administrativa.
lock table urban_expense_items, urban_expense_periods, urban_expense_allocations,
  urban_charge_items, urban_charges, urban_payments, urban_payment_allocations
  in share row exclusive mode;

do $$
declare
  target_org constant uuid := '98a857e1-dacc-4890-90e9-1f1ac8de9782';
  repair_reason constant text := 'Correccion unica: gasto de octubre cargado tambien en septiembre 2026';
  target_building uuid;
  september_period uuid;
  october_period uuid;
  expense_ids uuid[];
  charge_item_ids uuid[];
  charge_record record;
  payments_before jsonb;
  allocations_before jsonb;
  october_before jsonb;
  september_before jsonb;
  changed_count integer;
begin
  if current_user not in ('postgres', 'supabase_admin') then
    raise exception 'Ejecutar esta correccion desde SQL Editor como postgres.';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'urban_expense_items'::regclass
      and tgname = 'guard_urban_expense_item_payment_lock_before_change'
      and tgenabled = 'O'
  ) then
    raise exception 'Primero ejecuta el SQL 067. No se modifico nada.';
  end if;

  select b.id into strict target_building from urban_buildings b
  where b.organization_id = target_org and upper(trim(b.name)) = 'COLONIZADORES'
    and b.status = 'active';
  select p.id into strict september_period from urban_expense_periods p
  where p.organization_id = target_org and p.building_id = target_building
    and p.period_month = date '2026-09-01' and p.status <> 'cancelled';
  select p.id into strict october_period from urban_expense_periods p
  where p.organization_id = target_org and p.building_id = target_building
    and p.period_month = date '2026-10-01' and p.status <> 'cancelled';

  if (select count(*) from urban_expense_items e
      where e.period_id = september_period and e.organization_id = target_org
        and (e.status = 'valid' or (e.status = 'voided' and e.void_reason = repair_reason))) <> 4
    or (select count(distinct lower(trim(e.description))) from urban_expense_items e
        where e.period_id = september_period and e.organization_id = target_org
          and (e.status = 'valid' or (e.status = 'voided' and e.void_reason = repair_reason))) <> 4
    or exists (
      select 1 from urban_expense_items e
      where e.period_id = september_period and e.organization_id = target_org
        and (e.status = 'valid' or (e.status = 'voided' and e.void_reason = repair_reason))
        and not exists (
          select 1 from (values
            ('Seguros - Seguro', 6094::numeric), ('Servicios - AMOS', 11594::numeric),
            ('Impuestos - Provincial', 10950::numeric), ('Impuestos - Municipal', 53247::numeric)
          ) expected(description, amount)
          where lower(trim(e.description)) = lower(expected.description)
            and e.amount = expected.amount and e.currency = 'ARS'
        )
    ) then
    raise exception 'Los gastos de septiembre no coinciden con los cuatro informados. No se modifico nada.';
  end if;

  select array_agg(e.id order by e.id), jsonb_agg(to_jsonb(e) order by e.id)
    into expense_ids, september_before
  from urban_expense_items e where e.period_id = september_period
    and (e.status = 'valid' or (e.status = 'voided' and e.void_reason = repair_reason));

  if exists (
    select 1 from urban_expense_items old_expense where old_expense.id = any(expense_ids)
      and (select count(*) from urban_expense_items replacement
        where replacement.organization_id = target_org and replacement.period_id = october_period
          and replacement.status = 'valid'
          and lower(trim(replacement.description)) = lower(trim(old_expense.description))
          and replacement.amount = old_expense.amount and replacement.currency = old_expense.currency
          and replacement.transfer_to_tenant = old_expense.transfer_to_tenant) <> 1
  ) then
    raise exception 'Falta una copia unica en octubre de alguno de estos gastos. No se modifico nada.';
  end if;

  select coalesce(array_agg(distinct ci.id), '{}'::uuid[]) into charge_item_ids
  from urban_expense_allocations a
  join urban_charge_items ci on ci.id = a.charge_item_id
    or (ci.source_entity_type = 'urban_expense_allocation' and ci.source_entity_id = a.id)
  where a.organization_id = target_org and a.period_id = september_period
    and a.expense_item_id = any(expense_ids) and ci.organization_id = target_org;

  if exists (
    select 1 from urban_payment_allocations pa
    join urban_payments pay on pay.id = pa.payment_id
    where pa.charge_item_id = any(charge_item_ids)
      and pay.status = 'valid' and pa.allocated_amount > 0
  ) then
    raise exception 'Hay dinero valido imputado a esos gastos. No se modifico nada; revisar antes de continuar.';
  end if;
  if exists (select 1 from urban_charge_items
    where id = any(charge_item_ids) and item_type not in ('building_expense', 'unit_expense')) then
    raise exception 'Hay un concepto inesperado vinculado a los gastos. No se modifico nada.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(pay) order by pay.id), '[]'::jsonb) into payments_before
  from urban_payments pay where pay.organization_id = target_org;
  select coalesce(jsonb_agg(to_jsonb(pa) order by pa.id), '[]'::jsonb) into allocations_before
  from urban_payment_allocations pa where pa.organization_id = target_org;
  select jsonb_build_object(
    'period', (select to_jsonb(p) from urban_expense_periods p where p.id = october_period),
    'items', (select jsonb_agg(to_jsonb(e) order by e.id) from urban_expense_items e where e.period_id = october_period),
    'allocations', (select jsonb_agg(to_jsonb(a) order by a.id) from urban_expense_allocations a where a.period_id = october_period)
  ) into october_before;

  -- Solo este trigger se suspende dentro de la transaccion y con las tablas bloqueadas.
  -- Un error revierte tambien el cambio del trigger; nunca queda deshabilitado.
  alter table urban_expense_items disable trigger guard_urban_expense_item_payment_lock_before_change;
  update urban_expense_items
  set status = 'voided', voided_at = now(), voided_by = auth.uid(),
      void_reason = repair_reason, updated_at = now()
  where id = any(expense_ids) and organization_id = target_org and status = 'valid';
  get diagnostics changed_count = row_count;
  alter table urban_expense_items enable trigger guard_urban_expense_item_payment_lock_before_change;

  -- Conserva los conceptos y sus imputaciones historicas, pero sin deuda.
  update urban_charge_items set amount_due = 0
  where id = any(charge_item_ids) and organization_id = target_org and amount_due <> 0;
  for charge_record in
    select distinct charge_id from urban_charge_items where id = any(charge_item_ids)
  loop
    perform recalculate_urban_charge_status(target_org, charge_record.charge_id);
  end loop;

  if payments_before is distinct from (
    select coalesce(jsonb_agg(to_jsonb(pay) order by pay.id), '[]'::jsonb)
    from urban_payments pay where pay.organization_id = target_org
  ) or allocations_before is distinct from (
    select coalesce(jsonb_agg(to_jsonb(pa) order by pa.id), '[]'::jsonb)
    from urban_payment_allocations pa where pa.organization_id = target_org
  ) or october_before is distinct from (
    select jsonb_build_object(
      'period', (select to_jsonb(p) from urban_expense_periods p where p.id = october_period),
      'items', (select jsonb_agg(to_jsonb(e) order by e.id) from urban_expense_items e where e.period_id = october_period),
      'allocations', (select jsonb_agg(to_jsonb(a) order by a.id) from urban_expense_allocations a where a.period_id = october_period))
  ) then
    raise exception 'Fallo la verificacion de pagos/octubre. Se deshizo toda la correccion.';
  end if;

  if changed_count > 0 then
    insert into audit_logs(organization_id, actor_user_id, action, entity_type, entity_id, old_values, new_values)
    values (target_org, auth.uid(), 'repair_misdated_september_expenses', 'urban_expense_period', september_period,
      jsonb_build_object('items', september_before),
      jsonb_build_object('voidedItems', expense_ids, 'reason', repair_reason, 'octoberUnchanged', true, 'paymentsUnchanged', true));
  end if;
end;
$$;

select b.name as edificio, p.period_month as periodo, p.status as estado_liquidacion,
  count(e.id) filter (where e.status = 'valid') as gastos_vigentes,
  coalesce(sum(e.amount) filter (where e.status = 'valid'), 0) as total_vigente
from urban_expense_periods p
join urban_buildings b on b.id = p.building_id
left join urban_expense_items e on e.period_id = p.id
where p.organization_id = '98a857e1-dacc-4890-90e9-1f1ac8de9782'
  and upper(trim(b.name)) = 'COLONIZADORES' and b.status = 'active'
  and p.period_month in (date '2026-09-01', date '2026-10-01')
group by b.name, p.period_month, p.status order by p.period_month;

commit;
