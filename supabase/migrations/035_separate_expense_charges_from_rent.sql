-- Separa el calculo/cierre de expensas del alquiler mensual.
-- Las expensas generan items de expensa; no crean automaticamente un item de alquiler.
-- Al recalcular, no se borran items ya imputados a cobros para evitar romper auditoria/FKs.

create or replace function ensure_urban_expense_charge(
  target_organization_id uuid,
  target_unit_id uuid,
  charge_due_date date
)
returns urban_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  active_lease urban_leases;
  charge_month date;
  ensured_charge urban_charges;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para generar cargos de expensas.';
  end if;

  if charge_due_date is null then
    raise exception 'La fecha de vencimiento es obligatoria.';
  end if;

  charge_month := date_trunc('month', charge_due_date)::date;

  select *
    into active_lease
  from urban_leases
  where organization_id = target_organization_id
    and unit_id = target_unit_id
    and status = 'active'
    and charge_due_date between start_date and end_date
  order by start_date desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay contrato activo para ese vencimiento.';
  end if;

  insert into urban_charges (
    organization_id,
    lease_id,
    unit_id,
    period_month,
    due_date,
    status,
    created_by
  )
  values (
    target_organization_id,
    active_lease.id,
    target_unit_id,
    charge_month,
    charge_due_date,
    'pending',
    auth.uid()
  )
  on conflict (lease_id, period_month) do update
  set
    due_date = excluded.due_date,
    status = case
      when urban_charges.status = 'cancelled' then 'pending'::charge_status
      else urban_charges.status
    end
  returning * into ensured_charge;

  return ensured_charge;
end;
$$;

create or replace function cleanup_urban_expense_period_allocations(
  target_organization_id uuid,
  target_period_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  affected_charge_id uuid;
  affected_charge_ids uuid[] := '{}';
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para recalcular expensas.';
  end if;

  select coalesce(array_agg(distinct ci.charge_id), '{}')
    into affected_charge_ids
  from urban_expense_allocations a
  join urban_charge_items ci on ci.id = a.charge_item_id
  where a.period_id = target_period_id
    and a.organization_id = target_organization_id;

  delete from urban_charge_items i
  using urban_expense_allocations a
  where a.charge_item_id = i.id
    and a.period_id = target_period_id
    and a.organization_id = target_organization_id
    and i.item_type in ('building_expense', 'unit_expense')
    and not exists (
      select 1
      from urban_payment_allocations pa
      where pa.charge_item_id = i.id
    );

  delete from urban_expense_allocations a
  where a.period_id = target_period_id
    and a.organization_id = target_organization_id
    and (
      a.charge_item_id is null
      or not exists (
        select 1
        from urban_payment_allocations pa
        where pa.charge_item_id = a.charge_item_id
      )
    );

  foreach affected_charge_id in array affected_charge_ids
  loop
    select coalesce(sum(amount_due), 0)
      into total_due
    from urban_charge_items
    where charge_id = affected_charge_id;

    select coalesce(sum(pa.allocated_amount), 0)
      into total_paid
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    join urban_payments p on p.id = pa.payment_id
    where ci.charge_id = affected_charge_id
      and p.status = 'valid';

    update urban_charges
    set status = case
      when total_due <= 0 then 'cancelled'::charge_status
      when total_paid >= total_due then 'paid'::charge_status
      when total_paid > 0 then 'partial'::charge_status
      else 'pending'::charge_status
    end
    where id = affected_charge_id;
  end loop;

  update urban_expense_periods
  set status = 'draft'
  where id = target_period_id
    and organization_id = target_organization_id
    and status <> 'closed';
end;
$$;

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
  expense_record record;
  unit_record record;
  allocation urban_expense_allocations;
  existing_paid_allocation_id uuid;
  charge urban_charges;
  charge_item urban_charge_items;
  allocated numeric(14, 2);
  total_expenses numeric(14, 2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para calcular expensas.';
  end if;

  select *
    into target_period
  from urban_expense_periods
  where organization_id = target_organization_id
    and building_id = target_building_id
    and urban_expense_periods.period_month = calculate_urban_expense_period.period_month
  for update;

  if not found then
    raise exception 'No hay gastos cargados para ese periodo.';
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
    select *
    from urban_expense_items
    where period_id = target_period.id
      and organization_id = target_organization_id
      and status = 'valid'
  loop
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
       and calculate_urban_expense_period.period_month between date_trunc('month', l.start_date)::date and date_trunc('month', l.end_date)::date
      where u.building_id = target_building_id
        and u.organization_id = target_organization_id
        and u.status <> 'archived'
    loop
      allocated := round(expense_record.amount * unit_record.surface_m2 / building_total_surface, 2);

      existing_paid_allocation_id := null;

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
          where pa.charge_item_id = a.charge_item_id
        )
      limit 1;

      if existing_paid_allocation_id is not null then
        continue;
      end if;

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
        building_total_surface,
        round(unit_record.surface_m2 / building_total_surface * 100, 6),
        allocated,
        expense_record.currency,
        expense_record.transfer_to_tenant,
        case when expense_record.transfer_to_tenant then allocated else 0 end
      )
      returning * into allocation;

      if expense_record.transfer_to_tenant and unit_record.lease_id is not null and allocated > 0 then
        charge := ensure_urban_expense_charge(
          target_organization_id,
          unit_record.id,
          (period_month + ((least(coalesce(unit_record.monthly_due_day, 10), 28) - 1) * interval '1 day'))::date
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

  select coalesce(sum(amount), 0)
    into total_expenses
  from urban_expense_items
  where period_id = target_period.id
    and status = 'valid';

  update urban_expense_periods
  set status = 'calculated'
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
    'totalExpenses', total_expenses,
    'buildingTotalSurface', building_total_surface
  );
end;
$$;
