-- Ver edificios, departamentos y contratos urbanos.

with org as (
  select id from organizations order by created_at limit 1
)
select
  b.id as building_id,
  b.name as edificio,
  b.status::text as estado_edificio,
  b.has_expenses as usa_expensas,
  u.id as unit_id,
  u.name as departamento,
  u.status::text as estado_departamento,
  u.notes as detalle_departamento,
  l.id as lease_id,
  l.status::text as estado_contrato,
  l.start_date as inicio,
  l.end_date as fin,
  l.current_amount as monto,
  l.currency as moneda,
  l.monthly_due_day as dia_vencimiento,
  l.adjustment_frequency_months as frecuencia_meses,
  l.next_adjustment_date as proxima_actualizacion,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino
from urban_buildings b
left join urban_units u on u.building_id = b.id
left join urban_leases l on l.unit_id = u.id
left join contacts c on c.id = l.primary_tenant_contact_id
where b.organization_id = (select id from org)
order by b.name, u.name, l.start_date;
