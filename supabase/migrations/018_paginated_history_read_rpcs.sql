create or replace function get_pde_reservations_page(
  target_organization_id uuid,
  status_filter text default 'active',
  unit_filter text default null,
  guest_search text default null,
  month_filter integer default null,
  year_filter integer default null,
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      nullif(trim(coalesce(guest_search, '')), '') as guest_query,
      nullif(trim(coalesce(unit_filter, '')), '') as unit_query,
      coalesce(nullif(trim(coalesce(status_filter, '')), ''), 'active') as status_query
  ),
  payment_totals as (
    select
      p.reservation_id,
      coalesce(sum(p.amount) filter (where p.status = 'valid'), 0)::numeric(14, 2) as paid_amount,
      count(*) filter (where p.status = 'valid')::integer as payment_count
    from pde_reservation_payments p
    where p.organization_id = target_organization_id
    group by p.reservation_id
  ),
  base_rows as (
    select
      r.id,
      u.name as unit,
      r.guest_name_snapshot as guest,
      r.guest_phone_snapshot as phone,
      r.guest_email_snapshot as email,
      r.start_date,
      r.end_date,
      (r.end_date - r.start_date)::integer as nights,
      case when r.end_date > r.start_date
        then round(r.total_amount / nullif((r.end_date - r.start_date)::numeric, 0), 2)
        else 0
      end as nightly_amount,
      r.total_amount,
      r.currency,
      coalesce(pt.paid_amount, 0)::numeric(14, 2) as paid_amount,
      greatest(r.total_amount - coalesce(pt.paid_amount, 0), 0)::numeric(14, 2) as balance_amount,
      coalesce(pt.payment_count, 0) as payment_count,
      case r.status
        when 'paid' then 'Pagada'
        when 'deposit_received' then 'Sena recibida'
        when 'reserved' then 'Reservada'
        when 'cancelled' then 'Cancelada'
        when 'finished' then 'Finalizada'
      end as status_label,
      r.status::text as status_key,
      r.notes,
      r.cancel_reason,
      r.created_at,
      r.updated_at
    from pde_reservations r
    join pde_units u on u.id = r.unit_id
    left join payment_totals pt on pt.reservation_id = r.id
    cross join params p
    where r.organization_id = target_organization_id
      and is_org_member(target_organization_id)
      and (p.unit_query is null or u.name = p.unit_query)
      and (p.guest_query is null or immutable_unaccent(r.guest_name_snapshot) ilike '%' || immutable_unaccent(p.guest_query) || '%')
      and (month_filter is null or extract(month from r.start_date)::integer = month_filter)
      and (year_filter is null or extract(year from r.start_date)::integer = year_filter)
      and (from_date is null or r.start_date >= from_date)
      and (to_date is null or r.start_date <= to_date)
      and (
        p.status_query = 'all'
        or (p.status_query = 'active' and r.status in ('reserved', 'deposit_received', 'paid'))
        or (p.status_query = 'history' and r.status in ('cancelled', 'finished'))
        or r.status::text = p.status_query
      )
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by start_date asc, unit asc, created_at asc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'unit', pr.unit,
      'guest', pr.guest,
      'phone', pr.phone,
      'email', pr.email,
      'from', pr.start_date,
      'to', pr.end_date,
      'nights', pr.nights,
      'nightlyAmount', pr.nightly_amount,
      'total', pr.total_amount,
      'currency', pr.currency,
      'paid', pr.paid_amount,
      'balance', pr.balance_amount,
      'paymentCount', pr.payment_count,
      'status', pr.status_label,
      'statusKey', pr.status_key,
      'notes', pr.notes,
      'cancelReason', pr.cancel_reason,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.start_date asc, pr.unit asc, pr.created_at asc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;

create or replace function get_pde_expenses_page(
  target_organization_id uuid,
  unit_filter text default null,
  category_search text default null,
  month_filter integer default null,
  year_filter integer default null,
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      nullif(trim(coalesce(unit_filter, '')), '') as unit_query,
      nullif(trim(coalesce(category_search, '')), '') as category_query
  ),
  base_rows as (
    select
      a.id,
      e.id as expense_id,
      coalesce(u.name, 'General') as unit,
      e.target_type::text as target_type,
      e.expense_date,
      coalesce(c.name, 'Gasto') as category,
      e.description,
      a.allocated_amount as amount,
      e.amount as source_amount,
      e.currency,
      payment_method_label(e.payment_method) as method,
      e.notes,
      e.status::text as status_key,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      e.created_at,
      e.updated_at
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
    cross join params p
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and is_org_member(target_organization_id)
      and (p.unit_query is null or u.name = p.unit_query or (p.unit_query = 'General' and e.target_type = 'general_50_50'))
      and (p.category_query is null or immutable_unaccent(coalesce(c.name, e.description)) ilike '%' || immutable_unaccent(p.category_query) || '%')
      and (month_filter is null or extract(month from e.expense_date)::integer = month_filter)
      and (year_filter is null or extract(year from e.expense_date)::integer = year_filter)
      and (from_date is null or e.expense_date >= from_date)
      and (to_date is null or e.expense_date <= to_date)
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by expense_date desc, created_at desc, unit asc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'expenseId', pr.expense_id,
      'unit', pr.unit,
      'targetType', pr.target_type,
      'date', pr.expense_date,
      'category', pr.category,
      'description', pr.description,
      'amount', pr.amount,
      'sourceAmount', pr.source_amount,
      'currency', pr.currency,
      'method', pr.method,
      'notes', pr.notes,
      'statusKey', pr.status_key,
      'receiptName', pr.receipt_name,
      'receiptBucket', pr.receipt_bucket,
      'receiptPath', pr.receipt_path,
      'fileId', pr.file_id,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.expense_date desc, pr.created_at desc, pr.unit asc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;

create or replace function get_urban_payments_page(
  target_organization_id uuid,
  building_filter uuid default null,
  unit_filter uuid default null,
  tenant_search text default null,
  month_filter integer default null,
  year_filter integer default null,
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      nullif(trim(coalesce(tenant_search, '')), '') as tenant_query
  ),
  allocations as (
    select
      p.id as payment_id,
      (array_remove(array_agg(ch.id order by ch.period_month desc nulls last, ch.created_at desc nulls last), null))[1] as charge_id,
      max(ch.period_month) as period_month,
      coalesce(sum(a.allocated_amount) filter (where i.item_type = 'rent'), 0)::numeric(14, 2) as rent_paid,
      coalesce(sum(a.allocated_amount) filter (where i.item_type = 'rent_surcharge'), 0)::numeric(14, 2) as rent_surcharge_paid,
      coalesce(sum(a.allocated_amount) filter (where i.item_type in ('building_expense', 'unit_expense')), 0)::numeric(14, 2) as expenses_paid,
      coalesce(sum(a.allocated_amount) filter (where i.item_type = 'expense_surcharge'), 0)::numeric(14, 2) as expense_surcharge_paid
    from urban_payments p
    left join urban_payment_allocations a on a.payment_id = p.id
    left join urban_charge_items i on i.id = a.charge_item_id
    left join urban_charges ch on ch.id = i.charge_id
    where p.organization_id = target_organization_id
    group by p.id
  ),
  base_rows as (
    select
      p.id,
      a.charge_id,
      p.unit_id,
      u.name as unit,
      b.id as building_id,
      b.name as building,
      nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as tenant,
      p.payment_date,
      p.received_amount,
      p.currency,
      payment_method_label(p.payment_method) as method,
      p.notes,
      to_char(a.period_month, 'YYYY-MM') as charge_period,
      a.rent_paid,
      a.rent_surcharge_paid,
      a.expenses_paid,
      a.expense_surcharge_paid,
      receipt.original_filename as receipt_name,
      receipt.bucket as receipt_bucket,
      receipt.storage_path as receipt_path,
      receipt.id as file_id,
      p.created_at,
      p.updated_at
    from urban_payments p
    join urban_units u on u.id = p.unit_id
    join urban_buildings b on b.id = u.building_id
    join urban_leases l on l.id = p.lease_id
    join contacts c on c.id = l.primary_tenant_contact_id
    left join allocations a on a.payment_id = p.id
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
    cross join params x
    where p.organization_id = target_organization_id
      and p.status = 'valid'
      and is_org_member(target_organization_id)
      and (building_filter is null or b.id = building_filter)
      and (unit_filter is null or u.id = unit_filter)
      and (x.tenant_query is null or immutable_unaccent(nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '')) ilike '%' || immutable_unaccent(x.tenant_query) || '%')
      and (month_filter is null or extract(month from p.payment_date)::integer = month_filter)
      and (year_filter is null or extract(year from p.payment_date)::integer = year_filter)
      and (from_date is null or p.payment_date >= from_date)
      and (to_date is null or p.payment_date <= to_date)
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by payment_date desc, created_at desc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'chargeId', pr.charge_id,
      'unitId', pr.unit_id,
      'unit', pr.unit,
      'buildingId', pr.building_id,
      'building', pr.building,
      'tenant', pr.tenant,
      'paidAt', pr.payment_date,
      'amount', pr.received_amount,
      'currency', pr.currency,
      'method', pr.method,
      'notes', pr.notes,
      'chargePeriod', pr.charge_period,
      'allocation', jsonb_build_object(
        'expensesPaid', coalesce(pr.expenses_paid, 0),
        'expenseSurchargePaid', coalesce(pr.expense_surcharge_paid, 0),
        'rentPaid', coalesce(pr.rent_paid, 0),
        'rentSurchargePaid', coalesce(pr.rent_surcharge_paid, 0)
      ),
      'receiptName', pr.receipt_name,
      'receiptBucket', pr.receipt_bucket,
      'receiptPath', pr.receipt_path,
      'fileId', pr.file_id,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.payment_date desc, pr.created_at desc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;

create or replace function get_urban_expenses_page(
  target_organization_id uuid,
  building_filter uuid default null,
  category_search text default null,
  month_filter integer default null,
  year_filter integer default null,
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      nullif(trim(coalesce(category_search, '')), '') as category_query
  ),
  base_rows as (
    select
      e.id,
      ep.id as period_id,
      ep.period_month,
      b.id as building_id,
      b.name as building,
      e.expense_date,
      coalesce(c.name, 'Gasto') as category,
      e.description,
      e.amount,
      e.currency,
      e.transfer_to_tenant,
      e.notes,
      ep.status::text as period_status,
      e.status::text as status_key,
      e.created_at,
      e.updated_at
    from urban_expense_items e
    join urban_expense_periods ep on ep.id = e.period_id
    join urban_buildings b on b.id = ep.building_id
    left join expense_categories c on c.id = e.category_id
    cross join params p
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and is_org_member(target_organization_id)
      and (building_filter is null or b.id = building_filter)
      and (p.category_query is null or immutable_unaccent(coalesce(c.name, e.description)) ilike '%' || immutable_unaccent(p.category_query) || '%')
      and (month_filter is null or extract(month from e.expense_date)::integer = month_filter)
      and (year_filter is null or extract(year from e.expense_date)::integer = year_filter)
      and (from_date is null or e.expense_date >= from_date)
      and (to_date is null or e.expense_date <= to_date)
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by expense_date desc, created_at desc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'periodId', pr.period_id,
      'periodMonth', pr.period_month,
      'buildingId', pr.building_id,
      'building', pr.building,
      'date', pr.expense_date,
      'category', pr.category,
      'description', pr.description,
      'amount', pr.amount,
      'currency', pr.currency,
      'transferToTenant', pr.transfer_to_tenant,
      'notes', pr.notes,
      'periodStatus', pr.period_status,
      'statusKey', pr.status_key,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.expense_date desc, pr.created_at desc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;

create or replace function get_maintenance_history_page(
  target_organization_id uuid,
  building_filter uuid default null,
  unit_filter uuid default null,
  status_filter text default 'all',
  search_text text default null,
  month_filter integer default null,
  year_filter integer default null,
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      coalesce(nullif(trim(coalesce(status_filter, '')), ''), 'all') as status_query,
      nullif(trim(coalesce(search_text, '')), '') as search_query
  ),
  expense_totals as (
    select
      e.task_id,
      coalesce(sum(e.amount) filter (where e.status = 'valid' and e.currency = 'ARS'), 0)::numeric(14, 2) as total_ars,
      coalesce(sum(e.amount) filter (where e.status = 'valid' and e.currency = 'USD'), 0)::numeric(14, 2) as total_usd,
      count(*) filter (where e.status = 'valid')::integer as expense_count
    from maintenance_expenses e
    where e.organization_id = target_organization_id
    group by e.task_id
  ),
  base_rows as (
    select
      t.id,
      t.unit_id,
      u.name as unit,
      b.id as building_id,
      b.name as building,
      t.title,
      t.detail,
      nullif(trim(coalesce(w.first_name, '') || ' ' || coalesce(w.last_name, '')), '') as worker,
      w.phone as worker_phone,
      w.notes as profession,
      t.status::text as status_key,
      case t.status
        when 'finished' then 'Terminada'
        when 'cancelled' then 'Cancelada'
        else 'Abierta'
      end as status_label,
      t.opened_at,
      t.finished_at,
      coalesce(et.total_ars, 0) as total_ars,
      coalesce(et.total_usd, 0) as total_usd,
      coalesce(et.expense_count, 0) as expense_count,
      t.created_at,
      t.updated_at
    from maintenance_tasks t
    join urban_units u on u.id = t.unit_id
    join urban_buildings b on b.id = u.building_id
    left join contacts w on w.id = t.worker_contact_id
    left join expense_totals et on et.task_id = t.id
    cross join params p
    where t.organization_id = target_organization_id
      and is_org_member(target_organization_id)
      and (building_filter is null or b.id = building_filter)
      and (unit_filter is null or u.id = unit_filter)
      and (p.status_query = 'all' or t.status::text = p.status_query)
      and (
        p.search_query is null
        or immutable_unaccent(t.title) ilike '%' || immutable_unaccent(p.search_query) || '%'
        or immutable_unaccent(coalesce(t.detail, '')) ilike '%' || immutable_unaccent(p.search_query) || '%'
        or immutable_unaccent(coalesce(w.first_name, '') || ' ' || coalesce(w.last_name, '')) ilike '%' || immutable_unaccent(p.search_query) || '%'
      )
      and (month_filter is null or extract(month from t.opened_at)::integer = month_filter)
      and (year_filter is null or extract(year from t.opened_at)::integer = year_filter)
      and (from_date is null or t.opened_at >= from_date)
      and (to_date is null or t.opened_at <= to_date)
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by opened_at desc, created_at desc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'unitId', pr.unit_id,
      'unit', pr.unit,
      'buildingId', pr.building_id,
      'building', pr.building,
      'title', pr.title,
      'detail', pr.detail,
      'worker', pr.worker,
      'workerPhone', pr.worker_phone,
      'profession', pr.profession,
      'status', pr.status_label,
      'statusKey', pr.status_key,
      'openedAt', pr.opened_at,
      'finishedAt', pr.finished_at,
      'totalArs', pr.total_ars,
      'totalUsd', pr.total_usd,
      'expenseCount', pr.expense_count,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.opened_at desc, pr.created_at desc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;

create or replace function get_family_settlements_page(
  target_organization_id uuid,
  status_filter text default 'current',
  from_date date default null,
  to_date date default null,
  page_size integer default 50,
  page_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      greatest(1, least(coalesce(page_size, 50), 200)) as limit_value,
      greatest(0, coalesce(page_offset, 0)) as offset_value,
      coalesce(nullif(trim(coalesce(status_filter, '')), ''), 'current') as status_query
  ),
  item_totals as (
    select
      i.settlement_id,
      count(*)::integer as item_count,
      count(distinct i.unit_id)::integer as unit_count,
      count(distinct i.beneficiary_contact_id)::integer as beneficiary_count
    from family_settlement_items i
    where i.organization_id = target_organization_id
    group by i.settlement_id
  ),
  base_rows as (
    select
      s.id,
      s.period_start,
      s.period_end,
      s.version,
      s.corrects_settlement_id,
      s.is_current,
      s.status::text as status_key,
      s.total_ars,
      s.total_usd,
      s.notes,
      s.closed_at,
      coalesce(it.item_count, 0) as item_count,
      coalesce(it.unit_count, 0) as unit_count,
      coalesce(it.beneficiary_count, 0) as beneficiary_count,
      s.created_at,
      s.updated_at
    from family_settlements s
    left join item_totals it on it.settlement_id = s.id
    cross join params p
    where s.organization_id = target_organization_id
      and is_org_member(target_organization_id)
      and (from_date is null or s.period_end >= from_date)
      and (to_date is null or s.period_start <= to_date)
      and (
        p.status_query = 'all'
        or (p.status_query = 'current' and s.is_current = true and s.status = 'closed')
        or s.status::text = p.status_query
      )
  ),
  counted as (
    select count(*)::integer as total from base_rows
  ),
  page_rows as (
    select *
    from base_rows
    order by period_end desc, period_start desc, version desc
    limit (select limit_value from params)
    offset (select offset_value from params)
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'periodStart', pr.period_start,
      'periodEnd', pr.period_end,
      'version', pr.version,
      'correctsSettlementId', pr.corrects_settlement_id,
      'isCurrent', pr.is_current,
      'statusKey', pr.status_key,
      'totalArs', pr.total_ars,
      'totalUsd', pr.total_usd,
      'notes', pr.notes,
      'closedAt', pr.closed_at,
      'itemCount', pr.item_count,
      'unitCount', pr.unit_count,
      'beneficiaryCount', pr.beneficiary_count,
      'createdAt', pr.created_at,
      'updatedAt', pr.updated_at
    ) order by pr.period_end desc, pr.period_start desc, pr.version desc), '[]'::jsonb),
    'total', (select total from counted),
    'pageSize', (select limit_value from params),
    'pageOffset', (select offset_value from params)
  )
  from page_rows pr;
$$;
