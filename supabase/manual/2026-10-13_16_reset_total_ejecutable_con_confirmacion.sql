-- RESET TOTAL EJECUTABLE CON CONFIRMACION
--
-- Conserva usuarios, organizacion y permisos.
-- Borra todos los datos cargados de prueba de la primera organizacion.
--
-- USO:
-- 1) Corre la vista previa.
-- 2) Si queres borrar todo, cambia esta linea:
--      select false as ejecutar_reset
--    por:
--      select true as ejecutar_reset
-- 3) Ejecuta el archivo completo.

begin;

drop table if exists reset_confirmacion;
create temp table reset_confirmacion as
select false as ejecutar_reset;

-- Vista previa antes del reset
with org as (
  select id from organizations order by created_at limit 1
)
select 'contacts' as tabla, count(*) as registros from contacts where organization_id = (select id from org)
union all select 'urban_buildings', count(*) from urban_buildings where organization_id = (select id from org)
union all select 'urban_units', count(*) from urban_units where organization_id = (select id from org)
union all select 'urban_leases', count(*) from urban_leases where organization_id = (select id from org)
union all select 'urban_charges', count(*) from urban_charges where organization_id = (select id from org)
union all select 'urban_payments', count(*) from urban_payments where organization_id = (select id from org)
union all select 'urban_expense_periods', count(*) from urban_expense_periods where organization_id = (select id from org)
union all select 'urban_expense_items', count(*) from urban_expense_items where organization_id = (select id from org)
union all select 'family_distribution_groups', count(*) from family_distribution_groups where organization_id = (select id from org)
union all select 'family_settlements', count(*) from family_settlements where organization_id = (select id from org)
union all select 'maintenance_tasks', count(*) from maintenance_tasks where organization_id = (select id from org)
union all select 'pde_units', count(*) from pde_units where organization_id = (select id from org)
union all select 'pde_reservations', count(*) from pde_reservations where organization_id = (select id from org)
union all select 'pde_reservation_payments', count(*) from pde_reservation_payments where organization_id = (select id from org)
union all select 'pde_expenses', count(*) from pde_expenses where organization_id = (select id from org)
union all select 'calendar_notes', count(*) from calendar_notes where organization_id = (select id from org)
union all select 'files', count(*) from files where organization_id = (select id from org)
union all select 'operation_results', count(*) from operation_results where organization_id = (select id from org)
union all select 'audit_logs', count(*) from audit_logs where organization_id = (select id from org)
order by tabla;

-- Si ejecutar_reset queda en false, no borra nada.
with org as (select id from organizations order by created_at limit 1)
delete from file_links
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from family_settlement_corrections
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from family_settlement_items
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from family_settlements
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from family_distribution_shares
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from family_distribution_groups
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_payment_allocations
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_payments
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_expense_allocations
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_charge_items
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_charges
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_expense_items
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_expense_periods
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_lease_adjustments
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_leases
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from maintenance_expenses
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from maintenance_tasks
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_units
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from urban_buildings
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from pde_expense_allocations
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from pde_reservation_payments
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from pde_expenses
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from pde_reservations
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from pde_units
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from calendar_notes
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from expense_categories
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from contacts
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from files
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from operation_results
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

with org as (select id from organizations order by created_at limit 1)
delete from audit_logs
where organization_id = (select id from org)
  and (select ejecutar_reset from reset_confirmacion);

select
  case
    when (select ejecutar_reset from reset_confirmacion)
      then 'RESET EJECUTADO'
    else 'NO SE BORRO NADA: ejecutar_reset esta en false'
  end as resultado;

commit;
