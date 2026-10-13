-- Anular datos de Punta del Este por ID.
-- Tiene tres bloques separados: pagos, gastos y reservas.
-- Descomenta solo el bloque que necesites.

-- Vista previa de pagos PDE seleccionados
with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_PDE_PAYMENT_ID_1'::uuid
)
select
  p.id,
  u.name as departamento,
  r.guest_name_snapshot as huesped,
  p.payment_date,
  p.amount,
  p.currency,
  p.status::text as estado_actual
from pde_reservation_payments p
join pde_reservations r on r.id = p.reservation_id
join pde_units u on u.id = r.unit_id
join selected_ids x on x.id = p.id;

-- Ejecutar para anular pagos PDE
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_PDE_PAYMENT_ID_1'::uuid
-- )
-- update pde_reservation_payments p
-- set status = 'voided',
--     voided_at = now(),
--     void_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from selected_ids x
-- where p.id = x.id
--   and p.status = 'valid'
-- returning p.id, p.payment_date, p.amount, p.currency, p.status::text as estado_nuevo;

-- Vista previa de gastos PDE seleccionados
with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_PDE_EXPENSE_ID_1'::uuid
)
select
  e.id,
  coalesce(u.name, 'General 50/50') as departamento,
  e.expense_date,
  e.description,
  e.amount,
  e.currency,
  e.status::text as estado_actual
from pde_expenses e
left join pde_units u on u.id = e.unit_id
join selected_ids x on x.id = e.id;

-- Ejecutar para anular gastos PDE
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_PDE_EXPENSE_ID_1'::uuid
-- )
-- update pde_expenses e
-- set status = 'voided',
--     voided_at = now(),
--     void_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from selected_ids x
-- where e.id = x.id
--   and e.status = 'valid'
-- returning e.id, e.expense_date, e.amount, e.currency, e.status::text as estado_nuevo;

-- Vista previa de reservas PDE seleccionadas
with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_RESERVATION_ID_1'::uuid
)
select
  r.id,
  u.name as departamento,
  r.guest_name_snapshot as huesped,
  r.start_date,
  r.end_date,
  r.total_amount,
  r.currency,
  r.status::text as estado_actual
from pde_reservations r
join pde_units u on u.id = r.unit_id
join selected_ids x on x.id = r.id;

-- Ejecutar para cancelar reservas PDE
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_RESERVATION_ID_1'::uuid
-- )
-- update pde_reservations r
-- set status = 'cancelled',
--     cancelled_at = now(),
--     cancel_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from selected_ids x
-- where r.id = x.id
--   and r.status <> 'cancelled'
-- returning r.id, r.guest_name_snapshot, r.start_date, r.end_date, r.status::text as estado_nuevo;
