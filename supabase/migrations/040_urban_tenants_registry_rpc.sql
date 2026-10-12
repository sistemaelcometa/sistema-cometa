create or replace function get_urban_tenants(target_organization_id uuid)
returns table (
  id uuid,
  name text,
  document_number text,
  phone text,
  email text,
  address text,
  notes text,
  lease_count bigint,
  active_lease_count bigint,
  current_units text,
  last_lease_end date
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id,
    nullif(
      trim(
        coalesce(c.business_name, '') || ' ' ||
        coalesce(c.first_name, '') || ' ' ||
        coalesce(c.last_name, '')
      ),
      ''
    ) as name,
    c.document_number,
    c.phone,
    c.email,
    c.address,
    c.notes,
    count(l.id) as lease_count,
    count(l.id) filter (where l.status in ('active', 'upcoming')) as active_lease_count,
    nullif(
      string_agg(
        distinct case
          when l.status in ('active', 'upcoming') then u.name || ' (' || b.name || ')'
          else null
        end,
        ', '
      ),
      ''
    ) as current_units,
    max(l.end_date) as last_lease_end
  from contacts c
  left join urban_leases l
    on l.primary_tenant_contact_id = c.id
   and l.organization_id = c.organization_id
  left join urban_units u on u.id = l.unit_id
  left join urban_buildings b on b.id = u.building_id
  where c.organization_id = target_organization_id
    and c.status = 'active'
    and (c.is_tenant or l.id is not null)
    and is_org_member(target_organization_id)
  group by c.id
  order by name nulls last;
$$;
