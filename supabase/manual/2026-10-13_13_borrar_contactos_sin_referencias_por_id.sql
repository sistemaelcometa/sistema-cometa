-- Borrar fisicamente contactos por ID solo si no tienen referencias.
-- Si tienen contratos, reservas, gastos o liquidaciones, no se borran.
-- Para esos casos usa 2026-10-13_09_archivar_inquilinos_por_id.sql.

with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_CONTACT_ID_1'::uuid
)
select
  c.id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
  not exists (select 1 from urban_leases l where l.primary_tenant_contact_id = c.id)
    and not exists (select 1 from pde_reservations r where r.guest_contact_id = c.id)
    and not exists (select 1 from urban_expense_items ei where ei.provider_contact_id = c.id)
    and not exists (select 1 from maintenance_tasks mt where mt.worker_contact_id = c.id)
    and not exists (select 1 from family_distribution_shares fds where fds.beneficiary_contact_id = c.id)
    and not exists (select 1 from family_settlement_items fsi where fsi.beneficiary_contact_id = c.id)
    as se_puede_borrar
from contacts c
join selected_ids x on x.id = c.id
order by nombre;

-- Ejecutar borrado fisico solo de contactos sin referencias
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_CONTACT_ID_1'::uuid
-- )
-- delete from contacts c
-- using selected_ids x
-- where c.id = x.id
--   and not exists (select 1 from urban_leases l where l.primary_tenant_contact_id = c.id)
--   and not exists (select 1 from pde_reservations r where r.guest_contact_id = c.id)
--   and not exists (select 1 from urban_expense_items ei where ei.provider_contact_id = c.id)
--   and not exists (select 1 from maintenance_tasks mt where mt.worker_contact_id = c.id)
--   and not exists (select 1 from family_distribution_shares fds where fds.beneficiary_contact_id = c.id)
--   and not exists (select 1 from family_settlement_items fsi where fsi.beneficiary_contact_id = c.id)
-- returning c.id,
--   nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre;
