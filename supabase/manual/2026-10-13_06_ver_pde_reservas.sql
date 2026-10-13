-- Ver reservas de Punta del Este.

with org as (
  select id from organizations order by created_at limit 1
)
select
  r.id as reservation_id,
  u.name as departamento,
  r.guest_name_snapshot as huesped,
  r.guest_phone_snapshot as telefono,
  r.guest_email_snapshot as email,
  r.start_date as desde,
  r.end_date as hasta,
  r.total_amount as importe,
  r.currency as moneda,
  r.status::text as estado,
  r.notes as observaciones,
  r.created_at
from pde_reservations r
join pde_units u on u.id = r.unit_id
where r.organization_id = (select id from org)
order by r.created_at desc;
