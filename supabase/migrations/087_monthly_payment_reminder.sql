-- Recordatorio mensual de Santiago. No registra movimientos financieros.
begin;
create table if not exists monthly_payment_reminder_states (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references organizations(id) on delete cascade,
 reminder_key text not null default 'santiago' check(reminder_key='santiago'),
 period_month date not null check(extract(day from period_month)=1),
 snoozed_until date,
 paid_at timestamptz,
 paid_by uuid references profiles(id),
 updated_at timestamptz not null default now(),
 unique(organization_id,reminder_key,period_month)
);
alter table monthly_payment_reminder_states enable row level security;
drop policy if exists monthly_reminder_read on monthly_payment_reminder_states;
create policy monthly_reminder_read on monthly_payment_reminder_states for select to authenticated using(is_org_member(organization_id));
revoke all on monthly_payment_reminder_states from public,anon,authenticated;
grant select on monthly_payment_reminder_states to authenticated;

create or replace function monthly_reminder_argentina_today()
returns date language sql stable set search_path=public as $$
 select (now() at time zone 'America/Argentina/Buenos_Aires')::date;
$$;
revoke all on function monthly_reminder_argentina_today() from public,anon,authenticated;

create or replace function get_monthly_payment_reminder(target_organization_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare today date:=monthly_reminder_argentina_today(); month_start date:=date_trunc('month',today)::date; saved monthly_payment_reminder_states;
begin
 if not is_org_member(target_organization_id) then raise exception 'No tenes permisos para ver el recordatorio.'; end if;
 select * into saved from monthly_payment_reminder_states s where s.organization_id=target_organization_id and s.reminder_key='santiago' and s.period_month=month_start;
 return jsonb_build_object('reminder_key','santiago','title','Pagar Santiago','today',today,'period_month',month_start,'due_date',month_start+4,
  'snoozed_until',saved.snoozed_until,'paid_at',saved.paid_at,
  'visible',today>=month_start+4 and saved.paid_at is null and (saved.snoozed_until is null or today>=saved.snoozed_until));
end $$;

create or replace function update_monthly_payment_reminder(target_organization_id uuid,target_period_month date,reminder_action text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare today date:=monthly_reminder_argentina_today(); month_start date:=date_trunc('month',today)::date; saved monthly_payment_reminder_states; previous monthly_payment_reminder_states;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para actualizar el recordatorio.'; end if;
 if target_period_month is distinct from month_start then raise exception 'El mes del recordatorio cambio. Actualiza el aviso antes de continuar.'; end if;
 if today<month_start+4 then raise exception 'El recordatorio empieza el dia 5 de cada mes.'; end if;
 if reminder_action is null or reminder_action not in ('snooze','paid') then raise exception 'Elegi posponer o marcar como pagado.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,87));
 insert into monthly_payment_reminder_states(organization_id,period_month) values(target_organization_id,month_start) on conflict(organization_id,reminder_key,period_month) do nothing;
 select * into previous from monthly_payment_reminder_states s where s.organization_id=target_organization_id and s.reminder_key='santiago' and s.period_month=month_start for update;
 -- Pagado prevalece sobre una pantalla vieja que intente posponerlo.
 if previous.paid_at is not null or reminder_action='snooze' and previous.snoozed_until=today+1 then return get_monthly_payment_reminder(target_organization_id); end if;
 update monthly_payment_reminder_states set
  snoozed_until=case when reminder_action='snooze' then today+1 else null end,
  paid_at=case when reminder_action='paid' then now() else paid_at end,
  paid_by=case when reminder_action='paid' then auth.uid() else paid_by end,
  updated_at=now()
 where id=previous.id returning * into saved;
 insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,old_values,new_values)
 values(target_organization_id,auth.uid(),case when reminder_action='paid' then 'monthly_reminder_paid' else 'monthly_reminder_snoozed' end,'monthly_payment_reminder',saved.id,to_jsonb(previous),to_jsonb(saved));
 return get_monthly_payment_reminder(target_organization_id);
end $$;
revoke all on function get_monthly_payment_reminder(uuid),update_monthly_payment_reminder(uuid,date,text) from public,anon;
grant execute on function get_monthly_payment_reminder(uuid),update_monthly_payment_reminder(uuid,date,text) to authenticated;

-- Actualizar otras sesiones al marcar como pagado o posponer.
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='monthly_payment_reminder_states') then
  alter publication supabase_realtime add table monthly_payment_reminder_states;
 end if;
end $$;
commit;
