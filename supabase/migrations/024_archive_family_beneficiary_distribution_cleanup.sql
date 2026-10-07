-- Permite archivar beneficiarios sin liquidaciones cerradas.
-- Si el beneficiario participa en distribuciones activas, se archivan esas
-- distribuciones completas para evitar que queden porcentajes inconsistentes.

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
  affected_group_ids uuid[];
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado.';
  end if;

  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'No tenes permisos para archivar beneficiarios.';
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

  if exists (
    select 1
    from family_settlement_items
    where organization_id = target_organization_id
      and beneficiary_contact_id = archive_family_beneficiary.beneficiary_contact_id
  ) then
    raise exception 'No se puede archivar un beneficiario que ya fue usado en liquidaciones cerradas.';
  end if;

  select coalesce(array_agg(distinct g.id), '{}'::uuid[])
    into affected_group_ids
  from family_distribution_groups g
  join family_distribution_shares s on s.distribution_group_id = g.id
  where g.organization_id = target_organization_id
    and g.status = 'active'
    and s.beneficiary_contact_id = archive_family_beneficiary.beneficiary_contact_id;

  update family_distribution_groups
  set
    status = 'archived',
    valid_to = case
      when current_date >= valid_from then current_date
      else valid_from
    end
  where id = any(affected_group_ids);

  update contacts
  set
    status = 'archived',
    updated_at = now()
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
    to_jsonb(archived_contact) || jsonb_build_object(
      'archivedDistributionGroupIds',
      affected_group_ids
    )
  );

  return archived_contact;
end;
$$;
