-- Historial independiente de la ocupacion actual: los contratos vencidos
-- siguen siendo consultables aunque el departamento ya este disponible.
begin;

create or replace function get_urban_lease_history(target_organization_id uuid)
returns table (
  id uuid,
  unit_id uuid,
  tenant_name text,
  start_date date,
  end_date date,
  amount numeric,
  currency char(3),
  adjustment_frequency_months integer,
  next_adjustment_date date,
  status text,
  notes text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    l.id, l.unit_id,
    coalesce(nullif(trim(concat_ws(' ', c.business_name, c.first_name, c.last_name)), ''), 'Sin nombre'),
    l.start_date, l.end_date, l.current_amount, l.currency,
    l.adjustment_frequency_months, l.next_adjustment_date,
    case
      when l.status = 'rescinded' then 'Rescindido'
      when l.status = 'finalized'
        or l.end_date < (now() at time zone 'America/Argentina/Buenos_Aires')::date then 'Finalizado'
      when l.start_date > (now() at time zone 'America/Argentina/Buenos_Aires')::date then 'Próximo'
      else 'Activo'
    end,
    l.notes
  from urban_leases l
  join urban_units u on u.id = l.unit_id and u.organization_id = l.organization_id
  left join contacts c on c.id = l.primary_tenant_contact_id and c.organization_id = l.organization_id
  where l.organization_id = target_organization_id
    and l.status in ('active', 'upcoming', 'finalized', 'rescinded')
    and is_org_member(target_organization_id)
  order by l.unit_id,
    case
      when l.status in ('active', 'upcoming')
        and l.end_date >= (now() at time zone 'America/Argentina/Buenos_Aires')::date
        and l.start_date <= (now() at time zone 'America/Argentina/Buenos_Aires')::date then 0
      when l.status in ('active', 'upcoming')
        and l.start_date > (now() at time zone 'America/Argentina/Buenos_Aires')::date then 1
      else 2
    end,
    l.end_date desc, l.start_date desc, l.id;
$$;

revoke all on function get_urban_lease_history(uuid) from public, anon;
grant execute on function get_urban_lease_history(uuid) to authenticated;

commit;
