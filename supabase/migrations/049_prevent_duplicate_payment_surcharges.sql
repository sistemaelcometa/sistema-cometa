-- Evita que registrar un cobro cree expensas manuales o recargos duplicados y
-- deje siempre un saldo pendiente.

drop table if exists pg_temp.tmp_urban_charge_status_recalc;
create temporary table tmp_urban_charge_status_recalc (
  charge_id uuid primary key
) on commit drop;

drop table if exists pg_temp.tmp_urban_manual_expense_duplicates;
create temporary table tmp_urban_manual_expense_duplicates
on commit drop
as
select manual_item.id, manual_item.charge_id
from urban_charge_items manual_item
where manual_item.item_type = 'building_expense'
  and manual_item.source_entity_type = 'manual_payment_breakdown'
  and exists (
    select 1
    from urban_charge_items real_item
    where real_item.charge_id = manual_item.charge_id
      and real_item.id <> manual_item.id
      and real_item.item_type in ('building_expense', 'unit_expense')
      and coalesce(real_item.source_entity_type, '') <> 'manual_payment_breakdown'
  )
  and not exists (
    select 1
    from urban_payment_allocations a
    where a.charge_item_id = manual_item.id
  );

insert into tmp_urban_charge_status_recalc (charge_id)
select charge_id
from tmp_urban_manual_expense_duplicates
on conflict do nothing;

delete from urban_charge_items i
using tmp_urban_manual_expense_duplicates d
where i.id = d.id;

drop table if exists pg_temp.tmp_urban_surcharge_groups;

create temporary table tmp_urban_surcharge_groups
on commit drop
as
select
  charge_id,
  item_type,
  source_entity_type,
  (array_agg(id order by created_at asc, id asc))[1] as keeper_id,
  max(amount_due) as max_amount_due
from urban_charge_items
where item_type in ('rent_surcharge', 'expense_surcharge')
  and source_entity_type = 'payment_surcharge'
group by charge_id, item_type, source_entity_type
having count(*) > 1;

insert into tmp_urban_charge_status_recalc (charge_id)
select charge_id
from tmp_urban_surcharge_groups
on conflict do nothing;

update urban_charge_items i
set amount_due = greatest(g.max_amount_due, coalesce(a.allocated_amount, 0))
from tmp_urban_surcharge_groups g
left join (
  select
    g.keeper_id,
    coalesce(sum(a.allocated_amount), 0) as allocated_amount
  from tmp_urban_surcharge_groups g
  join urban_charge_items i
    on i.charge_id = g.charge_id
   and i.item_type = g.item_type
   and i.source_entity_type = g.source_entity_type
  left join urban_payment_allocations a on a.charge_item_id = i.id
  group by g.keeper_id
) a on a.keeper_id = g.keeper_id
where i.id = g.keeper_id;

update urban_payment_allocations a
set charge_item_id = g.keeper_id
from tmp_urban_surcharge_groups g
join urban_charge_items i
  on i.charge_id = g.charge_id
 and i.item_type = g.item_type
 and i.source_entity_type = g.source_entity_type
where a.charge_item_id = i.id
  and i.id <> g.keeper_id;

delete from urban_charge_items i
using tmp_urban_surcharge_groups g
where i.charge_id = g.charge_id
  and i.item_type = g.item_type
  and i.source_entity_type = g.source_entity_type
  and i.id <> g.keeper_id
  and not exists (
    select 1
    from urban_payment_allocations a
    where a.charge_item_id = i.id
  );

with charge_due_totals as (
  select
    i.charge_id,
    coalesce(sum(i.amount_due), 0) as total_due
  from urban_charge_items i
  join tmp_urban_charge_status_recalc ac on ac.charge_id = i.charge_id
  group by i.charge_id
),
charge_paid_totals as (
  select
    i.charge_id,
    coalesce(sum(a.allocated_amount), 0) as total_paid
  from urban_charge_items i
  join tmp_urban_charge_status_recalc ac on ac.charge_id = i.charge_id
  join urban_payment_allocations a on a.charge_item_id = i.id
  join urban_payments p on p.id = a.payment_id
  where p.status = 'valid'
  group by i.charge_id
),
charge_totals as (
  select
    ch.id,
    coalesce(d.total_due, 0) as total_due,
    coalesce(p.total_paid, 0) as total_paid
  from urban_charges ch
  join tmp_urban_charge_status_recalc ac on ac.charge_id = ch.id
  left join charge_due_totals d on d.charge_id = ch.id
  left join charge_paid_totals p on p.charge_id = ch.id
)
update urban_charges ch
set status = case
    when ct.total_paid >= ct.total_due and ct.total_due > 0 then 'paid'::charge_status
    when ct.total_paid > 0 then 'partial'::charge_status
    else 'pending'::charge_status
  end
from charge_totals ct
where ch.id = ct.id;

drop table if exists pg_temp.tmp_urban_surcharge_groups;
drop table if exists pg_temp.tmp_urban_manual_expense_duplicates;
drop table if exists pg_temp.tmp_urban_charge_status_recalc;

create or replace function prevent_duplicate_manual_expense_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.item_type = 'building_expense'
     and new.source_entity_type = 'manual_payment_breakdown'
     and exists (
       select 1
       from urban_charge_items i
       where i.charge_id = new.charge_id
         and i.item_type in ('building_expense', 'unit_expense')
         and coalesce(i.source_entity_type, '') <> 'manual_payment_breakdown'
     ) then
    return null;
  end if;

  return new;
end;
$$;

drop trigger if exists prevent_duplicate_manual_expense_item_before_insert on urban_charge_items;

create trigger prevent_duplicate_manual_expense_item_before_insert
before insert on urban_charge_items
for each row
execute function prevent_duplicate_manual_expense_item();

create or replace function merge_urban_payment_surcharge_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_item_id uuid;
begin
  if new.item_type in ('rent_surcharge', 'expense_surcharge')
     and new.source_entity_type = 'payment_surcharge' then
    select i.id
      into existing_item_id
    from urban_charge_items i
    where i.charge_id = new.charge_id
      and i.item_type = new.item_type
      and i.source_entity_type = new.source_entity_type
    order by i.created_at asc, i.id asc
    limit 1
    for update;

    if existing_item_id is not null then
      update urban_charge_items
      set
        amount_due = greatest(amount_due, new.amount_due),
        description = coalesce(nullif(new.description, ''), description),
        currency = new.currency
      where id = existing_item_id;

      return null;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists merge_urban_payment_surcharge_item_before_insert on urban_charge_items;

create trigger merge_urban_payment_surcharge_item_before_insert
before insert on urban_charge_items
for each row
execute function merge_urban_payment_surcharge_item();
