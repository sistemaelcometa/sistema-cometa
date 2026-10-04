-- RPCs para beneficiarios, distribuciones y liquidaciones familiares.

create or replace function get_family_liquidation_data(
  target_organization_id uuid,
  filter_period_start date default null,
  filter_period_end date default null
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with beneficiaries as (
    select
      c.id,
      trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as name,
      c.first_name,
      c.last_name,
      c.email,
      c.phone
    from contacts c
    where c.organization_id = target_organization_id
      and c.status = 'active'
      and c.is_family_beneficiary = true
      and is_org_member(target_organization_id)
    order by c.first_name, c.last_name, c.created_at
  ),
  distributions as (
    select
      g.id,
      g.unit_id,
      g.valid_from,
      g.valid_to,
      g.status::text as status,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', s.id,
            'beneficiaryId', s.beneficiary_contact_id,
            'percentage', s.percentage,
            'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))
          )
          order by c.first_name, c.last_name, s.created_at
        ) filter (where s.id is not null),
        '[]'::jsonb
      ) as shares
    from family_distribution_groups g
    left join family_distribution_shares s on s.distribution_group_id = g.id
    left join contacts c on c.id = s.beneficiary_contact_id
    where g.organization_id = target_organization_id
      and g.status = 'active'
      and is_org_member(target_organization_id)
    group by g.id
    order by g.valid_from desc
  ),
  settlements as (
    select
      fs.id,
      fs.period_start,
      fs.period_end,
      fs.version,
      fs.corrects_settlement_id,
      fs.is_current,
      fs.status::text as status,
      fs.total_ars,
      fs.total_usd,
      fs.notes,
      fs.closed_at,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'unitId', i.unit_id,
            'unitName', u.name,
            'buildingName', b.name,
            'beneficiaryId', i.beneficiary_contact_id,
            'beneficiaryName', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
            'paymentAllocationId', i.source_payment_allocation_id,
            'baseAmount', i.base_amount,
            'percentage', i.percentage_snapshot,
            'amount', i.settled_amount,
            'currency', i.currency,
            'description', i.description
          )
          order by b.name, u.name, c.first_name, c.last_name
        ) filter (where i.id is not null),
        '[]'::jsonb
      ) as items
    from family_settlements fs
    left join family_settlement_items i on i.settlement_id = fs.id
    left join urban_units u on u.id = i.unit_id
    left join urban_buildings b on b.id = u.building_id
    left join contacts c on c.id = i.beneficiary_contact_id
    where fs.organization_id = target_organization_id
      and is_org_member(target_organization_id)
      and (
        filter_period_start is null
        or filter_period_end is null
        or daterange(fs.period_start, fs.period_end, '[]') && daterange(filter_period_start, filter_period_end, '[]')
      )
    group by fs.id
    order by fs.period_start desc, fs.version desc
  )
  select jsonb_build_object(
    'beneficiaries', coalesce((select jsonb_agg(to_jsonb(beneficiaries)) from beneficiaries), '[]'::jsonb),
    'distributions', coalesce((select jsonb_agg(to_jsonb(distributions)) from distributions), '[]'::jsonb),
    'settlements', coalesce((select jsonb_agg(to_jsonb(settlements)) from settlements), '[]'::jsonb)
  );
$$;

create or replace function save_family_beneficiary(
  target_organization_id uuid,
  beneficiary_contact_id uuid default null,
  first_name text default null,
  last_name text default null,
  beneficiary_email text default null,
  beneficiary_phone text default null,
  beneficiary_notes text default null
)
returns contacts
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_contact contacts;
  saved_contact contacts;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para guardar beneficiarios.';
  end if;

  if nullif(trim(coalesce(first_name, '')), '') is null
     and nullif(trim(coalesce(last_name, '')), '') is null then
    raise exception 'El nombre del beneficiario es obligatorio.';
  end if;

  if beneficiary_contact_id is not null then
    select *
      into previous_contact
    from contacts
    where id = beneficiary_contact_id
      and organization_id = target_organization_id
      and status = 'active'
    for update;

    if not found then
      raise exception 'El beneficiario no existe o esta archivado.';
    end if;

    update contacts
    set
      first_name = nullif(trim(coalesce(save_family_beneficiary.first_name, '')), ''),
      last_name = nullif(trim(coalesce(save_family_beneficiary.last_name, '')), ''),
      email = nullif(trim(coalesce(beneficiary_email, '')), ''),
      phone = nullif(trim(coalesce(beneficiary_phone, '')), ''),
      notes = nullif(trim(coalesce(beneficiary_notes, '')), ''),
      is_family_beneficiary = true
    where id = beneficiary_contact_id
    returning * into saved_contact;

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
      'family_beneficiary_updated',
      'contact',
      saved_contact.id,
      to_jsonb(previous_contact),
      to_jsonb(saved_contact)
    );
  else
    insert into contacts (
      organization_id,
      contact_type,
      first_name,
      last_name,
      email,
      phone,
      notes,
      is_family_beneficiary,
      created_by
    )
    values (
      target_organization_id,
      'person',
      nullif(trim(coalesce(save_family_beneficiary.first_name, '')), ''),
      nullif(trim(coalesce(save_family_beneficiary.last_name, '')), ''),
      nullif(trim(coalesce(beneficiary_email, '')), ''),
      nullif(trim(coalesce(beneficiary_phone, '')), ''),
      nullif(trim(coalesce(beneficiary_notes, '')), ''),
      true,
      auth.uid()
    )
    returning * into saved_contact;

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
      'family_beneficiary_created',
      'contact',
      saved_contact.id,
      to_jsonb(saved_contact)
    );
  end if;

  return saved_contact;
