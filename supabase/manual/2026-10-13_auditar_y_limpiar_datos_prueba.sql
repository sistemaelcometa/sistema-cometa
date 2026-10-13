-- El Cometa - auditoria y limpieza manual de datos de prueba.
--
-- Como usar:
-- 1) Ejecuta primero las consultas de AUDITORIA.
-- 2) Copia los IDs que quieras limpiar en las tablas temporales de SELECCION.
-- 3) Ejecuta una VISTA PREVIA.
-- 4) Recien despues ejecuta el bloque de LIMPIEZA que corresponda.
--
-- Por defecto no borra nada: las tablas temporales arrancan vacias.
-- Si hay mas de una organizacion, cambia el CTE "org" por el id correcto.

-- =========================================================
-- 0. ORGANIZACIONES
-- =========================================================

select
  id,
  name,
  slug,
  created_at
from organizations
order by created_at;

-- Para casi todos los casos de este sistema hay una sola organizacion.
-- Si hubiera varias, reemplaza este CTE en las consultas por:
-- with org as (select 'PEGAR_ORGANIZATION_ID'::uuid as id)

-- =========================================================
-- 1. AUDITORIA GENERAL
-- =========================================================

-- 1A) Inquilinos / contactos cargados
with org as (
  select id from organizations order by created_at limit 1
),
contact_refs as (
  select
    c.id,
    count(distinct ul.id) as contratos_urbanos,
    count(distinct ul.id) filter (where ul.status in ('active', 'upcoming')) as contratos_activos,
    count(distinct uc.id) as cobros_urbanos,
    count(distinct up.id) as pagos_urbanos,
    count(distinct pr.id) as reservas_pde,
    count(distinct pp.id) as pagos_pde,
    count(distinct fdg.id) as distribuciones_familiares,
    count(distinct fsi.id) as items_liquidacion_familiar,
    count(distinct mt.id) as mantenimientos,
    count(distinct mei.id) as gastos_mantenimiento,
    count(distinct uei.id) as gastos_expensas
  from contacts c
  left join urban_leases ul on ul.primary_tenant_contact_id = c.id
  left join urban_charges uc on uc.lease_id = ul.id
  left join urban_payments up on up.lease_id = ul.id or up.unit_id = ul.unit_id
  left join pde_reservations pr on pr.guest_contact_id = c.id
  left join pde_reservation_payments pp on pp.reservation_id = pr.id
  left join family_distribution_shares fds on fds.beneficiary_contact_id = c.id
  left join family_distribution_groups fdg on fdg.id = fds.distribution_group_id
  left join family_settlement_items fsi on fsi.beneficiary_contact_id = c.id
  left join maintenance_tasks mt on mt.worker_contact_id = c.id
  left join maintenance_expenses mei on false
  left join urban_expense_items uei on uei.provider_contact_id = c.id
  where c.organization_id = (select id from org)
  group by c.id
)
select
  c.id as contact_id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
  c.document_number as dni,
  c.phone as telefono,
  c.email,
  c.status,
  c.is_tenant as inquilino,
  c.is_guest as huesped,
  c.is_provider as proveedor,
  c.is_worker as trabajador,
  c.is_family_beneficiary as beneficiario_familiar,
  r.contratos_urbanos,
  r.contratos_activos,
  r.cobros_urbanos,
  r.pagos_urbanos,
  r.reservas_pde,
  r.pagos_pde,
  r.distribuciones_familiares,
  r.items_liquidacion_familiar,
  r.mantenimientos,
  r.gastos_expensas,
  c.created_at
from contacts c
join contact_refs r on r.id = c.id
where c.organization_id = (select id from org)
order by c.created_at desc;

-- 1B) Edificios, departamentos y contratos urbanos
with org as (
  select id from organizations order by created_at limit 1
)
select
  b.id as building_id,
  b.name as edificio,
  b.status as estado_edificio,
  b.has_expenses as usa_expensas,
  u.id as unit_id,
  u.name as departamento,
  u.status as estado_departamento,
  l.id as lease_id,
  l.status as estado_contrato,
  l.start_date as inicio,
  l.end_date as fin,
  l.current_amount as monto,
  l.currency as moneda,
  l.monthly_due_day as dia_vencimiento,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino
