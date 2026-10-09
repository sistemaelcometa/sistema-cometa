-- Permite volver una liquidacion de expensas a borrador.
-- Elimina de cobros los items de expensa no cobrados para que vuelvan a figurar como sin liquidar.

create or replace function reset_urban_expense_period(
  target_organization_id uuid,
  target_building_id uuid,
  period_month date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reset_period_month date := date_trunc('month', reset_urban_expense_period.period_month)::date;
  target_period urban_expense_periods;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para volver atras la liquidacion de expensas.';
  end if;

  if reset_urban_expense_period.period_month is null
     or reset_urban_expense_period.period_month <> reset_period_month then
    raise exception 'El periodo debe ser el primer dia del mes.';
  end if;

  select *
    into target_period
  from urban_expense_periods
  where organization_id = target_organization_id
    and building_id = target_building_id
    and urban_expense_periods.period_month = reset_period_month
  for update;

  if not found then
    return jsonb_build_object(
      'status', 'missing',
      'periodMonth', reset_period_month
    );
  end if;

  if target_period.status = 'closed' then
    raise exception 'El periodo de expensas esta cerrado.';
  end if;

  perform cleanup_urban_expense_period_allocations(target_organization_id, target_period.id);

  return jsonb_build_object(
    'status', 'draft',
    'periodId', target_period.id,
    'periodMonth', reset_period_month
  );
end;
$$;
