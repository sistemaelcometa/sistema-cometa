-- Cada bolsa fisica tiene un numero permanente, aunque se repita su nombre.
begin;
alter table cometa_grain_stores add column if not exists bag_number bigint;
alter table cometa_grain_stores drop constraint if exists cometa_grain_stores_organization_id_location_name_key;
create unique index if not exists cometa_fixed_store_name_key on cometa_grain_stores(organization_id,location,name) where kind='silo';

-- Numerar bolsas existentes sin cambiar sus UUID, existencias ni movimientos.
with unnumbered as (
 select s.id,s.organization_id,row_number() over(partition by s.organization_id order by min(e.created_at) nulls last,s.id) as position
 from cometa_grain_stores s left join cometa_grain_events e on e.source_id=s.id or e.destination_id=s.id
 where s.kind='bag' and s.bag_number is null group by s.id,s.organization_id
), offsets as (
 select organization_id,coalesce(max(bag_number),0) as last_number from cometa_grain_stores group by organization_id
)
update cometa_grain_stores s set bag_number=u.position+o.last_number from unnumbered u join offsets o using(organization_id) where s.id=u.id;

create table if not exists cometa_bag_counters (
 organization_id uuid primary key references organizations(id) on delete cascade,
 last_number bigint not null check(last_number>0)
);
alter table cometa_bag_counters enable row level security;
revoke all on cometa_bag_counters from public,anon,authenticated;
insert into cometa_bag_counters(organization_id,last_number)
select organization_id,max(bag_number) from cometa_grain_stores where kind='bag' group by organization_id
on conflict(organization_id) do update set last_number=greatest(cometa_bag_counters.last_number,excluded.last_number);
create unique index if not exists cometa_bag_number_key on cometa_grain_stores(organization_id,bag_number) where bag_number is not null;
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='cometa_grain_stores'::regclass and conname='cometa_store_bag_number_check') then
  alter table cometa_grain_stores add constraint cometa_store_bag_number_check check((kind='bag' and bag_number is not null and bag_number>0) or (kind='silo' and bag_number is null));
 end if;
end $$;

create or replace function assign_cometa_bag_number()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='UPDATE' then
  if new.organization_id is distinct from old.organization_id or new.kind is distinct from old.kind or new.bag_number is distinct from old.bag_number then
   raise exception 'El tipo y numero interno del almacenamiento no se pueden cambiar. Crea un registro nuevo.';
  end if;
 elsif new.kind='bag' then
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text,78));
  insert into cometa_bag_counters(organization_id,last_number) values(new.organization_id,1)
  on conflict(organization_id) do update set last_number=cometa_bag_counters.last_number+1 returning last_number into new.bag_number;
 else new.bag_number:=null;
 end if;
 return new;
end $$;
drop trigger if exists cometa_bag_number on cometa_grain_stores;
create trigger cometa_bag_number before insert or update on cometa_grain_stores for each row execute function assign_cometa_bag_number();
revoke all on function assign_cometa_bag_number() from public,anon,authenticated;

-- Devuelve tambien el numero al crear una bolsa desde la cosecha.
-- La identidad de creacion permite reintentar sin crear otra bolsa fisica.
create or replace function save_cometa_grain_store(
 target_organization_id uuid,entry_kind text,entry_name text,entry_location text,
 entry_capacity numeric default null,target_id uuid default null,operation_id uuid default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare saved cometa_grain_stores;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para configurar almacenamientos.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 if entry_kind is null or entry_kind not in ('silo','bag') or entry_name is null or length(trim(entry_name)) not between 1 and 120 or entry_location is null or length(trim(entry_location)) not between 1 and 120 then raise exception 'Revisa el tipo, nombre y ubicacion del almacenamiento.'; end if;
 if entry_capacity is not null and (entry_capacity::text in ('NaN','Infinity','-Infinity') or entry_capacity<=0 or entry_capacity<>round(entry_capacity,3) or entry_capacity>=1e11) then raise exception 'Revisa la capacidad en toneladas.'; end if;
 if entry_kind='bag' then entry_capacity:=null; end if;
 if target_id is null then
  if operation_id is null then raise exception 'Falta la identidad de creacion del almacenamiento.'; end if;
  select * into saved from cometa_grain_stores s where s.id=operation_id;
  if found then
   if saved.organization_id<>target_organization_id or saved.kind<>entry_kind or saved.name<>trim(entry_name) or saved.location<>trim(entry_location) or saved.capacity is distinct from entry_capacity then raise exception 'La operacion ya existe con otros datos.'; end if;
   return to_jsonb(saved);
  end if;
  insert into cometa_grain_stores(id,organization_id,name,location,kind,capacity)
  values(operation_id,target_organization_id,trim(entry_name),trim(entry_location),entry_kind,entry_capacity) returning * into saved;
 else
  update cometa_grain_stores set name=trim(entry_name),location=trim(entry_location),kind=entry_kind,capacity=entry_capacity
  where id=target_id and organization_id=target_organization_id returning * into saved;
  if not found then raise exception 'El almacenamiento no pertenece a esta organizacion.'; end if;
 end if;
 return to_jsonb(saved);
exception when unique_violation then raise exception 'Ya existe un silo fijo con ese nombre en esta ubicacion.';
end $$;
revoke all on function save_cometa_grain_store(uuid,text,text,text,numeric,uuid,uuid) from public,anon;
grant execute on function save_cometa_grain_store(uuid,text,text,text,numeric,uuid,uuid) to authenticated;
commit;
