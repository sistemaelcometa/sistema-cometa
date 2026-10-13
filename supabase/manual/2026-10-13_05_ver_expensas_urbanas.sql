-- Ver periodos y gastos de expensas urbanas.

with org as (
  select id from organizations order by created_at limit 1
)
select
  ep.id as period_id,
  ep.period_month as periodo,
  ep.status::text as estado_periodo,
  b.name as edificio,
  ei.id as expense_item_id,
  ei.expense_date as fecha,
  ei.description as descripcion,
  ei.amount as importe,
  ei.currency as moneda,
  ei.transfer_to_tenant as pasa_al_inquilino,
  ei.status::text as estado_gasto,
  ei.created_at
from urban_expense_periods ep
join urban_buildings b on b.id = ep.building_id
left join urban_expense_items ei on ei.period_id = ep.id
where ep.organization_id = (select id from org)
order by ep.period_month desc, b.name, ei.expense_date desc;
