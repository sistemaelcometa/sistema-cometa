-- Ajustes siempre el dia 1 del MISMO mes, sin cambiar inicio, fin o importe.
-- Corrige las fechas pendientes de contratos activos/futuros y normaliza
-- cualquier fecha nueva enviada desde formularios o RPCs.
begin;

create or replace function normalize_urban_lease_adjustment_day()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.next_adjustment_date is not null then
    new.next_adjustment_date := date_trunc('month', new.next_adjustment_date)::date;
  end if;
  return new;
end;
$$;

drop trigger if exists urban_lease_adjustment_day_first on urban_leases;
create trigger urban_lease_adjustment_day_first
before insert or update of next_adjustment_date on urban_leases
for each row execute function normalize_urban_lease_adjustment_day();

with pending as materialized (
  select l.id, l.organization_id, l.next_adjustment_date as previous_date
  from urban_leases l
  where l.status in ('active', 'upcoming')
    and l.next_adjustment_date is not null
    and extract(day from l.next_adjustment_date) <> 1
), corrected as (
  update urban_leases l
  set next_adjustment_date = date_trunc('month', p.previous_date)::date
  from pending p
  where l.id = p.id
  returning l.id, l.organization_id, p.previous_date, l.next_adjustment_date
)
insert into audit_logs(organization_id, actor_user_id, action, entity_type, entity_id, old_values, new_values)
select organization_id, auth.uid(), 'urban_lease_adjustment_day_normalized', 'urban_lease', id,
  jsonb_build_object('next_adjustment_date', previous_date),
  jsonb_build_object('next_adjustment_date', next_adjustment_date)
from corrected;

commit;
