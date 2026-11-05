-- Lectura historica por contrato. No modifica importes, cargos ni pagos.
begin;
create or replace function get_urban_lease_amount_history(target_organization_id uuid,target_unit_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
with leases as (
 select l.*,coalesce(nullif(trim(concat_ws(' ',c.business_name,c.first_name,c.last_name)),''),'Sin nombre') as tenant_name
 from urban_leases l
 join urban_units u on u.id=l.unit_id and u.organization_id=l.organization_id
 left join contacts c on c.id=l.primary_tenant_contact_id and c.organization_id=l.organization_id
 where l.organization_id=target_organization_id and l.unit_id=target_unit_id
  and l.status in ('active','upcoming','finalized','rescinded') and is_org_member(target_organization_id)
), changes as (
 select a.*,lag(a.currency) over(partition by a.lease_id order by a.effective_date,a.created_at,a.id) as prior_currency,
  old_currency.currency as audited_previous_currency
 from urban_lease_adjustments a join leases l on l.id=a.lease_id and l.organization_id=a.organization_id
 left join lateral (
  select al.old_values->>'currency' as currency from audit_logs al
  where al.organization_id=a.organization_id and al.entity_type='urban_lease' and al.entity_id=a.lease_id
   and al.action='urban_lease_updated' and al.occurred_at=a.created_at
   and al.old_values->'current_amount'=to_jsonb(a.previous_amount)
   and al.new_values->'current_amount'=to_jsonb(a.new_amount)
   and al.old_values->>'currency' in ('ARS','USD')
  order by al.occurred_at,al.id limit 1
 ) old_currency on true
), bases as (
 select l.*,
  coalesce(creation.amount,first_change.previous_amount,l.current_amount) as initial_amount,
  case when creation.amount is not null then creation.currency
       when first_change.id is not null then coalesce(first_change.audited_previous_currency,first_change.prior_currency)
       else l.currency end as initial_currency,
  case when creation.amount is not null then 'creation_record'
       when first_change.id is not null then 'first_adjustment' else 'current_value' end as initial_source
 from leases l
 left join lateral (
  select (al.new_values->'lease'->>'current_amount')::numeric as amount,
    al.new_values->'lease'->>'currency' as currency
  from audit_logs al
  where al.organization_id=l.organization_id and al.entity_type='urban_lease' and al.entity_id=l.id
   and al.action='urban_lease_started'
   and jsonb_typeof(al.new_values->'lease'->'current_amount')='number'
   and al.new_values->'lease'->>'currency' in ('ARS','USD')
  order by al.occurred_at,al.id limit 1
 ) creation on true
 left join lateral (
  select * from changes a where a.lease_id=l.id order by a.effective_date,a.created_at,a.id limit 1
 ) first_change on true
), histories as (
 select l.*,
 jsonb_build_array(jsonb_build_object('id','initial-'||l.id::text,'kind','initial','date',l.start_date,
  'amount',l.initial_amount,'currency',l.initial_currency,'previousAmount',null,'previousCurrency',null))
 ||coalesce((
  select jsonb_agg(jsonb_build_object('id',a.id,'kind','adjustment','date',a.effective_date,'registeredAt',a.created_at,
   'amount',a.new_amount,'currency',a.currency,'previousAmount',a.previous_amount,
   'previousCurrency',coalesce(a.audited_previous_currency,a.prior_currency,l.initial_currency))
   order by a.effective_date,a.created_at,a.id)
  from changes a where a.lease_id=l.id
 ),'[]'::jsonb) as entries
 from bases l
)
select coalesce(jsonb_agg(jsonb_build_object(
 'id',h.id,'tenant',h.tenant_name,'start',h.start_date,'end',h.end_date,
 'currentAmount',h.current_amount,'currentCurrency',h.currency,'initialSource',h.initial_source,'entries',h.entries,
 'status',case when h.status='rescinded' then 'Rescindido'
   when h.status='finalized' or h.end_date<(now() at time zone 'America/Argentina/Buenos_Aires')::date then 'Finalizado'
   when h.start_date>(now() at time zone 'America/Argentina/Buenos_Aires')::date then 'Próximo' else 'Activo' end
) order by h.start_date desc,h.id),'[]'::jsonb) from histories h;
$$;
revoke all on function get_urban_lease_amount_history(uuid,uuid) from public,anon;
grant execute on function get_urban_lease_amount_history(uuid,uuid) to authenticated;
commit;
