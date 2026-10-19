-- Permite volver a abrir el cierre familiar sin borrar cobros ni sus copias historicas.
-- Solo owner/admin puede reabrir. Cada accion queda auditada.
-- El siguiente cierre recalcula con los cobros y repartos vigentes, con una nueva version.
-- Ejecutar este archivo NO reabre ninguna liquidacion: instala las funciones necesarias.

begin;

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
  settlement_request_hash text;
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

  if close_family_settlement.period_start is null
     or close_family_settlement.period_end is null
     or close_family_settlement.period_end < close_family_settlement.period_start then
    raise exception 'El periodo de liquidacion es invalido.';
  end if;

  if correction_of is not null and nullif(trim(coalesce(correction_reason, '')), '') is null then
    raise exception 'El motivo de correccion es obligatorio.';
  end if;

  -- El mismo bloqueo serializa cierres y reaperturas de este periodo.
  perform pg_advisory_xact_lock(hashtextextended(
    'family-settlement:' || target_organization_id::text || ':' ||
    close_family_settlement.period_start::text || ':' ||
    close_family_settlement.period_end::text, 0
  ));

  settlement_request_hash := md5(jsonb_build_object(
    'period_start', close_family_settlement.period_start,
    'period_end', close_family_settlement.period_end,
    'correction_of', correction_of,
    'correction_reason', correction_reason,
    'settlement_notes', settlement_notes
  )::text);

  select op.*
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = close_family_settlement.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> settlement_request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select fs.*
        into created_settlement
      from family_settlements fs
      where fs.id = existing_operation.result_entity_id;

      return created_settlement;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id, operation_id, operation_type, request_hash, status, created_by
  ) values (
    target_organization_id, close_family_settlement.operation_id,
    'close_family_settlement', settlement_request_hash, 'in_progress', auth.uid()
  );

  if correction_of is not null then
    select fs.*
      into previous_settlement
    from family_settlements fs
    where fs.id = correction_of
      and fs.organization_id = target_organization_id
      and fs.is_current = true
      and fs.status = 'closed'
    for update;

    if not found then
      raise exception 'La liquidacion a corregir no existe o no es la vigente.';
    end if;

    if previous_settlement.period_start <> close_family_settlement.period_start
       or previous_settlement.period_end <> close_family_settlement.period_end then
      raise exception 'La correccion debe mantener el mismo periodo de la liquidacion original.';
    end if;

  else
    select fs.*
      into existing_current
    from family_settlements fs
    where fs.organization_id = target_organization_id
      and fs.period_start = close_family_settlement.period_start
      and fs.period_end = close_family_settlement.period_end
      and fs.is_current = true
      and fs.status = 'closed'
    for update;

    if found then
      raise exception 'Ya existe una liquidacion vigente para este periodo.';
    end if;
  end if;

  -- No reutilizar versiones al cerrar nuevamente un periodo reabierto.
  select coalesce(max(fs.version), 0) + 1
    into settlement_version
  from family_settlements fs
  where fs.organization_id = target_organization_id
    and fs.period_start = close_family_settlement.period_start
    and fs.period_end = close_family_settlement.period_end;

  perform 1
  from urban_payments up
  where up.organization_id = target_organization_id
    and up.status = 'valid'
    and up.payment_date between close_family_settlement.period_start and close_family_settlement.period_end
  for update;

  select u.id as unit_id, u.name as unit_name
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
      select 1 from family_distribution_groups dg
      where dg.organization_id = target_organization_id
        and dg.unit_id = u.id
        and dg.status = 'active'
    )
  limit 1;

  if found then
    raise exception 'Falta distribucion familiar vigente para el departamento %.', missing_distribution.unit_name;
  end if;

  if correction_of is not null then
    update family_settlements fs
    set status = 'corrected', is_current = false
    where fs.id = correction_of
    returning fs.* into previous_settlement;
  end if;

  insert into family_settlements (
    organization_id, period_start, period_end, version,
    corrects_settlement_id, is_current, status, notes, closed_at, closed_by, created_by
  ) values (
    target_organization_id, close_family_settlement.period_start, close_family_settlement.period_end,
    settlement_version, correction_of, true, 'closed',
    nullif(trim(coalesce(settlement_notes, '')), ''), now(), auth.uid(), auth.uid()
  ) returning * into created_settlement;

  insert into family_settlement_items (
    organization_id, settlement_id, unit_id, beneficiary_contact_id,
    source_payment_allocation_id, distribution_group_id, distribution_share_id,
    base_amount, percentage_snapshot, settled_amount, currency, description
  )
  select
    target_organization_id, created_settlement.id, ch.unit_id,
    ds.beneficiary_contact_id, pa.id, dg.id, ds.id,
    pa.allocated_amount, ds.percentage, round(pa.allocated_amount * ds.percentage / 100, 2),
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
    coalesce(sum(fsi.settled_amount) filter (where fsi.currency = 'ARS'), 0),
    coalesce(sum(fsi.settled_amount) filter (where fsi.currency = 'USD'), 0)
    into calculated_total_ars, calculated_total_usd
  from family_settlement_items fsi
  where fsi.settlement_id = created_settlement.id;

  update family_settlements fs
  set total_ars = calculated_total_ars, total_usd = calculated_total_usd
  where fs.id = created_settlement.id
  returning fs.* into created_settlement;

  if correction_of is not null then
    insert into family_settlement_corrections (
      organization_id, previous_settlement_id, new_settlement_id, reason, created_by
    ) values (
      target_organization_id, correction_of, created_settlement.id, trim(correction_reason), auth.uid()
    );
  end if;

  insert into audit_logs (
    organization_id, actor_user_id, operation_id, action,
    entity_type, entity_id, old_values, new_values, metadata
  ) values (
    target_organization_id, auth.uid(), close_family_settlement.operation_id,
    case when correction_of is null then 'family_settlement_closed' else 'family_settlement_corrected' end,
    'family_settlement', created_settlement.id,
    case when correction_of is null then null else to_jsonb(previous_settlement) end,
    to_jsonb(created_settlement),
    jsonb_build_object(
      'periodStart', close_family_settlement.period_start,
      'periodEnd', close_family_settlement.period_end,
      'correctionOf', correction_of, 'correctionReason', correction_reason
    )
  );

  update operation_results op
  set status = 'succeeded', result_entity_type = 'family_settlement',
    result_entity_id = created_settlement.id,
    result_payload = jsonb_build_object(
      'settlement_id', created_settlement.id, 'version', created_settlement.version,
      'total_ars', created_settlement.total_ars, 'total_usd', created_settlement.total_usd
    ),
    completed_at = now()
  where op.organization_id = target_organization_id
    and op.operation_id = close_family_settlement.operation_id;

  return created_settlement;
