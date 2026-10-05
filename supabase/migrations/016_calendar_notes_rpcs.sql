create index if not exists calendar_notes_org_status_date_idx
  on calendar_notes(organization_id, status, event_date);

create or replace function get_calendar_notes(
  target_organization_id uuid,
  note_scope calendar_scope default null,
  from_date date default null,
  to_date date default null
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
        'id', n.id,
        'date', n.event_date,
        'title', n.title,
        'body', n.body,
        'scope', n.scope,
        'status', n.status,
        'createdAt', n.created_at,
        'updatedAt', n.updated_at,
        'version', n.version
      )
      order by n.event_date asc, n.created_at asc
    ),
    '[]'::jsonb
  )
  from calendar_notes n
  where n.organization_id = target_organization_id
    and n.status = 'active'
    and (note_scope is null or n.scope = note_scope)
    and (from_date is null or n.event_date >= from_date)
    and (to_date is null or n.event_date <= to_date)
    and is_org_member(target_organization_id);
$$;

create or replace function save_calendar_note(
  target_organization_id uuid,
  note_date date,
  note_title text,
  target_note_id uuid default null,
  note_scope calendar_scope default 'general',
  note_body text default null,
  operation_id uuid default gen_random_uuid()
)
returns calendar_notes
language plpgsql
security definer
set search_path = public
as $$
declare
  old_note calendar_notes;
  saved_note calendar_notes;
  existing_operation operation_results;
  request_hash text;
  cleaned_title text := nullif(trim(coalesce(note_title, '')), '');
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para guardar eventos del calendario.';
  end if;

  if cleaned_title is null then
    raise exception 'El titulo del evento es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'note_date', note_date,
    'note_title', cleaned_title,
    'target_note_id', target_note_id,
    'note_scope', note_scope,
    'note_body', note_body
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = save_calendar_note.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_note
      from calendar_notes
      where id = existing_operation.result_entity_id;

      return saved_note;
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
    save_calendar_note.operation_id,
    'save_calendar_note',
    request_hash,
    'in_progress',
    auth.uid()
  );

  if target_note_id is null then
    insert into calendar_notes (
      organization_id,
      scope,
      event_date,
      title,
      body,
      created_by
    )
    values (
      target_organization_id,
      note_scope,
      note_date,
      cleaned_title,
      nullif(trim(coalesce(note_body, '')), ''),
      auth.uid()
    )
    returning * into saved_note;
  else
    select *
      into old_note
    from calendar_notes
    where id = target_note_id
      and organization_id = target_organization_id
      and status = 'active'
    for update;

    if not found then
      raise exception 'El evento no existe o fue archivado.';
    end if;

    update calendar_notes
    set
      scope = note_scope,
      event_date = note_date,
      title = cleaned_title,
      body = nullif(trim(coalesce(note_body, '')), ''),
      version = version + 1
    where id = old_note.id
    returning * into saved_note;
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
    save_calendar_note.operation_id,
    case when target_note_id is null then 'calendar_note_created' else 'calendar_note_updated' end,
    'calendar_note',
    saved_note.id,
    case when target_note_id is null then null else to_jsonb(old_note) end,
    to_jsonb(saved_note),
    jsonb_build_object('scope', note_scope)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'calendar_note',
    result_entity_id = saved_note.id,
    result_payload = to_jsonb(saved_note),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = save_calendar_note.operation_id;

  return saved_note;
end;
$$;

create or replace function archive_calendar_note(
  target_organization_id uuid,
  target_note_id uuid,
  reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns calendar_notes
language plpgsql
security definer
set search_path = public
as $$
declare
  old_note calendar_notes;
  saved_note calendar_notes;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para eliminar eventos del calendario.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_note_id', target_note_id,
    'reason', reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = archive_calendar_note.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_note
      from calendar_notes
      where id = existing_operation.result_entity_id;

      return saved_note;
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
    archive_calendar_note.operation_id,
    'archive_calendar_note',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_note
  from calendar_notes
  where id = target_note_id
    and organization_id = target_organization_id
    and status = 'active'
  for update;

  if not found then
    raise exception 'El evento no existe o ya fue archivado.';
  end if;

  update calendar_notes
  set
    status = 'archived',
    version = version + 1
  where id = old_note.id
  returning * into saved_note;

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
    archive_calendar_note.operation_id,
    'calendar_note_archived',
    'calendar_note',
    saved_note.id,
    to_jsonb(old_note),
    to_jsonb(saved_note),
    jsonb_build_object('reason', reason)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'calendar_note',
    result_entity_id = saved_note.id,
    result_payload = to_jsonb(saved_note),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = archive_calendar_note.operation_id;

  return saved_note;
end;
$$;
