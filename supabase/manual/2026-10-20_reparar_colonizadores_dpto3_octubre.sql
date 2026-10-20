-- PASO 2: ejecutar despues de 066_guard_first_month_expenses_and_voided_surcharges.sql.
-- Solo repara el cargo diagnosticado. Conserva pagos, imputaciones y gastos.
-- Si los datos cambiaron desde el diagnostico, aborta sin modificar nada.
begin;

do $$
declare
  target_org constant uuid := '98a857e1-dacc-4890-90e9-1f1ac8de9782';
  target_charge constant uuid := '0f592252-be61-4946-84c3-5c3fee521f0f';
  original_payment constant uuid := 'fb987ff3-1dac-4304-ada6-3093c9b4d9a6';
  cancelled_payment constant uuid := '8d39799a-fb8c-4add-a9ec-99f4ee618b05';
  repair_items constant uuid[] := array[
    '994cea24-9158-4aab-aa9b-5c91e1c29bd3',
    'ad04d3b7-603c-49a9-a69f-fcbbb6012282',
    'b9fc6786-4fb8-4c77-922c-a442d06e842d',
    'f1cedbf0-ef48-4a34-ab69-9f3ac39636c0',
    '7788e7a1-0d8b-4f69-97c1-97fbb1c969e8'
  ]::uuid[];
  before_items jsonb;
begin
  if position('charge_lease.start_date' in pg_get_functiondef(
    'reconcile_urban_expense_period_charges(uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'Primero ejecuta el SQL 066. No se modifico ningun dato.';
  end if;

  perform 1 from urban_charges ch
  join urban_leases l on l.id = ch.lease_id
  where ch.id = target_charge and ch.organization_id = target_org
    and ch.period_month = date '2026-10-01'
    and ch.status <> 'cancelled'
    and l.start_date = date '2026-10-01'
    and l.current_amount = 950000 and l.currency = 'ARS'
  for update of ch, l;
  if not found then
    raise exception 'El contrato/cargo cambio: no se aplico la reparacion.';
  end if;

  perform 1 from urban_payments
  where organization_id = target_org and id in (original_payment, cancelled_payment)
  for update;
  perform 1 from urban_charge_items
  where organization_id = target_org and charge_id = target_charge
  for update;

  if not exists (
    select 1 from urban_payments p
    join urban_payment_allocations pa on pa.payment_id = p.id
    join urban_charge_items ci on ci.id = pa.charge_item_id
    where p.id = original_payment and p.organization_id = target_org
      and p.status = 'valid' and p.received_amount = 950000
      and p.payment_date = date '2026-10-06'
      and ci.charge_id = target_charge and ci.item_type = 'rent'
      and ci.amount_due = 950000 and pa.allocated_amount = 950000
  ) or not exists (
    select 1 from urban_payments
    where id = cancelled_payment and organization_id = target_org
      and status = 'voided' and received_amount = 95000
  ) then
    raise exception 'Los pagos cambiaron: no se aplico la reparacion.';
  end if;

  if exists (
    select 1 from urban_payment_allocations pa
    join urban_payments p on p.id = pa.payment_id
    join urban_charge_items ci on ci.id = pa.charge_item_id
    where ci.charge_id = target_charge and p.status = 'valid'
      and (p.id <> original_payment or ci.item_type <> 'rent')
      and pa.allocated_amount > 0
  ) or (select coalesce(sum(pa.allocated_amount), 0)
        from urban_payment_allocations pa
        join urban_charge_items ci on ci.id = pa.charge_item_id
        join urban_payments p on p.id = pa.payment_id
        where ci.charge_id = target_charge and p.status = 'valid') <> 950000
    or (select count(*) from urban_charge_items
        where charge_id = target_charge and organization_id = target_org) <> 6
    or (select count(*) from urban_charge_items
        where id = any(repair_items) and charge_id = target_charge
          and organization_id = target_org
          and ((item_type = 'building_expense' and source_entity_type = 'urban_expense_allocation')
            or (item_type = 'rent_surcharge' and source_entity_type = 'payment_surcharge'))) <> 5
  then
    raise exception 'Hay conceptos/pagos diferentes al diagnostico. No se modifico nada.';
  end if;

  select jsonb_agg(to_jsonb(ci) order by ci.id) into before_items
  from urban_charge_items ci where ci.id = any(repair_items);

  update urban_charge_items set amount_due = 0
  where id = any(repair_items) and organization_id = target_org
    and charge_id = target_charge and amount_due <> 0;
  if found then
    insert into audit_logs(organization_id, actor_user_id, action, entity_type, entity_id, old_values, new_values)
    values (target_org, auth.uid(), 'repair_first_month_charge', 'urban_charge', target_charge,
      jsonb_build_object('items', before_items),
      jsonb_build_object('rent', 950000, 'expenses', 0, 'surcharges', 0));
  end if;

  update urban_expense_allocations set charge_item_id = null
  where organization_id = target_org and charge_item_id = any(repair_items);

  perform recalculate_urban_charge_status(target_org, target_charge);
  if not exists (select 1 from urban_charges where id = target_charge and status = 'paid') then
    raise exception 'La verificacion del saldo fallo. Se deshizo la reparacion.';
  end if;
end;
$$;

select ch.id as charge_id, ch.period_month, ch.status as estado,
  (select sum(ci.amount_due) from urban_charge_items ci where ci.charge_id = ch.id) as total,
  (select sum(pa.allocated_amount) from urban_payment_allocations pa
   join urban_charge_items ci on ci.id = pa.charge_item_id
   join urban_payments p on p.id = pa.payment_id
   where ci.charge_id = ch.id and p.status = 'valid') as cobrado
from urban_charges ch
where ch.id = '0f592252-be61-4946-84c3-5c3fee521f0f'
  and ch.organization_id = '98a857e1-dacc-4890-90e9-1f1ac8de9782';

commit;
