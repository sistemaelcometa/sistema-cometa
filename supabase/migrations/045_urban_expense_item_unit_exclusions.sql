-- Permite excluir departamentos puntuales de un gasto de expensas.

create table if not exists urban_expense_item_excluded_units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  expense_item_id uuid not null references urban_expense_items(id) on delete cascade,
  unit_id uuid not null references urban_units(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (expense_item_id, unit_id)
);

alter table urban_expense_item_excluded_units enable row level security;

drop policy if exists urban_expense_item_excluded_units_select_member on urban_expense_item_excluded_units;
create policy urban_expense_item_excluded_units_select_member on urban_expense_item_excluded_units
  for select using (is_org_member(organization_id));

drop policy if exists urban_expense_item_excluded_units_insert_editor on urban_expense_item_excluded_units;
create policy urban_expense_item_excluded_units_insert_editor on urban_expense_item_excluded_units
  for insert with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

drop policy if exists urban_expense_item_excluded_units_update_editor on urban_expense_item_excluded_units;
create policy urban_expense_item_excluded_units_update_editor on urban_expense_item_excluded_units
  for update using (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

drop policy if exists urban_expense_item_excluded_units_delete_editor on urban_expense_item_excluded_units;
create policy urban_expense_item_excluded_units_delete_editor on urban_expense_item_excluded_units
  for delete using (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create or replace function get_urban_expenses(target_organization_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with period_totals as (
    select
      p.id as period_id,
      p.building_id,
      p.period_month,
      p.status,
      coalesce(sum(i.amount) filter (where i.status = 'valid'), 0)::numeric(14, 2) as total_amount
    from urban_expense_periods p
    left join urban_expense_items i on i.period_id = p.id
    where p.organization_id = target_organization_id
      and is_org_member(target_organization_id)
    group by p.id
  ),
  allocation_totals as (
    select
      a.period_id,
      coalesce(sum(a.allocated_amount), 0)::numeric(14, 2) as allocated_amount
    from urban_expense_allocations a
    join urban_expense_periods p on p.id = a.period_id
    where p.organization_id = target_organization_id
      and is_org_member(target_organization_id)
    group by a.period_id
  ),
  excluded_units as (
    select
      eu.expense_item_id,
      coalesce(jsonb_agg(eu.unit_id order by u.name), '[]'::jsonb) as excluded_unit_ids
    from urban_expense_item_excluded_units eu
    join urban_units u on u.id = eu.unit_id
    where eu.organization_id = target_organization_id
    group by eu.expense_item_id
  )
  select jsonb_build_object(
    'expenses',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'buildingId', p.building_id,
            'periodMonth', p.period_month,
            'category', coalesce(c.name, split_part(i.description, ' - ', 2), i.description),
            'group', case
              when position(' - ' in i.description) > 0 then split_part(i.description, ' - ', 1)
              else 'Otros'
            end,
            'amount', i.amount,
            'rule', case when i.transfer_to_tenant then 'Trasladar al inquilino' else 'No trasladar al inquilino' end,
            'notes', i.notes,
            'excludedUnitIds', coalesce(eu.excluded_unit_ids, '[]'::jsonb),
            'status', i.status
          )
          order by p.period_month desc, i.created_at desc
        )
        from urban_expense_items i
        join urban_expense_periods p on p.id = i.period_id
        left join expense_categories c on c.id = i.category_id
        left join excluded_units eu on eu.expense_item_id = i.id
        where i.organization_id = target_organization_id
          and i.status = 'valid'
          and is_org_member(target_organization_id)
      ),
      '[]'::jsonb
    ),
    'calculations',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'periodId', pt.period_id,
            'buildingId', pt.building_id,
            'periodMonth', pt.period_month,
            'status', pt.status,
            'totalExpenses', pt.total_amount,
            'allocatedAmount', coalesce(at.allocated_amount, 0)
          )
          order by pt.period_month desc
        )
        from period_totals pt
        left join allocation_totals at on at.period_id = pt.period_id
        where pt.status in ('calculated', 'closed')
      ),
      '[]'::jsonb
    )
  );
$$;

