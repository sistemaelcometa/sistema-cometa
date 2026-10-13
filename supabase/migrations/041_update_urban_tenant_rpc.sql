create or replace function update_urban_tenant(
  target_organization_id uuid,
  tenant_contact_id uuid,
  tenant_first_name text,
  tenant_last_name text default null,
  tenant_document_number text default null,
  tenant_phone text default null,
  tenant_email text default null,
  tenant_address text default null,
  tenant_notes text default null
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
    raise exception 'No tenes permisos para editar inquilinos.';
  end if;

  if tenant_contact_id is null then
    raise exception 'El inquilino es obligatorio.';
  end if;

  if nullif(trim(coalesce(tenant_first_name, '')), '') is null
     and nullif(trim(coalesce(tenant_last_name, '')), '') is null then
    raise exception 'El nombre del inquilino es obligatorio.';
  end if;

  select *
    into previous_contact
  from contacts c
  where c.id = tenant_contact_id
    and c.organization_id = target_organization_id
    and c.status = 'active'
    and (
      c.is_tenant
      or exists (
        select 1
        from urban_leases l
        where l.primary_tenant_contact_id = c.id
          and l.organization_id = target_organization_id
      )
    )
  for update;

  if not found then
    raise exception 'El inquilino no existe o esta archivado.';
  end if;

  update contacts c
  set
    contact_type = 'person',
    first_name = nullif(trim(coalesce(tenant_first_name, '')), ''),
    last_name = nullif(trim(coalesce(tenant_last_name, '')), ''),
    business_name = null,
    document_number = nullif(trim(coalesce(tenant_document_number, '')), ''),
    phone = nullif(trim(coalesce(tenant_phone, '')), ''),
    email = nullif(trim(coalesce(tenant_email, '')), ''),
    address = nullif(trim(coalesce(tenant_address, '')), ''),
    notes = nullif(trim(coalesce(tenant_notes, '')), ''),
    is_tenant = true
  where c.id = tenant_contact_id
    and c.organization_id = target_organization_id
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
    'urban_tenant_updated',
    'contact',
    saved_contact.id,
    to_jsonb(previous_contact),
    to_jsonb(saved_contact)
  );

  return saved_contact;
end;
$$;
