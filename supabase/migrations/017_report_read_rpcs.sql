create or replace function payment_method_label(method payment_method)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when method is null then null
    when 'transfer' then 'Transferencia'
    when 'cash' then 'Efectivo'
    when 'deposit' then 'Deposito'
    when 'card' then 'Tarjeta'
    else 'Otro'
  end;
$$;

create or replace function get_urban_report(
  target_organization_id uuid,
  from_date date default null,
  to_date date default null,
  movement_type text default 'Todos',
  person_search text default null,
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
      'urban_payment:' || p.id::text as row_id,
      'urban_payment' as source_type,
      p.id as source_id,
      p.payment_date as movement_date,
      'Ingreso' as movement_kind,
      'Cobro' as concept,
      coalesce(p.notes, 'Cobro de alquiler') as detail,
      b.name as building,
      u.name as department,
      nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as person,
      payment_method_label(p.payment_method) as method,
      p.received_amount as amount,
      p.currency,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      p.created_at as source_created_at
    from urban_payments p
    join urban_units u on u.id = p.unit_id
    join urban_buildings b on b.id = u.building_id
    join urban_leases l on l.id = p.lease_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join lateral (
      select f.id, f.bucket, f.storage_path, f.original_filename
      from file_links fl
      join files f on f.id = fl.file_id
      where fl.organization_id = p.organization_id
        and fl.entity_type = 'urban_payment'
        and fl.entity_id = p.id
        and f.status = 'active'
      order by f.created_at desc
      limit 1
    ) receipt on true
    where p.organization_id = target_organization_id
      and p.status = 'valid'
      and is_org_member(target_organization_id)

    union all

    select
      'urban_expense_item:' || e.id::text as row_id,
      'urban_expense_item' as source_type,
      e.id as source_id,
      e.expense_date as movement_date,
      'Egreso' as movement_kind,
      'Expensas' as concept,
      coalesce(c.name, e.description) as detail,
      b.name as building,
      '-' as department,
      '' as person,
      '-' as method,
      e.amount as amount,
      e.currency,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      e.created_at as source_created_at
    from urban_expense_items e
    join urban_expense_periods p on p.id = e.period_id
    join urban_buildings b on b.id = p.building_id
    left join expense_categories c on c.id = e.category_id
    left join lateral (
      select f.id, f.bucket, f.storage_path, f.original_filename
      from file_links fl
      join files f on f.id = fl.file_id
      where fl.organization_id = e.organization_id
        and fl.entity_type = 'urban_expense_item'
        and fl.entity_id = e.id
        and f.status = 'active'
      order by f.created_at desc
      limit 1
    ) receipt on true
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and p.status <> 'cancelled'
      and is_org_member(target_organization_id)

    union all

    select
      'maintenance_expense:' || e.id::text as row_id,
      'maintenance_expense' as source_type,
      e.id as source_id,
      e.expense_date as movement_date,
      'Egreso' as movement_kind,
      'Mantenimiento' as concept,
      t.title || ' - ' || e.description as detail,
      b.name as building,
      u.name as department,
      nullif(trim(coalesce(w.first_name, '') || ' ' || coalesce(w.last_name, '')), '') as person,
      '-' as method,
      e.amount as amount,
      e.currency,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      e.created_at as source_created_at
    from maintenance_expenses e
    join maintenance_tasks t on t.id = e.task_id
    join urban_units u on u.id = t.unit_id
    join urban_buildings b on b.id = u.building_id
    left join contacts w on w.id = t.worker_contact_id
    left join lateral (
      select f.id, f.bucket, f.storage_path, f.original_filename
      from file_links fl
      join files f on f.id = fl.file_id
      where fl.organization_id = e.organization_id
        and fl.entity_type = 'maintenance_expense'
        and fl.entity_id = e.id
        and f.status = 'active'
      order by f.created_at desc
      limit 1
    ) receipt on true
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and t.status <> 'cancelled'
      and is_org_member(target_organization_id)
  ),
  filtered_rows as (
    select *
    from movement_rows r
    where (from_date is null or r.movement_date >= from_date)
      and (to_date is null or r.movement_date <= to_date)
      and (movement_type is null or lower(movement_type) in ('todos', 'all') or r.movement_kind = movement_type)
      and (person_search is null or person_search = '' or lower(coalesce(r.person, '')) like '%' || lower(person_search) || '%')
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
        'rentIncome', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'urban_payment'), 0),
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'urban_expense_item'), 0),
        'maintenanceCosts', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'maintenance_expense'), 0)
      ),
      'USD', jsonb_build_object(
        'rentIncome', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'urban_payment'), 0),
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'urban_expense_item'), 0),
        'maintenanceCosts', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'maintenance_expense'), 0)
      )
    ),
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
          'building', building,
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
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'pde_expense'), 0),
        'maintenanceCosts', 0
      ),
      'USD', jsonb_build_object(
        'rentIncome', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'pde_payment'), 0),
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
