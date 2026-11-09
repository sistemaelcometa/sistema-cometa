-- Lotes administrables y clasificacion fina/gruesa sin modificar cosechas previas.
begin;
alter table cometa_fields add column if not exists deleted_at timestamptz;
alter table cometa_fields drop constraint if exists cometa_fields_organization_id_name_key;
create unique index if not exists cometa_fields_active_name_key on cometa_fields(organization_id,name) where deleted_at is null;
alter table cometa_harvests add column if not exists season text check(season in ('fina','gruesa'));

create or replace function delete_cometa_field(target_organization_id uuid,target_field_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para eliminar lotes.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 update cometa_fields set deleted_at=coalesce(deleted_at,now()) where id=target_field_id and organization_id=target_organization_id;
 if not found then raise exception 'El lote no pertenece a esta organizacion.'; end if;
end $$;

-- Tambien protege los registros enviados desde una version anterior de la app.
create or replace function check_cometa_harvest_field()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform 1 from cometa_fields where id=new.field_id and organization_id=new.organization_id and deleted_at is null for share;
 if not found then raise exception 'El lote fue eliminado o no pertenece a esta organizacion.'; end if;
 return new;
end $$;
drop trigger if exists cometa_harvest_field_guard on cometa_harvests;
create trigger cometa_harvest_field_guard before insert on cometa_harvests for each row execute function check_cometa_harvest_field();

create or replace function register_cometa_harvest_with_season(target_organization_id uuid,operation_id uuid,entry_date date,entry_field_id uuid,entry_campaign text,entry_crop text,entry_tonnes numeric,allocations jsonb,entry_season text)
returns uuid language plpgsql security definer set search_path=public as $$
declare existing cometa_harvests; saved_id uuid;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para registrar cosechas.'; end if;
 if entry_season is null or entry_season not in ('fina','gruesa') then raise exception 'Selecciona si la cosecha es fina o gruesa.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 select * into existing from cometa_harvests where id=operation_id;
 if found and (existing.organization_id<>target_organization_id or existing.season is distinct from entry_season) then raise exception 'La operacion ya existe con otros datos.'; end if;
 saved_id:=register_cometa_harvest(target_organization_id,operation_id,entry_date,entry_field_id,entry_campaign,entry_crop,entry_tonnes,allocations);
 update cometa_harvests set season=entry_season where id=saved_id and organization_id=target_organization_id;
 return saved_id;
end $$;

revoke all on function delete_cometa_field(uuid,uuid),register_cometa_harvest_with_season(uuid,uuid,date,uuid,text,text,numeric,jsonb,text),check_cometa_harvest_field() from public,anon;
grant execute on function delete_cometa_field(uuid,uuid),register_cometa_harvest_with_season(uuid,uuid,date,uuid,text,text,numeric,jsonb,text) to authenticated;
commit;
