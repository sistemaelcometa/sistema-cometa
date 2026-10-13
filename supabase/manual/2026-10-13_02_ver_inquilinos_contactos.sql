-- Ver todos los contactos/inquilinos y sus referencias.
-- Si hay varias organizaciones, reemplaza el CTE org por:
-- with org as (select 'PEGAR_ORGANIZATION_ID'::uuid as id)

with org as (
  select id from organizations order by created_at limit 1
),
base as (
  select c.*
  from contacts c
  where c.organization_id = (select id from org)
),
refs as (
  select
    c.id,
    (select count(*) from urban_leases l where l.primary_tenant_contact_id = c.id) as contratos_urbanos,
    (select count(*) from urban_leases l where l.primary_tenant_contact_id = c.id and l.status in ('active', 'upcoming')) as contratos_activos,
    (select count(*) from pde_reservations r where r.guest_contact_id = c.id) as reservas_pde,
    (select count(*) from urban_expense_items e where e.provider_contact_id = c.id) as gastos_expensas_como_proveedor,
    (select count(*) from maintenance_tasks t where t.worker_contact_id = c.id) as mantenimientos_como_trabajador,
    (select count(*) from family_distribution_shares s where s.beneficiary_contact_id = c.id) as distribuciones_familiares,
    (select count(*) from family_settlement_items i where i.beneficiary_contact_id = c.id) as items_liquidacion_familiar
  from base c
)
select
  c.id as contact_id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
  c.document_number as dni,
  c.phone as telefono,
  c.email,
  c.address as direccion,
  c.notes as observaciones,
  c.status::text as estado,
  c.is_tenant as inquilino,
  c.is_guest as huesped,
  c.is_provider as proveedor,
  c.is_worker as trabajador,
  c.is_family_beneficiary as beneficiario_familiar,
  r.contratos_urbanos,
  r.contratos_activos,
  r.reservas_pde,
  r.gastos_expensas_como_proveedor,
  r.mantenimientos_como_trabajador,
  r.distribuciones_familiares,
  r.items_liquidacion_familiar,
  c.created_at
from base c
join refs r on r.id = c.id
order by c.created_at desc;
