-- Ver ingresos/pagos de reservas de Punta del Este.

with org as (
  select id from organizations order by created_at limit 1
)
select
  p.id as pde_payment_id,
  p.reservation_id,
  u.name as departamento,
  r.guest_name_snapshot as huesped,
  p.payment_type::text as tipo_pago,
  p.payment_date as fecha,
  p.amount as importe,
  p.currency as moneda,
  p.payment_method::text as metodo,
  p.status::text as estado,
  p.notes as observaciones,
  p.created_at
from pde_reservation_payments p
join pde_reservations r on r.id = p.reservation_id
join pde_units u on u.id = r.unit_id
where p.organization_id = (select id from org)
order by p.payment_date desc, p.created_at desc;
