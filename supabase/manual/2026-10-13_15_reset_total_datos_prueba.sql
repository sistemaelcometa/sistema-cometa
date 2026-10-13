-- RESET TOTAL DE DATOS DE PRUEBA
--
-- Esto deja limpia la organizacion para volver a cargar desde cero.
-- Conserva:
-- - organizations
-- - profiles
-- - organization_members
--
-- Borra:
-- - contactos / inquilinos / huespedes / beneficiarios
-- - edificios y departamentos urbanos
-- - contratos, cobros, pagos, expensas, liquidaciones familiares
-- - reservas, pagos y gastos de Punta del Este
-- - mantenimientos, notas, archivos registrados, auditoria y operaciones
--
-- IMPORTANTE:
-- 1) Ejecuta primero la VISTA PREVIA.
-- 2) Si los conteos coinciden con lo que queres borrar, descomenta el bloque RESET.
-- 3) Esto es destructivo. No se puede deshacer desde la app.
--
-- Si hay varias organizaciones, reemplaza el CTE org por:
-- with org as (select 'PEGAR_ORGANIZATION_ID'::uuid as id)

-- =========================================================
-- VISTA PREVIA
-- =========================================================

with org as (
  select id from organizations order by created_at limit 1
)
select 'contacts' as tabla, count(*) as registros from contacts where organization_id = (select id from org)
union all select 'urban_buildings', count(*) from urban_buildings where organization_id = (select id from org)
union all select 'urban_units', count(*) from urban_units where organization_id = (select id from org)
union all select 'urban_leases', count(*) from urban_leases where organization_id = (select id from org)
union all select 'urban_lease_adjustments', count(*) from urban_lease_adjustments where organization_id = (select id from org)
union all select 'urban_charges', count(*) from urban_charges where organization_id = (select id from org)
union all select 'urban_charge_items', count(*) from urban_charge_items where organization_id = (select id from org)
union all select 'urban_payments', count(*) from urban_payments where organization_id = (select id from org)
union all select 'urban_payment_allocations', count(*) from urban_payment_allocations where organization_id = (select id from org)
union all select 'urban_expense_periods', count(*) from urban_expense_periods where organization_id = (select id from org)
union all select 'urban_expense_items', count(*) from urban_expense_items where organization_id = (select id from org)
union all select 'urban_expense_allocations', count(*) from urban_expense_allocations where organization_id = (select id from org)
union all select 'family_distribution_groups', count(*) from family_distribution_groups where organization_id = (select id from org)
union all select 'family_distribution_shares', count(*) from family_distribution_shares where organization_id = (select id from org)
union all select 'family_settlements', count(*) from family_settlements where organization_id = (select id from org)
union all select 'family_settlement_items', count(*) from family_settlement_items where organization_id = (select id from org)
union all select 'family_settlement_corrections', count(*) from family_settlement_corrections where organization_id = (select id from org)
union all select 'maintenance_tasks', count(*) from maintenance_tasks where organization_id = (select id from org)
union all select 'maintenance_expenses', count(*) from maintenance_expenses where organization_id = (select id from org)
union all select 'pde_units', count(*) from pde_units where organization_id = (select id from org)
union all select 'pde_reservations', count(*) from pde_reservations where organization_id = (select id from org)
union all select 'pde_reservation_payments', count(*) from pde_reservation_payments where organization_id = (select id from org)
union all select 'pde_expenses', count(*) from pde_expenses where organization_id = (select id from org)
union all select 'pde_expense_allocations', count(*) from pde_expense_allocations where organization_id = (select id from org)
union all select 'expense_categories', count(*) from expense_categories where organization_id = (select id from org)
union all select 'calendar_notes', count(*) from calendar_notes where organization_id = (select id from org)
union all select 'file_links', count(*) from file_links where organization_id = (select id from org)
union all select 'files', count(*) from files where organization_id = (select id from org)
union all select 'operation_results', count(*) from operation_results where organization_id = (select id from org)
union all select 'audit_logs', count(*) from audit_logs where organization_id = (select id from org)
order by tabla;

-- =========================================================
-- RESET TOTAL
-- =========================================================
-- Para ejecutar:
-- 1) Selecciona desde "begin;" hasta "commit;"
-- 2) Descomentalo
-- 3) Ejecutalo una sola vez

-- begin;
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from file_links where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from family_settlement_corrections where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from family_settlement_items where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from family_settlements where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from family_distribution_shares where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from family_distribution_groups where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_payment_allocations where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_payments where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_expense_allocations where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_charge_items where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_charges where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_expense_items where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_expense_periods where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_lease_adjustments where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_leases where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from maintenance_expenses where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from maintenance_tasks where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_units where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from urban_buildings where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from pde_expense_allocations where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from pde_reservation_payments where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from pde_expenses where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from pde_reservations where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from pde_units where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from calendar_notes where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from expense_categories where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from contacts where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from files where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from operation_results where organization_id = (select id from org);
--
-- with org as (select id from organizations order by created_at limit 1)
-- delete from audit_logs where organization_id = (select id from org);
--
-- commit;

-- =========================================================
-- VERIFICACION FINAL
-- =========================================================
-- Despues de ejecutar el reset, corre de nuevo la VISTA PREVIA.
-- Todos los conteos deberian quedar en 0.