end;
$$;

create or replace function archive_family_beneficiary(
  target_organization_id uuid,
  beneficiary_contact_id uuid
)
returns contacts
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_contact contacts;
  archived_contact contacts;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para archivar beneficiarios.';
  end if;

  if exists (
    select 1
    from family_settlement_items
    where organization_id = target_organization_id
      and beneficiary_contact_id = archive_family_beneficiary.beneficiary_contact_id
  ) then
    raise exception 'No se puede archivar un beneficiario que ya fue usado en liquidaciones cerradas.';
  end if;

  if exists (
    select 1
    from family_distribution_shares s
    join family_distribution_groups g on g.id = s.distribution_group_id
    where g.organization_id = target_organization_id
      and g.status = 'active'
      and s.beneficiary_contact_id = archive_family_beneficiary.beneficiary_contact_id
  ) then
    raise exception 'No se puede archivar un beneficiario usado en distribuciones activas.';
  end if;

  select *
    into previous_contact
  from contacts
  where id = beneficiary_contact_id
    and organization_id = target_organization_id
    and status = 'active'
    and is_family_beneficiary = true
  for update;

  if not found then
    raise exception 'El beneficiario no existe o ya esta archivado.';
  end if;

  update contacts
  set status = 'archived'
  where id = beneficiary_contact_id
  returning * into archived_contact;

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
    'family_beneficiary_archived',
    'contact',
    archived_contact.id,
    to_jsonb(previous_contact),
    to_jsonb(archived_contact)
  );

  return archived_contact;
end;
$$;

create or replace function save_family_distribution(
  target_organization_id uuid,
  target_unit_id uuid,
  shares jsonb,
  valid_from date default current_date,
  distribution_notes text default null
)
returns family_distribution_groups
language plpgsql
security definer
set search_path = public
as $$
declare
  unit_record urban_units;
  created_group family_distribution_groups;
  share_record record;
  share_total numeric(7, 4);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para guardar distribuciones.';
  end if;

  if valid_from is null then
    raise exception 'La fecha de vigencia es obligatoria.';
  end if;

  if shares is null or jsonb_typeof(shares) <> 'array' or jsonb_array_length(shares) = 0 then
    raise exception 'La distribucion debe incluir al menos un beneficiario.';
  end if;

  select *
    into unit_record
  from urban_units
  where id = target_unit_id
    and organization_id = target_organization_id
    and status <> 'archived'
  for update;

  if not found then
    raise exception 'El departamento no existe o esta archivado.';
  end if;

  select coalesce(sum((item->>'percentage')::numeric), 0)
    into share_total
  from jsonb_array_elements(shares) as item
  where nullif(item->>'beneficiaryId', '') is not null;

  if share_total <> 100.0000 then
    raise exception 'La distribucion familiar debe sumar exactamente 100%%. Suma actual: %', share_total;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(shares) as item
    left join contacts c
      on c.id = (item->>'beneficiaryId')::uuid
     and c.organization_id = target_organization_id
     and c.status = 'active'
     and c.is_family_beneficiary = true
    where nullif(item->>'beneficiaryId', '') is null
       or c.id is null
       or coalesce((item->>'percentage')::numeric, 0) <= 0
  ) then
    raise exception 'La distribucion contiene beneficiarios o porcentajes invalidos.';
  end if;

  update family_distribution_groups
  set
    status = 'archived',
    valid_to = case
      when valid_from > family_distribution_groups.valid_from then valid_from - 1
      else family_distribution_groups.valid_from
    end
  where organization_id = target_organization_id
    and unit_id = target_unit_id
    and status = 'active';

  insert into family_distribution_groups (
    organization_id,
    unit_id,
    valid_from,
    notes,
    created_by
  )
  values (
    target_organization_id,
    target_unit_id,
    save_family_distribution.valid_from,
    nullif(trim(coalesce(distribution_notes, '')), ''),
    auth.uid()
  )
  returning * into created_group;

  for share_record in
    select
      (item->>'beneficiaryId')::uuid as beneficiary_contact_id,
      (item->>'percentage')::numeric(7, 4) as percentage
    from jsonb_array_elements(shares) as item
  loop
    insert into family_distribution_shares (
      organization_id,
      distribution_group_id,
      beneficiary_contact_id,
      percentage
    )
    values (
      target_organization_id,
      created_group.id,
      share_record.beneficiary_contact_id,
      share_record.percentage
    );
  end loop;

  perform assert_family_distribution_total(created_group.id);

  insert into audit_logs (
    organization_id,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    'family_distribution_saved',
    'family_distribution_group',
    created_group.id,
    to_jsonb(created_group),
    jsonb_build_object('shares', shares)
  );

  return created_group;
