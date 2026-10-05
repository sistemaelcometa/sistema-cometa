create or replace function ensure_urban_maintenance_category(
  target_organization_id uuid,
  category_name text default 'Mantenimiento'
)
returns expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_name text := coalesce(nullif(trim(category_name), ''), 'Mantenimiento');
  existing_category expense_categories;
begin
  select *
    into existing_category
  from expense_categories
  where organization_id = target_organization_id
    and status = 'active'
    and scope in ('urban', 'both')
    and lower(name) = lower(cleaned_name)
  order by created_at
  limit 1
  for update;

  if found then
    return existing_category;
  end if;

  insert into expense_categories (
    organization_id,
    name,
    scope,
    created_by
  )
  values (
    target_organization_id,
    cleaned_name,
    'urban',
    auth.uid()
  )
  returning * into existing_category;

  return existing_category;
end;
$$;

create or replace function ensure_urban_worker_contact(
  target_organization_id uuid,
  worker_name text,
  worker_phone text default null,
  worker_profession text default null
)
returns contacts
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_name text := nullif(trim(coalesce(worker_name, '')), '');
  cleaned_phone text := nullif(trim(coalesce(worker_phone, '')), '');
  cleaned_profession text := nullif(trim(coalesce(worker_profession, '')), '');
  existing_contact contacts;
begin
  if cleaned_name is null then
    return null;
  end if;

  select *
    into existing_contact
  from contacts
  where organization_id = target_organization_id
    and status = 'active'
    and is_worker = true
    and lower(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, ''))) = lower(cleaned_name)
  order by created_at
  limit 1
  for update;

  if found then
    update contacts
    set
      phone = coalesce(cleaned_phone, phone),
      notes = coalesce(cleaned_profession, notes),
      is_provider = true,
      updated_at = now()
    where id = existing_contact.id
    returning * into existing_contact;

    return existing_contact;
  end if;

  insert into contacts (
    organization_id,
    contact_type,
    first_name,
    phone,
    notes,
    is_provider,
    is_worker,
    created_by
  )
  values (
    target_organization_id,
    'person',
    cleaned_name,
    cleaned_phone,
    cleaned_profession,
    true,
    true,
    auth.uid()
  )
  returning * into existing_contact;

  return existing_contact;
end;
$$;

create or replace function get_urban_maintenance(
  target_organization_id uuid,
  target_unit_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'unitId', t.unit_id,
        'unitName', u.name,
        'buildingId', b.id,
        'buildingName', b.name,
        'title', t.title,
        'detail', t.detail,
        'professionalName', nullif(trim(coalesce(w.first_name, '') || ' ' || coalesce(w.last_name, '')), ''),
        'professionalPhone', w.phone,
        'profession', w.notes,
        'status', case t.status
          when 'finished' then 'Terminada'
          when 'cancelled' then 'Cancelada'
          else 'Abierta'
        end,
        'statusKey', t.status,
        'startedAt', t.opened_at,
        'finishedAt', t.finished_at,
        'createdAt', t.created_at,
        'expenses', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', e.id,
              'date', e.expense_date,
              'concept', e.description,
              'amount', e.amount,
              'currency', e.currency,
              'categoryName', c.name,
              'receiptName', receipt.original_filename,
              'receiptBucket', receipt.bucket,
              'receiptPath', receipt.storage_path,
              'fileId', receipt.file_id
            )
            order by e.expense_date desc, e.created_at desc
          )
          from maintenance_expenses e
          left join expense_categories c on c.id = e.category_id
          left join lateral (
            select
              f.id as file_id,
              f.bucket,
              f.storage_path,
              f.original_filename
            from file_links fl
            join files f on f.id = fl.file_id
            where fl.organization_id = e.organization_id
              and fl.entity_type = 'maintenance_expense'
              and fl.entity_id = e.id
              and f.status = 'active'
            order by f.created_at desc
            limit 1
          ) receipt on true
          where e.organization_id = t.organization_id
            and e.task_id = t.id
            and e.status = 'valid'
        ), '[]'::jsonb)
      )
      order by t.opened_at desc, t.created_at desc
    ),
    '[]'::jsonb
  )
  from maintenance_tasks t
  join urban_units u on u.id = t.unit_id
  join urban_buildings b on b.id = u.building_id
  left join contacts w on w.id = t.worker_contact_id
  where t.organization_id = target_organization_id
    and t.status <> 'cancelled'
    and (target_unit_id is null or t.unit_id = target_unit_id)
    and is_org_member(target_organization_id);
$$;

