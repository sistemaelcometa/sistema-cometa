-- Corrige ambiguedades entre parametros de RPC y columnas de urban_expense_items.
-- Afectaba editar gastos (transfer_to_tenant) y anular gastos (void_reason).

create or replace function save_urban_expense_item(
  target_organization_id uuid,
  target_building_id uuid,
  period_month date,
  category_group text,
  category_name text,
  expense_amount numeric,
  transfer_to_tenant boolean default true,
  expense_notes text default null,
  target_expense_item_id uuid default null
)
returns urban_expense_items
language plpgsql
security definer
set search_path = public
as $$
declare
  expense_period_month date := save_urban_expense_item.period_month;
  expense_transfer_to_tenant boolean := coalesce(save_urban_expense_item.transfer_to_tenant, true);
  target_period urban_expense_periods;
  target_category expense_categories;
  saved_item urban_expense_items;
  previous_item urban_expense_items;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para cargar expensas.';
  end if;

  if expense_period_month is null
     or expense_period_month <> date_trunc('month', expense_period_month)::date then
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
    expense_period_month,
    'draft',
    auth.uid()
  )
  on conflict on constraint urban_expense_periods_building_id_period_month_key do update
  set status = case
    when urban_expense_periods.status = 'closed' then urban_expense_periods.status
    else urban_expense_periods.status
  end
  returning * into target_period;

  if target_period.status = 'closed' then
    raise exception 'El periodo de expensas esta cerrado.';
  end if;

  if target_period.status = 'calculated' then
    perform cleanup_urban_expense_period_allocations(target_organization_id, target_period.id);
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
      transfer_to_tenant = expense_transfer_to_tenant,
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
      expense_transfer_to_tenant,
      nullif(trim(coalesce(expense_notes, '')), ''),
      'valid',
      auth.uid()
    )
    returning * into saved_item;
  end if;

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
    to_jsonb(saved_item)
  );

  return saved_item;
end;
$$;

create or replace function void_urban_expense_item(
  target_organization_id uuid,
  target_expense_item_id uuid,
  void_reason text default null
)
returns urban_expense_items
language plpgsql
security definer
set search_path = public
as $$
declare
  expense_void_reason text := nullif(trim(coalesce(void_urban_expense_item.void_reason, '')), '');
  previous_item urban_expense_items;
  voided_item urban_expense_items;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para anular expensas.';
  end if;

  select *
    into previous_item
  from urban_expense_items
  where id = target_expense_item_id
    and organization_id = target_organization_id
    and status = 'valid'
  for update;

  if not found then
    raise exception 'El gasto no existe o ya fue anulado.';
  end if;

  if exists (
    select 1
    from urban_expense_periods
    where id = previous_item.period_id
      and status = 'closed'
  ) then
    raise exception 'No se puede anular un gasto de un periodo cerrado.';
  end if;

  perform cleanup_urban_expense_period_allocations(target_organization_id, previous_item.period_id);

  update urban_expense_items
  set
    status = 'voided',
    voided_at = now(),
    voided_by = auth.uid(),
    void_reason = expense_void_reason
  where id = target_expense_item_id
  returning * into voided_item;

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
    'urban_expense_item_voided',
    'urban_expense_item',
    voided_item.id,
    to_jsonb(previous_item),
    to_jsonb(voided_item)
  );

  return voided_item;
end;
$$;
