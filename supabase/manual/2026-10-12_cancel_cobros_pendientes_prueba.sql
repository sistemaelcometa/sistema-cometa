-- Limpieza manual de cobros pendientes de prueba.
--
-- No borra registros fisicamente: marca los vencimientos como cancelled.
-- Proteccion: solo afecta cargos pendientes, con vencimiento exacto 10/10/2026,
-- sin pagos validos asociados, y que coincidan con departamento + edificio + inquilino.
--
-- Ejecutar primero el PASO 1 y revisar que la lista sea exactamente la que queres sacar.
-- Despues ejecutar el PASO 2.

-- PASO 1: vista previa
with target_rows(unit_name, building_name, tenant_name, due_date) as (
  values
    ('1', 'expensas', 'Santiago Gimenez', date '2026-10-10'),
    ('1', 'Santiago', 'Santiago Gimenez', date '2026-10-10'),
    ('2', 'Santiago', 'Santiago Gimenez', date '2026-10-10'),
    ('DPTO 3', 'TIPUANA', 'Andres Massoni', date '2026-10-10'),
    ('LOCAL', 'TIPUANA', 'Augusto Redolfi', date '2026-10-10')
),
candidates as (
  select
    ch.id as charge_id,
    ch.organization_id,
    u.name as departamento,
    b.name as edificio,
    nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino,
    ch.due_date,
    ch.status as estado_cobro,
    l.status as estado_contrato,
    u.status as estado_departamento,
    coalesce(sum(i.amount_due), 0)::numeric(14, 2) as total
  from target_rows tr
  join urban_units u on lower(u.name) = lower(tr.unit_name)
  join urban_buildings b on b.id = u.building_id and lower(b.name) = lower(tr.building_name)
  join urban_charges ch on ch.unit_id = u.id and ch.due_date = tr.due_date
  join urban_leases l on l.id = ch.lease_id
  join contacts c on c.id = l.primary_tenant_contact_id
  left join urban_charge_items i on i.charge_id = ch.id
  where ch.status = 'pending'
    and lower(nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '')) = lower(tr.tenant_name)
    and not exists (
      select 1
      from urban_charge_items ci
      join urban_payment_allocations pa on pa.charge_item_id = ci.id
      join urban_payments p on p.id = pa.payment_id
      where ci.charge_id = ch.id
        and p.status = 'valid'
    )
  group by ch.id, ch.organization_id, u.name, b.name, c.id, ch.due_date, ch.status, l.status, u.status
)
select *
from candidates
order by edificio, departamento;

-- PASO 2: anular los cobros pendientes listados arriba
with target_rows(unit_name, building_name, tenant_name, due_date) as (
  values
    ('1', 'expensas', 'Santiago Gimenez', date '2026-10-10'),
    ('1', 'Santiago', 'Santiago Gimenez', date '2026-10-10'),
    ('2', 'Santiago', 'Santiago Gimenez', date '2026-10-10'),
    ('DPTO 3', 'TIPUANA', 'Andres Massoni', date '2026-10-10'),
    ('LOCAL', 'TIPUANA', 'Augusto Redolfi', date '2026-10-10')
),
candidates as (
  select ch.id
  from target_rows tr
  join urban_units u on lower(u.name) = lower(tr.unit_name)
  join urban_buildings b on b.id = u.building_id and lower(b.name) = lower(tr.building_name)
  join urban_charges ch on ch.unit_id = u.id and ch.due_date = tr.due_date
  join urban_leases l on l.id = ch.lease_id
  join contacts c on c.id = l.primary_tenant_contact_id
  where ch.status = 'pending'
    and lower(nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '')) = lower(tr.tenant_name)
    and not exists (
      select 1
      from urban_charge_items ci
      join urban_payment_allocations pa on pa.charge_item_id = ci.id
      join urban_payments p on p.id = pa.payment_id
      where ci.charge_id = ch.id
        and p.status = 'valid'
    )
)
update urban_charges ch
set status = 'cancelled'
from candidates
where ch.id = candidates.id
returning ch.id, ch.unit_id, ch.due_date, ch.status;
