-- Permite vincular archivos de contrato a contratos urbanos.

create or replace function register_uploaded_file_link(
  target_organization_id uuid,
  file_bucket text,
  file_storage_path text,
  original_filename text,
  mime_type text default null,
  size_bytes bigint default null,
  entity_type text default null,
  entity_id uuid default null,
  file_label text default 'Comprobante',
  operation_id uuid default gen_random_uuid()
)
returns files
language plpgsql
security definer
set search_path = public
as $$
declare
  saved_file files;
  target_exists boolean := false;
  old_file files;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para registrar archivos.';
  end if;

  if file_bucket not in ('receipts', 'contracts', 'maintenance', 'settlements') then
    raise exception 'Bucket no permitido.';
  end if;

  if public.storage_object_organization_id(file_storage_path) is distinct from target_organization_id then
    raise exception 'La ruta del archivo no corresponde a la organizacion.';
  end if;

  if nullif(trim(coalesce(original_filename, '')), '') is null then
    raise exception 'El nombre original del archivo es obligatorio.';
  end if;

  if entity_type is null or entity_id is null then
    raise exception 'La entidad vinculada es obligatoria.';
  end if;

  if entity_type = 'pde_reservation_payment' then
    select exists (
      select 1
      from pde_reservation_payments
      where id = entity_id
        and organization_id = target_organization_id
        and status = 'valid'
    ) into target_exists;
  elsif entity_type = 'pde_expense' then
    select exists (
      select 1
      from pde_expenses
      where id = entity_id
        and organization_id = target_organization_id
        and status = 'valid'
    ) into target_exists;
  elsif entity_type = 'urban_payment' then
    select exists (
      select 1
      from urban_payments
      where id = entity_id
        and organization_id = target_organization_id
        and status = 'valid'
    ) into target_exists;
  elsif entity_type = 'urban_expense_item' then
    select exists (
      select 1
      from urban_expense_items
      where id = entity_id
        and organization_id = target_organization_id
        and status = 'valid'
    ) into target_exists;
  elsif entity_type = 'maintenance_expense' then
    select exists (
      select 1
      from maintenance_expenses
      where id = entity_id
        and organization_id = target_organization_id
        and status = 'valid'
    ) into target_exists;
  elsif entity_type = 'urban_lease' then
    select exists (
      select 1
      from urban_leases
      where id = entity_id
        and organization_id = target_organization_id
        and status <> 'archived'
    ) into target_exists;
  else
    raise exception 'Tipo de entidad no permitido para archivos.';
  end if;

  if not target_exists then
    raise exception 'No existe la entidad a vincular o no esta vigente.';
  end if;

  select *
    into old_file
  from files
  where bucket = file_bucket
    and storage_path = file_storage_path
  for update;

  insert into files (
    organization_id,
    bucket,
    storage_path,
    original_filename,
    mime_type,
    size_bytes,
    status,
    uploaded_by
  )
  values (
    target_organization_id,
    file_bucket,
    file_storage_path,
    trim(original_filename),
    nullif(trim(coalesce(mime_type, '')), ''),
    size_bytes,
    'active',
    auth.uid()
  )
  on conflict (bucket, storage_path) do update
  set
    original_filename = excluded.original_filename,
    mime_type = excluded.mime_type,
    size_bytes = excluded.size_bytes,
    status = 'active',
    updated_at = now()
  returning * into saved_file;

  insert into file_links (
    organization_id,
    file_id,
    entity_type,
    entity_id,
    label,
    created_by
  )
  values (
    target_organization_id,
    saved_file.id,
    entity_type,
    entity_id,
    nullif(trim(coalesce(file_label, '')), ''),
    auth.uid()
  )
  on conflict (file_id, entity_type, entity_id) do nothing;

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
    register_uploaded_file_link.operation_id,
    'file_linked',
    register_uploaded_file_link.entity_type,
    register_uploaded_file_link.entity_id,
    case when old_file.id is null then null else to_jsonb(old_file) end,
    to_jsonb(saved_file),
    jsonb_build_object(
      'fileId', saved_file.id,
      'bucket', saved_file.bucket,
      'storagePath', saved_file.storage_path,
      'label', file_label
    )
  );

  return saved_file;
end;
$$;
