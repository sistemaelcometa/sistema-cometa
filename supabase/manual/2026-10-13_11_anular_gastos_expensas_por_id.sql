-- Anular gastos de expensas urbanas por ID.
-- No borra fisicamente: marca el gasto como voided.

with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_URBAN_EXPENSE_ITEM_ID_1'::uuid
)
select
  ei.id,
  ep.period_month as periodo,
  b.name as edificio,
  ei.expense_date as fecha,
  ei.description,
  ei.amount,
  ei.currency,
  ei.status::text as estado_actual
from urban_expense_items ei
join urban_expense_periods ep on ep.id = ei.period_id
join urban_buildings b on b.id = ep.building_id
join selected_ids x on x.id = ei.id
order by ei.expense_date;

-- Ejecutar para anular
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_URBAN_EXPENSE_ITEM_ID_1'::uuid
-- )
-- update urban_expense_items ei
-- set status = 'voided',
--     voided_at = now(),
--     void_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from selected_ids x
-- where ei.id = x.id
--   and ei.status = 'valid'
-- returning ei.id, ei.expense_date, ei.description, ei.amount, ei.currency, ei.status::text as estado_nuevo;