create or replace function save_maintenance_task(
  target_organization_id uuid,
  target_unit_id uuid,
  task_title text,
  target_task_id uuid default null,
  task_detail text default null,
  professional_name text default null,
  professional_phone text default null,
  profession text default null,
  task_opened_at date default current_date,
  operation_id uuid default gen_random_uuid()
)
returns maintenance_tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_unit urban_units;
  selected_worker contacts;
  old_task maintenance_tasks;
  saved_task maintenance_tasks;
  existing_operation operation_results;
  request_hash text;
  cleaned_title text := nullif(trim(coalesce(task_title, '')), '');
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para guardar tareas de mantenimiento.';
  end if;

  if cleaned_title is null then
    raise exception 'El titulo de la tarea es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_unit_id', target_unit_id,
    'task_title', cleaned_title,
    'target_task_id', target_task_id,
    'task_detail', task_detail,
    'professional_name', professional_name,
    'professional_phone', professional_phone,
    'profession', profession,
    'task_opened_at', task_opened_at
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = save_maintenance_task.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_task
      from maintenance_tasks
      where id = existing_operation.result_entity_id;

      return saved_task;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    save_maintenance_task.operation_id,
    'save_maintenance_task',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into selected_unit
  from urban_units
  where id = target_unit_id
    and organization_id = target_organization_id
    and status <> 'archived'
  for update;

  if not found then
    raise exception 'El departamento no existe o esta archivado.';
  end if;

  selected_worker := ensure_urban_worker_contact(
    target_organization_id,
    professional_name,
    professional_phone,
    profession
  );

  if target_task_id is null then
    insert into maintenance_tasks (
      organization_id,
      unit_id,
      title,
      detail,
      worker_contact_id,
      status,
      opened_at,
      created_by
    )
    values (
      target_organization_id,
      selected_unit.id,
      cleaned_title,
      nullif(trim(coalesce(task_detail, '')), ''),
      selected_worker.id,
      'open',
      task_opened_at,
      auth.uid()
    )
    returning * into saved_task;
  else
    select *
      into old_task
    from maintenance_tasks
    where id = target_task_id
      and organization_id = target_organization_id
      and status <> 'cancelled'
    for update;

    if not found then
      raise exception 'La tarea de mantenimiento no existe o fue anulada.';
    end if;

    update maintenance_tasks
    set
      unit_id = selected_unit.id,
      title = cleaned_title,
      detail = nullif(trim(coalesce(task_detail, '')), ''),
      worker_contact_id = selected_worker.id,
      opened_at = task_opened_at,
      version = version + 1
    where id = old_task.id
    returning * into saved_task;
  end if;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    save_maintenance_task.operation_id,
    case when target_task_id is null then 'maintenance_task_created' else 'maintenance_task_updated' end,
    'maintenance_task',
    saved_task.id,
    case when target_task_id is null then null else to_jsonb(old_task) end,
    to_jsonb(saved_task),
    jsonb_build_object('unitId', selected_unit.id, 'workerContactId', selected_worker.id)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'maintenance_task',
    result_entity_id = saved_task.id,
    result_payload = to_jsonb(saved_task),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = save_maintenance_task.operation_id;

  return saved_task;
end;
$$;

create or replace function finish_maintenance_task(
  target_organization_id uuid,
  target_task_id uuid,
  task_finished_at date default current_date,
  operation_id uuid default gen_random_uuid()
)
returns maintenance_tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  old_task maintenance_tasks;
  saved_task maintenance_tasks;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para cerrar tareas de mantenimiento.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_task_id', target_task_id,
    'task_finished_at', task_finished_at
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = finish_maintenance_task.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_task
      from maintenance_tasks
      where id = existing_operation.result_entity_id;

      return saved_task;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    finish_maintenance_task.operation_id,
    'finish_maintenance_task',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_task
  from maintenance_tasks
  where id = target_task_id
    and organization_id = target_organization_id
    and status = 'open'
  for update;

  if not found then
    raise exception 'La tarea no existe o no esta abierta.';
  end if;

  update maintenance_tasks
  set
    status = 'finished',
    finished_at = task_finished_at,
    version = version + 1
  where id = old_task.id
  returning * into saved_task;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    finish_maintenance_task.operation_id,
    'maintenance_task_finished',
    'maintenance_task',
    saved_task.id,
    to_jsonb(old_task),
    to_jsonb(saved_task),
    jsonb_build_object('finishedAt', task_finished_at)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'maintenance_task',
    result_entity_id = saved_task.id,
    result_payload = to_jsonb(saved_task),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = finish_maintenance_task.operation_id;

  return saved_task;
end;
$$;

