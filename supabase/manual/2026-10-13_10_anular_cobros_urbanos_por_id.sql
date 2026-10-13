-- Anular cobros urbanos por ID.
-- No borra fisicamente: marca el cobro como cancelled.
-- Solo anula cobros sin pagos validos asociados.

with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_CHARGE_ID_1'::uuid
)
select
  ch.id,
  ch.status::text as estado_actual,
  ch.period_month,
  ch.due_date,
  b.name as edificio,
  u.name as departamento,
  coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total,
  not exists (
    select 1
    from urban_charge_items ci2
    join urban_payment_allocations pa on pa.charge_item_id = ci2.id
    join urban_payments p on p.id = pa.payment_id
    where ci2.charge_id = ch.id
      and p.status = 'valid'
  ) as se_puede_anular
from urban_charges ch
join urban_units u on u.id = ch.unit_id
join urban_buildings b on b.id = u.building_id
left join urban_charge_items ci on ci.charge_id = ch.id
join selected_ids x on x.id = ch.id
group by ch.id, b.name, u.name
order by ch.due_date;

-- Ejecutar para anular
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_CHARGE_ID_1'::uuid
-- )
-- update urban_charges ch
-- set status = 'cancelled',
--     updated_at = now(),
--     version = version + 1
-- from selected_ids x
-- where ch.id = x.id
--   and ch.status in ('pending', 'partial')
--   and not exists (
--     select 1
--     from urban_charge_items ci
--     join urban_payment_allocations pa on pa.charge_item_id = ci.id
--     join urban_payments p on p.id = pa.payment_id
--     where ci.charge_id = ch.id
--       and p.status = 'valid'
--   )
-- returning ch.id, ch.due_date, ch.status::text as estado_nuevo;