from urban_buildings b
left join urban_units u on u.building_id = b.id
left join urban_leases l on l.unit_id = u.id
left join contacts c on c.id = l.primary_tenant_contact_id
where b.organization_id = (select id from org)
order by b.name, u.name, l.start_date;

-- 1C) Cobros urbanos pendientes, parciales, pagos y anulados
with org as (
  select id from organizations order by created_at limit 1
)
select
  ch.id as charge_id,
  ch.status as estado_cobro,
  ch.period_month as periodo,
  ch.due_date as vencimiento,
  b.name as edificio,
  u.name as departamento,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino,
  l.id as lease_id,
  l.status as estado_contrato,
  coalesce(sum(ci.amount_due) filter (where ci.item_type in ('rent', 'rent_surcharge')), 0)::numeric(14, 2) as alquiler,
  coalesce(sum(ci.amount_due) filter (where ci.item_type in ('building_expense', 'expense_surcharge', 'unit_expense')), 0)::numeric(14, 2) as expensas,
  coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total
from urban_charges ch
join urban_leases l on l.id = ch.lease_id
join urban_units u on u.id = ch.unit_id
join urban_buildings b on b.id = u.building_id
join contacts c on c.id = l.primary_tenant_contact_id
left join urban_charge_items ci on ci.charge_id = ch.id
where ch.organization_id = (select id from org)
group by ch.id, b.name, u.name, c.id, l.id
order by ch.due_date desc, b.name, u.name;

-- 1D) Expensas urbanas cargadas
with org as (
  select id from organizations order by created_at limit 1
)
select
  ep.id as period_id,
  ep.period_month as periodo,
  ep.status as estado_periodo,
  b.name as edificio,
  ei.id as expense_item_id,
  ei.expense_date as fecha,
  ei.description as descripcion,
  ei.amount as importe,
  ei.currency as moneda,
  ei.transfer_to_tenant as pasa_al_inquilino,
  ei.status as estado_gasto
from urban_expense_periods ep
join urban_buildings b on b.id = ep.building_id
left join urban_expense_items ei on ei.period_id = ep.id
where ep.organization_id = (select id from org)
order by ep.period_month desc, b.name, ei.expense_date desc;

-- 1E) Punta del Este: reservas, ingresos y egresos
with org as (
  select id from organizations order by created_at limit 1
)
select
  'reserva' as tipo,
  r.id as id,
  u.name as departamento,
  r.guest_name_snapshot as huesped,
  r.start_date as desde,
  r.end_date as hasta,
  r.total_amount as importe,
  r.currency as moneda,
  r.status::text as estado,
  r.created_at
from pde_reservations r
join pde_units u on u.id = r.unit_id
where r.organization_id = (select id from org)
union all
select
  'pago_reserva' as tipo,
  p.id as id,
  u.name as departamento,
  r.guest_name_snapshot as huesped,
  p.payment_date as desde,
  null::date as hasta,
  p.amount as importe,
  p.currency as moneda,
  p.status::text as estado,
  p.created_at
from pde_reservation_payments p
join pde_reservations r on r.id = p.reservation_id
join pde_units u on u.id = r.unit_id
where p.organization_id = (select id from org)
union all
select
  'gasto_pde' as tipo,
  e.id as id,
  coalesce(u.name, 'General 50/50') as departamento,
  null::text as huesped,
  e.expense_date as desde,
  null::date as hasta,
  e.amount as importe,
  e.currency as moneda,
  e.status::text as estado,
  e.created_at
from pde_expenses e
left join pde_units u on u.id = e.unit_id
where e.organization_id = (select id from org)
order by created_at desc;

-- =========================================================
-- 2. SELECCION MANUAL DE DATOS A LIMPIAR
-- =========================================================

create temp table if not exists cleanup_contacts (
  id uuid primary key
) on commit preserve rows;

create temp table if not exists cleanup_urban_leases (
  id uuid primary key
) on commit preserve rows;

create temp table if not exists cleanup_urban_charges (
  id uuid primary key
) on commit preserve rows;

