-- Borrado profundo de contratos urbanos de prueba por lease_id.
-- Usar solo para contratos de prueba, no para operatoria real.
-- Primero ejecuta la VISTA PREVIA. Si esta bien, descomenta el bloque BEGIN/COMMIT.

with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_LEASE_ID_1'::uuid
),
selected_leases as (
  select l.*
  from urban_leases l
  join selected_ids x on x.id = l.id
),
selected_charges as (
  select ch.*
  from urban_charges ch
  join selected_leases l on l.id = ch.lease_id
),
selected_items as (
  select ci.*
  from urban_charge_items ci
  join selected_charges ch on ch.id = ci.charge_id
),
selected_allocations as (
  select pa.*
  from urban_payment_allocations pa
  join selected_items ci on ci.id = pa.charge_item_id
),
selected_payments as (
  select distinct p.*
  from urban_payments p
  join selected_allocations pa on pa.payment_id = p.id
)
select
  (select count(*) from selected_leases) as contratos,
  (select count(*) from selected_charges) as cobros,
  (select count(*) from selected_items) as items_cobro,
  (select count(*) from selected_allocations) as asignaciones_pago,
  (select count(*) from selected_payments) as pagos;

-- Ejecutar borrado profundo
-- begin;
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- ),
-- selected_leases as (
--   select l.* from urban_leases l join selected_ids x on x.id = l.id
-- ),
-- selected_charges as (
--   select ch.* from urban_charges ch join selected_leases l on l.id = ch.lease_id
-- ),
-- selected_items as (
--   select ci.* from urban_charge_items ci join selected_charges ch on ch.id = ci.charge_id
-- ),
-- selected_allocations as (
--   select pa.* from urban_payment_allocations pa join selected_items ci on ci.id = pa.charge_item_id
-- )
-- delete from family_settlement_items fsi
-- using selected_allocations sa
-- where fsi.source_payment_allocation_id = sa.id;
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- ),
-- selected_leases as (
--   select l.* from urban_leases l join selected_ids x on x.id = l.id
-- ),
-- selected_charges as (
--   select ch.* from urban_charges ch join selected_leases l on l.id = ch.lease_id
-- ),
-- selected_items as (
--   select ci.* from urban_charge_items ci join selected_charges ch on ch.id = ci.charge_id
-- )
-- update urban_expense_allocations uea
-- set charge_item_id = null
-- from selected_items si
-- where uea.charge_item_id = si.id;
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- ),
-- selected_leases as (
--   select l.* from urban_leases l join selected_ids x on x.id = l.id
-- ),
-- selected_charges as (
--   select ch.* from urban_charges ch join selected_leases l on l.id = ch.lease_id
-- ),
-- selected_items as (
--   select ci.* from urban_charge_items ci join selected_charges ch on ch.id = ci.charge_id
-- )
-- delete from urban_payment_allocations pa
-- using selected_items si
-- where pa.charge_item_id = si.id;
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- )
-- delete from urban_payments p
-- using selected_ids x
-- where p.lease_id = x.id
--   and not exists (
--     select 1 from urban_payment_allocations pa where pa.payment_id = p.id
--   );
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- )
-- delete from urban_lease_adjustments a
-- using selected_ids x
-- where a.lease_id = x.id;
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- )
-- delete from file_links fl
-- using selected_ids x
-- where fl.entity_id = x.id
--   and fl.entity_type in ('urban_lease', 'lease', 'contract');
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- )
-- delete from urban_charges ch
-- using selected_ids x
-- where ch.lease_id = x.id;
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- ),
-- selected_leases as (
--   select l.* from urban_leases l join selected_ids x on x.id = l.id
-- )
-- update urban_units u
-- set status = 'available',
--     updated_at = now(),
--     version = version + 1
-- from selected_leases selected_l
-- where u.id = selected_l.unit_id
--   and u.status = 'rented'
--   and not exists (
--     select 1
--     from urban_leases l
--     where l.unit_id = u.id
--       and l.status in ('active', 'upcoming')
--       and l.id <> selected_l.id
--   );
--
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_LEASE_ID_1'::uuid
-- )
-- delete from urban_leases l
-- using selected_ids x
-- where l.id = x.id;
--
-- commit;