create or replace function cancel_maintenance_task(
  target_organization_id uuid,
  target_task_id uuid,
  reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns maintenance_tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  old_task maintenance_tasks;
  saved_task maintenance_tasks;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo duenio o administrador pueden eliminar tareas de mantenimiento.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_task_id', target_task_id,
    'reason', reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = cancel_maintenance_task.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_task
      from maintenance_tasks
      where id = existing_operation.result_entity_id;

      return saved_task;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    cancel_maintenance_task.operation_id,
    'cancel_maintenance_task',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_task
  from maintenance_tasks
  where id = target_task_id
    and organization_id = target_organization_id
    and status <> 'cancelled'
  for update;

  if not found then
    raise exception 'La tarea no existe o ya fue anulada.';
  end if;

  update maintenance_tasks
  set
    status = 'cancelled',
    version = version + 1
  where id = old_task.id
  returning * into saved_task;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    cancel_maintenance_task.operation_id,
    'maintenance_task_cancelled',
    'maintenance_task',
    saved_task.id,
    to_jsonb(old_task),
    to_jsonb(saved_task),
    jsonb_build_object('reason', reason)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'maintenance_task',
    result_entity_id = saved_task.id,
    result_payload = to_jsonb(saved_task),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = cancel_maintenance_task.operation_id;

  return saved_task;
end;
$$;

create or replace function save_maintenance_expense(
  target_organization_id uuid,
  target_task_id uuid,
  expense_date date,
  amount numeric,
  description text,
  currency char(3) default 'ARS',
  category_name text default 'Mantenimiento',
  target_expense_id uuid default null,
  operation_id uuid default gen_random_uuid()
)
returns maintenance_expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_task maintenance_tasks;
  selected_category expense_categories;
  old_expense maintenance_expenses;
  saved_expense maintenance_expenses;
  existing_operation operation_results;
  request_hash text;
  cleaned_description text := nullif(trim(coalesce(description, '')), '');
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para guardar gastos de mantenimiento.';
  end if;

  if amount <= 0 then
    raise exception 'El importe del gasto debe ser mayor a cero.';
  end if;

  if currency not in ('ARS', 'USD') then
    raise exception 'La moneda del gasto no es valida.';
  end if;

  if cleaned_description is null then
    raise exception 'El detalle del gasto es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_task_id', target_task_id,
    'expense_date', expense_date,
    'amount', amount,
    'description', cleaned_description,
    'currency', currency,
    'category_name', category_name,
    'target_expense_id', target_expense_id
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = save_maintenance_expense.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_expense
      from maintenance_expenses
      where id = existing_operation.result_entity_id;

      return saved_expense;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    save_maintenance_expense.operation_id,
    'save_maintenance_expense',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into selected_task
  from maintenance_tasks
  where id = target_task_id
    and organization_id = target_organization_id
    and status <> 'cancelled'
  for update;

  if not found then
    raise exception 'La tarea de mantenimiento no existe o fue anulada.';
  end if;

  selected_category := ensure_urban_maintenance_category(target_organization_id, category_name);

  if target_expense_id is null then
    insert into maintenance_expenses (
      organization_id,
      task_id,
      category_id,
      expense_date,
      description,
      amount,
      currency,
      created_by
    )
    values (
      target_organization_id,
      selected_task.id,
      selected_category.id,
      expense_date,
      cleaned_description,
      amount,
      currency,
      auth.uid()
    )
    returning * into saved_expense;
  else
    select *
      into old_expense
    from maintenance_expenses
    where id = target_expense_id
      and organization_id = target_organization_id
      and task_id = selected_task.id
      and status = 'valid'
    for update;

    if not found then
      raise exception 'El gasto de mantenimiento no existe o fue anulado.';
    end if;

    update maintenance_expenses
    set
      category_id = selected_category.id,
      expense_date = save_maintenance_expense.expense_date,
      description = cleaned_description,
      amount = save_maintenance_expense.amount,
      currency = save_maintenance_expense.currency,
      version = version + 1
    where id = old_expense.id
    returning * into saved_expense;
  end if;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    save_maintenance_expense.operation_id,
    case when target_expense_id is null then 'maintenance_expense_created' else 'maintenance_expense_updated' end,
    'maintenance_expense',
    saved_expense.id,
    case when target_expense_id is null then null else to_jsonb(old_expense) end,
    to_jsonb(saved_expense),
    jsonb_build_object('taskId', selected_task.id, 'categoryName', selected_category.name)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'maintenance_expense',
    result_entity_id = saved_expense.id,
    result_payload = to_jsonb(saved_expense),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = save_maintenance_expense.operation_id;

  return saved_expense;
end;
$$;

create or replace function void_maintenance_expense(
  target_organization_id uuid,
  target_expense_id uuid,
  reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns maintenance_expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  old_expense maintenance_expenses;
  saved_expense maintenance_expenses;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo duenio o administrador pueden anular gastos de mantenimiento.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_expense_id', target_expense_id,
    'reason', reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = void_maintenance_expense.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_expense
      from maintenance_expenses
      where id = existing_operation.result_entity_id;

      return saved_expense;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    void_maintenance_expense.operation_id,
    'void_maintenance_expense',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_expense
  from maintenance_expenses
  where id = target_expense_id
    and organization_id = target_organization_id
    and status = 'valid'
  for update;

  if not found then
    raise exception 'El gasto no existe o ya fue anulado.';
  end if;

  update maintenance_expenses
  set
    status = 'voided',
    voided_at = now(),
    voided_by = auth.uid(),
    void_reason = nullif(trim(coalesce(reason, '')), ''),
    version = version + 1
  where id = old_expense.id
  returning * into saved_expense;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    void_maintenance_expense.operation_id,
    'maintenance_expense_voided',
    'maintenance_expense',
    saved_expense.id,
    to_jsonb(old_expense),
    to_jsonb(saved_expense),
    jsonb_build_object('reason', reason)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'maintenance_expense',
    result_entity_id = saved_expense.id,
    result_payload = to_jsonb(saved_expense),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = void_maintenance_expense.operation_id;

  return saved_expense;
end;
$$;