create temp table if not exists cleanup_pde_reservations (
  id uuid primary key
) on commit preserve rows;

create temp table if not exists cleanup_pde_payments (
  id uuid primary key
) on commit preserve rows;

create temp table if not exists cleanup_pde_expenses (
  id uuid primary key
) on commit preserve rows;

create temp table if not exists cleanup_urban_expense_items (
  id uuid primary key
) on commit preserve rows;

truncate cleanup_contacts;
truncate cleanup_urban_leases;
truncate cleanup_urban_charges;
truncate cleanup_pde_reservations;
truncate cleanup_pde_payments;
truncate cleanup_pde_expenses;
truncate cleanup_urban_expense_items;

-- Pega aca los IDs elegidos. Deja comentado lo que no uses.
--
-- insert into cleanup_contacts(id) values
--   ('PEGAR_CONTACT_ID_1'),
--   ('PEGAR_CONTACT_ID_2');
--
-- insert into cleanup_urban_leases(id) values
--   ('PEGAR_LEASE_ID_1');
--
-- insert into cleanup_urban_charges(id) values
--   ('PEGAR_CHARGE_ID_1');
--
-- insert into cleanup_pde_reservations(id) values
--   ('PEGAR_RESERVATION_ID_1');
--
-- insert into cleanup_pde_payments(id) values
--   ('PEGAR_PDE_PAYMENT_ID_1');
--
-- insert into cleanup_pde_expenses(id) values
--   ('PEGAR_PDE_EXPENSE_ID_1');
--
-- insert into cleanup_urban_expense_items(id) values
--   ('PEGAR_URBAN_EXPENSE_ITEM_ID_1');

-- =========================================================
-- 3. VISTAS PREVIAS DE LO SELECCIONADO
-- =========================================================

select
  c.id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
  c.status,
  c.is_tenant,
  c.is_guest,
  c.is_provider,
  c.is_worker,
  c.is_family_beneficiary
from contacts c
join cleanup_contacts x on x.id = c.id
order by nombre;

select
  l.id as lease_id,
  l.status,
  b.name as edificio,
  u.name as departamento,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino,
  l.start_date,
  l.end_date,
  l.current_amount,
  l.currency
from urban_leases l
join urban_units u on u.id = l.unit_id
join urban_buildings b on b.id = u.building_id
join contacts c on c.id = l.primary_tenant_contact_id
join cleanup_urban_leases x on x.id = l.id
order by b.name, u.name, l.start_date;

select
  ch.id as charge_id,
  ch.status,
  ch.period_month,
  ch.due_date,
  b.name as edificio,
  u.name as departamento,
  coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total
from urban_charges ch
join urban_units u on u.id = ch.unit_id
join urban_buildings b on b.id = u.building_id
left join urban_charge_items ci on ci.charge_id = ch.id
join cleanup_urban_charges x on x.id = ch.id
group by ch.id, b.name, u.name
order by ch.due_date;

-- =========================================================
-- 4. LIMPIEZA SEGURA: ARCHIVAR CONTACTOS / INQUILINOS
-- =========================================================
-- Recomendado para limpiar la tabla de Inquilinos sin romper historial.
-- Los contactos archivados dejan de aparecer en el registro de inquilinos.

-- Vista previa de contactos que se archivarian
select
  c.id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
  c.status
from contacts c
join cleanup_contacts x on x.id = c.id
where c.status = 'active';

-- Ejecutar para archivar
-- update contacts c
-- set status = 'archived',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_contacts x
-- where c.id = x.id
--   and c.status = 'active'
-- returning c.id,
--   nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
--   c.status;

-- =========================================================
-- 5. LIMPIEZA DE COBROS URBANOS SELECCIONADOS
-- =========================================================
-- No borra fisicamente: marca como cancelled.
-- Solo afecta cobros sin pagos validos asociados.

-- Vista previa
select
  ch.id,
  ch.status,
  ch.due_date,
  b.name as edificio,
  u.name as departamento
