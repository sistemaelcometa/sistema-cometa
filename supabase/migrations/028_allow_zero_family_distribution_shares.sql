-- Permite dejar beneficiarios en 0% en la distribucion familiar.
-- Solo se guardan las participaciones mayores a 0%, pero la suma enviada debe dar 100%.

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

  if save_family_distribution.valid_from is null then
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
       or coalesce((item->>'percentage')::numeric, -1) < 0
  ) then
    raise exception 'La distribucion contiene beneficiarios o porcentajes invalidos.';
  end if;

  update family_distribution_groups
  set
    status = 'archived',
    valid_to = case
      when save_family_distribution.valid_from > family_distribution_groups.valid_from
        then save_family_distribution.valid_from - 1
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
    where coalesce((item->>'percentage')::numeric, 0) > 0
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
