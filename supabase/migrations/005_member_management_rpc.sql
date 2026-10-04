-- RPC para administrar accesos desde el sistema.

create or replace function get_organization_members(target_organization_id uuid)
returns table (
  member_id uuid,
  user_id uuid,
  email text,
  display_name text,
  role app_role,
  member_status member_status,
  requested_at timestamptz,
  enabled_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    om.id as member_id,
    om.user_id,
    p.email,
    p.display_name,
    om.role,
    om.status as member_status,
    om.created_at as requested_at,
    om.enabled_at
  from organization_members om
  join profiles p on p.id = om.user_id
  where om.organization_id = target_organization_id
    and has_org_role(
      target_organization_id,
      array['owner', 'admin']::app_role[]
    )
  order by
    case om.status
      when 'pending' then 1
      when 'active' then 2
      else 3
    end,
    p.email;
$$;