from urban_charges ch
join urban_units u on u.id = ch.unit_id
join urban_buildings b on b.id = u.building_id
join cleanup_urban_charges x on x.id = ch.id
where not exists (
  select 1
  from urban_charge_items ci
  join urban_payment_allocations pa on pa.charge_item_id = ci.id
  join urban_payments p on p.id = pa.payment_id
  where ci.charge_id = ch.id
    and p.status = 'valid'
);

-- Ejecutar para anular
-- update urban_charges ch
-- set status = 'cancelled',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_urban_charges x
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
-- returning ch.id, ch.due_date, ch.status;

-- =========================================================
-- 6. LIMPIEZA PROFUNDA DE CONTRATOS URBANOS DE PRUEBA
-- =========================================================
-- Usar solo para contratos de prueba elegidos por lease_id.
-- Borra pagos/asignaciones/cobros/ajustes del contrato seleccionado.
-- Si el contacto queda sin referencias, se puede borrar aparte; si no, conviene archivarlo.

-- Vista previa de impacto
with selected_leases as (
  select l.*
  from urban_leases l
  join cleanup_urban_leases x on x.id = l.id
),
selected_charges as (
  select ch.*
  from urban_charges ch
  join selected_leases l on l.id = ch.lease_id
),
selected_items as (
  select ci.*
  from urban_charge_items ci
  join selected_charges ch on ch.id = ci.charge_id
),
selected_allocations as (
  select pa.*
  from urban_payment_allocations pa
  join selected_items ci on ci.id = pa.charge_item_id
),
selected_payments as (
  select distinct p.*
  from urban_payments p
  join selected_allocations pa on pa.payment_id = p.id
)
select
  (select count(*) from selected_leases) as contratos,
  (select count(*) from selected_charges) as cobros,
  (select count(*) from selected_items) as items_cobro,
  (select count(*) from selected_allocations) as asignaciones_pago,
  (select count(*) from selected_payments) as pagos;

-- Ejecutar limpieza profunda
-- begin;
--
-- with selected_leases as (
--   select l.*
--   from urban_leases l
--   join cleanup_urban_leases x on x.id = l.id
-- ),
-- selected_charges as (
--   select ch.*
--   from urban_charges ch
--   join selected_leases l on l.id = ch.lease_id
-- ),
-- selected_items as (
--   select ci.*
--   from urban_charge_items ci
--   join selected_charges ch on ch.id = ci.charge_id
-- ),
-- selected_allocations as (
--   select pa.*
--   from urban_payment_allocations pa
--   join selected_items ci on ci.id = pa.charge_item_id
-- ),
-- selected_payments as (
--   select distinct p.*
--   from urban_payments p
--   join selected_allocations pa on pa.payment_id = p.id
-- )
-- delete from family_settlement_items fsi
-- using selected_allocations sa
-- where fsi.source_payment_allocation_id = sa.id;
--
-- with selected_leases as (
--   select l.* from urban_leases l join cleanup_urban_leases x on x.id = l.id
-- ),
-- selected_charges as (
--   select ch.* from urban_charges ch join selected_leases l on l.id = ch.lease_id
-- ),
-- selected_items as (
--   select ci.* from urban_charge_items ci join selected_charges ch on ch.id = ci.charge_id
-- )
-- update urban_expense_allocations uea
-- set charge_item_id = null
-- from selected_items si
-- where uea.charge_item_id = si.id;
--
-- with selected_leases as (
--   select l.* from urban_leases l join cleanup_urban_leases x on x.id = l.id
-- ),
-- selected_charges as (
--   select ch.* from urban_charges ch join selected_leases l on l.id = ch.lease_id
-- ),
-- selected_items as (
--   select ci.* from urban_charge_items ci join selected_charges ch on ch.id = ci.charge_id
-- )
-- delete from urban_payment_allocations pa
-- using selected_items si
-- where pa.charge_item_id = si.id;
--
-- delete from urban_payments p
-- using cleanup_urban_leases x
-- where p.lease_id = x.id
--   and not exists (
--     select 1 from urban_payment_allocations pa where pa.payment_id = p.id
--   );
--
-- delete from urban_lease_adjustments a
-- using cleanup_urban_leases x
-- where a.lease_id = x.id;
--
-- delete from file_links fl
-- using cleanup_urban_leases x
-- where fl.entity_id = x.id
--   and fl.entity_type in ('urban_lease', 'lease', 'contract');
--
-- delete from urban_charges ch
-- using cleanup_urban_leases x
-- where ch.lease_id = x.id;
--
-- update urban_units u
-- set status = 'available',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_urban_leases x
-- join urban_leases selected_l on selected_l.id = x.id
-- where u.id = selected_l.unit_id
--   and not exists (
--   select 1
--   from urban_leases l
--   where l.unit_id = u.id
--     and l.status in ('active', 'upcoming')
--     and l.id <> selected_l.id
-- )
--   and u.status = 'rented';
--
-- delete from urban_leases l
-- using cleanup_urban_leases x
-- where l.id = x.id;
--
-- commit;

