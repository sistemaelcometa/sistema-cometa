-- Archivar inquilinos/contactos por ID para que no aparezcan mas.
-- Primero pega los IDs descomentando lineas "union all".
-- Ejecuta la VISTA PREVIA. Si esta bien, descomenta el UPDATE.

with selected_ids(id) as (
  select null::uuid where false
  -- union all select 'PEGAR_CONTACT_ID_1'::uuid
  -- union all select 'PEGAR_CONTACT_ID_2'::uuid
)
select
  c.id,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
  c.status::text as estado_actual,
  c.is_tenant,
  c.is_guest,
  c.is_provider,
  c.is_worker,
  c.is_family_beneficiary
from contacts c
join selected_ids x on x.id = c.id
order by nombre;

-- Ejecutar para archivar
-- with selected_ids(id) as (
--   select null::uuid where false
--   union all select 'PEGAR_CONTACT_ID_1'::uuid
-- )
-- update contacts c
-- set status = 'archived',
--     updated_at = now(),
--     version = version + 1
-- from selected_ids x
-- where c.id = x.id
--   and c.status = 'active'
-- returning c.id,
--   nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as nombre,
--   c.status::text as estado_nuevo;