create or replace function get_urban_expenses_page(
  target_organization_id uuid,
  building_filter uuid default null,
  category_search text default null,
  month_filter integer default null,
  year_filter integer default null,
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      nullif(trim(coalesce(category_search, '')), '') as category_query
  ),
  excluded_units as (
    select
      eu.expense_item_id,
      coalesce(jsonb_agg(eu.unit_id order by u.name), '[]'::jsonb) as excluded_unit_ids
    from urban_expense_item_excluded_units eu
    join urban_units u on u.id = eu.unit_id
    where eu.organization_id = target_organization_id
    group by eu.expense_item_id
  ),
  base_rows as (
    select
      e.id,
      ep.id as period_id,
      ep.period_month,
      b.id as building_id,
      b.name as building,
      e.expense_date,
      coalesce(c.name, 'Gasto') as category,
      e.description,
      e.amount,
      e.currency,
      e.transfer_to_tenant,
      e.notes,
      coalesce(eu.excluded_unit_ids, '[]'::jsonb) as excluded_unit_ids,
      ep.status::text as period_status,
      e.status::text as status_key,
      e.created_at,
      e.updated_at
    from urban_expense_items e
    join urban_expense_periods ep on ep.id = e.period_id
    join urban_buildings b on b.id = ep.building_id
    left join expense_categories c on c.id = e.category_id
    left join excluded_units eu on eu.expense_item_id = e.id
    cross join params p
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and is_org_member(target_organization_id)
      and (building_filter is null or b.id = building_filter)
      and (p.category_query is null or immutable_unaccent(coalesce(c.name, e.description)) ilike '%' || immutable_unaccent(p.category_query) || '%')
      and (month_filter is null or extract(month from ep.period_month)::integer = month_filter)
      and (year_filter is null or extract(year from ep.period_month)::integer = year_filter)
      and (from_date is null or e.expense_date >= from_date)
      and (to_date is null or e.expense_date <= to_date)
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by period_month desc, expense_date desc, created_at desc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'periodId', pr.period_id,
      'periodMonth', pr.period_month,
      'buildingId', pr.building_id,
      'building', pr.building,
      'date', pr.expense_date,
      'category', pr.category,
      'description', pr.description,
      'amount', pr.amount,
      'currency', pr.currency,
      'transferToTenant', pr.transfer_to_tenant,
      'notes', pr.notes,
      'excludedUnitIds', pr.excluded_unit_ids,
      'periodStatus', pr.period_status,
      'statusKey', pr.status_key,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.period_month desc, pr.expense_date desc, pr.created_at desc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;

drop function if exists save_urban_expense_item(uuid, uuid, date, text, text, numeric, boolean, text, uuid);

create or replace function save_urban_expense_item(
  target_organization_id uuid,
  target_building_id uuid,
  period_month date,
  category_group text,
  category_name text,
  expense_amount numeric,
  transfer_to_tenant boolean default true,
  expense_notes text default null,
  target_expense_item_id uuid default null,
  excluded_unit_ids uuid[] default '{}'::uuid[]
)
returns urban_expense_items
language plpgsql
security definer
set search_path = public
as $$
declare
  target_period urban_expense_periods;
  target_category expense_categories;
  saved_item urban_expense_items;
  previous_item urban_expense_items;
  excluded_ids uuid[] := coalesce(excluded_unit_ids, '{}'::uuid[]);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para cargar expensas.';
  end if;

  if period_month is null or period_month <> date_trunc('month', period_month)::date then
    raise exception 'El periodo debe ser el primer dia del mes.';
  end if;

  if nullif(trim(coalesce(category_name, '')), '') is null then
    raise exception 'El rubro es obligatorio.';
  end if;

  if coalesce(expense_amount, 0) <= 0 then
    raise exception 'El importe debe ser mayor a cero.';
  end if;

  if not exists (
    select 1
    from urban_buildings
    where id = target_building_id
      and organization_id = target_organization_id
      and status = 'active'
  ) then
    raise exception 'El edificio no existe o esta archivado.';
  end if;

  if exists (
    select 1
    from unnest(excluded_ids) excluded(unit_id)
    left join urban_units u
      on u.id = excluded.unit_id
     and u.organization_id = target_organization_id
     and u.building_id = target_building_id
     and u.status <> 'archived'
    where u.id is null
  ) then
    raise exception 'La lista de departamentos excluidos contiene departamentos invalidos.';
  end if;

  if (
    select count(*)
    from urban_units u
    where u.organization_id = target_organization_id
      and u.building_id = target_building_id
      and u.status <> 'archived'
      and not (u.id = any(excluded_ids))
  ) <= 0 then
    raise exception 'El gasto debe incluir al menos un departamento.';
  end if;

  select *
    into target_category
  from expense_categories
  where organization_id = target_organization_id
    and lower(name) = lower(trim(category_name))
    and status = 'active'
  order by created_at
  limit 1;

  if not found then
    insert into expense_categories (
      organization_id,
      name,
      scope,
      created_by
    )
    values (
      target_organization_id,
      trim(category_name),
      'urban',
      auth.uid()
    )
    returning * into target_category;
  end if;

  insert into urban_expense_periods (
    organization_id,
    building_id,
    period_month,
    status,
    created_by
  )
  values (
    target_organization_id,
    target_building_id,
    period_month,
    'draft',
    auth.uid()
  )
  on conflict (building_id, period_month) do update
  set status = case
    when urban_expense_periods.status = 'closed' then urban_expense_periods.status
    else 'draft'::expense_period_status
  end
  returning * into target_period;

  if target_period.status = 'closed' then
    raise exception 'El periodo de expensas esta cerrado.';
  end if;

  if target_expense_item_id is not null then
    select *
      into previous_item
    from urban_expense_items
    where id = target_expense_item_id
      and organization_id = target_organization_id
      and period_id = target_period.id
      and status = 'valid'
    for update;

    if not found then
      raise exception 'El gasto no existe o ya fue anulado.';
    end if;

    perform cleanup_urban_expense_period_allocations(target_organization_id, target_period.id);

    update urban_expense_items
    set
      category_id = target_category.id,
      expense_date = current_date,
      description = concat_ws(' - ', nullif(trim(coalesce(category_group, '')), ''), trim(category_name)),
      amount = expense_amount,
      currency = 'ARS',
      transfer_to_tenant = coalesce(transfer_to_tenant, true),
      notes = nullif(trim(coalesce(expense_notes, '')), '')
    where id = target_expense_item_id
    returning * into saved_item;
  else
    insert into urban_expense_items (
      organization_id,
      period_id,
      category_id,
      expense_date,
      description,
      amount,
      currency,
      transfer_to_tenant,
      notes,
      status,
      created_by
    )
    values (
      target_organization_id,
      target_period.id,
      target_category.id,
      current_date,
      concat_ws(' - ', nullif(trim(coalesce(category_group, '')), ''), trim(category_name)),
      expense_amount,
      'ARS',
      coalesce(transfer_to_tenant, true),
      nullif(trim(coalesce(expense_notes, '')), ''),
      'valid',
      auth.uid()
    )
    returning * into saved_item;
  end if;

  delete from urban_expense_item_excluded_units
  where organization_id = target_organization_id
    and expense_item_id = saved_item.id;

  insert into urban_expense_item_excluded_units (
    organization_id,
    expense_item_id,
    unit_id
  )
  select distinct
    target_organization_id,
    saved_item.id,
    excluded.unit_id
  from unnest(excluded_ids) excluded(unit_id);

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    case when previous_item.id is null then 'urban_expense_item_created' else 'urban_expense_item_updated' end,
    'urban_expense_item',
    saved_item.id,
    case when previous_item.id is null then null else to_jsonb(previous_item) end,
    to_jsonb(saved_item) || jsonb_build_object('excludedUnitIds', excluded_ids)
  );

  return saved_item;
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

  expense_charge_month := (date_trunc('month', calculate_urban_expense_period.period_month)::date + interval '1 month')::date;

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
    'chargedPeriodMonth', expense_charge_month,
    'totalExpenses', total_expenses,
    'buildingTotalSurface', building_total_surface
  );
end;
$$;
