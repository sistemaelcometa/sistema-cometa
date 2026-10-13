-- Ver organizaciones disponibles.
-- Si hay una sola, los otros SQL usan esa por defecto.

select
  id,
  name,
  slug,
  created_at
from organizations
order by created_at;