end;
$$;

create or replace function close_family_settlement(
  target_organization_id uuid,
  period_start date,
  period_end date,
  correction_of uuid default null,
  correction_reason text default null,
  settlement_notes text default null,
  operation_id uuid default gen_random_uuid()
)
returns family_settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  created_settlement family_settlements;
  previous_settlement family_settlements;
  existing_current family_settlements;
  existing_operation operation_results;
  request_hash text;
  settlement_version integer := 1;
  missing_distribution record;
  calculated_total_ars numeric(14, 2);
  calculated_total_usd numeric(14, 2);
  inserted_items integer;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para cerrar liquidaciones.';
  end if;

  if correction_of is not null
     and not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo owner/admin puede corregir liquidaciones cerradas.';
  end if;

  if period_start is null or period_end is null or period_end < period_start then
    raise exception 'El periodo de liquidacion es invalido.';
  end if;

  if correction_of is not null and nullif(trim(coalesce(correction_reason, '')), '') is null then
    raise exception 'El motivo de correccion es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'period_start', period_start,
    'period_end', period_end,
    'correction_of', correction_of,
    'correction_reason', correction_reason,
    'settlement_notes', settlement_notes
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = close_family_settlement.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into created_settlement
      from family_settlements
      where id = existing_operation.result_entity_id;

      return created_settlement;
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
    close_family_settlement.operation_id,
    'close_family_settlement',
    request_hash,
    'in_progress',
    auth.uid()
  );

  if correction_of is not null then
    select *
      into previous_settlement
    from family_settlements
    where id = correction_of
      and organization_id = target_organization_id
      and is_current = true
      and status = 'closed'
    for update;

    if not found then
      raise exception 'La liquidacion a corregir no existe o no es la vigente.';
    end if;

    if previous_settlement.period_start <> period_start
       or previous_settlement.period_end <> period_end then
      raise exception 'La correccion debe mantener el mismo periodo de la liquidacion original.';
    end if;

    settlement_version := previous_settlement.version + 1;
  else
    select *
      into existing_current
    from family_settlements
    where organization_id = target_organization_id
      and period_start = close_family_settlement.period_start
      and period_end = close_family_settlement.period_end
      and is_current = true
      and status = 'closed'
    for update;

    if found then
      raise exception 'Ya existe una liquidacion vigente para este periodo.';
    end if;
  end if;

  perform 1
  from urban_payments up
  where up.organization_id = target_organization_id
    and up.status = 'valid'
    and up.payment_date between close_family_settlement.period_start and close_family_settlement.period_end
  for update;

  select
    u.id as unit_id,
    u.name as unit_name
    into missing_distribution
  from urban_payment_allocations pa
  join urban_payments up on up.id = pa.payment_id
  join urban_charge_items ci on ci.id = pa.charge_item_id
  join urban_charges ch on ch.id = ci.charge_id
  join urban_units u on u.id = ch.unit_id
  where up.organization_id = target_organization_id
    and up.status = 'valid'
    and up.payment_date between close_family_settlement.period_start and close_family_settlement.period_end
    and ci.item_type in ('rent', 'rent_surcharge')
    and pa.allocated_amount > 0
    and not exists (
      select 1
      from family_distribution_groups dg
      where dg.organization_id = target_organization_id
        and dg.unit_id = u.id
        and dg.status = 'active'
        and up.payment_date between dg.valid_from and coalesce(dg.valid_to, 'infinity'::date)
    )
  limit 1;

  if found then
    raise exception 'Falta distribucion familiar vigente para el departamento %.', missing_distribution.unit_name;
  end if;

  if correction_of is not null then
    update family_settlements
    set
      status = 'corrected',
      is_current = false
    where id = correction_of
    returning * into previous_settlement;
  end if;

  insert into family_settlements (
    organization_id,
    period_start,
    period_end,
    version,
    corrects_settlement_id,
    is_current,
    status,
    notes,
    closed_at,
    closed_by,
    created_by
  )
  values (
    target_organization_id,
    close_family_settlement.period_start,
    close_family_settlement.period_end,
    settlement_version,
    correction_of,
    true,
    'closed',
    nullif(trim(coalesce(settlement_notes, '')), ''),
    now(),
    auth.uid(),
    auth.uid()
  )
  returning * into created_settlement;

  insert into family_settlement_items (
    organization_id,
    settlement_id,
    unit_id,
    beneficiary_contact_id,
    source_payment_allocation_id,
    distribution_group_id,
    distribution_share_id,
    base_amount,
    percentage_snapshot,
    settled_amount,
    currency,
    description
  )
  select
    target_organization_id,
    created_settlement.id,
    ch.unit_id,
    ds.beneficiary_contact_id,
    pa.id,
    dg.id,
    ds.id,
    pa.allocated_amount,
    ds.percentage,
    round(pa.allocated_amount * ds.percentage / 100, 2),
    pa.currency,
    case ci.item_type
      when 'rent' then 'Alquiler cobrado'
      when 'rent_surcharge' then 'Recargo de alquiler cobrado'
      else ci.description
    end
  from urban_payment_allocations pa
  join urban_payments up on up.id = pa.payment_id
  join urban_charge_items ci on ci.id = pa.charge_item_id
  join urban_charges ch on ch.id = ci.charge_id
  join family_distribution_groups dg
    on dg.organization_id = target_organization_id
   and dg.unit_id = ch.unit_id
   and dg.status = 'active'
   and up.payment_date between dg.valid_from and coalesce(dg.valid_to, 'infinity'::date)
  join family_distribution_shares ds on ds.distribution_group_id = dg.id
  where up.organization_id = target_organization_id
    and up.status = 'valid'
    and up.payment_date between close_family_settlement.period_start and close_family_settlement.period_end
    and ci.item_type in ('rent', 'rent_surcharge')
    and pa.allocated_amount > 0
  order by up.payment_date, ch.unit_id, ci.item_type, ds.created_at;

  get diagnostics inserted_items = row_count;

  if inserted_items = 0 then
    raise exception 'No hay cobros de alquiler para liquidar en este periodo.';
  end if;

  select
    coalesce(sum(settled_amount) filter (where currency = 'ARS'), 0),
    coalesce(sum(settled_amount) filter (where currency = 'USD'), 0)
    into calculated_total_ars, calculated_total_usd
  from family_settlement_items
  where settlement_id = created_settlement.id;

  update family_settlements
  set
    total_ars = calculated_total_ars,
    total_usd = calculated_total_usd
  where id = created_settlement.id
  returning * into created_settlement;

  if correction_of is not null then
    insert into family_settlement_corrections (
      organization_id,
      previous_settlement_id,
      new_settlement_id,
      reason,
      created_by
    )
    values (
      target_organization_id,
      correction_of,
      created_settlement.id,
      trim(correction_reason),
      auth.uid()
    );
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
    close_family_settlement.operation_id,
    case when correction_of is null then 'family_settlement_closed' else 'family_settlement_corrected' end,
    'family_settlement',
    created_settlement.id,
    case when correction_of is null then null else to_jsonb(previous_settlement) end,
    to_jsonb(created_settlement),
    jsonb_build_object(
      'periodStart', period_start,
      'periodEnd', period_end,
      'correctionOf', correction_of,
      'correctionReason', correction_reason
    )
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'family_settlement',
    result_entity_id = created_settlement.id,
    result_payload = jsonb_build_object(
      'settlement_id', created_settlement.id,
      'version', created_settlement.version,
      'total_ars', created_settlement.total_ars,
      'total_usd', created_settlement.total_usd
    ),
    completed_at = now()
  where operation_results.organization_id = target_organization_id
    and operation_results.operation_id = close_family_settlement.operation_id;

  return created_settlement;
end;
$$;
