import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const root=new URL('../',import.meta.url),read=path=>readFile(new URL(path,root),'utf8');
function fn(text,name){const start=text.indexOf(`create or replace function ${name}(`);assert.ok(start>=0,name);return text.slice(start,text.indexOf('$$;',text.indexOf('as $$',start))+3)}

test('PDE miscellaneous incomes have independent persistence, report totals, receipts, access controls and safe cancellation',async t=>{
  const db=new PGlite(),org=randomUUID(),otherOrg=randomUUID(),actor=randomUUID();
  const query=async(text,args=[])=>(await db.query(text,args)).rows;
  const mutation=async({organization=org,amount=1500.25,unit=null,description='Reintegro de servicios',operation=randomUUID(),date='2026-10-29'}={})=>(await query("select * from register_pde_misc_income($1,$2,$3,$4,$5,'transfer',$6)",[organization,date,amount,description,unit,operation]))[0];
  const report=async(args=[]) => (await query("select get_pde_report($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) as report",[org,...[null,null,'Todos',null,null,null,null,50,0].map((value,i)=>args[i]===undefined?value:args[i])]))[0].report;
  const migration=await read('supabase/migrations/068_pde_misc_incomes.sql');
  let first,second;
  try{
    const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
    await db.exec(`create role anon;create role authenticated;
      create schema auth;create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor_id',true),'')::uuid;$$;
      grant usage on schema auth to authenticated;
      create schema storage;
      create function storage.foldername(text) returns text[] language sql immutable as $$select string_to_array($1,'/');$$;`);
    await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
    await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
    for(const name of ['has_org_role','is_org_member'])await db.exec(fn(schema,name));
    const pde=await read('supabase/migrations/012_pde_reservations_rpcs.sql');
    await db.exec(fn(pde,'ensure_pde_unit'));
    await db.exec(fn(await read('supabase/migrations/003_storage_and_access_rpcs.sql'),'storage_object_organization_id'));
    await db.exec(fn(await read('supabase/migrations/017_report_read_rpcs.sql'),'payment_method_label'));
    await query("select set_config('test.actor_id',$1,false)",[actor]);
    await query('insert into auth.users values($1)',[actor]);
    await query("insert into profiles(id,email) values($1,'test@localhost')",[actor]);
    await query("insert into organizations(id,name,slug) values($1,'Prueba','prueba'),($2,'Otra','otra')",[org,otherOrg]);
    await query("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
    await db.exec(migration);await db.exec(migration);

    await t.test('general and unit incomes retain cents, are counted once and never create a reservation',async()=>{
      const operation=randomUUID();
      first=await mutation({operation});
      assert.equal(Number(first.amount),1500.25);assert.equal(first.unit_id,null);
      assert.equal((await mutation({operation})).id,first.id);
      await assert.rejects(mutation({operation,amount:1500.26}),/operation_id ya fue usado/);
      second=await mutation({amount:0.01,unit:'601'});
      assert.ok(second.unit_id);
      for(const table of ['pde_reservations','pde_reservation_payments','pde_expenses'])assert.equal((await query(`select count(*)::int as n from ${table}`))[0].n,0);
      const data=(await query('select get_pde_data($1) as data',[org]))[0].data;
      assert.equal(data.miscIncomes.length,2);assert.equal(data.miscIncomes.find(item=>item.id===first.id).unit,'General');
      const totals=await report();assert.equal(totals.totals.USD.incomes,1500.26);assert.equal(totals.chart.USD.rentIncome,0);assert.equal(totals.chart.USD.miscIncome,1500.26);
      assert.ok(totals.movements.every(item=>item.concept==='Ingresos varios'&&item.sourceType==='pde_misc_income'));
    });

    await t.test('invalid money, missing concepts, viewers and other organizations cannot write',async()=>{
      for(const amount of [0,-1,0.001,1000000000000])await assert.rejects(mutation({amount}),/importe/);
      await assert.rejects(mutation({description:'  '}),/concepto/);
      await assert.rejects(mutation({organization:otherOrg}),/permisos/);
      await query("update organization_members set role='viewer'");
      await assert.rejects(mutation(),/permisos/);
      await assert.rejects(query('select void_pde_misc_income($1,$2)',[org,first.id]),/permisos/);
      await query("update organization_members set role='owner'");
      await query("select set_config('test.actor_id','',false)");
      await assert.rejects(mutation(),/autenticado/);
      await query("select set_config('test.actor_id',$1,false)",[actor]);
    });

    await t.test('existing rent and expense movements keep their own categories and exact totals',async()=>{
      await db.exec('begin');
      try{
        const [unit]=await query("select * from ensure_pde_unit($1,'209')",[org]),reservation=randomUUID(),expense=randomUUID();
        await query("insert into pde_reservations(id,organization_id,unit_id,guest_name_snapshot,start_date,end_date,total_amount,status) values($1,$2,$3,'Huesped','2026-10-29','2026-10-31',100,'paid')",[reservation,org,unit.id]);
        await query("insert into pde_reservation_payments(organization_id,reservation_id,payment_type,payment_date,amount,payment_method) values($1,$2,'balance','2026-10-29',100,'transfer')",[org,reservation]);
        await query("insert into pde_expenses(id,organization_id,unit_id,expense_date,description,amount) values($1,$2,$3,'2026-10-29','Limpieza',20.01)",[expense,org,unit.id]);
        await query("insert into pde_expense_allocations(organization_id,expense_id,unit_id,percentage_snapshot,allocated_amount,currency) values($1,$2,$3,100,20.01,'USD')",[org,expense,unit.id]);
        const result=await report();
        assert.equal(result.chart.USD.rentIncome,100);assert.equal(result.chart.USD.miscIncome,1500.26);
        assert.equal(result.totals.USD.incomes,1600.26);assert.equal(result.totals.USD.expenses,20.01);assert.equal(result.totals.USD.margin,1580.25);
        assert.equal(result.movements.length,4);
      }finally{await db.exec('rollback')}
    });

    await t.test('report filters and pagination include miscellaneous incomes without changing rent totals',async()=>{
      assert.equal((await report(['2026-11-01',null])).totalCount,0);
      assert.equal((await report([null,null,'Egreso'])).totalCount,0);
      assert.equal((await report([null,null,'Ingreso',null,'601'])).totalCount,1);
      assert.equal((await report([null,null,'Ingreso',null,'General'])).totals.USD.incomes,1500.25);
      assert.equal((await report([null,null,'Todos',null,null,11])).totalCount,0);
      const page=await report([null,null,'Todos',null,null,null,null,1,1]);
      assert.equal(page.movements.length,1);assert.equal(page.totalCount,2);assert.equal(page.totals.USD.incomes,1500.26);
    });

    await t.test('receipts link only to an authorized valid income and are readable from both data and reports',async()=>{
      const path=`org/${org}/receipts/pde_misc_income/${first.id}/comprobante.pdf`;
      await query("select register_uploaded_file_link($1,'receipts',$2,'comprobante.pdf','application/pdf',10,'pde_misc_income',$3,'Comprobante',$4)",[org,path,first.id,randomUUID()]);
      const data=(await query('select get_pde_data($1) as data',[org]))[0].data;
      assert.equal(data.miscIncomes.find(item=>item.id===first.id).receiptName,'comprobante.pdf');
      assert.equal((await report()).movements.find(item=>item.sourceId===first.id).receiptName,'comprobante.pdf');
      await assert.rejects(query("select register_uploaded_file_link($1,'receipts',$2,'other.pdf','application/pdf',10,'pde_misc_income',$3,'Comprobante',$4)",[otherOrg,`org/${otherOrg}/receipts/a.pdf`,first.id,randomUUID()]),/permisos/);
    });

    await t.test('RLS permits member reads, hides other organizations and denies direct writes',async()=>{
      await db.exec('set role authenticated');
      assert.equal((await query('select count(*)::int as n from pde_misc_incomes'))[0].n,2);
      await assert.rejects(query("update pde_misc_incomes set amount=1 where id=$1",[first.id]),/permission denied/);
      await db.exec('reset role');
      await query("update organization_members set organization_id=$1",[otherOrg]);
      await db.exec('set role authenticated');
      assert.equal((await query('select count(*)::int as n from pde_misc_incomes'))[0].n,0);
      await db.exec('reset role');
      await query("update organization_members set organization_id=$1",[org]);
    });

    await t.test('cancellation is repeatable and audited; money leaves the balance but history and receipt remain',async()=>{
      await assert.rejects(query('select void_pde_misc_income($1,$2)',[otherOrg,first.id]),/permisos/);
      await query("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[otherOrg,actor]);
      await assert.rejects(query('select void_pde_misc_income($1,$2)',[otherOrg,first.id]),/no existe/);
      for(let i=0;i<2;i++)await query("select void_pde_misc_income($1,$2,'Error de carga')",[org,first.id]);
      const [row]=await query('select * from pde_misc_incomes where id=$1',[first.id]);assert.equal(row.status,'voided');assert.equal(Number(row.amount),1500.25);
      assert.equal((await query("select count(*)::int as n from audit_logs where action='pde_misc_income_voided'"))[0].n,1);
      assert.equal((await query('select count(*)::int as n from file_links where entity_id=$1',[first.id]))[0].n,1);
      assert.equal((await report()).totals.USD.incomes,0.01);
      assert.equal((await query('select get_pde_data($1) as data',[org]))[0].data.miscIncomes.length,1);
    });
  }finally{await db.close()}
});
