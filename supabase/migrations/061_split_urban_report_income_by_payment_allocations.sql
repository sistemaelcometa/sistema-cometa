-- Split urban report income by payment allocations.
-- A single collected payment can include rent and expenses; the chart must show
-- each part in its own bucket.

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
  with payment_parts as (
    select
      p.id as payment_id,
      coalesce(sum(a.allocated_amount) filter (where i.item_type in ('rent', 'rent_surcharge')), 0)::numeric(14, 2) as rent_amount,
      coalesce(sum(a.allocated_amount) filter (where i.item_type in ('building_expense', 'unit_expense', 'expense_surcharge')), 0)::numeric(14, 2) as expense_amount,
      coalesce(sum(a.allocated_amount), 0)::numeric(14, 2) as allocated_amount
    from urban_payments p
    left join urban_payment_allocations a on a.payment_id = p.id
    left join urban_charge_items i on i.id = a.charge_item_id
    where p.organization_id = target_organization_id
      and p.status = 'valid'
    group by p.id
  ),
  payment_base as (
    select
      p.id,
      p.payment_date,
      p.notes,
      p.payment_method,
      p.received_amount,
      p.currency,
      p.created_at,
      b.name as building,
      u.name as department,
      nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as person,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      case
        when coalesce(pp.allocated_amount, 0) > 0 then coalesce(pp.rent_amount, 0)
        else p.received_amount
      end as report_rent_amount,
      case
        when coalesce(pp.allocated_amount, 0) > 0 then coalesce(pp.expense_amount, 0)
        else 0
      end as report_expense_amount
    from urban_payments p
    join urban_units u on u.id = p.unit_id
    join urban_buildings b on b.id = u.building_id
    join urban_leases l on l.id = p.lease_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join payment_parts pp on pp.payment_id = p.id
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
  ),
  movement_rows as (
    select
      'urban_payment_rent:' || p.id::text as row_id,
      'urban_payment_rent' as source_type,
      p.id as source_id,
      p.payment_date as movement_date,
      'Ingreso' as movement_kind,
      'Alquileres' as concept,
      coalesce(p.notes, 'Cobro de alquiler') as detail,
      p.building,
      p.department,
      p.person,
      payment_method_label(p.payment_method) as method,
      p.report_rent_amount as amount,
      p.currency,
      p.receipt_name,
      p.receipt_bucket,
      p.receipt_path,
      p.file_id,
      p.created_at as source_created_at
    from payment_base p
    where p.report_rent_amount > 0

    union all

    select
      'urban_payment_expenses:' || p.id::text as row_id,
      'urban_payment_expenses' as source_type,
      p.id as source_id,
      p.payment_date as movement_date,
      'Ingreso' as movement_kind,
      'Expensas cobradas' as concept,
      coalesce(p.notes, 'Cobro de expensas') as detail,
      p.building,
      p.department,
      p.person,
      payment_method_label(p.payment_method) as method,
      p.report_expense_amount as amount,
      p.currency,
      p.receipt_name,
      p.receipt_bucket,
      p.receipt_path,
      p.file_id,
      p.created_at as source_created_at
    from payment_base p
    where p.report_expense_amount > 0

    union all

    select
      'urban_expense_item:' || e.id::text as row_id,
      case
        when lower(coalesce(e.description, '')) like 'mantenimiento general%' then 'urban_expense_maintenance'
        else 'urban_expense_item'
      end as source_type,
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
        'rentIncome', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'urban_payment_rent'), 0),
        'expenseIncome', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'urban_payment_expenses'), 0),
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'ARS' and source_type = 'urban_expense_item'), 0),
        'maintenanceCosts', coalesce(sum(amount) filter (where currency = 'ARS' and source_type in ('maintenance_expense', 'urban_expense_maintenance')), 0)
      ),
      'USD', jsonb_build_object(
        'rentIncome', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'urban_payment_rent'), 0),
        'expenseIncome', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'urban_payment_expenses'), 0),
        'expenseCosts', coalesce(sum(amount) filter (where currency = 'USD' and source_type = 'urban_expense_item'), 0),
        'maintenanceCosts', coalesce(sum(amount) filter (where currency = 'USD' and source_type in ('maintenance_expense', 'urban_expense_maintenance')), 0)
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
