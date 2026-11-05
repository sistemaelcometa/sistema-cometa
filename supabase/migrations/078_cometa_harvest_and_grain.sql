-- Cosechas y existencias fisicas, independientes de Caja.
begin;
create table if not exists cometa_fields (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references organizations(id) on delete cascade,
 name text not null check(length(trim(name)) between 1 and 120),unique(organization_id,name)
);
create table if not exists cometa_grain_stores (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references organizations(id) on delete cascade,
 location text not null check(length(trim(location)) between 1 and 120),name text not null check(length(trim(name)) between 1 and 120),
 kind text not null check(kind in ('silo','bag')),capacity numeric(14,3) check(capacity>0),unique(organization_id,location,name)
);
create table if not exists cometa_harvests (
 id uuid primary key,organization_id uuid not null references organizations(id) on delete cascade,field_id uuid not null references cometa_fields(id),
 harvest_date date not null,campaign text not null check(length(trim(campaign)) between 1 and 40),crop text not null check(length(trim(crop)) between 1 and 80),
 tonnes numeric(14,3) not null check(tonnes>0),request jsonb not null,created_at timestamptz not null default now(),created_by uuid references profiles(id)
);
create table if not exists cometa_grain_events (
 id uuid primary key default gen_random_uuid(),sequence bigint generated always as identity,operation_id uuid not null,organization_id uuid not null references organizations(id) on delete cascade,
 harvest_id uuid not null references cometa_harvests(id),event_date date not null,
 kind text not null check(kind in ('deposit','direct_sale','sale','transfer')),
 source_id uuid references cometa_grain_stores(id),destination_id uuid references cometa_grain_stores(id),
 tonnes numeric(14,3) not null check(tonnes>0),recipient text not null default '',reference text not null default '',
 request jsonb,created_at timestamptz not null default now(),created_by uuid references profiles(id),voided_at timestamptz,
 check((kind='deposit' and source_id is null and destination_id is not null) or (kind='direct_sale' and source_id is null and destination_id is null) or (kind='sale' and source_id is not null and destination_id is null) or (kind='transfer' and source_id is not null and destination_id is not null and source_id<>destination_id))
);
create index if not exists cometa_grain_events_org_idx on cometa_grain_events(organization_id,harvest_id,event_date);
do $$ declare tab text; begin
 foreach tab in array array['cometa_fields','cometa_grain_stores','cometa_harvests','cometa_grain_events'] loop
  execute format('alter table %I enable row level security',tab);
  execute format('drop policy if exists grain_read on %I',tab);
  execute format('create policy grain_read on %I for select to authenticated using(is_org_member(organization_id))',tab);
  execute format('revoke all on %I from anon,authenticated',tab);
  execute format('grant select on %I to authenticated',tab);
 end loop;
end $$;

