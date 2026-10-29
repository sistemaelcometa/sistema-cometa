-- Ingresos PDE independientes de reservas. No modifica cobros existentes.
begin;

create table if not exists pde_misc_incomes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid references pde_units(id) on delete restrict,
  income_date date not null,
  description text not null check (length(trim(description)) > 0),
  amount numeric(14,2) not null check (amount > 0),
  currency char(3) not null default 'USD' check (currency = 'USD'),
  payment_method payment_method not null default 'transfer',
  status record_status not null default 'valid',
  voided_at timestamptz,
  voided_by uuid references profiles(id),
  void_reason text,
  operation_id uuid not null,
  request_hash text not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (organization_id, operation_id)
);
create index if not exists pde_misc_incomes_org_date_idx
  on pde_misc_incomes(organization_id, income_date desc);
alter table pde_misc_incomes enable row level security;
drop policy if exists pde_misc_incomes_select_member on pde_misc_incomes;
create policy pde_misc_incomes_select_member on pde_misc_incomes
  for select using (is_org_member(organization_id));
revoke all on pde_misc_incomes from anon, authenticated;
grant select on pde_misc_incomes to authenticated;

create or replace function register_pde_misc_income(
  target_organization_id uuid,
  income_date date,
  income_amount numeric,
  income_description text,
  target_unit_name text default null,
  income_payment_method payment_method default 'transfer',
  operation_id uuid default gen_random_uuid()
)
returns pde_misc_incomes
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_description text := nullif(trim(coalesce(income_description, '')), '');
  cleaned_unit text := nullif(trim(coalesce(target_unit_name, '')), '');
  income_request_hash text;
  selected_unit pde_units;
  saved_income pde_misc_incomes;
begin
  if auth.uid() is null then raise exception 'Usuario no autenticado.'; end if;
  if not has_org_role(target_organization_id, array['owner','admin','editor']::app_role[]) then
    raise exception 'No tenes permisos para registrar ingresos.';
  end if;
  if register_pde_misc_income.income_date is null or operation_id is null then
    raise exception 'La fecha y el identificador de operacion son obligatorios.';
  end if;
  if income_amount is null or income_amount <= 0 or income_amount <> round(income_amount,2)
     or income_amount > 999999999999.99 then
    raise exception 'El importe debe ser mayor a cero y tener hasta dos decimales.';
  end if;
  if cleaned_description is null or income_payment_method is null then
    raise exception 'El concepto y el medio de cobro son obligatorios.';
  end if;
  income_request_hash := md5(jsonb_build_object('date',register_pde_misc_income.income_date,
    'amount',income_amount,'description',cleaned_description,'unit',cleaned_unit,
    'method',income_payment_method)::text);
  perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text || ':' || operation_id::text,0));
  select * into saved_income from pde_misc_incomes m
  where m.organization_id = target_organization_id and m.operation_id = register_pde_misc_income.operation_id;
  if found then
    if saved_income.request_hash <> income_request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;
    return saved_income;
  end if;
  if cleaned_unit is not null then
    selected_unit := ensure_pde_unit(target_organization_id, cleaned_unit);
  end if;
  insert into pde_misc_incomes(organization_id,unit_id,income_date,description,amount,
    payment_method,operation_id,request_hash,created_by)
  values (target_organization_id,selected_unit.id,register_pde_misc_income.income_date,
    cleaned_description,income_amount,income_payment_method,register_pde_misc_income.operation_id,
    income_request_hash,auth.uid()) returning * into saved_income;
  insert into audit_logs(organization_id,actor_user_id,operation_id,action,entity_type,entity_id,new_values)
  values(target_organization_id,auth.uid(),register_pde_misc_income.operation_id,
    'pde_misc_income_registered','pde_misc_income',saved_income.id,to_jsonb(saved_income));
  return saved_income;
end;
$$;

create or replace function void_pde_misc_income(
  target_organization_id uuid, target_income_id uuid, reason text default 'Anulado desde ingresos varios'
)
returns pde_misc_incomes
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_income pde_misc_incomes;
  saved_income pde_misc_incomes;
