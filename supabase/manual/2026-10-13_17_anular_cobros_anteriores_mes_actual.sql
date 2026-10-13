-- ANULAR COBROS URBANOS ANTERIORES AL MES ACTUAL
--
-- Uso unico para limpiar contratos historicos cargados ahora:
-- deja visibles solo los cobros del mes actual en adelante.
--
-- No toca contratos, edificios, departamentos, inquilinos ni usuarios.
-- No anula cobros que tengan pagos validos asignados.

-- 1) VISTA PREVIA: revisa que estos sean los cobros viejos a ocultar.
with org as (
  select id
  from organizations
  order by created_at
  limit 1
),
cutoff as (
  select date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date as mes_actual
),
totales as (
  select
    ci.charge_id,
    coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total
  from urban_charge_items ci
  where ci.organization_id = (select id from org)
  group by ci.charge_id
),
pagos as (
  select distinct ci.charge_id
  from urban_charge_items ci
  join urban_payment_allocations pa on pa.charge_item_id = ci.id
  join urban_payments p on p.id = pa.payment_id
  where ci.organization_id = (select id from org)
    and p.status = 'valid'
)
select
  ch.id as charge_id,
  ch.period_month,
  ch.due_date,
  ch.status,
  ub.name as edificio,
  uu.name as departamento,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino,
  coalesce(t.total, 0) as total
from urban_charges ch
join urban_leases ul on ul.id = ch.lease_id
join urban_units uu on uu.id = ch.unit_id
join urban_buildings ub on ub.id = uu.building_id
join contacts c on c.id = ul.primary_tenant_contact_id
left join totales t on t.charge_id = ch.id
left join pagos p on p.charge_id = ch.id
where ch.organization_id = (select id from org)
  and ch.period_month < (select mes_actual from cutoff)
  and ch.status = 'pending'
  and p.charge_id is null
order by ch.due_date, ub.name, uu.name;

-- 2) EJECUCION: cambia false por true y corre SOLO este bloque si la vista previa esta bien.
with confirmar as (
  select false as ejecutar_limpieza
),
org as (
  select id
  from organizations
  order by created_at
  limit 1
),
cutoff as (
  select date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date as mes_actual
),
cobros_a_anular as (
  select ch.id
  from urban_charges ch
  where ch.organization_id = (select id from org)
    and ch.period_month < (select mes_actual from cutoff)
    and ch.status = 'pending'
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
set
  status = 'cancelled',
  updated_at = now(),
  version = ch.version + 1
from cobros_a_anular target
where ch.id = target.id
  and (select ejecutar_limpieza from confirmar)
returning
  ch.id as charge_id,
  ch.period_month,
  ch.due_date,
  ch.status;
