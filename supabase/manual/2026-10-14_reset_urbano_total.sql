-- RESET URBANO TOTAL
--
-- Conserva:
-- - auth.users, profiles, organizations y organization_members.
-- - PDE, calendario, categorias, archivos fisicos, auditoria y configuracion.
--
-- Borra:
-- - Edificios urbanos y departamentos.
-- - Contratos, ajustes, cobros, conceptos, pagos e imputaciones.
-- - Expensas urbanas: periodos, gastos, exclusiones y distribuciones.
-- - Mantenimiento urbano y liquidaciones familiares vinculadas a departamentos urbanos
--   porque esas tablas bloquean el borrado de departamentos por foreign keys.
-- - Contactos marcados como inquilino o usados como inquilino en contratos urbanos.
-- - Links de archivos asociados a los registros urbanos borrados.
--
-- USO:
-- 1) Ejecuta primero el bloque de VISTA PREVIA.
-- 2) Si esta todo bien, cambia en el bloque de EJECUCION:
--      v_ejecutar_reset boolean := false;
--    por:
--      v_ejecutar_reset boolean := true;
-- 3) Ejecuta el archivo completo.
--
-- Si tenes mas de una organizacion, completa v_target_organization_id con el id.

-- =========================
-- VISTA PREVIA
-- =========================

with org as (
  select id, name
  from organizations
  order by created_at
  limit 1
),
tenant_contacts as (
  select distinct c.id
  from contacts c
  left join urban_leases l
    on l.primary_tenant_contact_id = c.id
   and l.organization_id = c.organization_id
  where c.organization_id = (select id from org)
    and (c.is_tenant is true or l.id is not null)
)
select 'organizacion' as tabla, (select name from org) as detalle, 1 as registros
union all select 'urban_buildings', 'edificios', count(*) from urban_buildings where organization_id = (select id from org)
union all select 'urban_units', 'departamentos', count(*) from urban_units where organization_id = (select id from org)
union all select 'urban_leases', 'contratos', count(*) from urban_leases where organization_id = (select id from org)
union all select 'urban_lease_adjustments', 'actualizaciones de contratos', count(*) from urban_lease_adjustments where organization_id = (select id from org)
union all select 'urban_charges', 'cobros mensuales', count(*) from urban_charges where organization_id = (select id from org)
union all select 'urban_charge_items', 'conceptos de cobro', count(*) from urban_charge_items where organization_id = (select id from org)
union all select 'urban_payments', 'pagos registrados', count(*) from urban_payments where organization_id = (select id from org)
union all select 'urban_payment_allocations', 'imputaciones de pagos', count(*) from urban_payment_allocations where organization_id = (select id from org)
union all select 'urban_expense_periods', 'periodos de expensas', count(*) from urban_expense_periods where organization_id = (select id from org)
union all select 'urban_expense_items', 'gastos de expensas', count(*) from urban_expense_items where organization_id = (select id from org)
union all select 'urban_expense_allocations', 'distribuciones de expensas', count(*) from urban_expense_allocations where organization_id = (select id from org)
union all select 'urban_expense_item_excluded_units', 'exclusiones de expensas', count(*)
  from urban_expense_item_excluded_units
  where organization_id = (select id from org)
union all select 'maintenance_tasks', 'mantenimientos urbanos', count(*) from maintenance_tasks where organization_id = (select id from org)
union all select 'maintenance_expenses', 'gastos de mantenimiento', count(*) from maintenance_expenses where organization_id = (select id from org)
union all select 'family_distribution_groups', 'grupos familiares vinculados a departamentos', count(*) from family_distribution_groups where organization_id = (select id from org)
union all select 'family_settlements', 'liquidaciones familiares', count(*) from family_settlements where organization_id = (select id from org)
union all select 'contacts', 'inquilinos/contactos urbanos a borrar', count(*) from tenant_contacts
order by tabla;

-- =========================
-- EJECUCION
-- =========================

do $$
declare
  v_ejecutar_reset boolean := false;
  v_target_organization_id uuid := null;
  v_organization_id uuid;
  v_tenant_contact_ids uuid[] := '{}'::uuid[];
  v_deleted integer;