begin
  if auth.uid() is null then raise exception 'Usuario no autenticado.'; end if;
  if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then
    raise exception 'No tenes permisos para anular ingresos.';
  end if;
  if nullif(trim(coalesce(reason,'')),'') is null then raise exception 'El motivo es obligatorio.'; end if;
  select * into previous_income from pde_misc_incomes m
  where m.id = target_income_id and m.organization_id = target_organization_id for update;
  if not found then raise exception 'El ingreso no existe en esta organizacion.'; end if;
  if previous_income.status = 'voided' then return previous_income; end if;
  update pde_misc_incomes set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = trim(reason)
  where id = target_income_id returning * into saved_income;
  insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_organization_id,auth.uid(),'pde_misc_income_voided','pde_misc_income',saved_income.id,
    to_jsonb(previous_income),to_jsonb(saved_income));
  return saved_income;
end;
$$;

revoke all on function register_pde_misc_income(uuid,date,numeric,text,text,payment_method,uuid) from public;
revoke all on function void_pde_misc_income(uuid,uuid,text) from public;
grant execute on function register_pde_misc_income(uuid,date,numeric,text,text,payment_method,uuid) to authenticated;
grant execute on function void_pde_misc_income(uuid,uuid,text) to authenticated;

alter table pde_misc_incomes replica identity full;
do $$
begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'pde_misc_incomes') then
    alter publication supabase_realtime add table pde_misc_incomes;
  end if;
end;
$$;


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
  elsif entity_type = 'pde_misc_income' then
    select exists (select 1 from pde_misc_incomes m
      where m.id = entity_id and m.organization_id = target_organization_id and m.status = 'valid')
      into target_exists;
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
    register_uploaded_file_link.entity_type,
    register_uploaded_file_link.entity_id,
    nullif(trim(coalesce(file_label, '')), ''),
    auth.uid()
  )
  on conflict on constraint file_links_file_id_entity_type_entity_id_key do nothing;

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
    'expenses', coalesce((select jsonb_agg(to_jsonb(expenses)) from expenses), '[]'::jsonb),
    'miscIncomes', coalesce((
      select jsonb_agg(jsonb_build_object('id',m.id,'unit',coalesce(u.name,'General'),
        'date',m.income_date,'detail',m.description,'amount',m.amount,'currency',m.currency,
        'method',m.payment_method,'receiptName',coalesce(receipt.original_filename,''),
        'receiptBucket',coalesce(receipt.bucket,''),'receiptPath',coalesce(receipt.storage_path,''),
        'fileId',receipt.id) order by m.income_date desc,m.created_at desc,m.id)
      from pde_misc_incomes m
      left join pde_units u on u.id = m.unit_id and u.organization_id = m.organization_id
      left join lateral (
        select f.* from file_links fl join files f on f.id = fl.file_id
        where fl.organization_id = m.organization_id and fl.entity_type = 'pde_misc_income'
          and fl.entity_id = m.id and f.status = 'active' order by f.created_at desc limit 1
      ) receipt on true
      where m.organization_id = target_organization_id and m.status = 'valid'
        and is_org_member(target_organization_id)
    ),'[]'::jsonb)
  );
$$;

