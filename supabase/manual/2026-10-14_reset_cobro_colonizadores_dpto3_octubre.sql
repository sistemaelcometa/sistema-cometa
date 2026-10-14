-- Reset puntual del cobro bugueado:
-- COLONIZADORES / DPTO 3 / BETINA ACOSTA / vencimiento 10/10/2026.
--
-- Que hace:
-- 1) ubica ese cobro de octubre 2026,
-- 2) elimina items de expensas/recargos/manuales que hayan quedado pegados,
--    solo si no tienen pagos validos imputados,
-- 3) deja el cargo pendiente,
-- 4) vuelve a correr la sincronizacion general para que el cobro quede consistente.

begin;

with target_charge as (
  select
    ch.organization_id,
    ch.id as charge_id
  from urban_charges ch
  join urban_leases l on l.id = ch.lease_id
  join urban_units u on u.id = ch.unit_id
  join urban_buildings b on b.id = u.building_id
  join contacts c on c.id = l.primary_tenant_contact_id
  where upper(b.name) = 'COLONIZADORES'
    and upper(u.name) = 'DPTO 3'
    and upper(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))) = 'BETINA ACOSTA'
    and ch.period_month = date '2026-10-01'
    and ch.due_date = date '2026-10-10'
),
items_to_remove as (
  select ci.id
  from urban_charge_items ci
  join target_charge tc on tc.charge_id = ci.charge_id
  where ci.item_type <> 'rent'
    and not exists (
      select 1
      from urban_payment_allocations pa
      join urban_payments p on p.id = pa.payment_id
      where pa.charge_item_id = ci.id
        and p.status = 'valid'
    )
),
removed_allocations as (
  delete from urban_payment_allocations pa
  using items_to_remove r
  where pa.charge_item_id = r.id
  returning pa.id
),
removed_items as (
  delete from urban_charge_items ci
  using items_to_remove r
  where ci.id = r.id
  returning ci.id
),
updated_charge as (
  update urban_charges ch
  set status = 'pending',
      updated_at = now()
  from target_charge tc
  where ch.id = tc.charge_id
    and ch.status <> 'paid'
  returning ch.organization_id, ch.id
),
recalculated as (
  select recalculate_urban_charge_status(organization_id, id)
  from updated_charge
),
synced as (
  select sync_urban_billing(org.organization_id)
  from (
    select distinct organization_id
    from target_charge
  ) org
)
select
  (select count(*) from target_charge) as cargos_encontrados,
  (select count(*) from removed_items) as items_eliminados,
  (select count(*) from removed_allocations) as imputaciones_eliminadas,
  (select count(*) from recalculated) as cargos_recalculados,
  (select count(*) from synced) as sincronizaciones_corridas;

commit;

-- Verificacion final: deberia quedar alquiler 950000, expensas 0, estado pending.
select
  ch.id as charge_id,
  b.name as edificio,
  u.name as departamento,
  trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as inquilino,
  ch.period_month,
  ch.due_date,
  ch.status,
  coalesce(sum(ci.amount_due) filter (where ci.item_type = 'rent'), 0) as alquiler,
  coalesce(sum(ci.amount_due) filter (where ci.item_type in ('building_expense', 'unit_expense')), 0) as expensas,
  coalesce(sum(ci.amount_due), 0) as total
from urban_charges ch
join urban_leases l on l.id = ch.lease_id
join urban_units u on u.id = ch.unit_id
join urban_buildings b on b.id = u.building_id
join contacts c on c.id = l.primary_tenant_contact_id
left join urban_charge_items ci on ci.charge_id = ch.id
where upper(b.name) = 'COLONIZADORES'
  and upper(u.name) = 'DPTO 3'
  and upper(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))) = 'BETINA ACOSTA'
  and ch.period_month = date '2026-10-01'
  and ch.due_date = date '2026-10-10'
group by ch.id, b.name, u.name, c.business_name, c.first_name, c.last_name, ch.period_month, ch.due_date, ch.status;
