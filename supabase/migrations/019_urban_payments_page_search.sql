-- Amplia la busqueda paginada de cobros urbanos.
-- El parametro tenant_search queda como busqueda general para no romper clientes existentes.

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
      nullif(trim(coalesce(tenant_search, '')), '') as search_query
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
      and (
        x.search_query is null
        or immutable_unaccent(concat_ws(
          ' ',
          nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''),
          u.name,
          b.name,
          payment_method_label(p.payment_method),
          receipt.original_filename,
          p.notes
        )) ilike '%' || immutable_unaccent(x.search_query) || '%'
      )
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
