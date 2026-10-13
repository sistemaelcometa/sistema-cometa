-- Ver egresos/gastos de Punta del Este.

with org as (
  select id from organizations order by created_at limit 1
)
select
  e.id as pde_expense_id,
  coalesce(u.name, 'General 50/50') as departamento,
  e.target_type::text as tipo,
  e.expense_date as fecha,
  e.description as descripcion,
  e.amount as importe,
  e.currency as moneda,
  e.payment_method::text as metodo,
  e.status::text as estado,
  e.notes as observaciones,
  e.created_at
from pde_expenses e
left join pde_units u on u.id = e.unit_id
where e.organization_id = (select id from org)
order by e.expense_date desc, e.created_at desc;
