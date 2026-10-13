-- Ver cobros urbanos.

with org as (
  select id from organizations order by created_at limit 1
)
select
  ch.id as charge_id,
  ch.status::text as estado_cobro,
  ch.period_month as periodo,
  ch.due_date as vencimiento,
  b.name as edificio,
  u.name as departamento,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino,
  l.id as lease_id,
  l.status::text as estado_contrato,
  coalesce(sum(ci.amount_due) filter (where ci.item_type in ('rent', 'rent_surcharge')), 0)::numeric(14, 2) as alquiler,
  coalesce(sum(ci.amount_due) filter (where ci.item_type in ('building_expense', 'expense_surcharge', 'unit_expense')), 0)::numeric(14, 2) as expensas,
  coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total,
  ch.created_at
from urban_charges ch
join urban_leases l on l.id = ch.lease_id
join urban_units u on u.id = ch.unit_id
join urban_buildings b on b.id = u.building_id
join contacts c on c.id = l.primary_tenant_contact_id
left join urban_charge_items ci on ci.charge_id = ch.id
where ch.organization_id = (select id from org)
group by ch.id, b.name, u.name, c.id, l.id
order by ch.due_date desc, b.name, u.name;
