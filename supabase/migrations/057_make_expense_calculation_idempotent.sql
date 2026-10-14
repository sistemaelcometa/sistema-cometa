-- Hace idempotente la liquidacion de expensas.
-- Si ya existe una asignacion para el mismo gasto/departamento, se actualiza
-- en vez de intentar insertar otra fila y chocar con
-- urban_expense_allocations_expense_item_id_unit_id_key.

create or replace function calculate_urban_expense_period(
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
  target_period urban_expense_periods;
  building_total_surface numeric(10, 2);
  expense_total_surface numeric(10, 2);
  expense_record record;
  unit_record record;
  allocation urban_expense_allocations;
  existing_paid_allocation_id uuid;
  charge urban_charges;
  charge_item urban_charge_items;
  allocated numeric(14, 2);
  total_expenses numeric(14, 2);
  expense_charge_month date;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para calcular expensas.';
  end if;

  if calculate_urban_expense_period.period_month is null
     or calculate_urban_expense_period.period_month <> date_trunc('month', calculate_urban_expense_period.period_month)::date then
    raise exception 'El periodo de expensas debe ser el primer dia del mes.';
  end if;

  expense_charge_month := (date_trunc('month', calculate_urban_expense_period.period_month)::date + interval '1 month')::date;

  select *
    into target_period
  from urban_expense_periods
  where organization_id = target_organization_id
    and building_id = target_building_id
    and urban_expense_periods.period_month = calculate_urban_expense_period.period_month
  for update;

  if not found then
    insert into urban_expense_periods (
      organization_id,
      building_id,
      period_month,
      status,
      created_by
    )
    select
      target_organization_id,
      target_building_id,
      calculate_urban_expense_period.period_month,
      'draft'::expense_period_status,
      auth.uid()
    where exists (
      select 1
      from urban_buildings b
      where b.id = target_building_id
        and b.organization_id = target_organization_id
        and b.status = 'active'
    )
    returning * into target_period;
  end if;

  if target_period.id is null then
    raise exception 'No se encontro el edificio para calcular expensas.';
  end if;

  if target_period.status = 'closed' then
    raise exception 'El periodo de expensas esta cerrado.';
  end if;

  perform cleanup_urban_expense_period_allocations(target_organization_id, target_period.id);

  select coalesce(sum(surface_m2), 0)
    into building_total_surface
  from urban_units
  where building_id = target_building_id
    and organization_id = target_organization_id
    and status <> 'archived';

  if building_total_surface <= 0 then
    raise exception 'El edificio no tiene superficie cargada para distribuir.';
  end if;

  for expense_record in
    select
      i.*,
      coalesce(array_agg(eu.unit_id) filter (where eu.unit_id is not null), '{}'::uuid[]) as excluded_unit_ids
    from urban_expense_items i
    left join urban_expense_item_excluded_units eu
      on eu.expense_item_id = i.id
     and eu.organization_id = target_organization_id
    where i.period_id = target_period.id
      and i.organization_id = target_organization_id
      and i.status = 'valid'
    group by i.id
  loop
    select coalesce(sum(u.surface_m2), 0)
      into expense_total_surface
    from urban_units u
    where u.building_id = target_building_id
      and u.organization_id = target_organization_id
      and u.status <> 'archived'
      and not (u.id = any(expense_record.excluded_unit_ids));

    if expense_total_surface <= 0 then
      raise exception 'El gasto "%" no tiene departamentos incluidos.', expense_record.description;
    end if;

    for unit_record in
      select
        u.*,
        l.id as lease_id,
        l.currency,
        l.monthly_due_day
      from urban_units u
      left join urban_leases l
        on l.unit_id = u.id
       and l.organization_id = target_organization_id
       and l.status = 'active'
       and expense_charge_month between date_trunc('month', l.start_date)::date and date_trunc('month', l.end_date)::date
       and calculate_urban_expense_period.period_month >= date_trunc('month', l.start_date)::date
      where u.building_id = target_building_id
        and u.organization_id = target_organization_id
        and u.status <> 'archived'
        and not (u.id = any(expense_record.excluded_unit_ids))
    loop
      allocated := round(expense_record.amount * unit_record.surface_m2 / expense_total_surface, 2);
      existing_paid_allocation_id := null;
      allocation := null;

      select a.id
        into existing_paid_allocation_id
      from urban_expense_allocations a
      where a.period_id = target_period.id
        and a.expense_item_id = expense_record.id
        and a.unit_id = unit_record.id
        and a.organization_id = target_organization_id
        and exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = a.charge_item_id
            and pay.status = 'valid'
        )
      limit 1;

      if existing_paid_allocation_id is not null then
        continue;
      end if;

      select *
        into allocation
      from urban_expense_allocations a
      where a.organization_id = target_organization_id
        and a.expense_item_id = expense_record.id
        and a.unit_id = unit_record.id
      for update;

      if allocation.id is not null then
        update urban_charge_items old_item
        set
          description = 'Expensas recalculadas',
          amount_due = 0
        where old_item.id = allocation.charge_item_id
          and old_item.organization_id = target_organization_id
          and old_item.item_type in ('building_expense', 'unit_expense')
          and not exists (
            select 1
            from urban_payment_allocations pa
            join urban_payments pay on pay.id = pa.payment_id
            where pa.charge_item_id = old_item.id
              and pay.status = 'valid'
          );

        update urban_expense_allocations
        set
          period_id = target_period.id,
          unit_surface_m2_snapshot = unit_record.surface_m2,
          building_total_surface_m2_snapshot = expense_total_surface,
          percentage_snapshot = round(unit_record.surface_m2 / expense_total_surface * 100, 6),
          allocated_amount = allocated,
          currency = expense_record.currency,
          transfer_to_tenant = expense_record.transfer_to_tenant,
          tenant_amount = case when expense_record.transfer_to_tenant then allocated else 0 end,
          charge_item_id = null
        where id = allocation.id
        returning * into allocation;
      else
        insert into urban_expense_allocations (
          organization_id,
          expense_item_id,
          period_id,
          unit_id,
          unit_surface_m2_snapshot,
          building_total_surface_m2_snapshot,
          percentage_snapshot,
          allocated_amount,
          currency,
          transfer_to_tenant,
          tenant_amount
        )
        values (
          target_organization_id,
          expense_record.id,
          target_period.id,
          unit_record.id,
          unit_record.surface_m2,
          expense_total_surface,
          round(unit_record.surface_m2 / expense_total_surface * 100, 6),
          allocated,
          expense_record.currency,
          expense_record.transfer_to_tenant,
          case when expense_record.transfer_to_tenant then allocated else 0 end
        )
        returning * into allocation;
      end if;

      if expense_record.transfer_to_tenant and unit_record.lease_id is not null and allocated > 0 then
        charge := ensure_urban_expense_charge(
          target_organization_id,
          unit_record.id,
          (expense_charge_month + ((least(coalesce(unit_record.monthly_due_day, 10), 28) - 1) * interval '1 day'))::date
        );

        insert into urban_charge_items (
          organization_id,
          charge_id,
          item_type,
          description,
          amount_due,
          currency,
          source_entity_type,
          source_entity_id
        )
        values (
          target_organization_id,
          charge.id,
          'building_expense',
          expense_record.description,
          allocated,
          expense_record.currency,
          'urban_expense_allocation',
          allocation.id
        )
        returning * into charge_item;

        update urban_expense_allocations
        set charge_item_id = charge_item.id
        where id = allocation.id;
      end if;
    end loop;
  end loop;

  perform reconcile_urban_expense_period_charges(target_organization_id, target_period.id);

  select coalesce(sum(amount), 0)
    into total_expenses
  from urban_expense_items
  where period_id = target_period.id
    and status = 'valid';

  update urban_expense_periods
  set status = 'calculated',
      updated_at = now()
  where id = target_period.id;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    'urban_expense_period_calculated',
    'urban_expense_period',
    target_period.id,
    jsonb_build_object('period_id', target_period.id, 'total_expenses', total_expenses)
  );

  return jsonb_build_object(
    'periodId', target_period.id,
    'buildingId', target_building_id,
    'periodMonth', period_month,
    'chargedPeriodMonth', expense_charge_month,
    'totalExpenses', total_expenses,
    'buildingTotalSurface', building_total_surface
  );
end;
$$;