create or replace function configure_cometa_grain(target_organization_id uuid,entry_kind text,entry_name text,entry_location text default '',entry_capacity numeric default null,target_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare saved_id uuid;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para configurar cosechas.'; end if;
 if entry_name is null or length(trim(entry_name)) not between 1 and 120 then raise exception 'Ingresa un nombre de hasta 120 caracteres.'; end if;
 if entry_kind='field' then
  if target_id is null then insert into cometa_fields(organization_id,name) values(target_organization_id,trim(entry_name)) returning id into saved_id;
  else update cometa_fields set name=trim(entry_name) where id=target_id and organization_id=target_organization_id returning id into saved_id; end if;
 elsif entry_kind in ('silo','bag') then
  if entry_location is null or length(trim(entry_location)) not between 1 and 120 or entry_capacity is not null and (entry_capacity::text in ('NaN','Infinity','-Infinity') or entry_capacity<=0 or entry_capacity<>round(entry_capacity,3) or entry_capacity>=1e11) then raise exception 'Revisa la ubicacion y la capacidad en toneladas.'; end if;
  if target_id is null then insert into cometa_grain_stores(organization_id,name,location,kind,capacity) values(target_organization_id,trim(entry_name),trim(entry_location),entry_kind,entry_capacity) returning id into saved_id;
  else update cometa_grain_stores set name=trim(entry_name),location=trim(entry_location),kind=entry_kind,capacity=entry_capacity where id=target_id and organization_id=target_organization_id returning id into saved_id; end if;
 else raise exception 'Tipo de configuracion invalido.';
 end if;
 if saved_id is null then raise exception 'El registro no pertenece a esta organizacion.'; end if;
 return saved_id;
exception when unique_violation then raise exception 'Ya existe ese nombre en esta ubicacion.';
end $$;

create or replace function register_cometa_harvest(target_organization_id uuid,operation_id uuid,entry_date date,entry_field_id uuid,entry_campaign text,entry_crop text,entry_tonnes numeric,allocations jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare payload jsonb; existing cometa_harvests; row_data jsonb; amount numeric; total numeric:=0; dest uuid; event_kind text;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para registrar cosechas.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 payload:=jsonb_build_object('date',entry_date,'field',entry_field_id,'campaign',entry_campaign,'crop',entry_crop,'tonnes',entry_tonnes,'allocations',allocations);
 select * into existing from cometa_harvests where id=operation_id;
 if found then
  if existing.organization_id<>target_organization_id or existing.request<>payload then raise exception 'La operacion ya existe con otros datos.'; end if;
  return existing.id;
 end if;
 if exists(select 1 from cometa_grain_events e where e.operation_id=register_cometa_harvest.operation_id) then raise exception 'La operacion ya existe con otros datos.'; end if;
 if operation_id is null or entry_date is null or not exists(select 1 from cometa_fields f where f.id=entry_field_id and f.organization_id=target_organization_id) then raise exception 'Revisa la fecha y el lote de origen.'; end if;
 if entry_campaign is null or length(trim(entry_campaign)) not between 1 and 40 or entry_crop is null or length(trim(entry_crop)) not between 1 and 80 then raise exception 'Completa campana y cultivo.'; end if;
 if entry_tonnes is null or entry_tonnes::text in ('NaN','Infinity','-Infinity') or entry_tonnes<=0 or entry_tonnes<>round(entry_tonnes,3) or entry_tonnes>=1e11 then raise exception 'Ingresa toneladas positivas con hasta 3 decimales.'; end if;
 if jsonb_typeof(allocations) is distinct from 'array' or jsonb_array_length(allocations) not between 1 and 100 then raise exception 'Indica al menos un destino de la cosecha.'; end if;
 insert into cometa_harvests(id,organization_id,field_id,harvest_date,campaign,crop,tonnes,request,created_by) values(operation_id,target_organization_id,entry_field_id,entry_date,trim(entry_campaign),trim(entry_crop),entry_tonnes,payload,auth.uid());
 for row_data in select value from jsonb_array_elements(allocations) loop
  amount:=(row_data->>'tonnes')::numeric;dest:=nullif(row_data->>'store_id','')::uuid;event_kind:=row_data->>'kind';
  if amount is null or amount::text in ('NaN','Infinity','-Infinity') or amount<=0 or amount<>round(amount,3) or amount>=1e11 or event_kind is null or event_kind not in ('deposit','direct_sale') then raise exception 'Revisa las toneladas y el tipo de cada destino.'; end if;
  if event_kind='deposit' and not exists(select 1 from cometa_grain_stores s where s.id=dest and s.organization_id=target_organization_id) or event_kind='direct_sale' and dest is not null then raise exception 'Destino de cosecha invalido.'; end if;
  if length(coalesce(row_data->>'recipient',''))>200 or length(coalesce(row_data->>'reference',''))>200 then raise exception 'Destino o referencia demasiado largo.'; end if;
  insert into cometa_grain_events(operation_id,organization_id,harvest_id,event_date,kind,destination_id,tonnes,recipient,reference,created_by) values(operation_id,target_organization_id,operation_id,entry_date,event_kind,dest,amount,coalesce(row_data->>'recipient',''),coalesce(row_data->>'reference',''),auth.uid());
  total:=total+amount;
 end loop;
 if total<>entry_tonnes then raise exception 'El reparto de destinos debe coincidir con las toneladas cosechadas.'; end if;
 return operation_id;
end $$;

create or replace function register_cometa_grain_exit(target_organization_id uuid,operation_id uuid,entry_harvest_id uuid,entry_date date,entry_kind text,source_store_id uuid,destination_store_id uuid,entry_tonnes numeric,entry_recipient text default '',entry_reference text default '')
returns uuid language plpgsql security definer set search_path=public as $$
declare available numeric; payload jsonb; existing cometa_grain_events; latest date;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para registrar extracciones.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 payload:=jsonb_build_object('harvest',entry_harvest_id,'date',entry_date,'kind',entry_kind,'source',source_store_id,'destination',destination_store_id,'tonnes',entry_tonnes,'recipient',entry_recipient,'reference',entry_reference);
 select * into existing from cometa_grain_events e where e.operation_id=register_cometa_grain_exit.operation_id limit 1;
 if found then
  if existing.organization_id<>target_organization_id or existing.request is distinct from payload then raise exception 'La operacion ya existe con otros datos.'; end if;
  return existing.id;
 end if;
 if operation_id is null or entry_date is null or entry_kind is null or entry_kind not in ('sale','transfer') or not exists(select 1 from cometa_harvests h where h.id=entry_harvest_id and h.organization_id=target_organization_id) then raise exception 'Revisa la cosecha, fecha y tipo de extraccion.'; end if;
 if entry_tonnes is null or entry_tonnes::text in ('NaN','Infinity','-Infinity') or entry_tonnes<=0 or entry_tonnes<>round(entry_tonnes,3) or entry_tonnes>=1e11 then raise exception 'Ingresa toneladas positivas con hasta 3 decimales.'; end if;
 if not exists(select 1 from cometa_grain_stores s where s.id=source_store_id and s.organization_id=target_organization_id) or entry_kind='transfer' and (source_store_id=destination_store_id or not exists(select 1 from cometa_grain_stores s where s.id=destination_store_id and s.organization_id=target_organization_id)) or entry_kind='sale' and destination_store_id is not null then raise exception 'Origen o destino invalido.'; end if;
 if length(coalesce(entry_recipient,''))>200 or length(coalesce(entry_reference,''))>200 then raise exception 'Destino o referencia demasiado largo.'; end if;
 select max(event_date) into latest from cometa_grain_events e where e.harvest_id=entry_harvest_id and e.voided_at is null;
 if latest is null or entry_date<latest then raise exception 'La fecha debe ser igual o posterior a la ultima operacion de esta cosecha (%).',latest; end if;
 select coalesce(sum(case when e.destination_id=source_store_id then e.tonnes else 0 end-case when e.source_id=source_store_id then e.tonnes else 0 end),0) into available from cometa_grain_events e where e.harvest_id=entry_harvest_id and e.voided_at is null;
 if entry_tonnes>available then raise exception 'La extraccion supera el saldo disponible: % toneladas.',available; end if;
 insert into cometa_grain_events(operation_id,organization_id,harvest_id,event_date,kind,source_id,destination_id,tonnes,recipient,reference,request,created_by) values(operation_id,target_organization_id,entry_harvest_id,entry_date,entry_kind,source_store_id,destination_store_id,entry_tonnes,coalesce(entry_recipient,''),coalesce(entry_reference,''),payload,auth.uid()) returning * into existing;
 return existing.id;
end $$;

create or replace function void_cometa_grain_operation(target_organization_id uuid,target_operation_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare origin_id uuid;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para anular operaciones.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 select harvest_id into origin_id from cometa_grain_events where organization_id=target_organization_id and operation_id=target_operation_id limit 1;
 if origin_id is null then raise exception 'No se encontro la operacion.'; end if;
 if not exists(select 1 from cometa_grain_events where organization_id=target_organization_id and operation_id=target_operation_id and voided_at is null) then return; end if;
 -- Se permite corregir desde la ultima operacion hacia atras, conservando historial.
 if exists(select 1 from cometa_grain_events e where e.harvest_id=origin_id and e.voided_at is null and e.operation_id<>target_operation_id and e.sequence>(select max(sequence) from cometa_grain_events where operation_id=target_operation_id)) then raise exception 'Primero anula las operaciones posteriores de esta cosecha.'; end if;
 update cometa_grain_events set voided_at=coalesce(voided_at,now()) where organization_id=target_organization_id and operation_id=target_operation_id;
end $$;

create or replace function get_cometa_grain(target_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
 if not is_org_member(target_organization_id) then raise exception 'No tenes permisos para ver estas cosechas.'; end if;
 with events as (select * from cometa_grain_events where organization_id=target_organization_id),
 balances as (
  select harvest_id,store_id,sum(delta) as tonnes from (
   select harvest_id,destination_id as store_id,tonnes as delta from events where voided_at is null and destination_id is not null
   union all select harvest_id,source_id,-tonnes from events where voided_at is null and source_id is not null
  ) x group by harvest_id,store_id having sum(delta)>0
 ) select jsonb_build_object(
  'fields',coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from cometa_fields f where f.organization_id=target_organization_id),'[]'::jsonb),
  'stores',coalesce((select jsonb_agg(to_jsonb(s) order by s.location,s.name) from cometa_grain_stores s where s.organization_id=target_organization_id),'[]'::jsonb),
  'harvests',coalesce((select jsonb_agg(to_jsonb(h)||jsonb_build_object('field_name',f.name,'voided',not exists(select 1 from events e where e.harvest_id=h.id and e.voided_at is null)) order by h.harvest_date desc,h.created_at desc) from cometa_harvests h join cometa_fields f on f.id=h.field_id where h.organization_id=target_organization_id),'[]'::jsonb),
  'balances',coalesce((select jsonb_agg(to_jsonb(b)) from balances b),'[]'::jsonb),
  'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.event_date desc,e.sequence desc) from events e),'[]'::jsonb)
 ) into result;
 return result;
end $$;

-- Silos iniciales de referencia; sin capacidad inventada. Nombres editables.
insert into cometa_grain_stores(organization_id,location,name,kind)
select o.id,s.location,'Silo '||s.num,'silo' from organizations o cross join (values ('Casa',1),('Casa',2),('Casa',3),('Fenoglio',1),('Fenoglio',2),('Freyre',1),('Freyre',2)) s(location,num)
where not exists(select 1 from cometa_grain_stores existing where existing.organization_id=o.id)
on conflict(organization_id,location,name) do nothing;

revoke all on function configure_cometa_grain(uuid,text,text,text,numeric,uuid),register_cometa_harvest(uuid,uuid,date,uuid,text,text,numeric,jsonb),register_cometa_grain_exit(uuid,uuid,uuid,date,text,uuid,uuid,numeric,text,text),void_cometa_grain_operation(uuid,uuid),get_cometa_grain(uuid) from public,anon;
grant execute on function configure_cometa_grain(uuid,text,text,text,numeric,uuid),register_cometa_harvest(uuid,uuid,date,uuid,text,text,numeric,jsonb),register_cometa_grain_exit(uuid,uuid,uuid,date,text,uuid,uuid,numeric,text,text),void_cometa_grain_operation(uuid,uuid),get_cometa_grain(uuid) to authenticated;
commit;