end;
$$;


create or replace function reopen_family_settlement(
  target_organization_id uuid,
  target_settlement_id uuid,
  reason text default 'Reapertura desde el sistema.',
  operation_id uuid default gen_random_uuid()
)
returns family_settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  original_settlement family_settlements;
  reopened_settlement family_settlements;
  existing_operation operation_results;
  reopening_request_hash text;
  reopening_reason text := nullif(trim(coalesce(reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;
  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo owner/admin puede reabrir liquidaciones familiares.';
  end if;
  if reopening_reason is null then
    raise exception 'El motivo de reapertura es obligatorio.';
  end if;

  select fs.* into original_settlement
  from family_settlements fs
  where fs.id = target_settlement_id
    and fs.organization_id = target_organization_id;
  if not found then
    raise exception 'La liquidacion no existe en esta organizacion.';
  end if;

  -- Tomar el bloqueo del periodo antes de bloquear filas, igual que al cerrar.
  perform pg_advisory_xact_lock(hashtextextended(
    'family-settlement:' || target_organization_id::text || ':' ||
    original_settlement.period_start::text || ':' ||
    original_settlement.period_end::text, 0
  ));

  reopening_request_hash := md5(jsonb_build_object(
    'settlement_id', target_settlement_id, 'reason', reopening_reason
  )::text);

  select op.* into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = reopen_family_settlement.operation_id
  for update;
  if found then
    if existing_operation.operation_type <> 'reopen_family_settlement'
       or existing_operation.request_hash <> reopening_request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;
    if existing_operation.status = 'succeeded' then
      select fs.* into reopened_settlement
      from family_settlements fs
      where fs.id = existing_operation.result_entity_id
        and fs.organization_id = target_organization_id;
      return reopened_settlement;
    end if;
    raise exception 'La operacion todavia esta en proceso.';
  end if;

  select fs.* into original_settlement
  from family_settlements fs
  where fs.id = target_settlement_id
    and fs.organization_id = target_organization_id
  for update;
  if original_settlement.status <> 'closed' or not original_settlement.is_current then
    raise exception 'Solo se puede reabrir el cierre vigente. Puede que ya haya sido reabierto.';
  end if;

  insert into operation_results (
    organization_id, operation_id, operation_type, request_hash, status, created_by
  ) values (
    target_organization_id, reopen_family_settlement.operation_id,
    'reopen_family_settlement', reopening_request_hash, 'in_progress', auth.uid()
  );

  -- Mantener los importes y los items originales como historial del cierre.
  update family_settlements fs
  set status = 'cancelled', is_current = false
  where fs.id = target_settlement_id
    and fs.organization_id = target_organization_id
  returning fs.* into reopened_settlement;

  insert into audit_logs (
    organization_id, actor_user_id, operation_id, action, entity_type,
    entity_id, old_values, new_values, metadata
  ) values (
    target_organization_id, auth.uid(), reopen_family_settlement.operation_id,
    'family_settlement_reopened', 'family_settlement', reopened_settlement.id,
    to_jsonb(original_settlement), to_jsonb(reopened_settlement),
    jsonb_build_object(
      'reason', reopening_reason,
      'periodStart', reopened_settlement.period_start,
      'periodEnd', reopened_settlement.period_end
    )
  );

  update operation_results op
  set status = 'succeeded', result_entity_type = 'family_settlement',
    result_entity_id = reopened_settlement.id,
    result_payload = jsonb_build_object('settlement_id', reopened_settlement.id, 'reopened', true),
    completed_at = now()
  where op.organization_id = target_organization_id
    and op.operation_id = reopen_family_settlement.operation_id;

  return reopened_settlement;
end;
$$;

revoke all on function reopen_family_settlement(uuid, uuid, text, uuid) from public;
grant execute on function reopen_family_settlement(uuid, uuid, text, uuid) to authenticated;

commit;