begin
  select coalesce(
    v_target_organization_id,
    (select id from organizations order by created_at limit 1)
  )
    into v_organization_id;

  if v_organization_id is null then
    raise exception 'No se encontro ninguna organizacion.';
  end if;

  if not v_ejecutar_reset then
    raise notice 'NO SE BORRO NADA. Cambia v_ejecutar_reset a true para ejecutar el reset urbano.';
    return;
  end if;

  select coalesce(array_agg(distinct contact_id), '{}'::uuid[])
    into v_tenant_contact_ids
  from (
    select primary_tenant_contact_id as contact_id
    from urban_leases
    where organization_id = v_organization_id
      and primary_tenant_contact_id is not null

    union

    select id as contact_id
    from contacts
    where organization_id = v_organization_id
      and is_tenant is true
  ) contact_source;

  delete from file_links
  where organization_id = v_organization_id
    and entity_type in (
      'urban_building',
      'urban_unit',
      'urban_lease',
      'urban_lease_adjustment',
      'urban_charge',
      'urban_charge_item',
      'urban_payment',
      'urban_expense_period',
      'urban_expense_item',
      'maintenance_task',
      'maintenance_expense',
      'family_distribution_group',
      'family_distribution_share',
      'family_settlement',
      'family_settlement_item'
    );
  get diagnostics v_deleted = row_count;
  raise notice 'file_links borrados: %', v_deleted;

  delete from family_settlement_corrections
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'family_settlement_corrections borrados: %', v_deleted;

  delete from family_settlement_items
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'family_settlement_items borrados: %', v_deleted;

  delete from family_settlements
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'family_settlements borrados: %', v_deleted;

  delete from family_distribution_shares
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'family_distribution_shares borrados: %', v_deleted;

  delete from family_distribution_groups
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'family_distribution_groups borrados: %', v_deleted;

  delete from urban_payment_allocations
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_payment_allocations borrados: %', v_deleted;

  delete from urban_payments
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_payments borrados: %', v_deleted;

  delete from urban_expense_allocations
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_expense_allocations borrados: %', v_deleted;

  if to_regclass('public.urban_expense_item_excluded_units') is not null then
    delete from urban_expense_item_excluded_units
    where organization_id = v_organization_id;
    get diagnostics v_deleted = row_count;
    raise notice 'urban_expense_item_excluded_units borrados: %', v_deleted;
  end if;

  delete from urban_charge_items
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_charge_items borrados: %', v_deleted;

  delete from urban_charges
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_charges borrados: %', v_deleted;

  delete from urban_expense_items
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_expense_items borrados: %', v_deleted;

  delete from urban_expense_periods
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_expense_periods borrados: %', v_deleted;

  delete from urban_lease_adjustments
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_lease_adjustments borrados: %', v_deleted;

  delete from urban_leases
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_leases borrados: %', v_deleted;

  delete from maintenance_expenses
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'maintenance_expenses borrados: %', v_deleted;

  delete from maintenance_tasks
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'maintenance_tasks borrados: %', v_deleted;

  delete from urban_units
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_units borrados: %', v_deleted;

  delete from urban_buildings
  where organization_id = v_organization_id;
  get diagnostics v_deleted = row_count;
  raise notice 'urban_buildings borrados: %', v_deleted;

  delete from contacts
  where organization_id = v_organization_id
    and id = any(v_tenant_contact_ids);
  get diagnostics v_deleted = row_count;
  raise notice 'contacts de inquilinos borrados: %', v_deleted;

  raise notice 'RESET URBANO EJECUTADO.';
end $$;

-- Control posterior: si el reset se ejecuto, estos valores deberian quedar en cero.
with org as (
  select id, name
  from organizations
  order by created_at
  limit 1
)
select 'urban_buildings' as tabla, count(*) as registros from urban_buildings where organization_id = (select id from org)
union all select 'urban_units', count(*) from urban_units where organization_id = (select id from org)
union all select 'urban_leases', count(*) from urban_leases where organization_id = (select id from org)
union all select 'urban_charges', count(*) from urban_charges where organization_id = (select id from org)
union all select 'urban_payments', count(*) from urban_payments where organization_id = (select id from org)
union all select 'urban_expense_periods', count(*) from urban_expense_periods where organization_id = (select id from org)
union all select 'urban_expense_items', count(*) from urban_expense_items where organization_id = (select id from org)
order by tabla;
