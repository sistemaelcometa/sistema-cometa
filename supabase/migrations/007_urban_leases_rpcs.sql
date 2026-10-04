-- RPCs para contratos e inquilinos urbanos.

drop function if exists get_urban_structure(uuid);

create or replace function get_urban_structure(target_organization_id uuid)
returns table (
  building_id uuid,
  building_name text,
  building_address text,
  building_has_expenses boolean,
  unit_id uuid,
  unit_name text,
  unit_surface_m2 numeric,
  unit_status urban_unit_status,
  lease_id uuid,
  tenant_contact_id uuid,
  tenant_name text,
  tenant_document_number text,
  tenant_phone text,
  tenant_email text,
  tenant_address text,
  tenant_notes text,
  lease_start_date date,
  lease_end_date date,
  lease_amount numeric,
  lease_currency char(3),
  lease_due_day integer,
  lease_next_adjustment_date date,
  lease_adjustment_frequency_months integer,
  lease_status urban_lease_status
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id as building_id,
    b.name as building_name,
    b.address as building_address,
    b.has_expenses as building_has_expenses,
    u.id as unit_id,
    u.name as unit_name,
    u.surface_m2 as unit_surface_m2,
    u.status as unit_status,
    l.id as lease_id,
    c.id as tenant_contact_id,
    nullif(
      trim(
        coalesce(c.business_name, '') || ' ' ||
        coalesce(c.first_name, '') || ' ' ||
        coalesce(c.last_name, '')
      ),
      ''
    ) as tenant_name,
    c.document_number as tenant_document_number,
    c.phone as tenant_phone,
    c.email as tenant_email,
    c.address as tenant_address,
    c.notes as tenant_notes,
    l.start_date as lease_start_date,
    l.end_date as lease_end_date,
    l.current_amount as lease_amount,
    l.currency as lease_currency,
    l.monthly_due_day as lease_due_day,
    l.next_adjustment_date as lease_next_adjustment_date,
    l.adjustment_frequency_months as lease_adjustment_frequency_months,
    l.status as lease_status
  from urban_buildings b
  left join urban_units u
    on u.building_id = b.id
   and u.status <> 'archived'
  left join lateral (
    select *
    from urban_leases ul
    where ul.unit_id = u.id
      and ul.status in ('active', 'upcoming')
    order by
      case ul.status when 'active' then 0 else 1 end,
      ul.start_date
    limit 1
  ) l on true
  left join contacts c on c.id = l.primary_tenant_contact_id
  where b.organization_id = target_organization_id
    and b.status = 'active'
    and is_org_member(target_organization_id)
  order by b.name, u.name;
$$;

create or replace function start_urban_lease(
  target_organization_id uuid,
  target_unit_id uuid,
  tenant_contact_id uuid default null,
  tenant_first_name text default null,
  tenant_last_name text default null,
  tenant_document_number text default null,
  tenant_phone text default null,
  tenant_email text default null,
  tenant_address text default null,
  tenant_notes text default null,
  lease_start_date date default null,
  lease_end_date date default null,
  lease_amount numeric default null,
  lease_currency char(3) default 'ARS',
  lease_due_day integer default null,
  lease_adjustment_frequency_months integer default null,
  lease_next_adjustment_date date default null,
  lease_notes text default null,
  operation_id uuid default gen_random_uuid()
)
returns table (
  lease_id uuid,
  unit_id uuid,
  tenant_id uuid,
  tenant_name text,
  start_date date,
  end_date date,
  current_amount numeric,
  currency char(3),
  monthly_due_day integer,
  next_adjustment_date date,
  status urban_lease_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  locked_unit urban_units;
  selected_contact contacts;
  created_contact contacts;
  created_lease urban_leases;
  previous_operation operation_results;
  request_hash text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para cargar contratos.';
  end if;

  if lease_start_date is null or lease_end_date is null then
    raise exception 'Las fechas del contrato son obligatorias.';
  end if;

  if lease_end_date <= lease_start_date then
    raise exception 'La fecha de fin debe ser posterior al inicio.';
  end if;

  if coalesce(lease_amount, 0) < 0 then
    raise exception 'El importe del alquiler no puede ser negativo.';
  end if;

  if lease_currency not in ('ARS', 'USD') then
    raise exception 'La moneda del contrato no es valida.';
  end if;

  if coalesce(lease_due_day, 0) not between 1 and 28 then
    raise exception 'El dia de vencimiento debe estar entre 1 y 28.';
  end if;

  if lease_adjustment_frequency_months is not null and lease_adjustment_frequency_months <= 0 then
    raise exception 'La frecuencia de ajuste debe ser mayor a cero.';
  end if;

  request_hash := md5(jsonb_build_object(
    'target_organization_id', target_organization_id,
    'target_unit_id', target_unit_id,
    'tenant_contact_id', tenant_contact_id,
    'tenant_first_name', tenant_first_name,
    'tenant_last_name', tenant_last_name,
    'tenant_document_number', tenant_document_number,
    'tenant_phone', tenant_phone,
    'tenant_email', tenant_email,
    'tenant_address', tenant_address,
    'lease_start_date', lease_start_date,
    'lease_end_date', lease_end_date,
    'lease_amount', lease_amount,
    'lease_currency', lease_currency,
    'lease_due_day', lease_due_day,
    'lease_adjustment_frequency_months', lease_adjustment_frequency_months,
    'lease_next_adjustment_date', lease_next_adjustment_date
  )::text);

  select *
    into previous_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = start_urban_lease.operation_id
  for update;

  if found then
    if previous_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if previous_operation.status = 'succeeded' then
      return query
        select
          l.id,
          l.unit_id,
          l.primary_tenant_contact_id,
          nullif(
            trim(
              coalesce(c.business_name, '') || ' ' ||
              coalesce(c.first_name, '') || ' ' ||
              coalesce(c.last_name, '')
            ),
            ''
          ),
          l.start_date,
          l.end_date,
          l.current_amount,
          l.currency,
          l.monthly_due_day,
          l.next_adjustment_date,
          l.status
        from urban_leases l
        join contacts c on c.id = l.primary_tenant_contact_id
        where l.id = (previous_operation.result_payload->>'lease_id')::uuid;
      return;
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
    start_urban_lease.operation_id,
    'start_urban_lease',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into locked_unit
  from urban_units
  where id = target_unit_id
    and organization_id = target_organization_id
    and status <> 'archived'
  for update;

  if not found then
    raise exception 'El departamento no existe o esta archivado.';
  end if;

  if exists (
    select 1
    from urban_leases existing_lease
    where existing_lease.unit_id = target_unit_id
      and existing_lease.status in ('active', 'upcoming')
      and daterange(existing_lease.start_date, existing_lease.end_date, '[]') && daterange(lease_start_date, lease_end_date, '[]')
    for update
  ) then
    raise exception 'Ya existe un contrato activo o futuro para esas fechas.';
  end if;

  if tenant_contact_id is not null then
    select *
      into selected_contact
    from contacts
    where id = tenant_contact_id
      and organization_id = target_organization_id
      and status = 'active'
    for update;

    if not found then
      raise exception 'El inquilino seleccionado no existe o esta archivado.';
    end if;

    update contacts
    set
      phone = coalesce(nullif(trim(coalesce(tenant_phone, '')), ''), phone),
      email = coalesce(nullif(trim(coalesce(tenant_email, '')), ''), email),
      address = coalesce(nullif(trim(coalesce(tenant_address, '')), ''), address),
      notes = coalesce(nullif(trim(coalesce(tenant_notes, '')), ''), notes),
      is_tenant = true
    where id = tenant_contact_id
    returning * into selected_contact;
  else
    if nullif(trim(coalesce(tenant_first_name, '') || ' ' || coalesce(tenant_last_name, '')), '') is null then
      raise exception 'El nombre del inquilino es obligatorio.';
    end if;

    insert into contacts (
      organization_id,
      contact_type,
      first_name,
      last_name,
      document_number,
      phone,
      email,
      address,
      notes,
      is_tenant,
      created_by
    )
    values (
      target_organization_id,
      'person',
      nullif(trim(coalesce(tenant_first_name, '')), ''),
      nullif(trim(coalesce(tenant_last_name, '')), ''),
      nullif(trim(coalesce(tenant_document_number, '')), ''),
      nullif(trim(coalesce(tenant_phone, '')), ''),
      nullif(trim(coalesce(tenant_email, '')), ''),
      nullif(trim(coalesce(tenant_address, '')), ''),
      nullif(trim(coalesce(tenant_notes, '')), ''),
      true,
      auth.uid()
    )
    returning * into created_contact;

    selected_contact := created_contact;

    insert into audit_logs (
      organization_id,
      actor_user_id,
      operation_id,
      action,
      entity_type,
      entity_id,
      new_values
    )
    values (
      target_organization_id,
      auth.uid(),
      start_urban_lease.operation_id,
      'contact_created_for_urban_lease',
      'contact',
      selected_contact.id,
      to_jsonb(selected_contact)
    );
  end if;

  insert into urban_leases (
    organization_id,
    unit_id,
    primary_tenant_contact_id,
    start_date,
    end_date,
    current_amount,
    currency,
    monthly_due_day,
    adjustment_frequency_months,
    next_adjustment_date,
    status,
    notes,
    created_by
  )
  values (
    target_organization_id,
    target_unit_id,
    selected_contact.id,
    lease_start_date,
    lease_end_date,
    lease_amount,
    lease_currency,
    lease_due_day,
    lease_adjustment_frequency_months,
    lease_next_adjustment_date,
    'active',
    nullif(trim(coalesce(lease_notes, '')), ''),
    auth.uid()
  )
  returning * into created_lease;

  update urban_units
  set status = 'rented'
  where id = target_unit_id;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values
  )
  values (
    target_organization_id,
    auth.uid(),
    start_urban_lease.operation_id,
    'urban_lease_started',
    'urban_lease',
    created_lease.id,
    jsonb_build_object('unit', to_jsonb(locked_unit)),
    jsonb_build_object('lease', to_jsonb(created_lease), 'tenant', to_jsonb(selected_contact))
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'urban_lease',
    result_entity_id = created_lease.id,
    result_payload = jsonb_build_object(
      'lease_id', created_lease.id,
      'unit_id', created_lease.unit_id,
      'tenant_contact_id', selected_contact.id
    ),
    completed_at = now()
  where operation_results.organization_id = target_organization_id
    and operation_results.operation_id = start_urban_lease.operation_id;

  return query
    select
      created_lease.id,
      created_lease.unit_id,
      selected_contact.id,
      nullif(
        trim(
          coalesce(selected_contact.business_name, '') || ' ' ||
          coalesce(selected_contact.first_name, '') || ' ' ||
          coalesce(selected_contact.last_name, '')
        ),
        ''
      ),
      created_lease.start_date,
      created_lease.end_date,
      created_lease.current_amount,
      created_lease.currency,
      created_lease.monthly_due_day,
      created_lease.next_adjustment_date,
      created_lease.status;
end;
$$;
