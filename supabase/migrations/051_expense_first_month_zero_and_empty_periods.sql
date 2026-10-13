-- Evita cobrar expensas atrasadas a contratos que arrancan en el mes del cobro.
-- Tambien permite cerrar/liquidar un periodo de expensas en cero cuando no hubo gastos.

drop table if exists pg_temp.tmp_first_month_expense_charge_items;

create temporary table tmp_first_month_expense_charge_items on commit drop as
select
  ci.id as charge_item_id,
  ci.charge_id
from urban_charge_items ci
join urban_charges ch
  on ch.id = ci.charge_id
join urban_leases l
  on l.id = ch.lease_id
join urban_expense_allocations a
  on a.charge_item_id = ci.id
join urban_expense_periods p
  on p.id = a.period_id
where ci.item_type in ('building_expense', 'unit_expense')
  and ci.source_entity_type = 'urban_expense_allocation'
  and p.period_month < date_trunc('month', l.start_date)::date
  and not exists (
    select 1
    from urban_payment_allocations pa
    where pa.charge_item_id = ci.id
  );

update urban_expense_allocations a
set charge_item_id = null
where a.charge_item_id in (
  select charge_item_id
  from tmp_first_month_expense_charge_items
);

delete from urban_charge_items ci
using tmp_first_month_expense_charge_items t
where ci.id = t.charge_item_id;

delete from urban_expense_allocations a
using urban_expense_periods p, urban_units u, urban_leases l
where a.period_id = p.id
  and a.unit_id = u.id
  and l.unit_id = u.id
  and l.organization_id = a.organization_id
  and p.period_month < date_trunc('month', l.start_date)::date
  and a.charge_item_id is null
  and not exists (
    select 1
    from urban_payment_allocations pa
    where pa.charge_item_id = a.charge_item_id
  );

with totals as (
  select
    ch.id as charge_id,
    coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as amount_due,
    coalesce(sum(pa.allocated_amount) filter (where pay.status = 'valid'), 0)::numeric(14, 2) as paid_amount
  from urban_charges ch
  left join urban_charge_items ci
    on ci.charge_id = ch.id
  left join urban_payment_allocations pa
    on pa.charge_item_id = ci.id
  left join urban_payments pay
    on pay.id = pa.payment_id
  where ch.id in (
    select distinct charge_id
    from tmp_first_month_expense_charge_items
  )
  group by ch.id
)
update urban_charges ch
set
  status = case
    when totals.amount_due > 0 and totals.paid_amount >= totals.amount_due then 'paid'::charge_status
    when totals.paid_amount > 0 then 'partial'::charge_status
    else 'pending'::charge_status
  end,
  updated_at = now()
from totals
where ch.id = totals.charge_id;

drop table if exists pg_temp.tmp_first_month_expense_charge_items;

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