-- =========================================================
-- 7. LIMPIEZA PDE
-- =========================================================

-- Anular pagos de reservas PDE seleccionados
-- update pde_reservation_payments p
-- set status = 'voided',
--     voided_at = now(),
--     void_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_pde_payments x
-- where p.id = x.id
--   and p.status = 'valid'
-- returning p.id, p.payment_date, p.amount, p.currency, p.status;

-- Anular gastos PDE seleccionados
-- update pde_expenses e
-- set status = 'voided',
--     voided_at = now(),
--     void_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_pde_expenses x
-- where e.id = x.id
--   and e.status = 'valid'
-- returning e.id, e.expense_date, e.amount, e.currency, e.status;

-- Cancelar reservas PDE seleccionadas
-- update pde_reservations r
-- set status = 'cancelled',
--     cancelled_at = now(),
--     cancel_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_pde_reservations x
-- where r.id = x.id
--   and r.status <> 'cancelled'
-- returning r.id, r.guest_name_snapshot, r.start_date, r.end_date, r.status;

-- =========================================================
-- 8. LIMPIEZA DE GASTOS DE EXPENSAS URBANAS
-- =========================================================

-- Anular gastos de expensas seleccionados
-- update urban_expense_items ei
-- set status = 'voided',
--     voided_at = now(),
--     void_reason = 'Limpieza manual de datos de prueba',
--     updated_at = now(),
--     version = version + 1
-- from cleanup_urban_expense_items x
-- where ei.id = x.id
--   and ei.status = 'valid'
-- returning ei.id, ei.expense_date, ei.description, ei.amount, ei.currency, ei.status;

-- =========================================================
-- 9. BORRADO FISICO DE CONTACTOS SIN REFERENCIAS
-- =========================================================
-- Esto solo borra contactos que no estan referenciados por nada importante.
-- Si no se borran, usa el archivo seguro de ARCHIVAR de la seccion 4.

-- Vista previa de contactos seleccionados que son borrables fisicamente
select
  c.id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre
from contacts c
join cleanup_contacts x on x.id = c.id
where not exists (select 1 from urban_leases l where l.primary_tenant_contact_id = c.id)
  and not exists (select 1 from pde_reservations r where r.guest_contact_id = c.id)
  and not exists (select 1 from urban_expense_items ei where ei.provider_contact_id = c.id)
  and not exists (select 1 from maintenance_tasks mt where mt.worker_contact_id = c.id)
  and not exists (select 1 from family_distribution_shares fds where fds.beneficiary_contact_id = c.id)
  and not exists (select 1 from family_settlement_items fsi where fsi.beneficiary_contact_id = c.id);

-- Ejecutar borrado fisico solo de esos contactos sin referencias
-- delete from contacts c
-- using cleanup_contacts x
-- where c.id = x.id
--   and not exists (select 1 from urban_leases l where l.primary_tenant_contact_id = c.id)
--   and not exists (select 1 from pde_reservations r where r.guest_contact_id = c.id)
--   and not exists (select 1 from urban_expense_items ei where ei.provider_contact_id = c.id)
--   and not exists (select 1 from maintenance_tasks mt where mt.worker_contact_id = c.id)
--   and not exists (select 1 from family_distribution_shares fds where fds.beneficiary_contact_id = c.id)
--   and not exists (select 1 from family_settlement_items fsi where fsi.beneficiary_contact_id = c.id)
-- returning c.id,
--   nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre;
