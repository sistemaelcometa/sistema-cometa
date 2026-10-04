-- RPC minima para iniciar el flujo de acceso antes de tener membresia.

create or replace function get_default_organization()
returns table (
  id uuid,
  name text,
  slug text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    organizations.id,
    organizations.name,
    organizations.slug
  from organizations
  where organizations.slug = 'el-cometa'
  limit 1;
$$;
