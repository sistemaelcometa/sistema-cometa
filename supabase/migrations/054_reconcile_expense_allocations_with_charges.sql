-- Mantiene alineada la liquidacion de expensas con la tabla de cobros.
-- Si una expensa transferible fue calculada para un departamento, debe existir
-- su concepto de cobro aun cuando ese departamento este excluido de otros gastos.

create or replace function reconcile_urban_expense_period_charges(
  target_organization_id uuid,
  target_period_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  allocation_record record;
  ensured_charge urban_charges;
  ensured_charge_item_id uuid;
  total_due numeric(14, 2);
  total_paid numeric(14, 2);
begin
  if auth.uid() is null
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'Usuario no autenticado.';
  end if;

  if auth.uid() is not null
     and not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para reconciliar expensas.';
  end if;

  for allocation_record in
    select
      a.id as allocation_id,
      a.unit_id,
      a.tenant_amount,
      a.currency,
      a.charge_item_id,
      i.description,
      (p.period_month + interval '1 month')::date as charge_month,
      coalesce(l.monthly_due_day, 10) as monthly_due_day,
      l.id as lease_id
    from urban_expense_allocations a
    join urban_expense_items i on i.id = a.expense_item_id
    join urban_expense_periods p on p.id = a.period_id
    join urban_leases l
      on l.unit_id = a.unit_id
     and l.organization_id = a.organization_id
     and l.status = 'active'
     and (p.period_month + interval '1 month')::date between date_trunc('month', l.start_date)::date and date_trunc('month', l.end_date)::date
     and p.period_month >= date_trunc('month', l.start_date)::date
    where a.organization_id = target_organization_id
      and a.period_id = target_period_id
      and a.transfer_to_tenant
      and a.tenant_amount > 0
      and i.status = 'valid'
  loop
    if allocation_record.charge_item_id is not null
       and exists (
         select 1
         from urban_charge_items ci
         join urban_charges ch on ch.id = ci.charge_id
         where ci.id = allocation_record.charge_item_id
           and ci.organization_id = target_organization_id
           and ch.lease_id = allocation_record.lease_id
           and ch.unit_id = allocation_record.unit_id
           and ci.item_type in ('building_expense', 'unit_expense')
       ) then
      update urban_charge_items
      set
        description = allocation_record.description,
        amount_due = allocation_record.tenant_amount,
        currency = allocation_record.currency,
        source_entity_type = 'urban_expense_allocation',
        source_entity_id = allocation_record.allocation_id
      where id = allocation_record.charge_item_id
        and organization_id = target_organization_id
        and not exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = allocation_record.charge_item_id
            and pay.status = 'valid'
        );

      continue;
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
      allocation_record.lease_id,
      allocation_record.unit_id,
      allocation_record.charge_month,
      (
        allocation_record.charge_month
        + ((least(coalesce(allocation_record.monthly_due_day, 10), 28) - 1) * interval '1 day')
      )::date,
      'pending',
      auth.uid()
    )
    on conflict (lease_id, period_month) do update
    set
      due_date = excluded.due_date,
      status = case
        when urban_charges.status = 'cancelled' then 'pending'::charge_status
        else urban_charges.status
      end,
      updated_at = now()
    returning * into ensured_charge;

    select ci.id
      into ensured_charge_item_id
    from urban_charge_items ci
    where ci.organization_id = target_organization_id
      and ci.charge_id = ensured_charge.id
      and ci.source_entity_type = 'urban_expense_allocation'
      and ci.source_entity_id = allocation_record.allocation_id
    limit 1;

    if ensured_charge_item_id is null then
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
        ensured_charge.id,
        'building_expense',
        allocation_record.description,
        allocation_record.tenant_amount,
        allocation_record.currency,
        'urban_expense_allocation',
        allocation_record.allocation_id
      )
      returning id into ensured_charge_item_id;
    else
      update urban_charge_items
      set
        description = allocation_record.description,
        amount_due = allocation_record.tenant_amount,
        currency = allocation_record.currency
      where id = ensured_charge_item_id
        and not exists (
          select 1
          from urban_payment_allocations pa
          join urban_payments pay on pay.id = pa.payment_id
          where pa.charge_item_id = ensured_charge_item_id
            and pay.status = 'valid'
        );
    end if;

    update urban_expense_allocations
    set charge_item_id = ensured_charge_item_id
    where id = allocation_record.allocation_id
      and organization_id = target_organization_id;
  end loop;

  for ensured_charge in
    select distinct ch.*
    from urban_charges ch
    join urban_charge_items ci on ci.charge_id = ch.id
    join urban_expense_allocations a on a.charge_item_id = ci.id
    where a.organization_id = target_organization_id
      and a.period_id = target_period_id
  loop
    select coalesce(sum(amount_due), 0)
      into total_due
    from urban_charge_items
    where charge_id = ensured_charge.id;

    select coalesce(sum(pa.allocated_amount), 0)
      into total_paid
    from urban_payment_allocations pa
    join urban_charge_items ci on ci.id = pa.charge_item_id
    join urban_payments pay on pay.id = pa.payment_id
    where ci.charge_id = ensured_charge.id
      and pay.status = 'valid';

    update urban_charges
    set status = case
      when total_due > 0 and total_paid >= total_due then 'paid'::charge_status
      when total_paid > 0 then 'partial'::charge_status
      else 'pending'::charge_status
    end,
    updated_at = now()
    where id = ensured_charge.id;
  end loop;
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

do $$
declare
  period_record record;
begin
  for period_record in
    select id, organization_id
    from urban_expense_periods
    where status in ('calculated', 'closed')
  loop
    perform reconcile_urban_expense_period_charges(period_record.organization_id, period_record.id);
  end loop;
end;
$$;
