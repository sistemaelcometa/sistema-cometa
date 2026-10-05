-- Registro y lectura de comprobantes subidos a Storage.

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
  else
    raise exception 'Tipo de entidad no permitido para comprobantes.';
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

create or replace function get_pde_data(
  target_organization_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with payment_totals as (
    select
      p.reservation_id,
      coalesce(sum(p.amount) filter (where p.status = 'valid'), 0) as paid_amount,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'date', p.payment_date,
            'amount', p.amount,
            'currency', p.currency,
            'method', p.payment_method,
            'type', p.payment_type,
            'detail', p.notes,
            'receiptName', pr.original_filename,
            'receiptBucket', pr.bucket,
            'receiptPath', pr.storage_path,
            'fileId', pr.id
          )
          order by p.payment_date, p.created_at
        ) filter (where p.status = 'valid'),
        '[]'::jsonb
      ) as payments
    from pde_reservation_payments p
    left join lateral (
      select f.id, f.bucket, f.storage_path, f.original_filename
      from file_links fl
      join files f on f.id = fl.file_id
      where fl.organization_id = p.organization_id
        and fl.entity_type = 'pde_reservation_payment'
        and fl.entity_id = p.id
        and f.status = 'active'
      order by f.created_at desc
      limit 1
    ) pr on true
    where p.organization_id = target_organization_id
    group by p.reservation_id
  ),
  units as (
    select
      u.id,
      u.name,
      u.description,
      u.display_color
    from pde_units u
    where u.organization_id = target_organization_id
      and u.status = 'active'
      and is_org_member(target_organization_id)
    order by u.name
  ),
  reservations as (
    select
      r.id,
      u.name as unit,
      r.guest_name_snapshot as guest,
      r.guest_phone_snapshot as phone,
      r.guest_email_snapshot as email,
      r.start_date as "from",
      r.end_date as "to",
      r.total_amount as total,
      r.currency,
      coalesce(pt.paid_amount, 0) as paid,
      case r.status
        when 'paid' then 'Pagada'
        when 'deposit_received' then 'Seña recibida'
        when 'reserved' then 'Reservada'
        when 'cancelled' then 'Cancelada'
        when 'finished' then 'Finalizada'
      end as status,
      r.status::text as "rawStatus",
      r.notes,
      r.cancel_reason as "cancelReason",
      r.created_at as "createdAt",
      coalesce(pt.payments, '[]'::jsonb) as payments
    from pde_reservations r
    join pde_units u on u.id = r.unit_id
    left join payment_totals pt on pt.reservation_id = r.id
    where r.organization_id = target_organization_id
      and is_org_member(target_organization_id)
    order by r.start_date desc, u.name, r.created_at desc
  ),
  expenses as (
    select
      a.id,
      e.id as "expenseId",
      u.name as unit,
      e.target_type::text as "targetType",
      e.expense_date as date,
      c.name as rubric,
      a.allocated_amount as amount,
      e.currency,
      e.description as detail,
      e.payment_method as "paymentMethod",
      e.notes,
      e.status::text as status,
      e.created_at as "createdAt",
      er.original_filename as "receiptName",
      er.bucket as "receiptBucket",
      er.storage_path as "receiptPath",
      er.id as "fileId"
    from pde_expense_allocations a
    join pde_expenses e on e.id = a.expense_id
    join pde_units u on u.id = a.unit_id
    left join expense_categories c on c.id = e.category_id
    left join lateral (
      select f.id, f.bucket, f.storage_path, f.original_filename
      from file_links fl
      join files f on f.id = fl.file_id
      where fl.organization_id = e.organization_id
        and fl.entity_type = 'pde_expense'
        and fl.entity_id = e.id
        and f.status = 'active'
      order by f.created_at desc
      limit 1
    ) er on true
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and is_org_member(target_organization_id)
    order by e.expense_date desc, e.created_at desc, u.name
  )
  select jsonb_build_object(
    'units', coalesce((select jsonb_agg(to_jsonb(units)) from units), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(to_jsonb(reservations)) from reservations), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(expenses)) from expenses), '[]'::jsonb)
  );
$$;