create or replace function get_pde_report(
  target_organization_id uuid,
  from_date date default null,
  to_date date default null,
  movement_type text default 'Todos',
  person_search text default null,
  department_filter text default null,
  month_filter integer default null,
  year_filter integer default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with movement_rows as (
    select
      'pde_payment:' || p.id::text as row_id,
      'pde_payment' as source_type,
      p.id as source_id,
      p.payment_date as movement_date,
      'Ingreso' as movement_kind,
      'Alquiler' as concept,
      coalesce(p.notes, 'Cobro de reserva') as detail,
      u.name as department,
      r.guest_name_snapshot as person,
      payment_method_label(p.payment_method) as method,
      p.amount as amount,
      p.currency,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      p.created_at as source_created_at
    from pde_reservation_payments p
    join pde_reservations r on r.id = p.reservation_id
    join pde_units u on u.id = r.unit_id
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
    ) receipt on true
    where p.organization_id = target_organization_id
      and p.status = 'valid'
      and r.status <> 'cancelled'
      and is_org_member(target_organization_id)

    union all

    select
      'pde_misc_income:' || m.id::text, 'pde_misc_income', m.id, m.income_date,
      'Ingreso', 'Ingresos varios', m.description, coalesce(u.name,'General'), '',
      payment_method_label(m.payment_method), m.amount, m.currency,
      receipt.original_filename, receipt.bucket, receipt.storage_path, receipt.id, m.created_at
    from pde_misc_incomes m
    left join pde_units u on u.id = m.unit_id and u.organization_id = m.organization_id
    left join lateral (
      select f.* from file_links fl join files f on f.id = fl.file_id
      where fl.organization_id = m.organization_id and fl.entity_type = 'pde_misc_income'
        and fl.entity_id = m.id and f.status = 'active' order by f.created_at desc limit 1
    ) receipt on true
    where m.organization_id = target_organization_id and m.status = 'valid'
      and is_org_member(target_organization_id)

    union all

    select
      'pde_expense_allocation:' || a.id::text as row_id,
      'pde_expense' as source_type,
      e.id as source_id,
      e.expense_date as movement_date,
      'Egreso' as movement_kind,
      coalesce(c.name, 'Gasto') as concept,
      e.description as detail,
      u.name as department,
      '' as person,
      coalesce(payment_method_label(e.payment_method), '-') as method,
      a.allocated_amount as amount,
      a.currency,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      e.created_at as source_created_at
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
    ) receipt on true
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and is_org_member(target_organization_id)
  ),
  filtered_rows as (
    select *
    from movement_rows r
    where (from_date is null or r.movement_date >= from_date)
      and (to_date is null or r.movement_date <= to_date)
      and (movement_type is null or lower(movement_type) in ('todos', 'all') or r.movement_kind = movement_type)
      and (person_search is null or person_search = '' or lower(coalesce(r.person, '')) like '%' || lower(person_search) || '%')
      and (department_filter is null or department_filter = '' or department_filter = 'Todos' or r.department = department_filter)
      and (month_filter is null or extract(month from r.movement_date)::integer = month_filter)
      and (year_filter is null or extract(year from r.movement_date)::integer = year_filter)
  ),
  page_rows as (
    select *
    from filtered_rows
    order by movement_date desc, source_created_at desc, row_id desc
    limit greatest(1, least(coalesce(page_size, 50), 200))
    offset greatest(coalesce(page_offset, 0), 0)
  )
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'ARS', jsonb_build_object(
        'incomes', coalesce(sum(amount) filter (where currency = 'ARS' and movement_kind = 'Ingreso'), 0),
        'expenses', coalesce(sum(amount) filter (where currency = 'ARS' and movement_kind = 'Egreso'), 0),
        'margin', coalesce(sum(amount) filter (where currency = 'ARS' and movement_kind = 'Ingreso'), 0)
          - coalesce(sum(amount) filter (where currency = 'ARS' and movement_kind = 'Egreso'), 0)
      ),
      'USD', jsonb_build_object(
        'incomes', coalesce(sum(amount) filter (where currency = 'USD' and movement_kind = 'Ingreso'), 0),
        'expenses', coalesce(sum(amount) filter (where currency = 'USD' and movement_kind = 'Egreso'), 0),
        'margin', coalesce(sum(amount) filter (where currency = 'USD' and movement_kind = 'Ingreso'), 0)
          - coalesce(sum(amount) filter (where currency = 'USD' and movement_kind = 'Egreso'), 0)
      )
    ),
    'chart', jsonb_build_object(
      'ARS', jsonb_build_object(
        'rentIncome', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'pde_payment'), 0),
        'miscIncome', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'pde_misc_income'), 0),
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'pde_expense'), 0),
        'maintenanceCosts', 0
      ),
      'USD', jsonb_build_object(
        'rentIncome', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'pde_payment'), 0),
        'miscIncome', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'pde_misc_income'), 0),
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'pde_expense'), 0),
        'maintenanceCosts', 0
      )
    ),
    'departments', coalesce((
      select jsonb_agg(distinct department order by department)
      from movement_rows
      where department is not null and department <> ''
    ), '[]'::jsonb),
    'totalCount', (select count(*) from filtered_rows),
    'movements', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', row_id,
          'sourceType', source_type,
          'sourceId', source_id,
          'date', movement_date,
          'type', movement_kind,
          'concept', concept,
          'detail', detail,
          'department', department,
          'person', person,
          'method', method,
          'amount', amount,
          'currency', currency,
          'receiptName', coalesce(receipt_name, ''),
          'receiptBucket', coalesce(receipt_bucket, ''),
          'receiptPath', coalesce(receipt_path, ''),
          'fileId', file_id
        )
        order by movement_date desc, source_created_at desc, row_id desc
      )
      from page_rows
    ), '[]'::jsonb)
  )
  from filtered_rows;
$$;

commit;

