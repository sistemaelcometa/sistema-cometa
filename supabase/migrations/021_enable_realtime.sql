-- Habilita Realtime para las tablas operativas del sistema.
-- El frontend usa estos eventos para invalidar cache y refrescar vistas abiertas.

do $$
declare
  table_name text;
  realtime_tables text[] := array[
    'contacts',
    'urban_buildings',
    'urban_units',
    'urban_leases',
    'urban_lease_adjustments',
    'urban_charges',
    'urban_charge_items',
    'urban_payments',
    'urban_payment_allocations',
    'expense_categories',
    'urban_expense_periods',
    'urban_expense_items',
    'urban_expense_allocations',
    'family_distribution_groups',
    'family_distribution_shares',
    'family_settlements',
    'family_settlement_items',
    'family_settlement_corrections',
    'maintenance_tasks',
    'maintenance_expenses',
    'pde_units',
    'pde_reservations',
    'pde_reservation_payments',
    'pde_expenses',
    'pde_expense_allocations',
    'calendar_notes',
    'files',
    'file_links'
  ];
begin
  foreach table_name in array realtime_tables loop
    execute format('alter table public.%I replica identity full', table_name);

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = table_name
    ) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
end;
$$;
